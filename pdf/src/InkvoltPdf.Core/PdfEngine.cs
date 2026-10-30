using System.Reflection;
using System.Runtime.InteropServices;
using MuPDFCore;
using MuPDFCore.StructuredText;

namespace InkvoltPdf.Core;

/// <summary>An edit needs the document's permissions (owner) password: it was opened without it, or the one given is wrong.</summary>
public sealed class OwnerPasswordRequiredException(bool wrongPassword, Exception? inner = null)
    : Exception(wrongPassword ? "Incorrect permissions password." : "Editing this PDF needs its permissions (owner) password.", inner)
{
    public bool WrongPassword { get; } = wrongPassword;
}

public sealed class PasswordRequiredException(bool wrongPassword) : Exception(wrongPassword ? "Incorrect password." : "This document is password protected.")
{
    public bool WrongPassword { get; } = wrongPassword;
}

/// <summary>A bookmark. TargetY: where on the page it leads (page space, points from the top), when the destination says.</summary>
public sealed record OutlineNode(string Title, int PageIndex, IReadOnlyList<OutlineNode> Children, double? TargetY = null);

/// <summary>
/// A clickable area on a page: either an internal jump (PageIndex, plus TargetY in the target page's space when the
/// destination names a position) or an external URI.
/// </summary>
public sealed record PageLink(RectD Area, int PageIndex, string? Uri, double? TargetY = null);

/// <summary>Pixels from a render, packed BGR24 (tight stride = Width * 3).</summary>
public sealed record RenderedImage(int Width, int Height, byte[] Pixels)
{
    public int Stride => Width * 3;

    /// <summary>The image turned clockwise by <paramref name="rotation"/> (0, 90, 180 or 270); itself for 0.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired (checked every few rows).</exception>
    public RenderedImage Rotated(int rotation, CancellationToken cancel = default)
    {
        rotation = RotatedView.Normalize(rotation);
        if (rotation == 0) return this;
        var (w, h) = rotation == 180 ? (Width, Height) : (Height, Width);
        var dst = GC.AllocateUninitializedArray<byte>(Pixels.Length);
        var src = Pixels;
        int sw = Width, sh = Height, dstStride = w * 3;
        for (var y = 0; y < sh; y++)
        {
            if ((y & 63) == 0) cancel.ThrowIfCancellationRequested();
            var s = y * sw * 3;
            for (var x = 0; x < sw; x++, s += 3)
            {
                // Clockwise: 90 sends (x, y) to (h' - 1 - y, x); 180 to (w - 1 - x, h - 1 - y); 270 to (y, w - 1 - x).
                var (dx, dy) = rotation switch
                {
                    90 => (sh - 1 - y, x),
                    180 => (sw - 1 - x, sh - 1 - y),
                    _ => (y, sw - 1 - x),
                };
                var d = dy * dstStride + dx * 3;
                dst[d] = src[s];
                dst[d + 1] = src[s + 1];
                dst[d + 2] = src[s + 2];
            }
        }
        return new RenderedImage(w, h, dst);
    }
}

/// <summary>
/// One open document in MuPDF. MuPDF is not thread-safe per document, so every call takes a lock; callers may use
/// it from any thread (renders run on a background worker, hit-testing on the UI thread). Text, links and outline
/// come from a second MuPDF instance of the same file with its own lock, so the UI never waits behind a render.
/// Each instance keeps only the most recently used pages loaded (<see cref="LoadedPages"/>), so native memory stays
/// bounded however far a long document is scrolled.
/// </summary>
public sealed class PdfEngine : IDisposable
{
    private const int TextCacheSize = 48;

    /// <summary>MuPDF pages (with their display lists) kept loaded per instance; older ones are freed.</summary>
    internal const int LoadedPagesKept = 32;

    /// <summary>Largest render or image export allowed, in pixels (200 MP is 600 MB of BGR).</summary>
    public const long MaxPixels = 200_000_000;

    // Lock order: _gate, _textGate, _readerGate, a reader's Gate (only Dispose and the LoadedCounts test hook take more
    // than one; FindAll's workers hold a reader's Gate alone).
    private readonly Lock _gate = new();
    private readonly Lock _textGate = new();
    private readonly MuPDFContext _ctx;
    private readonly MuPDFDocument _doc;
    private readonly LoadedPages _loaded;     // under _gate
    private readonly Func<MuPDFContext, MuPDFDocument> _reopen;
    private IntPtr[]? _clones;                // contexts cloned from _ctx for strip renders, under _gate
    private readonly string? _password;
    private MuPDFContext? _textCtx;
    private MuPDFDocument? _textDoc;
    private LoadedPages? _textLoaded;         // under _textGate
    private readonly PageGeometry[] _pages;
    private readonly Dictionary<int, PageText> _textCache = [];
    private readonly LinkedList<int> _textLru = [];
    private readonly Dictionary<int, PageLink[]> _links = [];
    // What each page's text reads as, once read: kept for the engine's lifetime (an edit makes a new engine), so Find
    // skips pages that can't match without reading them again. Written once per page (Interlocked).
    private readonly string?[] _pageStrings;
    private long _rememberedChars;
    // Whole page texts (with their boxes) kept for the engine's lifetime while they are few characters in all (a drawing
    // set's title blocks): a later search or selection on them never goes back to MuPDF. Written once per page.
    private readonly PageText?[] _pageTexts;
    private long _keptChars;
    // Extra MuPDF instances for reading many pages' text at once (FindAll), each with its own lock (reader.Gate).
    private readonly Lock _readerGate = new();
    private readonly List<TextReader> _readers = [];       // every one opened, under _readerGate
    private readonly Stack<TextReader> _idleReaders = [];  // under _readerGate
    private int _extractions;
    // What a lone accent glyph actually draws ("=" under the name "dotaccent"), by font, text and size: rendered once.
    private readonly System.Collections.Concurrent.ConcurrentDictionary<(string Font, string Text, double Size), string?> _drawnAs = new();
    private IReadOnlyList<OutlineNode>? _outline;
    private volatile bool _disposed;

    public int PageCount => _pages.Length;
    public bool IsEncrypted { get; }

    /// <param name="reopen">Opens the same document again in another context (for the text instance).</param>
    private PdfEngine(MuPDFContext ctx, MuPDFDocument doc, bool encrypted, Func<MuPDFContext, MuPDFDocument> reopen, string? password)
    {
        _ctx = ctx;
        _doc = doc;
        IsEncrypted = encrypted;
        _reopen = reopen;
        _password = password;
        _loaded = new LoadedPages(doc, LoadedPagesKept);
        _pages = new PageGeometry[doc.Pages.Count];
        _pageStrings = new string?[_pages.Length];
        _pageTexts = new PageText?[_pages.Length];
        for (var i = 0; i < _pages.Length; i++)
        {
            _loaded.Touch(i); // reading every page's size loads it: keep only the last few
            var b = doc.Pages[i].Bounds;
            _pages[i] = new PageGeometry(b.X0, b.Y0, b.Width, b.Height);
        }
    }

    /// <exception cref="PasswordRequiredException">The document is encrypted and the password is missing or wrong.</exception>
    public static PdfEngine Open(byte[] data, InputFileTypes type, string? password) =>
        Open(c => new MuPDFDocument(c, data, type), password);

