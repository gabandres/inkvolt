using System.Text;

namespace InkvoltPdf.Core;

/// <summary>Which PDF names a file's raw bytes mention, read in chunks (a gigabyte never sits in memory).</summary>
internal static class PdfNames
{
    /// <summary>
    /// The <paramref name="names"/> ("/Annots", ...) the file's bytes contain, each matched as the start of a name ("/Annots"
    /// is also found in "/AnnotsX", and by chance in compressed data): a name not returned appears nowhere in the file
    /// outside compressed streams, unless it is written with #xx escapes.
    /// </summary>
    public static HashSet<string> Scan(string path, IReadOnlyList<string> names)
    {
        var found = new HashSet<string>();
        var keys = names.Select(n => Encoding.ASCII.GetBytes(n)).ToArray();
        var longest = keys.Max(k => k.Length);
        var buffer = new byte[(1 << 20) + longest];
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.SequentialScan);
        var carry = 0;
        while (true)
        {
            var read = file.Read(buffer, carry, buffer.Length - carry);
            var length = carry + read;
            // Names starting before the limit are whole in the buffer now; the rest wait for the next chunk.
            var limit = read == 0 ? length : Math.Max(0, length - (longest - 1));
            var span = buffer.AsSpan(0, length);
            for (var i = 0; i < limit; i++)
            {
                var k = span[i..limit].IndexOf((byte)'/');
                if (k < 0) break;
                i += k;
                var rest = span[i..];
                for (var n = 0; n < keys.Length; n++)
                    if (rest.Length > 1 && rest[1] == keys[n][1] && rest.StartsWith(keys[n])) found.Add(names[n]);
            }
            if (read == 0 || found.Count == names.Count) return found;
            carry = length - limit;
            buffer.AsSpan(limit, carry).CopyTo(buffer);
        }
    }
}
