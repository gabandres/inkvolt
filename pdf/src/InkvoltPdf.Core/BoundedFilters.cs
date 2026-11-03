using System.IO.Compression;
using System.Reflection;
using PdfSharp.Pdf.Filters;

namespace InkvoltPdf.Core;

/// <summary>
/// PDFsharp's Flate, LZW and ASCII85 decoders with a limit. PDFsharp decodes through one shared instance of each
/// (<see cref="Filtering"/>), for <c>UnfilteredValue</c> and also on its own while it opens a file (object streams and
/// cross-reference streams), so these replace those instances: every stage of a filter chain, wherever it is in the array,
/// is measured before it is decoded, and one that would go past the limit throws <see cref="StreamTooLargeException"/>
/// with nothing spent. The limit is <see cref="PdfObj.MaxStreamBytes"/> a stream, or what <see cref="Within{T}"/> says;
/// opening a file (<see cref="PdfObj.Read"/>) also has that much in all.
/// </summary>
internal static class BoundedFilters
{
    /// <summary>Deflate packs at most about 1032 to 1: a stream this many times shorter than a limit can't inflate past it.</summary>
    private const int MaxFlateRatio = 1032;

    /// <summary>A 9-bit LZW code gives at most 4096 bytes (PDFsharp's table goes to 8192 entries, each one byte longer).</summary>
    private const int MaxLzwRatio = 8192 * 8 / 9 + 1;

    [ThreadStatic] private static int t_limit;
    [ThreadStatic] private static long t_left;
    [ThreadStatic] private static bool t_counting;

    static BoundedFilters()
    {
        // Filtering's lazily made instances, by their field names in PDFsharp 6.2.x (pinned below 6.5, which is AGPL).
        Set("_flateDecode", new BoundedFlate());
        Set("_lzwDecode", new BoundedLzw());
        Set("_ascii85Decode", new BoundedAscii85());

        static void Set(string field, Filter filter) =>
            (typeof(Filtering).GetField(field, BindingFlags.NonPublic | BindingFlags.Static)
             ?? throw new MissingFieldException(nameof(Filtering), field)).SetValue(null, filter);
    }

    /// <summary>Puts the bounded decoders in place (once; every call after the first does nothing).</summary>
    public static void Install() { }

    /// <summary>Whether PDFsharp decodes through these (a test checks it).</summary>
    public static bool Installed => Filtering.FlateDecode is BoundedFlate && Filtering.LzwDecode is BoundedLzw && Filtering.Ascii85Decode is BoundedAscii85;

    /// <summary>
    /// Runs <paramref name="read"/> (on this thread) with each decoded stage limited to <paramref name="maxBytes"/>, and with
    /// <paramref name="totalBytes"/> for all of them together when given.
    /// </summary>
    public static T Within<T>(int maxBytes, long? totalBytes, Func<T> read)
    {
        Install();
        var (limit, left, counting) = (t_limit, t_left, t_counting);
        t_limit = maxBytes;
        if (totalBytes is { } total) (t_left, t_counting) = (counting ? Math.Min(left, total) : total, true);
        var entered = t_left;
        try
        {
            return read();
        }
        finally
        {
            // What was spent inside counts against an outer total too.
            var spent = entered - t_left;
            (t_limit, t_left, t_counting) = (limit, counting ? left - spent : left, counting);
        }
    }

    /// <summary>How many bytes PDFsharp's LZW decoder writes for <paramref name="data"/>, counted without writing them.</summary>
    public static long LzwLength(byte[] data) => BoundedLzw.Count(data);

    /// <summary>The most the next stage may decode to.</summary>
    private static int Limit
    {
        get
        {
            var limit = t_limit > 0 ? t_limit : PdfObj.MaxStreamBytes;
            return t_counting ? (int)Math.Min(limit, t_left) : limit;
        }
    }

    /// <summary>Throws when <paramref name="bytes"/> are more than the limit, else counts them against the total.</summary>
    private static void Spend(long bytes, int limit)
    {
        if (bytes > limit) throw new StreamTooLargeException(t_limit > 0 ? t_limit : PdfObj.MaxStreamBytes);
        if (t_counting) t_left -= bytes;
    }

