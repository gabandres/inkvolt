using System.Runtime.CompilerServices;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// A file PDFsharp won't be given (<see cref="PdfShapeGuard"/>): its pages still show (MuPDF), but nothing can read or edit
/// its objects. Reported like any other file PDFsharp can't read.
/// </summary>
public sealed class PdfShapeException() : InvalidOperationException(PdfStrings.Doc_ShapeRefused);

/// <summary>
/// Stops the shapes of file that PDFsharp can't survive, before it meets them (<see cref="PdfObj.Read"/>). It walks what it
/// reads by recursion, and a stack overflow can't be caught: it ends the app with every open document. So: nesting without
/// end (<see cref="GuardedFile"/>, <see cref="CheckObjectStream"/>), a page tree that holds itself, runs very deep or
/// multiplies (<see cref="CheckPageTree"/>), and cross-reference sections that lead back to themselves, which it follows
/// for good (<see cref="PdfRepair.SectionsEnd"/>). Each document's bytes are checked once.
/// </summary>
internal static class PdfShapeGuard
{
    /// <summary>
    /// The deepest arrays and dictionaries are read: a file's real ones nest a few levels. Each level takes 250-500 bytes of
    /// stack (2,000 levels overflow a 512 KB stack, 1,000 don't), and threads here have 1 MB or more.
    /// </summary>
    internal const int MaxNesting = 512;

    /// <summary>The deepest page tree: real ones have a few levels. PDFsharp takes about 370 bytes of stack a level.</summary>
    private const int MaxPageTreeDepth = 256;

    /// <summary>The most entries a page tree may have, counting each as often as it is listed: a tree made to multiply stops here.</summary>
    private const int MaxPageTreeEntries = 4 << 20;

    /// <summary>The shortest a reference is written ("1 0 R "): what lists more comments than the file could spell out shares one list across pages.</summary>
    private const int ShortestReference = 6;

    /// <summary>What one list shared by a few pages may add, however small the file.</summary>
    private const long SharedListingBytes = 1 << 20;

    private static readonly ConditionalWeakTable<byte[], object> Verdicts = [];
    private static readonly object Good = new(), Refused = new();

    /// <summary>These bytes were checked, or came from a document that was: they are read without another look. Bytes refused once are refused at once from then on.</summary>
    /// <exception cref="PdfShapeException">They were refused.</exception>
    public static bool IsKnown(byte[] data)
    {
        if (!Verdicts.TryGetValue(data, out var verdict)) return false;
        return ReferenceEquals(verdict, Good) ? true : throw new PdfShapeException();
    }

    public static void MarkKnown(byte[] data) => Verdicts.AddOrUpdate(data, Good);

    public static void MarkRefused(byte[] data) => Verdicts.AddOrUpdate(data, Refused);