    /// <summary>
    /// Opens a file in place: MuPDF reads it as pages need it, so a big file isn't read into memory. The file stays
    /// open (readable by others, but not replaceable) until the engine is disposed.
    /// </summary>
    /// <exception cref="PasswordRequiredException">The document is encrypted and the password is missing or wrong.</exception>
    public static PdfEngine OpenFile(string path, InputFileTypes type, string? password) =>
        Open(c => new MuPDFDocument(c, path), password);

    private static PdfEngine Open(Func<MuPDFContext, MuPDFDocument> create, string? password)
    {
        // MuPDF's resource cache (decoded images, fonts) defaults to 256 MB per document; 128 MB keeps re-renders fast
        // without letting several open tabs balloon.
        var ctx = new MuPDFContext(128 * 1024 * 1024);
        MuPDFDocument? doc = null;
        try
        {
            doc = NewDocument(ctx, () => create(ctx));
            var encrypted = doc.EncryptionState != EncryptionState.Unencrypted;
            if (doc.EncryptionState == EncryptionState.Encrypted)
            {
                if (string.IsNullOrEmpty(password)) throw new PasswordRequiredException(false);
                if (!Unlock(doc, password)) throw new PasswordRequiredException(true);
            }
            return new PdfEngine(ctx, doc, encrypted, c => NewDocument(c, () => create(c)), password);
        }
        catch
        {
            if (doc is not null) DisposeDocument(doc);
            ctx.Dispose();
            throw;
        }
    }

    /// <summary>Opens a file in place (MuPDF reads only what it needs), e.g. for a quick preview. Null if it is encrypted.</summary>
    public static PdfEngine? OpenPreview(string path)
    {
        var ctx = new MuPDFContext(32 * 1024 * 1024);
        MuPDFDocument? doc = null;
        try
        {
            doc = NewDocument(ctx, () => new MuPDFDocument(ctx, path));
            if (doc.EncryptionState == EncryptionState.Encrypted)
            {
                DisposeDocument(doc);
                ctx.Dispose();
                return null;
            }
            return new PdfEngine(ctx, doc, false, c => NewDocument(c, () => new MuPDFDocument(c, path)), null);
        }
        catch
        {
            if (doc is not null) DisposeDocument(doc);
            ctx.Dispose();
            throw;
        }
    }

    public static InputFileTypes TypeFromPath(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".xps" or ".oxps" => InputFileTypes.XPS,
        ".epub" => InputFileTypes.EPUB,
        ".cbz" => InputFileTypes.CBZ,
        ".fb2" => InputFileTypes.FB2,
        ".mobi" => InputFileTypes.MOBI,
        ".png" => InputFileTypes.PNG,
        ".jpg" or ".jpeg" => InputFileTypes.JPEG,
        ".bmp" => InputFileTypes.BMP,
        ".gif" => InputFileTypes.GIF,
        ".tif" or ".tiff" => InputFileTypes.TIFF,
        _ => InputFileTypes.PDF,
    };

    public PageGeometry GetPage(int index) => _pages[index];

