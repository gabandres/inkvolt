using System.IO.Compression;
using System.Text;

namespace InkvoltPdf.Bench;

/// <summary>
/// Writes a PDF one object at a time to a stream (a gigabyte file never sits in memory), with a classic cross-reference
/// table. Objects can be reserved ahead (a page needs its parent's number) and written in any order. Nothing in the
/// output depends on the clock or the machine: the same calls give the same bytes.
/// </summary>
public sealed class PdfFileWriter : IDisposable
{
    private static readonly byte[] Header = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A];
    private readonly Stream _out;
    private readonly List<long> _offsets = [-1]; // by object number; 0 is the free-list head
    private long _pos;

    public PdfFileWriter(Stream output)
    {
        _out = output;
        Write(Header);
    }

    /// <summary>Takes the next object number without writing the object yet (see <see cref="Put"/>).</summary>
    public int Reserve()
    {
        _offsets.Add(-1);
        return _offsets.Count - 1;
    }

    public int Add(string body)
    {
        var id = Reserve();
        Put(id, body);
        return id;
    }

    public void Put(int id, string body)
    {
        _offsets[id] = _pos;
        Write($"{id} 0 obj\n{body}\nendobj\n");
    }

    /// <summary>Adds a stream object; <paramref name="entries"/> are the dictionary's other entries ("/Type /XObject …").</summary>
    public int AddStream(string entries, ReadOnlySpan<byte> data, CompressionLevel? compress = CompressionLevel.Optimal)
    {
        var id = Reserve();
        PutStream(id, entries, data, compress);
        return id;
    }

    public void PutStream(int id, string entries, ReadOnlySpan<byte> data, CompressionLevel? compress = CompressionLevel.Optimal)
    {
        if (compress is { } level)
        {
            PutStream(id, entries + " /Filter /FlateDecode", Deflate(data, level), null);
            return;
        }
        _offsets[id] = _pos;
        Write($"{id} 0 obj\n<< {entries} /Length {data.Length} >>\nstream\n");
        Write(data);
        Write("\nendstream\nendobj\n");
    }

    /// <summary>Writes the cross-reference table and trailer. <paramref name="fileId"/> is the document's /ID (32 hex digits).</summary>
    public void Finish(int rootId, int infoId, string fileId)
    {
        var xref = _pos;
        var sb = new StringBuilder();
        sb.Append($"xref\n0 {_offsets.Count}\n0000000000 65535 f \n");
        for (var i = 1; i < _offsets.Count; i++)
        {
            if (_offsets[i] < 0) throw new InvalidOperationException($"Object {i} was reserved but never written.");
            sb.Append($"{_offsets[i]:D10} 00000 n \n");
        }
        sb.Append($"trailer\n<< /Size {_offsets.Count} /Root {rootId} 0 R /Info {infoId} 0 R /ID [<{fileId}> <{fileId}>] >>\nstartxref\n{xref}\n%%EOF\n");
        Write(sb.ToString());
        _out.Flush();
    }

    public static byte[] Deflate(ReadOnlySpan<byte> data, CompressionLevel level)
    {
        using var ms = new MemoryStream(data.Length / 2 + 64);
        using (var z = new ZLibStream(ms, level, leaveOpen: true)) z.Write(data);
        return ms.ToArray();
    }

    /// <summary>A PDF literal string: letters, digits and punctuation only (what the corpus uses), escaped where needed.</summary>
    public static string Str(string s) => "(" + s.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)") + ")";

    private void Write(string s) => Write(Encoding.Latin1.GetBytes(s));

    private void Write(ReadOnlySpan<byte> bytes)
    {
        _out.Write(bytes);
        _pos += bytes.Length;
    }

    public void Dispose() => _out.Dispose();
}

/// <summary>
/// A page tree in groups of <see cref="GroupSize"/> kids under one root (as most generators write them). Reserve the tree
/// first, write each page with <see cref="ParentOf"/> as its /Parent, then <see cref="Write"/> it.
/// </summary>
public sealed class PageTree
{
    public const int GroupSize = 64;
    private readonly PdfFileWriter _w;
    private readonly int[] _groups;
    private readonly List<int> _pages = [];

    public int RootId { get; }

    public PageTree(PdfFileWriter w, int pageCount)
    {
        _w = w;
        RootId = w.Reserve();
        _groups = new int[(pageCount + GroupSize - 1) / GroupSize];
        for (var i = 0; i < _groups.Length; i++) _groups[i] = w.Reserve();
    }

    public int ParentOf(int pageIndex) => _groups[pageIndex / GroupSize];

    /// <summary>Records a page object (written by the caller) in order.</summary>
    public void Add(int pageId) => _pages.Add(pageId);

    public void Write()
    {
        for (var g = 0; g < _groups.Length; g++)
        {
            var kids = _pages.Skip(g * GroupSize).Take(GroupSize).ToList();
            _w.Put(_groups[g], $"<< /Type /Pages /Parent {RootId} 0 R /Count {kids.Count} /Kids [{string.Join(' ', kids.Select(k => $"{k} 0 R"))}] >>");
        }
        _w.Put(RootId, $"<< /Type /Pages /Count {_pages.Count} /Kids [{string.Join(' ', _groups.Select(k => $"{k} 0 R"))}] >>");
    }
}
