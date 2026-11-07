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
    private static readonly object Good = new(), Refused = new(), Pending = new();

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
        // Pending, not Refused: a refusal the check itself makes stays when it ends.
        Verdicts.TryAdd(data, Pending);
        check.ContinueWith(_ =>
        {
            if (Verdicts.TryGetValue(data, out var verdict) && ReferenceEquals(verdict, Pending) && !check.IsFaulted) Verdicts.Remove(data);
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
    /// and each object starts at no depth. An unfiltered object stream's data, which PDFsharp parses again, is counted as it
    /// is read (in one read or several), told by the tokens of its dictionary: /Type /ObjStm without /Filter.
    /// </summary>
    public sealed class GuardedFile(byte[] data) : MemoryStream(data, writable: false)
    {
        private Nesting _nesting;      // the tokens read, since the last move to an object
        private Nesting _objectStream; // an unfiltered object stream's data, across the reads of it
        private bool _objStm, _filter; // the dictionary read since the last "obj" names /Type /ObjStm, a /Filter
        private bool _nextIsObjectStream; // the "stream" keyword followed such a dictionary: its data is read next
        private bool _inObjectStream;
        private readonly byte[] _token = new byte[MaxToken + 1];
        private int _tokenLength = -1; // -1: between tokens
        private bool _name;

        /// <summary>The longest token looked at: what PDFsharp reads as /ObjStm, /Filter, obj or stream is shorter, escapes and all.</summary>
        private const int MaxToken = 32;

        public override int ReadByte()
        {
            var b = base.ReadByte();
            if (b >= 0)
            {
                _nesting.Read((byte)b);
                Token((byte)b);
            }
            return b;
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var n = base.Read(buffer, offset, count);
            // Only an object stream's own data is parsed again (a filtered one is checked once decoded, in BoundedFilters):
            // a content stream's or a picture's bytes are never nesting, whatever they hold. Which stream it is comes from
            // the tokens of its dictionary, read just before, however far into the stream this read is.
            if (_nextIsObjectStream)
            {
                (_nextIsObjectStream, _inObjectStream) = (false, true);
                _objectStream.Reset();
            }
            if (_inObjectStream)
                foreach (var b in buffer.AsSpan(offset, n)) _objectStream.Read(b);
            return n;
        }

        /// <summary>Follows the tokens PDFsharp's parser reads a byte at a time (names decoded, as it decodes them).</summary>
        private void Token(byte b)
        {
            if (!Incremental.IsWhite(b) && !Incremental.IsDelimiter(b))
            {
                if (_tokenLength < 0) (_tokenLength, _name) = (0, false);
                if (_tokenLength <= MaxToken) _token[_tokenLength++] = b;
                return;
            }
            EndToken();
            if (b == '/') (_tokenLength, _name) = (0, true);
        }

        private void EndToken()
        {
            if (_tokenLength is < 0 or > MaxToken)
            {
                _tokenLength = -1;
                return;
            }
            var token = _token.AsSpan(0, _tokenLength);
            _tokenLength = -1;
            if (_name)
            {
                Span<byte> name = stackalloc byte[MaxToken];
                var length = 0;
                for (var i = 0; i < token.Length; i++)
                {
                    if (token[i] == '#' && i + 2 < token.Length && byte.TryParse(token.Slice(i + 1, 2), System.Globalization.NumberStyles.HexNumber, null, out var c))
                    {
                        name[length++] = c;
                        i += 2;
                    }
                    else name[length++] = token[i];
                }
                if (name[..length].SequenceEqual("ObjStm"u8)) _objStm = true;
                else if (name[..length].SequenceEqual("Filter"u8)) _filter = true;
            }
            else if (token.SequenceEqual("obj"u8))
            {
                // A new object: what follows is its dictionary. (An indirect /Length is read after the "stream" keyword.)
                (_objStm, _filter, _inObjectStream) = (false, false, false);
            }
            else if (token.SequenceEqual("stream"u8))
            {
                _nextIsObjectStream = _objStm && !_filter;
                _inObjectStream = false;
            }
        }

        public override long Position
        {
            get => base.Position;
            set
            {
                _nesting.Reset();
                _tokenLength = -1;
                base.Position = value;
            }
        }

        public override long Seek(long offset, SeekOrigin loc)
        {
            _nesting.Reset();
            _tokenLength = -1;
            return base.Seek(offset, loc);
        }
    }
}