    /// <summary>Renders a page (or a region of it, in page points) at <paramref name="scale"/> pixels per point.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired (MuPDF stops mid-render).</exception>
    /// <exception cref="InvalidOperationException">The image would exceed <see cref="MaxPixels"/>.</exception>
    /// <param name="annotations">Whether comments, stamps and form fields are drawn (false: the page's own content only).</param>
    public RenderedImage Render(int page, double scale, RectD? region = null, CancellationToken cancel = default, bool annotations = true)
    {
        cancel.ThrowIfCancellationRequested();
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            cancel.ThrowIfCancellationRequested();
            _loaded.Touch(page);
            var g = _pages[page];
            var r = region ?? new RectD(0, 0, g.Width, g.Height);
            var area = new Rectangle(g.OriginX + r.X, g.OriginY + r.Y, g.OriginX + r.Right, g.OriginY + r.Bottom);
            var px = area.Round(scale);
            CheckSize(px.Width, px.Height);
            var bytes = MuPDFDocument.GetRenderedSize(area, scale, PixelFormats.BGR);
            if (bytes != px.Width * px.Height * 3)
                throw new InvalidOperationException($"Unexpected render buffer size {bytes} for {px.Width}x{px.Height}.");
            var pixels = GC.AllocateUninitializedArray<byte>(bytes);
            unsafe
            {
                fixed (byte* p = pixels)
                {
                    _clones ??= AbortableRender.Clone(_ctx, StripThreads);
                    if (!annotations) _doc.Render(page, area, scale, PixelFormats.BGR, (IntPtr)p, includeAnnotations: false);
                    else if (!AbortableRender.TryRender(_ctx, _doc, page, area, scale, (IntPtr)p, cancel, _clones))
                        _doc.Render(page, area, scale, PixelFormats.BGR, (IntPtr)p, includeAnnotations: true);
                    cancel.ThrowIfCancellationRequested();
                }
            }
            return new RenderedImage(px.Width, px.Height, pixels);
        }
    }

    /// <summary>Renders a page straight to a PNG or JPEG file at the given resolution.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired before the render started.</exception>
    /// <exception cref="InvalidOperationException">The image would exceed <see cref="MaxPixels"/>.</exception>
    public void SaveImage(int page, double dpi, string path, bool jpeg, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            cancel.ThrowIfCancellationRequested();
            var scale = dpi / 72.0;
            var g = _pages[page];
            CheckSize(Math.Ceiling(g.Width * scale), Math.Ceiling(g.Height * scale));
            _loaded.Touch(page);
            if (jpeg) _doc.SaveImageAsJPEG(page, scale, path, 90, includeAnnotations: true);
            else _doc.SaveImage(page, scale, PixelFormats.RGB, path, RasterOutputFileTypes.PNG, includeAnnotations: true);
        }
    }

    /// <summary>
    /// Threads a large render is split across (horizontal strips, each on a context cloned from the render instance's).
    /// A drawing sheet's 72,000 paths rasterize about 2.4 times as fast on four; more gain little, as MuPDFCore's native
    /// wrapper serializes MuPDF's allocations.
    /// </summary>
    internal static int StripThreads { get; set; } = Math.Clamp(Environment.ProcessorCount / 3, 1, 4);

    /// <summary>Renders with fewer pixels than this run on one thread.</summary>
    internal static long StripMinPixels { get; set; } = 200_000;

    /// <summary>
    /// MuPDF renders stop early when their "cookie" says abort, but MuPDFCore's public Render passes no cookie (and the
    /// Abort of its multi-threaded renderer blocks until the render is done). This calls the native entry point
    /// MuPDFDocument.Render uses, the same way, with a cookie, and splits a large render into strips on cloned contexts.
    /// Pinned to MuPDFCore 2.0.1's internals: if they differ, TryRender returns false and the caller renders without
    /// mid-render abort, on one thread.
    /// </summary>
    private static class AbortableRender
    {
        private delegate int RenderSubDisplayList(IntPtr ctx, IntPtr list, float x0, float y0, float x1, float y1, float zoom, int format, IntPtr pixels, IntPtr cookie);

        private const BindingFlags Internal = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
        private static readonly RenderSubDisplayList? Native;
        private static readonly FieldInfo? DisplayLists, NativeList, NativeContext, XRes, YRes;
        private static readonly ConstructorInfo? NewList;
        private static readonly MethodInfo? CloneContexts, DisposeContext;

        static AbortableRender()
        {
            try
            {
                var asm = typeof(MuPDFDocument).Assembly;
                var listType = asm.GetType("MuPDFCore.MuPDFDisplayList");
                var native = asm.GetType("MuPDFCore.NativeMethods")?.GetMethod("RenderSubDisplayList", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
                DisplayLists = typeof(MuPDFDocument).GetField("DisplayLists", Internal);
                XRes = typeof(MuPDFDocument).GetField("ImageXRes", Internal);
                YRes = typeof(MuPDFDocument).GetField("ImageYRes", Internal);
                NativeContext = typeof(MuPDFContext).GetField("NativeContext", Internal);
                NativeList = listType?.GetField("NativeDisplayList", Internal);
                NewList = listType?.GetConstructor(Internal, [typeof(MuPDFContext), typeof(MuPDFPage), typeof(bool)]);
                var methods = asm.GetType("MuPDFCore.NativeMethods");
                CloneContexts = methods?.GetMethod("CloneContext", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public, [typeof(IntPtr), typeof(int), typeof(IntPtr)]);
                DisposeContext = methods?.GetMethod("DisposeContext", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public, [typeof(IntPtr)]);
                if (CloneContexts?.ReturnType != typeof(int)) CloneContexts = null;
                if (native is null || DisplayLists?.FieldType.GetElementType() != listType || XRes?.FieldType != typeof(double) || YRes?.FieldType != typeof(double) ||
                    NativeContext?.FieldType != typeof(IntPtr) || NativeList?.FieldType != typeof(IntPtr) || NewList is null)
                    return;
                Native = native.CreateDelegate<RenderSubDisplayList>();
            }
            catch (Exception ex) when (ex is ArgumentException or MemberAccessException or TypeLoadException)
            {
                Native = null;
            }
        }

        /// <summary>
        /// <paramref name="count"/> contexts cloned from <paramref name="ctx"/> (sharing its resource store), for rendering
        /// on other threads; empty when they can't be made. Free them with <see cref="Free"/> before disposing ctx.
        /// </summary>
        public static IntPtr[] Clone(MuPDFContext ctx, int count)
        {
            if (Native is null || CloneContexts is null || DisposeContext is null || count < 2) return [];
            var buffer = Marshal.AllocHGlobal(IntPtr.Size * count);
            try
            {
                if ((int)CloneContexts.Invoke(null, [(IntPtr)NativeContext!.GetValue(ctx)!, count, buffer])! != 0) return [];
                var clones = new IntPtr[count];
                for (var i = 0; i < count; i++) clones[i] = Marshal.ReadIntPtr(buffer, i * IntPtr.Size);
                return clones;
            }
            catch (Exception ex) when (ex is TargetInvocationException or ArgumentException or MemberAccessException)
            {
                return [];
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void Free(IntPtr[] clones)
        {
            foreach (var c in clones) DisposeContext?.Invoke(null, [c]);
        }

        /// <summary>
        /// Renders like MuPDFDocument.Render (BGR, with annotations), in strips on <paramref name="clones"/> when it is
        /// large; false if it can't (then nothing was drawn).
        /// </summary>
        /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired; the pixels are incomplete.</exception>
        public static bool TryRender(MuPDFContext ctx, MuPDFDocument doc, int page, Rectangle area, double scale, IntPtr pixels, CancellationToken cancel,
            IntPtr[] clones)
        {
            if (Native is null || (double)XRes!.GetValue(doc)! != 72 || (double)YRes!.GetValue(doc)! != 72) return false;
            // Regions reaching outside the page get clipped by MuPDFCore after rendering: leave those to it.
            var b = doc.Pages[page].Bounds;
            if (area.X0 < b.X0 - 0.01 || area.Y0 < b.Y0 - 0.01 || area.X1 > b.X1 + 0.01 || area.Y1 > b.Y1 + 0.01) return false;
            if (DisplayLists!.GetValue(doc) is not Array lists) return false;
            var list = lists.GetValue(page);
            if (list is null)
            {
                list = NewList!.Invoke([ctx, doc.Pages[page], true]);
                lists.SetValue(list, page);
            }
            var nativeList = (IntPtr)NativeList!.GetValue(list)!;
            var px = area.Round(scale);
            if (clones.Length > 1 && (long)px.Width * px.Height >= StripMinPixels && px.Height >= 8 * clones.Length
                && RenderStrips(clones, nativeList, area, px, scale, pixels, page, cancel))
                return true;

            var cookie = Marshal.AllocHGlobal(64); // fz_cookie is 24 bytes on 64-bit
            try
            {
                for (var i = 0; i < 64; i += 4) Marshal.WriteInt32(cookie, i, 0);
                int result;
                using (cancel.Register(() => Marshal.WriteInt32(cookie, 0, 1)))
                {
                    result = Native((IntPtr)NativeContext!.GetValue(ctx)!, nativeList,
                        area.X0, area.Y0, area.X1, area.Y1, (float)scale, (int)PixelFormats.BGR, pixels, cookie);
                }
                cancel.ThrowIfCancellationRequested();
                if (result != 0) throw new InvalidOperationException($"MuPDF could not render page {page + 1} (error {result}).");
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(cookie);
            }
        }

        /// <summary>
        /// The render as horizontal strips, one per clone, run at once. Each strip reaches half a pixel into its neighbours
        /// (so no strip edge falls where float rounding could move it) and only its whole rows are kept: a row at a strip's
        /// edge may miss shapes that lie outside the strip, the next strip draws it whole. False (nothing drawn) if a
        /// strip's pixel box isn't what the split expects.
        /// </summary>
        private static unsafe bool RenderStrips(IntPtr[] clones, IntPtr list, Rectangle area, RoundedRectangle px, double scale, IntPtr pixels, int page,
            CancellationToken cancel)
        {
            var n = clones.Length;
            var stride = px.Width * 3;
            var strips = new (Rectangle Area, int From, int To, int Top, int Rows)[n];
            for (var k = 0; k < n; k++)
            {
                var from = px.Y0 + (int)((long)px.Height * k / n);
                var to = px.Y0 + (int)((long)px.Height * (k + 1) / n);
                var a = new Rectangle(area.X0, k == 0 ? area.Y0 : (from - 0.5) / scale, area.X1, k == n - 1 ? area.Y1 : (to + 0.5) / scale);
                var b = a.Round(scale);
                if (b.X0 != px.X0 || b.X1 != px.X1 || b.Y0 > from || b.Y1 < to || b.Y0 < from - 1 || b.Y1 > to + 1
                    || MuPDFDocument.GetRenderedSize(a, scale, PixelFormats.BGR) != (long)b.Width * b.Height * 3)
                    return false;
                strips[k] = (a, from, to, b.Y0, b.Height);
            }

            var cookies = new IntPtr[n];
            for (var k = 0; k < n; k++)
            {
                cookies[k] = Marshal.AllocHGlobal(64);
                for (var i = 0; i < 64; i += 4) Marshal.WriteInt32(cookies[k], i, 0);
            }
            var failed = 0;
            try
            {
                using (cancel.Register(() => { foreach (var c in cookies) Marshal.WriteInt32(c, 0, 1); }))
                {
                    Parallel.For(0, n, new ParallelOptions { MaxDegreeOfParallelism = n }, k =>
                    {
                        var s = strips[k];
                        var strip = GC.AllocateUninitializedArray<byte>(s.Rows * stride);
                        fixed (byte* p = strip)
                        {
                            var r = Native!(clones[k], list, s.Area.X0, s.Area.Y0, s.Area.X1, s.Area.Y1, (float)scale, (int)PixelFormats.BGR, (IntPtr)p, cookies[k]);
                            if (r != 0)
                            {
                                Interlocked.Exchange(ref failed, r);
                                return;
                            }
                            var bytes = (long)(s.To - s.From) * stride;
                            Buffer.MemoryCopy(p + (long)(s.From - s.Top) * stride, (byte*)pixels + (long)(s.From - px.Y0) * stride, bytes, bytes);
                        }
                    });
                }
                cancel.ThrowIfCancellationRequested();
                if (failed != 0) throw new InvalidOperationException($"MuPDF could not render page {page + 1} (error {failed}).");
                return true;
            }
            finally
            {
                foreach (var c in cookies) Marshal.FreeHGlobal(c);
            }
        }
    }

    /// <summary>
    /// Unlocks an encrypted document. MuPDFCore leaves a document unlocked with its owner (permissions) password marked
    /// as encrypted, so every page access would still throw; MuPDF itself has accepted the password by then.
    /// </summary>
    private static bool Unlock(MuPDFDocument doc, string password)
    {
        if (!doc.TryUnlock(password, out var kind)) return false;
        if (doc.EncryptionState == EncryptionState.Encrypted && kind.HasFlag(PasswordTypes.Owner))
            typeof(MuPDFDocument).GetProperty(nameof(MuPDFDocument.EncryptionState))?.SetMethod?.Invoke(doc, [EncryptionState.Unlocked]);
        return doc.EncryptionState != EncryptionState.Encrypted;
    }

    private static void CheckSize(double width, double height)
    {
        if (width * height > MaxPixels)
            throw new InvalidOperationException($"The image would be too large ({width:0} x {height:0} pixels). Use a lower zoom or resolution.");
    }

    /// <summary>The text instance of the document, opened on first use. Call under _textGate.</summary>
    private MuPDFDocument TextDoc()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_textDoc is not null) return _textDoc;
        var (ctx, doc) = OpenAgain();
        _textCtx = ctx;
        _textLoaded = new LoadedPages(doc, LoadedPagesKept);
        return _textDoc = doc;
    }

    /// <summary>Another MuPDF instance of the same document, unlocked, in a context of its own.</summary>
    private (MuPDFContext, MuPDFDocument) OpenAgain()
    {
        var ctx = new MuPDFContext(32 * 1024 * 1024);
        MuPDFDocument? doc = null;
        try
        {
            doc = _reopen(ctx);
            if (doc.EncryptionState == EncryptionState.Encrypted && !Unlock(doc, _password ?? ""))
                throw new PasswordRequiredException(true);
            if (doc.Pages.Count != _pages.Length) throw new InvalidOperationException("The document changed while open.");
            return (ctx, doc);
        }
        catch
        {
            if (doc is not null) DisposeDocument(doc);
            ctx.Dispose();
            throw;
        }
    }

    /// <summary>The text instance with <paramref name="page"/> marked as just used. Call under _textGate.</summary>
    private MuPDFDocument TextDoc(int page)
    {
        var doc = TextDoc();
        _textLoaded!.Touch(page);
        return doc;
    }

    /// <summary>
    /// Takes the text lock. While another page's text is being read it waits, but gives up as soon as
    /// <paramref name="cancel"/> fires (a cancelled job doesn't queue up behind a long extraction).
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    private void EnterText(CancellationToken cancel)
    {
        if (!cancel.CanBeCanceled)
        {
            _textGate.Enter();
            return;
        }
        while (!_textGate.TryEnter(20)) cancel.ThrowIfCancellationRequested();
        if (!cancel.IsCancellationRequested) return;
        _textGate.Exit();
        cancel.ThrowIfCancellationRequested();
    }

    /// <summary>The page's text layer (cached; cheap to call repeatedly from the UI).</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired before the page was read.</exception>
    public PageText GetText(int page, bool cache = true, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        EnterText(cancel);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (Volatile.Read(ref _pageTexts[page]) is { } kept) return kept;
            if (_textCache.TryGetValue(page, out var hit))
            {
                _textLru.Remove(page);
                _textLru.AddFirst(page);
                return hit;
            }

            var text = ExtractText(TextDoc(page), page);
            Remember(page, text);
            if (cache)
            {
                _textCache[page] = text;
                _textLru.AddFirst(page);
                while (_textLru.Count > TextCacheSize)
                {
                    _textCache.Remove(_textLru.Last!.Value);
                    _textLru.RemoveLast();
                }
            }
            return text;
        }
        finally
        {
            _textGate.Exit();
        }
    }

    /// <summary>A page's text layer read from <paramref name="doc"/> (the text instance or a reader), under its lock.</summary>
    private PageText ExtractText(MuPDFDocument doc, int page)
    {
        Interlocked.Increment(ref _extractions);
        var g = _pages[page];
        var lines = new List<List<(string, RectD)>>();
        var directions = new List<(double, double)>();
        using var st = doc.GetStructuredTextPage(page, includeAnnotations: false);
        foreach (var block in st)
        {
            if (block is not MuPDFTextStructuredTextBlock tb) continue;
            foreach (var line in tb)
            {
                var chars = new List<(string, RectD)>();
                foreach (var ch in line)
                {
                    var q = ch.BoundingQuad;
                    var l = Math.Min(Math.Min(q.UpperLeft.X, q.LowerLeft.X), Math.Min(q.UpperRight.X, q.LowerRight.X));
                    var r = Math.Max(Math.Max(q.UpperLeft.X, q.LowerLeft.X), Math.Max(q.UpperRight.X, q.LowerRight.X));
                    var t = Math.Min(Math.Min(q.UpperLeft.Y, q.LowerLeft.Y), Math.Min(q.UpperRight.Y, q.LowerRight.Y));
                    var b = Math.Max(Math.Max(q.UpperLeft.Y, q.LowerLeft.Y), Math.Max(q.UpperRight.Y, q.LowerRight.Y));
                    chars.Add((ch.Character, RectD.FromEdges(l - g.OriginX, t - g.OriginY, r - g.OriginX, b - g.OriginY)));
                }
                lines.Add(chars);
                directions.Add((line.Direction.X, line.Direction.Y)); // the baseline's direction (sideways text: vertical)
            }
        }
        return new PageText(lines, directions);
    }

    /// <summary>Page text remembered as strings, in UTF-16 units across all pages (about 128 MB): beyond it, pages are read again.</summary>
    private const long MaxRememberedChars = 64_000_000;

    /// <summary>Pages <see cref="FindAll"/>'s workers may read ahead of the caller.</summary>
    private const int FindReadAhead = 64;

    /// <summary>
    /// Threads (each with its own MuPDF instance) <see cref="FindAll"/> reads pages on. Two, not one per core: MuPDFCore's
    /// native wrapper guards MuPDF's allocations with process-wide mutexes, so instances in one process wait on each other
    /// (four threads take four times the CPU of one for no gain; four processes run four times as fast). The second
    /// thread overlaps one page's MuPDF work with another's conversion (about 15% on a long text).
    /// </summary>
    internal static int FindThreads { get; set; } = Math.Min(2, Environment.ProcessorCount);

    /// <summary>Test hook: pages whose text was read from MuPDF so far (any instance).</summary>
    internal int Extractions => Volatile.Read(ref _extractions);

    /// <summary>
    /// Characters of whole page texts kept for the engine's lifetime (about 40 MB with their boxes): a drawing set's 400
    /// sheets keep theirs; a long book keeps its strings only.
    /// </summary>
    internal static long KeptTextChars { get; set; } = 1_000_000;

    private void Remember(int page, PageText text)
    {
        var length = text.Text.Length;
        if (Interlocked.Read(ref _keptChars) + length <= KeptTextChars && Interlocked.CompareExchange(ref _pageTexts[page], text, null) is null)
            Interlocked.Add(ref _keptChars, length);
        if (Interlocked.Read(ref _rememberedChars) + length > MaxRememberedChars) return;
        if (Interlocked.CompareExchange(ref _pageStrings[page], text.Text, null) is null) Interlocked.Add(ref _rememberedChars, length);
    }

    /// <summary>One page's outcome in <see cref="FindAll"/>: its matches (and its text when there are any), or why it couldn't be read.</summary>
    public sealed record PageMatches(int Page, PageText? Text, IReadOnlyList<(int Start, int End)> Hits, Exception? Error = null);

    /// <summary>
    /// <see cref="PageText.Find"/> on every page, as one search: pages are read on <see cref="FindThreads"/> threads (each
    /// with its own MuPDF instance) and come back in page order as soon as each page and those
    /// before it are done, so the first matches show before the end. A page whose text was read before (by any call) and
    /// can't match is not read again, nor one whose whole text is kept. A page that can't be read comes back with its <see cref="PageMatches.Error"/>.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="ObjectDisposedException">The engine was disposed (the document changed) meanwhile.</exception>
    public IEnumerable<PageMatches> FindAll(string query, bool matchCase, bool wholeWord, bool ignoreAccents = false, CancellationToken cancel = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var count = _pages.Length;
        if (count == 0) yield break;
        var results = new PageMatches?[count];
        var sync = new object();
        int next = -1, consumed = 0;
        var stop = false;
        var workers = new Thread[Math.Min(FindThreads, count)];
        for (var t = 0; t < workers.Length; t++)
        {
            workers[t] = new Thread(Work) { IsBackground = true, Priority = ThreadPriority.Normal, Name = "Inkvolt PDF find" };
            workers[t].Start();
        }
        try
        {
            for (var i = 0; i < count; i++)
            {
                PageMatches? r;
                cancel.ThrowIfCancellationRequested();
                lock (sync)
                {
                    while ((r = results[i]) is null)
                    {
                        cancel.ThrowIfCancellationRequested();
                        Monitor.Wait(sync, 50);
                    }
                    results[i] = null;
                    consumed = i + 1;
                    Monitor.PulseAll(sync);
                }
                if (r.Error is ObjectDisposedException) throw new ObjectDisposedException(nameof(PdfEngine), r.Error);
                yield return r;
            }
        }
        finally
        {
            lock (sync)
            {
                stop = true;
                Monitor.PulseAll(sync);
            }
            foreach (var w in workers) w.Join();
        }

        void Work()
        {
            TextReader? reader = null;
            try
            {
                while (true)
                {
                    int i;
                    lock (sync)
                    {
                        if (stop || next + 1 >= count) return;
                        i = ++next;
                        while (!stop && i >= consumed + FindReadAhead) Monitor.Wait(sync);
                        if (stop) return;
                    }
                    if (cancel.IsCancellationRequested) return;
                    PageMatches m;
                    try
                    {
                        m = FindOn(ref reader, i, query, matchCase, wholeWord, ignoreAccents);
                    }
                    catch (Exception ex)
                    {
                        m = new PageMatches(i, null, [], ex);
                    }
                    lock (sync)
                    {
                        results[i] = m;
                        Monitor.PulseAll(sync);
                    }
                    if (m.Error is ObjectDisposedException) return;
                }
            }
            finally
            {
                if (reader is not null) ReturnReader(reader);
            }
        }
    }

    private PageMatches FindOn(ref TextReader? reader, int page, string query, bool matchCase, bool wholeWord, bool ignoreAccents)
    {
        if (Volatile.Read(ref _pageStrings[page]) is { } known && !PageText.Matches(known, query, matchCase, wholeWord, ignoreAccents))
            return new PageMatches(page, null, []);
        var text = Volatile.Read(ref _pageTexts[page]);
        if (text is null && _textGate.TryEnter())
        {
            try
            {
                if (!_disposed && _textCache.TryGetValue(page, out var hit)) text = hit;
            }
            finally
            {
                _textGate.Exit();
            }
        }
        if (text is null)
        {
            reader ??= RentReader();
            lock (reader.Gate)
            {
                ObjectDisposedException.ThrowIf(reader.Disposed, this);
                reader.Loaded.Touch(page);
                text = ExtractText(reader.Doc, page);
            }
            Remember(page, text);
        }
        var hits = text.Find(query, matchCase, wholeWord, ignoreAccents);
        return new PageMatches(page, hits.Count > 0 ? text : null, hits);
    }

    /// <summary>
    /// Another MuPDF instance of the file for reading pages' text in <see cref="FindAll"/>, used by one thread at a time
    /// under its <see cref="Gate"/>. It keeps two pages loaded: a search reads each page once.
    /// </summary>
    private sealed class TextReader(MuPDFContext ctx, MuPDFDocument doc)
    {
        public Lock Gate { get; } = new();
        public MuPDFContext Ctx { get; } = ctx;
        public MuPDFDocument Doc { get; } = doc;
        public LoadedPages Loaded { get; } = new(doc, 2);
        public bool Disposed { get; set; }
    }

    private TextReader RentReader()
    {
        lock (_readerGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_idleReaders.TryPop(out var idle)) return idle;
        }
        var (ctx, doc) = OpenAgain();
        var reader = new TextReader(ctx, doc);
        lock (_readerGate)
        {
            if (!_disposed)
            {
                _readers.Add(reader);
                return reader;
            }
        }
        DisposeDocument(doc);
        ctx.Dispose();
        throw new ObjectDisposedException(nameof(PdfEngine));
    }

    private void ReturnReader(TextReader reader)
    {
        lock (_readerGate)
            if (!reader.Disposed) _idleReaders.Push(reader);
    }

    /// <summary>Most vector paths a page may draw for its thin lines to be read as table rules (maps and charts draw thousands).</summary>
    private const int MaxRulePaths = 4000;

    /// <summary>Pictures larger than this many pixels are exported as JPEG (scans, photos), smaller ones as PNG.</summary>
    private const long JpegAbovePixels = 1_500_000;

    /// <summary>Largest picture rendered again to keep its transparency, and largest rendering of a vector figure (pixels).</summary>
    private const long MaxRenderedPicture = 4_000_000;

    /// <summary>
    /// What Export to Word / Excel / text reads from a page: text lines with their fonts, sizes, colors and direction, the
    /// pictures (encoded, when <paramref name="images"/>; transparent ones as PNG with their transparency) and the thin
    /// lines and box outlines the page draws. Charts and diagrams drawn with vectors (<see cref="DocLayout.FigureRegions"/>)
    /// become one picture each, rendered as shown, and their labels and lines are left out of the text. Not cached.
    /// </summary>
    /// <param name="boxesOnly">Pictures and figures say where they are, without their pixels (tagging needs no more).</param>
    /// <param name="shapes">Read the page's simple shapes too (<see cref="ExportShapes"/>); what is neither one nor text is added as a picture.</param>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired before the page was read.</exception>
    public ExportPage GetExportPage(int page, bool images, CancellationToken cancel = default, bool boxesOnly = false, bool shapes = false)
    {
        cancel.ThrowIfCancellationRequested();
        var lines = new List<ExportLine>();
        var raw = new List<(List<ExportGlyph> Glyphs, int Turn, bool Sideways)>();
        var pictures = new List<ExportImage>();
        var paths = new List<(RectD Box, bool Stroked)>();
        var colors = new List<uint>();
        var tooManyPaths = false;
        PageGeometry g;
        EnterText(cancel);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            g = _pages[page];
            var flags = StructuredTextFlags.CollectVectors | (images ? StructuredTextFlags.PreserveImages : StructuredTextFlags.None);
            using var st = TextDoc(page).GetStructuredTextPage(page, includeAnnotations: true, flags);
            var pg = g;
            RectD Box(Rectangle r) => RectD.FromEdges(r.X0 - pg.OriginX, r.Y0 - pg.OriginY, r.X1 - pg.OriginX, r.Y1 - pg.OriginY);
            foreach (var block in st)
            {
                cancel.ThrowIfCancellationRequested();
                switch (block)
                {
                    case MuPDFTextStructuredTextBlock tb:
                        foreach (var line in tb) raw.Add(ReadGlyphs(line, g));
                        break;
                    case MuPDFImageStructuredTextBlock ib when images && ib.Image is { Width: > 0, Height: > 0 } img:
                    {
                        var box = Box(ib.BoundingBox).Intersect(new RectD(0, 0, g.Width, g.Height));
                        if (box.Width < 2 || box.Height < 2) break; // clipped away or a hairline
                        if (boxesOnly)
                        {
                            pictures.Add(new ExportImage([], "png", img.Width, img.Height, box));
                            break;
                        }
                        using var ms = new MemoryStream();
                        var jpeg = (long)img.Width * img.Height > JpegAbovePixels;
                        try
                        {
                            if (jpeg) img.WriteAsJPEG(ms, 85);
                            else img.Write(ms, RasterOutputFileTypes.PNG);
                        }
                        catch (Exception ex) when (ex is MuPDFException or ArgumentException or NotSupportedException)
                        {
                            ms.SetLength(0); // an image MuPDF can't convert (unusual color space): rendered below instead
                        }
                        pictures.Add(new ExportImage(ms.ToArray(), jpeg ? "jpeg" : "png", img.Width, img.Height, box));
                        break;
                    }
                    case MuPDFVectorStructuredTextBlock vb:
                        if (paths.Count < MaxRulePaths)
                        {
                            paths.Add((Box(vb.BoundingBox), vb.Stroked));
                            colors.Add(vb.Color is { Length: >= 3 } c ? (uint)c[0] << 16 | (uint)c[1] << 8 | c[2] : 0);
                        }
                        else tooManyPaths = true;
                        break;
                }
            }
        }
        finally
        {
            _textGate.Exit();
        }

        IReadOnlyList<RectD> rules = tooManyPaths ? [] : DocLayout.RulesFromPaths(paths);
        // Accents joined to their letters and leaders found across the page (a capital's accent is a line of its own);
        // lines split where a table's vertical rule passes between two characters (cells MuPDF read as one line).
        var composed = ExportGlyphs.Compose([.. raw.Select(r => r.Glyphs)], i => raw[i].Turn == 0 && !raw[i].Sideways);
        // An accent standing alone may be another shape under an accent's name (a form's "=" named "dotaccent"): what it
        // draws decides.
        foreach (var glyphs in composed)
            for (var k = 0; k < glyphs.Count; k++)
            {
                if (!ExportGlyphs.IsLoneAccent(glyphs, k)) continue;
                // A glyph of one font at one size draws the same everywhere: rendered once.
                var key = (glyphs[k].Look.Font, glyphs[k].Text, Math.Round(glyphs[k].Look.Size, 1));
                if (!_drawnAs.TryGetValue(key, out var drawn))
                {
                    const double ppp = 8;
                    if (RenderRegionRgba(page, glyphs[k].Rect, ppp, cancel) is not { } r) continue;
                    var alpha = new byte[r.Width * r.Height];
                    for (var p = 0; p < alpha.Length; p++) alpha[p] = r.Rgba[p * 4 + 3];
                    drawn = ExportGlyphs.DrawnAs(alpha, r.Width, r.Height, r.Width / Math.Max(0.01, glyphs[k].Rect.Width), glyphs[k].Look.Size);
                    _drawnAs[key] = drawn;
                }
                if (drawn is not null && !(drawn == "−" && glyphs[k].Text == "¯")) glyphs[k] = glyphs[k] with { Text = drawn };
            }
        var verticals = rules.Where(r => r.Width <= 3 && r.Height > 6).ToList();
        for (var i = 0; i < composed.Count; i++)
            if (composed[i].Count > 0) lines.AddRange(LinesOf(composed[i], raw[i].Turn, raw[i].Sideways, verticals));

        var figures = DocLayout.FigureRegions(paths, lines, g.Width, g.Height);
        if (figures.Count > 0)
        {
            bool InFigure(RectD r) => figures.Any(f => f.Inflate(1).Contains(r.CenterX, r.CenterY));
            lines.RemoveAll(l => InFigure(l.Box));
            rules = [.. rules.Where(r => !InFigure(r))];
            pictures.RemoveAll(p => InFigure(p.Box));
        }
        if (images && boxesOnly) pictures.AddRange(figures.Select(f => new ExportImage([], "png", 0, 0, f)));
        else if (images)
        {
            // Rendered again where the picture stands: what MuPDF draws applies its soft mask, so a transparent logo keeps
            // its transparency (the picture's own pixels have none). Not where text lies over it (it would be doubled).
            for (var i = pictures.Count - 1; i >= 0; i--)
            {
                var p = pictures[i];
                var covered = lines.Any(l => Overlap(l.Box, p.Box) > 0.2 * l.Box.Width * l.Box.Height);
                var tooBig = (long)p.PixelWidth * p.PixelHeight > MaxRenderedPicture;
                if (covered || (tooBig && p.Data.Length > 0))
                {
                    if (p.Data.Length == 0) pictures.RemoveAt(i);
                    continue;
                }
                var scale = Math.Clamp(Math.Max(p.PixelWidth / p.Box.Width, p.PixelHeight / p.Box.Height), 0.5, 8);
                if (RenderRegionRgba(page, p.Box, scale, cancel) is not { } r)
                {
                    if (p.Data.Length == 0) pictures.RemoveAt(i);
                    continue;
                }
                var transparent = HasTransparency(r.Rgba);
                if (transparent || p.Data.Length == 0)
                    pictures[i] = p with { Data = PngEncoder.Encode(r.Width, r.Height, r.Rgba, alpha: true), Extension = "png", PixelWidth = r.Width, PixelHeight = r.Height };
            }
            foreach (var f in figures)
                if (RenderRegionRgba(page, f, 2, cancel) is { } r)
                    pictures.Add(new ExportImage(PngEncoder.Encode(r.Width, r.Height, r.Rgba, alpha: HasTransparency(r.Rgba)), "png", r.Width, r.Height, f));
        }
        IReadOnlyList<ExportShape> found = [];
        if (shapes && images && !boxesOnly && !tooManyPaths)
        {
            var drawn = paths.Select((p, i) => new ExportPath(p.Box, p.Stroked, colors[i]))
                .Where(p => !figures.Any(f => f.Inflate(1).Contains(p.Box.CenterX, p.Box.CenterY))).ToList();
            ExportShapes.Raster? raster = null;
            if (ExportShapes.NeedsRaster(drawn) && RenderRegionRgba(page, new RectD(0, 0, g.Width, g.Height), 2, cancel) is { } whole)
                raster = new ExportShapes.Raster(whole.Rgba, whole.Width, whole.Height, whole.Width / Math.Max(1, g.Width));
            var (simple, keep) = ExportShapes.Read(drawn, raster, lines, [.. pictures.Select(p => p.Box)], g.Width, g.Height, cancel);
            found = simple;
            foreach (var area in keep)
                if (RenderRegionRgba(page, area, 2, cancel) is { } r)
                    pictures.Add(new ExportImage(PngEncoder.Encode(r.Width, r.Height, r.Rgba, alpha: true), "png", r.Width, r.Height, area));
        }
        return new ExportPage(g.Width, g.Height, lines, pictures, rules) { Shapes = found };

        static double Overlap(RectD a, RectD b) =>
            Math.Max(0, Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X)) * Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y));

        static bool HasTransparency(byte[] rgba)
        {
            for (var k = 3; k < rgba.Length; k += 4)
                if (rgba[k] != 255) return true;
            return false;
        }
    }

    /// <summary>
    /// A region of a page (page space) rendered on a transparent background as straight (not premultiplied) RGBA, at
    /// <paramref name="scale"/> pixels per point or less (at most <see cref="MaxRenderedPicture"/> pixels); null if MuPDF
    /// can't draw it.
    /// </summary>
    private (byte[] Rgba, int Width, int Height)? RenderRegionRgba(int page, RectD region, double scale, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var area0 = region.Width * region.Height;
        if (area0 <= 0) return null;
        if (area0 * scale * scale > MaxRenderedPicture) scale = Math.Sqrt(MaxRenderedPicture / area0);
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _loaded.Touch(page);
            var g = _pages[page];
            var area = new Rectangle(g.OriginX + region.X, g.OriginY + region.Y, g.OriginX + region.Right, g.OriginY + region.Bottom);
            var px = area.Round(scale);
            if (px.Width <= 0 || px.Height <= 0) return null;
            byte[] rgba;
            try
            {
                rgba = _doc.Render(page, area, scale, PixelFormats.RGBA, includeAnnotations: true);
            }
            catch (MuPDFException)
            {
                return null;
            }
            if (rgba.Length != px.Width * px.Height * 4) return null;
            // MuPDF's pixels are premultiplied by alpha; PNG wants them straight.
            for (var i = 0; i < rgba.Length; i += 4)
            {
                var a = rgba[i + 3];
                if (a is 0 or 255) continue;
                rgba[i] = (byte)Math.Min(255, rgba[i] * 255 / a);
                rgba[i + 1] = (byte)Math.Min(255, rgba[i + 1] * 255 / a);
                rgba[i + 2] = (byte)Math.Min(255, rgba[i + 2] * 255 / a);
            }
            return (rgba, px.Width, px.Height);
        }
    }

    /// <summary>A structured-text line's characters (page space), with which way it reads.</summary>
    private static (List<ExportGlyph> Glyphs, int Turn, bool Sideways) ReadGlyphs(MuPDFStructuredTextLine line, PageGeometry g)
    {
        var glyphs = new List<ExportGlyph>();
        foreach (var ch in line)
        {
            var q = ch.BoundingQuad;
            var l = Math.Min(Math.Min(q.UpperLeft.X, q.LowerLeft.X), Math.Min(q.UpperRight.X, q.LowerRight.X));
            var r = Math.Max(Math.Max(q.UpperLeft.X, q.LowerLeft.X), Math.Max(q.UpperRight.X, q.LowerRight.X));
            var t = Math.Min(Math.Min(q.UpperLeft.Y, q.LowerLeft.Y), Math.Min(q.UpperRight.Y, q.LowerRight.Y));
            var b = Math.Max(Math.Max(q.UpperLeft.Y, q.LowerLeft.Y), Math.Max(q.UpperRight.Y, q.LowerRight.Y));
            var rect = RectD.FromEdges(l - g.OriginX, t - g.OriginY, r - g.OriginX, b - g.OriginY);
            var font = ch.Font;
            var name = font?.Name ?? "";
            var look = new ExportSpan("", name, ch.Size, (font?.IsBold ?? false) || FontNames.LooksBold(name),
                (font?.IsItalic ?? false) || FontNames.LooksItalic(name), ch.Color & 0xFFFFFF, rect)
            {
                Serif = font?.IsSerif ?? false, Mono = font?.IsMonospaced ?? false,
            };
            glyphs.Add(new ExportGlyph(ch.Character, rect, look));
        }
        var turn = ExportLine.TurnOf(line.Direction.X, line.Direction.Y);
        var sideways = Math.Abs(line.Direction.Y) > 0.1 || line.Direction.X <= 0;
        return (glyphs, turn, sideways);
    }

    /// <summary>
    /// A line's characters as spans of one look each, split where a left-to-right line has a gap wide enough to be a
    /// column gap: over 2.5 times the type size, or over its size between two numbers (table columns set close together,
    /// which MuPDF reads as one line), and where one of <paramref name="verticals"/> (a table's rules) passes between two
    /// characters. A leader is a span of its own. Empty when it holds no characters.
    /// </summary>
    private static List<ExportLine> LinesOf(List<ExportGlyph> chars, int turn, bool sideways, List<RectD> verticals)
    {
        var result = new List<ExportLine>();
        // Positions along the reading direction, whichever way the line runs.
        var along = chars.Select(c => turn switch
        {
            0 => (c.Text, c.Rect.X, c.Rect.Right, c.Look.Size),
            1 => (c.Text, c.Rect.Y, c.Rect.Bottom, c.Look.Size),
            2 => (c.Text, -c.Rect.Right, -c.Rect.X, c.Look.Size),
            _ => (c.Text, -c.Rect.Bottom, -c.Rect.Y, c.Look.Size),
        }).ToList();
        var parts = ExportLine.SplitAtColumnGaps(along);
        if (turn == 0 && verticals.Count > 0) parts = [.. parts.SelectMany(p => SplitAtRules(chars, p, verticals))];
        foreach (var part in parts)
        {
            var spans = new List<ExportSpan>();
            var text = new System.Text.StringBuilder();
            ExportSpan? look = null;
            RectD box = default;
            var leader = false;
            for (var i = part.Start; i < part.End; i++)
            {
                var (s, rect, c) = chars[i];
                var isLeader = s.Length == 1 && ExportGlyphs.IsLeader(s[0]);
                if (look is null || !look.SameLook(c) || isLeader || leader)
                {
                    if (look is not null && text.Length > 0) spans.Add(look with { Text = text.ToString(), Box = box });
                    text.Clear();
                    look = c;
                    box = rect;
                }
                else box = box.Union(rect);
                leader = isLeader;
                text.Append(s);
            }
            if (look is not null && text.Length > 0) spans.Add(look with { Text = text.ToString(), Box = box });
            if (spans.Count > 0) result.Add(ExportLine.Of(spans, sideways) with { Turn = turn });
        }
        return result;
    }

    /// <summary>A left-to-right part of a line cut where a vertical rule runs between two of its characters, at their height.</summary>
    private static IEnumerable<(int Start, int End)> SplitAtRules(List<ExportGlyph> chars, (int Start, int End) part, List<RectD> verticals)
    {
        var start = part.Start;
        var lastInk = -1;
        for (var i = part.Start; i < part.End; i++)
        {
            if (string.IsNullOrWhiteSpace(chars[i].Text)) continue;
            if (lastInk >= 0)
            {
                var (a, b) = (chars[lastInk].Rect, chars[i].Rect);
                var cy = (a.CenterY + b.CenterY) / 2;
                if (verticals.Any(v => v.CenterX >= a.CenterX && v.CenterX <= b.CenterX && v.Y <= cy && v.Bottom >= cy))
                {
                    yield return (start, lastInk + 1);
                    start = i;
                }
            }
            lastInk = i;
        }
        yield return (start, part.End);
    }

    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired before the links were read.</exception>
    public IReadOnlyList<PageLink> GetLinks(int page, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        EnterText(cancel);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_links.TryGetValue(page, out var cached)) return cached;

            var g = _pages[page];
            var list = new List<PageLink>();
            foreach (var link in TextDoc(page).Pages[page].Links)
            {
                var a = link.ActiveArea;
                var area = RectD.FromEdges(a.X0 - g.OriginX, a.Y0 - g.OriginY, a.X1 - g.OriginX, a.Y1 - g.OriginY);
                switch (link.Destination)
                {
                    case MuPDFInternalLinkDestination d when d.PageNumber >= 0 && d.PageNumber < _pages.Length:
                        list.Add(new PageLink(area, d.PageNumber, null, TargetY(d.PageNumber, d.Y)));
                        break;
                    case MuPDFExternalLinkDestination e when !string.IsNullOrWhiteSpace(e.Uri):
                        list.Add(new PageLink(area, -1, e.Uri));
                        break;
                }
            }
            return _links[page] = [.. list];
        }
        finally
        {
            _textGate.Exit();
        }
    }

    /// <summary>
    /// MuPDFCore keeps every page it loads, and the display list made to render or read it, until the document is
    /// closed: scrolling through a 10,000-page file would hold them all in native memory. This keeps the most recently
    /// used pages of one MuPDF instance and frees the others (they load again when needed). Use under that instance's
    /// lock. Pinned to MuPDFCore 2.0.1's internals (the page and display list arrays); if they differ, it falls back to
    /// the public <see cref="MuPDFDocument.ClearCache"/> (display lists only) every <c>capacity</c> pages.
    /// </summary>
    internal sealed class LoadedPages(MuPDFDocument doc, int capacity)
    {
        private const BindingFlags Internal = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
        private static readonly FieldInfo? PageArray = typeof(MuPDFPageCollection).GetField("Pages", Internal);
        private static readonly FieldInfo? ListArray = typeof(MuPDFDocument).GetField("DisplayLists", Internal);
        private readonly LinkedList<int> _lru = [];
        private readonly Dictionary<int, LinkedListNode<int>> _nodes = [];
        private int _evicted;

        public int Count => _lru.Count;

        /// <summary>Marks a page as just used; frees the least recently used one beyond the capacity.</summary>
        public void Touch(int page)
        {
            if (_nodes.TryGetValue(page, out var node))
            {
                _lru.Remove(node);
                _lru.AddFirst(node);
                return;
            }
            _nodes[page] = _lru.AddFirst(page);
            while (_lru.Count > capacity)
            {
                var old = _lru.Last!.Value;
                _lru.RemoveLast();
                _nodes.Remove(old);
                Free(old);
            }
        }

        private void Free(int page)
        {
            if (ListArray?.GetValue(doc) is Array lists && PageArray?.GetValue(doc.Pages) is Array pages
                && page < lists.Length && page < pages.Length)
            {
                (lists.GetValue(page) as IDisposable)?.Dispose();
                lists.SetValue(null, page);
                (pages.GetValue(page) as IDisposable)?.Dispose();
                pages.SetValue(null, page);
                return;
            }
            if (++_evicted % capacity == 0) doc.ClearCache();
        }

        /// <summary>Test hook: how many pages and display lists the instance holds right now (-1 if unknown).</summary>
        internal (int Pages, int Lists) Held()
        {
            if (ListArray?.GetValue(doc) is not Array lists || PageArray?.GetValue(doc.Pages) is not Array pages) return (-1, -1);
            int p = 0, l = 0;
            foreach (var x in pages) if (x is not null) p++;
            foreach (var x in lists) if (x is not null) l++;
            return (p, l);
        }
    }

    /// <summary>Test hook: MuPDF pages and display lists held by the render and text instances.</summary>
    internal ((int Pages, int Lists) Render, (int Pages, int Lists) Text) LoadedCounts()
    {
        lock (_gate)
        {
            lock (_textGate) return (_loaded.Held(), _textLoaded?.Held() ?? (0, 0));
        }
    }


    public IReadOnlyList<OutlineNode> GetOutline()
    {
        lock (_textGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_outline is not null) return _outline;
            try
            {
                _outline = Convert(TextDoc().Outline);
            }
            catch (Exception ex) when (ex is MuPDFException or InvalidOperationException or NullReferenceException)
            {
                // A broken outline must not stop the document from opening.
                _outline = [];
            }
            return _outline;
        }

        List<OutlineNode> Convert(IEnumerable<MuPDFOutlineItem>? items)
        {
            var list = new List<OutlineNode>();
            if (items is null) return list;
            foreach (var item in items)
                list.Add(new OutlineNode(item.Title ?? "", item.PageNumber, Convert(item.Children), TargetY(item.PageNumber, item.Location.Y)));
            return list;
        }
    }

    /// <summary>A destination's y (MuPDF page space) in our page space, or null when the destination names no position.</summary>
    private double? TargetY(int page, float y) =>
        page >= 0 && page < _pages.Length && float.IsFinite(y) ? Math.Clamp(y - _pages[page].OriginY, 0, _pages[page].Height) : null;

    public void Dispose()
    {
        lock (_gate)
        {
            lock (_textGate)
            {
                if (_disposed) return;
                _disposed = true;
                if (_textDoc is not null) DisposeDocument(_textDoc);
                _textCtx?.Dispose();
                _textDoc = null;
                _textCtx = null;
                lock (_readerGate)
                {
                    foreach (var r in _readers)
                        lock (r.Gate)
                        {
                            r.Disposed = true;
                            DisposeDocument(r.Doc);
                            r.Ctx.Dispose();
                        }
                    _readers.Clear();
                    _idleReaders.Clear();
                }
            }
            if (_clones is not null) AbortableRender.Free(_clones);
            DisposeDocument(_doc);
            _ctx.Dispose();
        }
    }

    /// <summary>
    /// Makes a MuPDF document. MuPDFCore's constructor can throw after the object exists (a file MuPDF can't repair, or
    /// memory running out while it reads); that object's finalizer throws, ending the process, if it runs after its
    /// context was disposed. So on any failure it is finalized here, while <paramref name="ctx"/> is still alive. Out of
    /// memory becomes <see cref="InsufficientMemoryException"/>: that document can't be used, the process goes on.
    /// Every MuPDFDocument is made through this.
    /// </summary>
    /// <exception cref="InsufficientMemoryException">Memory ran out while the document was read.</exception>
    internal static MuPDFDocument NewDocument(MuPDFContext ctx, Func<MuPDFDocument> create)
    {
        try
        {
            return create();
        }
        catch (Exception ex)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.KeepAlive(ctx);
            if (ex is OutOfMemoryException) throw new InsufficientMemoryException("There isn't enough memory to open this document.", ex);
            throw;
        }
    }

    /// <summary>
    /// MuPDFCore throws from a finalizer (crashing the process) if a page outlives its context, so pages must be
    /// disposed explicitly, before the document and the context.
    /// </summary>
    internal static void DisposeDocument(MuPDFDocument doc)
    {
        doc.Pages.Dispose();
        doc.Dispose();
    }
}