    /// <summary>
    /// Refuses <paramref name="data"/> until <paramref name="check"/> (a read of the same bytes that is taking too long)
    /// ends: then they are read as they are, checked again, unless the check itself gave a verdict.
    /// </summary>
    public static void RefuseUntil(byte[] data, Task check)
    {
        Verdicts.TryAdd(data, Refused);
        check.ContinueWith(_ =>
        {
            if (Verdicts.TryGetValue(data, out var verdict) && ReferenceEquals(verdict, Refused) && !check.IsFaulted) Verdicts.Remove(data);
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    /// <exception cref="PdfShapeException">The cross-reference sections lead back to one already read.</exception>
    public static void CheckSections(byte[] data)
    {
        if (!PdfRepair.SectionsEnd(data)) throw new PdfShapeException();
    }

    /// <summary>
    /// Refuses a page tree PDFsharp would recurse through for good or for too long, or whose pages share one list of
    /// comments and widgets so often that every reader would make millions of records from a small file (2,000 pages with
    /// 2,000 widgets: 4 million). Walks it itself, without recursion and without touching <c>PdfDocument.Pages</c>, which
    /// flattens the tree. Anything else wrong with the document is left for its readers to report.
    /// </summary>
    /// <exception cref="PdfShapeException">The tree is one of those.</exception>
    public static void CheckPageTree(PdfDocument doc, long fileLength)
    {
        if (Read(() => PdfObj.Dict(doc.Internals.Catalog?.Elements["/Pages"])) is not { } root) return;
        var path = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance) { root };
        var stack = new Stack<(PdfDictionary Node, PdfArray? Kids, int Next)>();
        stack.Push((root, Read(() => PdfObj.Array(root.Elements["/Kids"])), 0));
        long entries = 0, listed = 0;
        while (stack.TryPop(out var top))
        {
            if (top.Kids is not { } list || top.Next >= list.Elements.Count)
            {
                path.Remove(top.Node);
                continue;
            }
            stack.Push(top with { Next = top.Next + 1 });
            // An entry that can't be read is passed over, never the rest of the tree: PDFsharp reaches the others too.
            if (Read(() => PdfObj.Dict(list.Elements[top.Next])) is not { } kid) continue;
            if (++entries > MaxPageTreeEntries) throw new PdfShapeException();
            if (Read(() => PdfObj.Array(kid.Elements["/Kids"])) is { } kids)
            {
                if (!path.Add(kid) || stack.Count >= MaxPageTreeDepth) throw new PdfShapeException();
                stack.Push((kid, kids, 0));
            }
            else
            {
                listed += Read(() => PdfObj.Array(kid.Elements["/Annots"]))?.Elements.Count ?? 0;
                if (listed * ShortestReference > fileLength + SharedListingBytes) throw new PdfShapeException();
            }
        }

        // What PDFsharp gives, or null where it fails (left for the document's readers to report).
        static T? Read<T>(Func<T?> get) where T : class
        {
            try
            {
                return get();
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                return null;
            }
        }
    }

    /// <summary>
    /// Refuses a decoded stream that is an object stream (its text starts with an object's number and offset, unlike a
    /// cross-reference stream's rows) nesting past <see cref="MaxNesting"/>: PDFsharp parses it as it opens the file, with a
    /// reader this class can't watch.
    /// </summary>
    /// <exception cref="PdfShapeException">It does.</exception>
    public static void CheckObjectStream(ReadOnlySpan<byte> bytes)
    {
        if (!StartsWithTwoNumbers(bytes)) return;
        var depth = new Nesting();
        foreach (var b in bytes) depth.Read(b);
    }

    /// <summary>
    /// Whether the stream data starting at <paramref name="at"/> belongs to an object stream without a filter: the
    /// dictionary before it (from its object's "obj", within <see cref="PdfRepair"/>'s dictionary limit) names /ObjStm
    /// and no /Filter.
    /// </summary>
    internal static bool IsUnfilteredObjectStreamAt(byte[] data, int at)
    {
        if (at <= 0 || at > data.Length) return false;
        var from = Math.Max(0, at - (64 * 1024));
        var before = data.AsSpan(from, at - from);
        var obj = before.LastIndexOf("obj"u8);
        if (obj < 0) return false;
        var dict = before[obj..];
        return dict.IndexOf("/ObjStm"u8) >= 0 && dict.IndexOf("/Filter"u8) < 0;
    }

    private static bool StartsWithTwoNumbers(ReadOnlySpan<byte> bytes)
    {
        var i = 0;
        for (var number = 0; number < 2; number++)
        {
            while (i < bytes.Length && Incremental.IsWhite(bytes[i])) i++;
            var start = i;
            while (i < bytes.Length && bytes[i] is >= (byte)'0' and <= (byte)'9') i++;
            if (i == start) return false;
        }
        return true;
    }

    /// <summary>How deep the arrays and dictionaries are in the tokens read so far.</summary>
    private struct Nesting
    {
        private int _depth;
        private byte _last;

        public void Read(byte b)
        {
            switch (b)
            {
                case (byte)'[':
                    Open();
                    break;
                case (byte)'<' when _last == '<':
                    Open();
                    _last = 0;
                    return;
                case (byte)']':
                    Close();
                    break;
                case (byte)'>' when _last == '>':
                    Close();
                    _last = 0;
                    return;
            }
            _last = b;
        }

        public void Reset() => (_depth, _last) = (0, 0);

        private void Open()
        {
            if (++_depth > MaxNesting) throw new PdfShapeException();
        }

        private void Close()
        {
            if (_depth > 0) _depth--;
        }
    }

    /// <summary>
    /// The file as PDFsharp reads it, with the nesting counted as it goes: its parser takes tokens a byte at a time and a
    /// stream's data in one read, and goes to each object by position, so stream data never counts, whatever bytes it holds,
    /// and each object starts at no depth. What it reads in one go gets <see cref="CheckObjectStream"/>.
    /// </summary>
    public sealed class GuardedFile : MemoryStream
    {
        private readonly byte[] _data;

        public GuardedFile(byte[] data) : base(data, writable: false) => _data = data;

        private Nesting _nesting;

        public override int ReadByte()
        {
            var b = base.ReadByte();
            if (b >= 0) _nesting.Read((byte)b);
            return b;
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var at = (int)Position;
            var n = base.Read(buffer, offset, count);
            // Only an object stream's own data is parsed again (a filtered one is checked once decoded, in BoundedFilters):
            // a content stream's or a picture's bytes are never nesting, whatever they hold.
            if (IsUnfilteredObjectStreamAt(_data, at)) CheckObjectStream(buffer.AsSpan(offset, n));
            return n;
        }

        public override long Position
        {
            get => base.Position;
            set
            {
                _nesting.Reset();
                base.Position = value;
            }
        }

        public override long Seek(long offset, SeekOrigin loc)
        {
            _nesting.Reset();
            return base.Seek(offset, loc);
        }
    }
}