    /// <summary>Flate: inflated a chunk at a time and kept nowhere when the stream could go past the limit, then decoded by PDFsharp.</summary>
    private sealed class BoundedFlate : FlateDecode
    {
        public override byte[] Decode(byte[] data, FilterParms? parms)
        {
            var limit = Limit;
            if ((long)data.Length * MaxFlateRatio > limit && InflatesPast(data, limit)) Spend(long.MaxValue, limit);
            var bytes = base.Decode(data, parms);
            Spend(bytes.Length, limit);
            return bytes;
        }

        private static bool InflatesPast(byte[] raw, int limit)
        {
            // PDFsharp skips two bytes (the zlib header) whatever they are and never reads the checksum: so does this.
            if (raw.Length < 2) return false;
            using var z = new DeflateStream(new MemoryStream(raw, 2, raw.Length - 2), CompressionMode.Decompress);
            var chunk = new byte[64 * 1024];
            long total = 0;
            try
            {
                for (int n; (n = z.Read(chunk)) > 0;)
                    if ((total += n) > limit) return true;
            }
            catch (InvalidDataException)
            {
                // damaged past what was counted: PDFsharp fails on it (or not) as it would have
            }
            return false;
        }
    }

    /// <summary>LZW: its output counted (lengths only) as PDFsharp's decoder would make it, then decoded by a decoder of its own.</summary>
    private sealed class BoundedLzw : LzwDecode
    {
        public override byte[] Decode(byte[] data, FilterParms? parms)
        {
            var limit = Limit;
            if ((long)data.Length * MaxLzwRatio > limit && Count(data) > limit) Spend(long.MaxValue, limit);
            // PDFsharp's LzwDecode keeps its state in the instance: one shared instance isn't safe on two threads.
            var bytes = new LzwDecode().Decode(data, parms);
            Spend(bytes.Length, limit);
            return bytes;
        }

        /// <summary>
        /// How many bytes PDFsharp's LzwDecode writes for <paramref name="data"/> (its table and its code widths, entry lengths
        /// in place of entries), so whatever it does with a strange stream this counts the same.
        /// </summary>
        public static long Count(byte[] data)
        {
            if (data.Length >= 2 && data[0] == 0 && data[1] == 1) return 0; // a flavor it refuses
            var lengths = new int[8192];
            int index = 0, bits = 9, at = 0, next = 0, held = 0, last = 0;
            long total = 0;
            void Reset()
            {
                for (var i = 0; i < 256; i++) lengths[i] = 1;
                index = 258;
                bits = 9;
            }
            int Code()
            {
                if (at >= data.Length) return 257;
                next = (next << 8) | data[at++];
                held += 8;
                if (held < bits)
                {
                    if (at >= data.Length) return 257;
                    next = (next << 8) | data[at++];
                    held += 8;
                }
                var code = (next >> (held - bits)) & ((1 << bits) - 1);
                held -= bits;
                return code;
            }
            void Add(int length)
            {
                if (index >= lengths.Length) throw new InvalidDataException(); // where PDFsharp's table overflows
                lengths[index++] = length;
                bits = index switch { 511 => 10, 1023 => 11, 2047 => 12, _ => bits };
            }
            Reset();
            try
            {
                for (int code; (code = Code()) != 257;)
                {
                    if (code == 256)
                    {
                        Reset();
                        if ((code = Code()) == 257) break;
                        total += lengths[code];
                    }
                    else if (code < index)
                    {
                        total += lengths[code];
                        Add(lengths[last] + 1);
                    }
                    else
                    {
                        total += lengths[last];
                        Add(lengths[last] + 1);
                    }
                    last = code;
                }
            }
            catch (InvalidDataException)
            {
                // PDFsharp fails here too
            }
            return total;
        }
    }

    /// <summary>ASCII85: "z" stands for four zero bytes, so it can decode to four times its length: bounded before decoding.</summary>
    private sealed class BoundedAscii85 : Ascii85Decode
    {
        public override byte[] Decode(byte[] data, FilterParms? parms)
        {
            var limit = Limit;
            if ((long)data.Length > limit / 4)
            {
                long most = 4;
                foreach (var b in data) most += b == 'z' ? 4 : b is >= (byte)'!' and <= (byte)'u' ? 1 : 0;
                if (most > limit) Spend(long.MaxValue, limit);
            }
            var bytes = base.Decode(data, parms);
            Spend(bytes.Length, limit);
            return bytes;
        }
    }
}
