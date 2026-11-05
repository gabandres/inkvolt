using MuPDFCore;
using MuPDFCore.StructuredText;

namespace InkvoltPdf.Core;

/// <summary>
/// Page checks (<see cref="PageChecks"/>): before MuPDF runs a page's content in this process (a render, the text, an
/// export, Find), the page has been drawn within the limit in a check process, once per engine. A page refused there
/// throws <see cref="PageRefusedException"/> from every one of those calls, at once.
/// </summary>
public sealed partial class PdfEngine
{
    /// <summary>Test hook: this engine's own check processes instead of the app's.</summary>
    internal PageCheckPlan? CheckPlan { get; set; }

    private readonly Lock _checkGate = new();
    private byte[]? _verdicts;                  // PageVerdicts; written under _checkGate, read without it
    private CheckRequest?[]? _checking;         // under _checkGate
    private CheckedDocument? _checked;          // under _checkGate
    private PageCheckPlan? _checkedBy;          // under _checkGate

    /// <summary>Test hook: what the check of each page found so far.</summary>
    internal PageVerdict VerdictOf(int page) => Volatile.Read(ref _verdicts) is { } v ? (PageVerdict)Volatile.Read(ref v[page]) : PageVerdict.Unknown;

    /// <summary>
    /// Returns once this process may run <paramref name="page"/>'s content: its check found it fine (now or before), or no
    /// check can be had (no check processes, none starting now, a document a check process can't open from here: one with
    /// a password, or not a PDF). Waits for the check, which is shared by every caller asking about the page meanwhile.
    /// </summary>
    /// <exception cref="PageRefusedException">The page took too long in its check, MuPDF gave up on it there, or it ended the check process.</exception>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired while the check went on (it goes on without the caller).</exception>
    private void Vet(int page, CancellationToken cancel)
    {
        if (Volatile.Read(ref _verdicts) is { } known)
            switch ((PageVerdict)Volatile.Read(ref known[page]))
            {
                case PageVerdict.Fine: return;
                case var v when PageRefusedException.Refuses(v): throw new PageRefusedException(page, v);
            }
        CheckRequest request;
        PageCheckPlan plan;
        lock (_checkGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (ChecksPlan() is not { } p) return;
            plan = p;
            if ((PageVerdict)_verdicts![page] != PageVerdict.Unknown)
            {
                Decided(page);
                return;
            }
            request = _checking![page] ??= plan.Ask(_checked!, page);
            request.Speculative = false;
            request.Waiters++;
            // The next page is checked meanwhile: scrolling, Find and thumbnails go on in page order.
            AskAhead(page + 1);
        }
        try
        {
            request.Done.Wait(cancel);
        }
        finally
        {
            lock (_checkGate)
            {
                if (--request.Waiters == 0 && !request.Done.IsCompleted && plan.Withdraw(request) && _checking![page] == request)
                    _checking[page] = null;
            }
        }
        lock (_checkGate)
        {
            if (_checking![page] == request)
            {
                _checking[page] = null;
                // A check that couldn't be had (no check process started, the engine went away, the wait was given up)
                // decides nothing: the page runs now, and is asked about again next time (PageCheckPlan: failing open).
                if (request.Result != PageVerdict.Unchecked) Volatile.Write(ref _verdicts![page], (byte)request.Result);
            }
            Decided(page);
        }
    }

    /// <summary>The plan this engine's pages are checked by, its state made on first use; null when they aren't. Under _checkGate.</summary>
    private PageCheckPlan? ChecksPlan()
    {
        if (_checkedBy is not null) return _checkedBy;
        if (_source is null || (CheckPlan ?? PageChecks.Plan) is not { } plan) return null;
        _checkedBy = plan;
        _checked = new CheckedDocument(_source.Data, _source.Path, _source.Type, _pages.Length);
        _checking = new CheckRequest?[_pages.Length];
        Volatile.Write(ref _verdicts, new byte[_pages.Length]);
        return plan;
    }

    /// <summary>Asks for a check of <paramref name="page"/> that no one waits for yet, unless it is known or asked for. Under _checkGate.</summary>
    private void AskAhead(int page)
    {
        if (page < 0 || page >= _pages.Length || _checkedBy is not { } plan) return;
        if ((PageVerdict)_verdicts![page] != PageVerdict.Unknown || _checking![page] is not null) return;
        _checking[page] = plan.Ask(_checked!, page, speculative: true);
    }

    /// <summary>The first page is checked as the document opens, while the app gets ready to show it.</summary>
    private void CheckFirstPage()
    {
        lock (_checkGate)
        {
            if (!_disposed && ChecksPlan() is not null) AskAhead(0);
        }
    }

    /// <summary>Returns or throws as the page's verdict says. Under _checkGate.</summary>
    private void Decided(int page)
    {
        if ((PageVerdict)_verdicts![page] is var v && PageRefusedException.Refuses(v)) throw new PageRefusedException(page, v);
    }

    /// <summary>Whether a page is refused already (Find doesn't hand it to a worker): without asking for a check.</summary>
    private bool IsRefused(int page) => PageRefusedException.Refuses(VerdictOf(page));

    /// <summary>
    /// In a check process: decodes each picture on <paramref name="page"/> of more than <paramref name="abovePixels"/> at its
    /// full size. Drawing the page small decodes a JPEG at an eighth of its size and a JPEG 2000 at its smallest level, so
    /// what an export (pictures at their own size) or a deep zoom costs here is only found out this way.
    /// </summary>
    /// <exception cref="MuPDFException">MuPDF couldn't decode one (its memory past the process's limit, say).</exception>
    internal void DecodeLargePictures(int page, long abovePixels)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var st = _doc.GetStructuredTextPage(page, includeAnnotations: true, StructuredTextFlags.PreserveImages);
            foreach (var block in st)
                if (block is MuPDFImageStructuredTextBlock { Image: { } image } && (long)image.Width * image.Height > abovePixels)
                    _ = image.GetBytes(PixelFormats.RGB);
        }
    }

    /// <summary>The engine is going away: its checks end, and the check processes let go of its document.</summary>
    private void ForgetChecks()
    {
        PageCheckPlan? plan;
        CheckedDocument? doc;
        lock (_checkGate)
        {
            plan = _checkedBy;
            doc = _checked;
        }
        if (plan is not null && doc is not null) plan.Forget(doc);
    }
}
