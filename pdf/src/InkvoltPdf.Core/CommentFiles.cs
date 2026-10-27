using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

public enum CommentFileFormat { Xfdf, Fdf, Csv }

/// <param name="Data">The file's bytes.</param>
/// <param name="Count">Comments written (replies included).</param>
/// <param name="Left">Annotations not written and why, one line per kind.</param>
public sealed record CommentExport(byte[] Data, int Count, IReadOnlyList<string> Left);

/// <param name="Data">The document with the comments added (<paramref name="Data"/> is the original when none was).</param>
/// <param name="Added">Comments added (replies included).</param>
/// <param name="Skipped">One line per comment not imported: where it is and why (already in the document, no such page,
/// a kind that isn't imported).</param>
/// <param name="Notes">Anything else worth knowing (a reply kept on its own because its comment isn't there).</param>
public sealed record CommentImport(byte[] Data, int Added, IReadOnlyList<string> Skipped, IReadOnlyList<string> Notes);

/// <summary>
/// Comments in and out (roadmap 1.4): a document's comments exported as XFDF (Acrobat's XML, ISO 19444-1), FDF (PDF
/// syntax: each annotation as it is, appearance streams included) or CSV (a row per comment, for spreadsheets), and
/// imported from any of them into a document.
/// <para>
/// What travels: type, text (plain and rich), author, subject, dates, color and fill, opacity, flags, border, line
/// endings, geometry (rectangle, quads, ink strokes, vertices, line points, callouts), the reply tree (/IRT by id, reply
/// or group), review states, and appearances: every one in FDF, a stamp's in XFDF (its <c>appearance</c> element);
/// imported comments without one get Inkvolt's own (drawings from their geometry, highlights from their quads, notes
/// their icon, stamps their design).
/// </para>
/// <para>
/// Import merges: a comment whose id (/NM, XFDF <c>name</c>) is already in the document, or one equal to a comment there
/// (type, page, place, text and author) when it has no id, is skipped and reported, so importing the same file twice
/// adds nothing. Only an allow-list of annotation entries comes in, and every value is cleaned on the way: no actions,
/// JavaScript, file attachments, embedded files or external streams can enter the document; XML is read without DTDs;
/// files over <see cref="MaxFileBytes"/> or with more than <see cref="MaxComments"/> comments are refused.
/// </para>
/// </summary>
public static partial class CommentFiles
{
    public const int MaxFileBytes = 64 * 1024 * 1024;
    public const int MaxComments = 100_000;
    private const int MaxNodes = 4_000_000;

    public static string Extension(CommentFileFormat format) => format switch
    {
        CommentFileFormat.Xfdf => ".xfdf",
        CommentFileFormat.Fdf => ".fdf",
        _ => ".csv",
    };

    /// <summary>The format of a file by its extension (.xfdf, .xml, .fdf, .csv, .txt), or null.</summary>
    public static CommentFileFormat? FormatOf(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".xfdf" or ".xml" => CommentFileFormat.Xfdf,
        ".fdf" => CommentFileFormat.Fdf,
        ".csv" or ".txt" => CommentFileFormat.Csv,
        _ => null,
    };

    /// <summary>One comment on its way in or out: the annotation's entries (keys without the slash, values as in
    /// <see cref="Fdf"/>), its page, its id and the id of the comment it replies to.</summary>
    internal sealed class Record
    {
        public required string Key { get; init; }
        public required int Page { get; init; }
        public required Dictionary<string, object?> Dict { get; init; }
        public string? ReplyTo { get; init; }

        public string Subtype => (Dict.GetValueOrDefault("Subtype") as Fdf.Name)?.Value ?? "";
    }

    /// <summary>Annotations that are not comments: never exported or imported.</summary>
    private static readonly HashSet<string> NotComments = ["Widget", "Link", "Popup", ""];

    /// <summary>Annotations that carry files or media: not exported, never imported.</summary>
    private static readonly HashSet<string> NotCarried = ["FileAttachment", "Sound", "Movie", "Screen", "RichMedia", "3D", "PrinterMark", "TrapNet", "Watermark", "Projection"];

    // ---------------- Export ----------------

    /// <param name="pdfFileName">The PDF's file name, written as the file the comments belong to (XFDF and FDF <c>f</c>).</param>
    public static CommentExport Export(byte[] data, string? password, CommentFileFormat format, string? pdfFileName = null)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF's comments can't be read");
        var (records, left) = Collect(doc);
        var bytes = format switch
        {
            CommentFileFormat.Xfdf => WriteXfdf(records, pdfFileName, left),
            CommentFileFormat.Fdf => WriteFdf(records, pdfFileName),
            _ => WriteCsv(records),
        };
        var count = format == CommentFileFormat.Xfdf ? records.Count(r => XfdfElements.ContainsKey(r.Subtype)) : records.Count;
        return new CommentExport(bytes, count, left);
    }

    /// <summary>The comments of the document, in page order, each with its id (its /NM, else one made from where and what it is).</summary>
    internal static (List<Record> Records, List<string> Left) Collect(PdfDocument doc)
    {
        var found = new List<(int Page, PdfDictionary Annot)>();
        var keys = new Dictionary<PdfDictionary, string>(ReferenceEqualityComparer.Instance);
        var left = new SortedDictionary<string, int>(StringComparer.Ordinal);
        for (var p = 0; p < doc.PageCount; p++)
        {
            if (PdfObj.Array(doc.Pages[p].Elements["/Annots"]) is not { } annots) continue;
            for (var i = 0; i < annots.Elements.Count; i++)
            {
                if (PdfObj.Dict(annots.Elements[i]) is not { } a || keys.ContainsKey(a)) continue;
                var subtype = PdfObj.Name(a.Elements["/Subtype"]) ?? "";
                if (NotComments.Contains(subtype)) continue;
                if (NotCarried.Contains(subtype))
                {
                    left[subtype] = left.GetValueOrDefault(subtype) + 1;
                    continue;
                }
                found.Add((p, a));
                keys[a] = PdfObj.Str(a.Elements["/NM"]) is { Length: > 0 } nm ? nm : MadeKey(p, i, subtype, a);
            }
        }
        var portable = new ToPortable();
        var records = found.Select(f => new Record
        {
            Key = keys[f.Annot],
            Page = f.Page,
            Dict = portable.Annotation(f.Annot),
            ReplyTo = PdfObj.Dict(f.Annot.Elements["/IRT"]) is { } target && keys.TryGetValue(target, out var k) ? k : null,
        }).ToList();
        var lines = left.Select(kv => $"{Plural(kv.Value, KindName(kv.Key))}: not exported (they hold files or media)").ToList();
        return (records, lines);
    }

    /// <summary>An id for a comment without /NM: the same for the same comment of the same file, every time.</summary>
    private static string MadeKey(int page, int index, string subtype, PdfDictionary a)
    {
        var text = string.Join('\u001f', page.ToString(CultureInfo.InvariantCulture), index.ToString(CultureInfo.InvariantCulture), subtype,
            Rect(PdfObj.Array(a.Elements["/Rect"])), PdfObj.Str(a.Elements["/Contents"]) ?? "", PdfObj.Str(a.Elements["/T"]) ?? "", PdfObj.Str(a.Elements["/M"]) ?? "");
        return "inkvoltpdf-x-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..24];

        static string Rect(PdfArray? r) => r is null ? "" : string.Join(' ', Enumerable.Range(0, r.Elements.Count).Select(k => Fdf.Number(PdfObj.Num(r, k))));
    }

    /// <summary>PDFsharp objects to plain values: shared objects once, cycles cut, references to pages and the
    /// document's structure left out (they mean nothing in another file).</summary>
    private sealed class ToPortable
    {
        private readonly Dictionary<PdfObject, object?> _done = new(ReferenceEqualityComparer.Instance);
        private readonly HashSet<PdfObject> _path = new(ReferenceEqualityComparer.Instance);
        private int _nodes;

        /// <summary>Entries of an annotation that point into its document (or are its actions): never exported.</summary>
        private static readonly HashSet<string> SkipTop = ["P", "Parent", "Popup", "IRT", "StructParent", "OC", "A", "AA", "PA", "PieceInfo"];

        /// <summary>Entries deeper down that lead out into the document.</summary>
        private static readonly HashSet<string> SkipNested = ["P", "Parent", "Popup", "IRT", "StructParent", "StructParents", "Annots", "Pages", "AA"];

        public Dictionary<string, object?> Annotation(PdfDictionary a)
        {
            var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var key in a.Elements.Keys)
            {
                var name = key.TrimStart('/');
                if (!SkipTop.Contains(name)) dict[name] = Value(a.Elements[key], 1);
            }
            return dict;
        }

        private object? Value(PdfItem? item, int depth)
        {
            if (++_nodes > MaxNodes || depth > 32) return null;
            PdfObject? shared = null;
            if (item is PdfReference r)
            {
                item = r.Value;
                shared = item as PdfObject;
            }
            if (shared is not null)
            {
                if (_done.TryGetValue(shared, out var known)) return known;
                if (!_path.Add(shared)) return null;
            }
            try
            {
                object? result = item switch
                {
                    PdfDictionary d => Dict(d, depth),
                    PdfArray arr => arr.Elements.Select(x => Value(x, depth + 1)).ToList(),
                    PdfName n => new Fdf.Name(n.Value.TrimStart('/')),
                    PdfString s => s.Value,
                    PdfBoolean b => b.Value,
                    PdfInteger i => (double)i.Value,
                    PdfLongInteger l => (double)l.Value,
                    PdfReal x => x.Value,
                    _ => null,
                };
                if (shared is not null) _done[shared] = result;
                return result;
            }
            finally
            {
                if (shared is not null) _path.Remove(shared);
            }
        }

        private object Dict(PdfDictionary d, int depth)
        {
            var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var key in d.Elements.Keys)
            {
                var name = key.TrimStart('/');
                if (SkipNested.Contains(name) || name == "Length" && d.Stream is not null) continue;
                dict[name] = Value(d.Elements[key], depth + 1);
            }
            return d.Stream is { } s ? new Fdf.Stream(dict, s.Value ?? []) : dict;
        }
    }

    private static byte[] WriteFdf(List<Record> records, string? pdfFileName)
    {
        var w = new Fdf.Writer();
        var root = w.Reserve();
        var refs = records.Select(_ => w.Reserve()).ToList();
        var byKey = new Dictionary<string, Fdf.Ref>(StringComparer.Ordinal);
        for (var i = 0; i < records.Count; i++) byKey.TryAdd(records[i].Key, refs[i]);
        for (var i = 0; i < records.Count; i++)
        {
            var r = records[i];
            var dict = new Dictionary<string, object?>(r.Dict, StringComparer.Ordinal)
            {
                ["Page"] = (double)r.Page,
                ["NM"] = r.Key,
            };
            if (r.ReplyTo is { } to && byKey.TryGetValue(to, out var target)) dict["IRT"] = target;
            w.Set(refs[i], dict);
        }
        var fdf = new Dictionary<string, object?>(StringComparer.Ordinal) { ["Annots"] = refs.Cast<object?>().ToList() };
        if (pdfFileName is not null) fdf["F"] = pdfFileName;
        w.Set(root, new Dictionary<string, object?>(StringComparer.Ordinal) { ["FDF"] = fdf, ["Type"] = new Fdf.Name("Catalog") });
        return w.Finish(root);
    }

    // ---------------- Import ----------------

    /// <summary>Adds the comments in <paramref name="file"/> (XFDF, FDF or CSV, told apart by their content) to the document.</summary>
    /// <exception cref="InvalidDataException">The file isn't one of them, is damaged, too big, or carries a DTD.</exception>
    public static CommentImport Import(byte[] data, string? password, byte[] file)
    {
        var (records, skipped) = Parse(file);
        var notes = new List<string>();
        using var doc = Annotations.OpenForEdit(data, password);

        // What is already there: by id, and by what it is for comments without one.
        var byKey = new Dictionary<string, PdfDictionary>(StringComparer.Ordinal);
        var byLook = new Dictionary<string, PdfDictionary>(StringComparer.Ordinal);
        for (var p = 0; p < doc.PageCount; p++)
            foreach (var a in PdfObj.Array(doc.Pages[p].Elements["/Annots"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>() ?? [])
            {
                if (PdfObj.Str(a.Elements["/NM"]) is { Length: > 0 } nm) byKey.TryAdd(nm, a);
                byLook.TryAdd(Look(p, PdfObj.Name(a.Elements["/Subtype"]) ?? "", PdfObj.Array(a.Elements["/Rect"]) is { } r ? [.. Enumerable.Range(0, r.Elements.Count).Select(k => PdfObj.Num(r, k))] : null,
                    PdfObj.Str(a.Elements["/Contents"]), PdfObj.Str(a.Elements["/T"])), a);
            }

        var added = new List<(Record Record, PdfDictionary Annot)>();
        var builder = new FromPortable(doc);
        foreach (var r in records)
        {
            var subtype = r.Subtype;
            string Where() => $"Page {r.Page + 1}, {KindName(subtype)}{(r.Dict.GetValueOrDefault("T") is string { Length: > 0 } t ? " by " + t : "")}";
            if (r.Page < 0 || r.Page >= doc.PageCount)
            {
                skipped.Add($"{Where()}: the document has no page {r.Page + 1}");
                continue;
            }
            if (NotComments.Contains(subtype) || NotCarried.Contains(subtype))
            {
                skipped.Add($"{Where()}: {(NotCarried.Contains(subtype) ? "files and media aren't imported" : "not a comment")}");
                continue;
            }
            if (byKey.ContainsKey(r.Key))
            {
                skipped.Add($"{Where()}: already in the document");
                continue;
            }
            var rect = Numbers(r.Dict.GetValueOrDefault("Rect"));
            if (rect is not { Count: 4 } || rect.Any(v => !double.IsFinite(v)))
            {
                skipped.Add($"{Where()}: it has no position");
                continue;
            }
            if (byLook.TryGetValue(Look(r.Page, subtype, rect, r.Dict.GetValueOrDefault("Contents") as string, r.Dict.GetValueOrDefault("T") as string), out var same))
            {
                byKey[r.Key] = same;
                skipped.Add($"{Where()}: already in the document");
                continue;
            }

            var page = doc.Pages[r.Page];
            var annot = new PdfDictionary(doc);
            foreach (var (key, value) in Allowed(r.Dict))
                if (builder.Item(value) is { } item) annot.Elements["/" + key] = item;
            annot.Elements["/Type"] = new PdfName("/Annot");
            annot.Elements["/NM"] = PdfObj.MakeString(r.Key);
            annot.Elements["/P"] = page.Reference!;
            doc.Internals.AddObject(annot);
            PdfObj.Annots(doc, page).Elements.Add(annot.Reference!);
            if (!HasAppearance(annot)) Annotations.MakeAppearance(doc, page, annot);
            byKey[r.Key] = annot;
            added.Add((r, annot));
        }

        var orphans = 0;
        foreach (var (r, annot) in added)
        {
            if (r.ReplyTo is not { } to) continue;
            if (byKey.TryGetValue(to, out var target) && !ReferenceEquals(target, annot) && target.Reference is not null)
            {
                annot.Elements["/IRT"] = target.Reference;
                if (r.Dict.GetValueOrDefault("RT") is Fdf.Name { Value: "Group" }) annot.Elements["/RT"] = new PdfName("/Group");
            }
            else
            {
                orphans++;
                annot.Elements.Remove("/RT");
            }
        }
        if (orphans > 0)
            notes.Add($"{Plural(orphans, "reply", "replies")} kept as comments of their own: the comment they answer is neither in the document nor in the file.");
        if (added.Count == 0) return new CommentImport(data, 0, skipped, notes);
        return new CommentImport(PdfObj.Save(doc), added.Count, skipped, notes);
    }

    /// <summary>How many comments <paramref name="file"/> holds: checks it can be imported before any edit starts.</summary>
    /// <exception cref="InvalidDataException">As <see cref="Import"/>.</exception>
    public static int Count(byte[] file) => Parse(file).Records.Count;

    /// <summary>The comments in an XFDF, FDF or CSV file, and lines for those that can't be read.</summary>
    internal static (List<Record> Records, List<string> Skipped) Parse(byte[] file)
    {
        if (file.Length == 0) throw new InvalidDataException("The file is empty.");
        if (file.Length > MaxFileBytes) throw new InvalidDataException($"The file is larger than {MaxFileBytes >> 20} MB, the most Inkvolt PDF imports.");
        var skipped = new List<string>();
        var start = file.Length >= 3 && file[0] == 0xEF && file[1] == 0xBB && file[2] == 0xBF ? 3 : 0;
        while (start < file.Length && file[start] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') start++;
        List<Record> records;
        if (start < file.Length && file[start] == (byte)'<') records = ReadXfdf(file, skipped);
        else if (file.AsSpan(start).StartsWith("%FDF"u8)) records = ReadFdf(file, skipped);
        else records = ReadCsv(file, skipped);
        if (records.Count > MaxComments) throw new InvalidDataException($"The file has more than {MaxComments:N0} comments, the most Inkvolt PDF imports.");
        return (records, skipped);
    }

    private static List<Record> ReadFdf(byte[] file, List<string> skipped)
    {
        Fdf.Document fdf;
        try
        {
            fdf = Fdf.Read(Encoding.Latin1.GetString(file));
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException or IndexOutOfRangeException)
        {
            throw new InvalidDataException("The FDF file is damaged.", ex);
        }
        if (fdf.FdfDict() is not { } root) throw new InvalidDataException("The FDF file has no /FDF dictionary.");
        if (fdf.Resolve(root.GetValueOrDefault("Annots")) is not List<object?> list) return [];
        if (list.Count > MaxComments) throw new InvalidDataException($"The file has more than {MaxComments:N0} comments, the most Inkvolt PDF imports.");

        var cleaner = new Cleaner(fdf.Resolve);
        var dicts = list.Select(fdf.Resolve).OfType<Dictionary<string, object?>>().ToList();
        var keys = new Dictionary<Dictionary<string, object?>, string>(ReferenceEqualityComparer.Instance);
        for (var i = 0; i < dicts.Count; i++)
            keys.TryAdd(dicts[i], fdf.Resolve(dicts[i].GetValueOrDefault("NM")) is string { Length: > 0 } nm ? nm : HashKey("fdf", i, fdf, dicts[i]));
        var records = new List<Record>();
        foreach (var d in dicts)
        {
            var page = fdf.Resolve(d.GetValueOrDefault("Page")) is double pg && pg is >= 0 and < int.MaxValue ? (int)pg : -1;
            var clean = cleaner.Annotation(d);
            if (clean is null) continue;
            string? replyTo = fdf.Resolve(d.GetValueOrDefault("IRT")) is Dictionary<string, object?> parent && keys.TryGetValue(parent, out var pk) ? pk
                : fdf.Resolve(d.GetValueOrDefault("IRT")) is string s ? s : null;
            records.Add(new Record { Key = keys[d], Page = page, Dict = clean, ReplyTo = replyTo });
        }
        return records;
    }

    /// <summary>An id for an imported comment without one, from what it is.</summary>
    private static string HashKey(string kind, int index, Fdf.Document? doc, Dictionary<string, object?> d)
    {
        var text = new StringBuilder(kind).Append(index);
        foreach (var key in new[] { "Subtype", "Page", "Rect", "Contents", "T", "M" })
            text.Append('\u001f').Append(new Fdf.Writer().Serialize(doc is null ? d.GetValueOrDefault(key) : Shallow(doc.Resolve(d.GetValueOrDefault(key)))));
        return "inkvoltpdf-x-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())))[..24];

        static object? Shallow(object? o) => o is Fdf.Stream ? null : o;
    }

    /// <summary>Comments are the same when they are of one type, on one page, in one place (to the point), with the same text and author.</summary>
    private static string Look(int page, string subtype, IReadOnlyList<double>? rect, string? contents, string? author) =>
        string.Join('\u001f', page.ToString(CultureInfo.InvariantCulture), subtype,
            rect is { Count: 4 } ? string.Join(' ', new[] { Math.Min(rect[0], rect[2]), Math.Min(rect[1], rect[3]), Math.Max(rect[0], rect[2]), Math.Max(rect[1], rect[3]) }
                .Select(v => Math.Round(v).ToString(CultureInfo.InvariantCulture))) : "",
            (contents ?? "").Replace("\r\n", "\n").Replace('\r', '\n'), author ?? "");

    private static bool HasAppearance(PdfDictionary annot) =>
        PdfObj.Dict(annot.Elements["/AP"]) is { } ap && PdfObj.Resolve(ap.Elements["/N"]) is PdfDictionary;

    internal static List<double>? Numbers(object? o) =>
        o is List<object?> list && list.All(x => x is double) ? [.. list.Cast<double>()] : null;

    // ---------------- Cleaning what comes in ----------------

    /// <summary>The annotation entries an import keeps. Everything else (actions, /A, /AA, popups, files, structure,
    /// layers, private data of other apps) stays out.</summary>
    private static readonly HashSet<string> AllowedKeys =
    [
        "Subtype", "Rect", "Contents", "M", "F", "C", "CA", "ca", "T", "Subj", "CreationDate", "RT", "IT", "QuadPoints", "InkList", "L",
        "LE", "Vertices", "BS", "Border", "BE", "IC", "DA", "DS", "Q", "RC", "RD", "CL", "Name", "Open", "Rotate", "State", "StateModel",
        "AP", "AS", "LL", "LLE", "LLO", "Cap", "CP", "CO", "Measure", "Sy", "OverlayText", "Repeat", "RO", "Lang", "InkvoltPdfStamp",
    ];

    private static IEnumerable<KeyValuePair<string, object?>> Allowed(Dictionary<string, object?> d) =>
        d.Where(kv => AllowedKeys.Contains(kv.Key) && kv.Value is not null);

    /// <summary>
    /// Values made safe: references resolved (cycles cut), and anything that could act removed at every depth: action
    /// and file specification dictionaries, entries naming actions, JavaScript, files or the document's structure, and
    /// streams with external data or PostScript.
    /// </summary>
    internal sealed class Cleaner(Func<object?, object?> resolve)
    {
        private static readonly HashSet<string> ActionTypes =
        [
            "JavaScript", "Launch", "SubmitForm", "ResetForm", "ImportData", "URI", "GoTo", "GoToR", "GoToE", "GoToDp", "Named", "Rendition",
            "Movie", "Sound", "Hide", "SetOCGState", "Trans", "GoTo3DView", "RichMediaExecute", "Thread", "SetState", "NOP", "ECMAScript",
        ];

        private static readonly HashSet<string> DroppedKeys =
        [
            "AA", "JS", "JavaScript", "OpenAction", "URI", "Launch", "EF", "EmbeddedFiles", "FS", "RichMediaContent",
            "RichMediaSettings", "Sound", "Movie", "P", "Parent", "Popup", "StructParent", "StructParents", "PieceInfo", "OC", "Annots",
            "Pages", "XFA", "AcroForm",
        ];

        private readonly Dictionary<object, object?> _done = new(ReferenceEqualityComparer.Instance);
        private readonly HashSet<object> _path = new(ReferenceEqualityComparer.Instance);
        private int _nodes;

        public Dictionary<string, object?>? Annotation(Dictionary<string, object?> d) => Value(d, 0) as Dictionary<string, object?>;

        public object? Value(object? v, int depth)
        {
            if (++_nodes > MaxNodes) throw new InvalidDataException("The file holds more objects than Inkvolt PDF imports.");
            if (depth > 32) return null;
            v = resolve(v);
            if (v is Dictionary<string, object?> or Fdf.Stream or List<object?>)
            {
                if (_done.TryGetValue(v, out var known)) return known;
                if (!_path.Add(v)) return null;
                try
                {
                    object? result = v switch
                    {
                        Dictionary<string, object?> d => Dict(d, depth),
                        Fdf.Stream s => Stream(s, depth),
                        List<object?> l => l.Count > 1_000_000 ? null : l.Select(x => Value(x, depth + 1)).ToList(),
                        _ => null,
                    };
                    _done[v] = result;
                    return result;
                }
                finally
                {
                    _path.Remove(v);
                }
            }
            return v switch
            {
                double d => double.IsFinite(d) ? d : null,
                string or bool or Fdf.Name => v,
                _ => null,
            };
        }

        private Dictionary<string, object?>? Dict(Dictionary<string, object?> d, int depth)
        {
            if (IsActionOrFile(d)) return null;
            var clean = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var (key, value) in d)
            {
                if (DroppedKeys.Contains(key) || key == "IRT") continue;
                if (Value(value, depth + 1) is { } item) clean[key] = item;
            }
            return clean;
        }

        private Fdf.Stream? Stream(Fdf.Stream s, int depth)
        {
            if (IsActionOrFile(s.Dict) || resolve(s.Dict.GetValueOrDefault("Subtype")) is Fdf.Name { Value: "PS" }) return null;
            if (s.Dict.ContainsKey("F") || s.Dict.ContainsKey("FFilter")) return null; // data in an external file
            var clean = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var (key, value) in s.Dict)
            {
                if (DroppedKeys.Contains(key) || key is "Length" or "DL" or "FDecodeParms" or "Metadata") continue;
                if (Value(value, depth + 1) is { } item) clean[key] = item;
            }
            return new Fdf.Stream(clean, s.Data);
        }

        private bool IsActionOrFile(Dictionary<string, object?> d) =>
            resolve(d.GetValueOrDefault("Type")) is Fdf.Name { Value: "Action" or "Filespec" or "EmbeddedFile" }
            || resolve(d.GetValueOrDefault("S")) is Fdf.Name s && ActionTypes.Contains(s.Value)
            || d.ContainsKey("JS");
    }

    /// <summary>Plain values to PDFsharp objects in <paramref name="doc"/>; streams become indirect objects, each once.</summary>
    private sealed class FromPortable(PdfDocument doc)
    {
        private readonly Dictionary<Fdf.Stream, PdfReference> _streams = new(ReferenceEqualityComparer.Instance);

        public PdfItem? Item(object? v, int depth = 0)
        {
            if (depth > 40) return null;
            switch (v)
            {
                case Fdf.Stream s:
                {
                    if (_streams.TryGetValue(s, out var known)) return known;
                    var d = new PdfDictionary(doc);
                    d.CreateStream(s.Data);
                    foreach (var (key, value) in s.Dict)
                        if (Item(value, depth + 1) is { } item) d.Elements["/" + key] = item;
                    doc.Internals.AddObject(d);
                    _streams[s] = d.Reference!;
                    return d.Reference;
                }
                case Dictionary<string, object?> dict:
                {
                    var d = new PdfDictionary(doc);
                    foreach (var (key, value) in dict)
                        if (Item(value, depth + 1) is { } item) d.Elements["/" + key] = item;
                    return d;
                }
                case List<object?> list:
                    return new PdfArray(doc, [.. list.Select(x => Item(x, depth + 1) ?? PdfNull.Value)]);
                case Fdf.Name n:
                    return new PdfName("/" + n.Value);
                case string s:
                    return PdfObj.MakeString(s);
                case bool b:
                    return new PdfBoolean(b);
                case double d:
                    return Math.Abs(d - Math.Round(d)) < 1e-9 && Math.Abs(d) < int.MaxValue ? new PdfInteger((int)Math.Round(d)) : new PdfReal(d);
                default:
                    return null;
            }
        }
    }

    // ---------------- Words ----------------

    /// <summary>What a comment of <paramref name="subtype"/> is called ("highlight", "note", "drawing").</summary>
    public static string KindName(string subtype) => subtype switch
    {
        "Text" => "note",
        "FreeText" => "text box",
        "Highlight" => "highlight",
        "Underline" => "underline",
        "StrikeOut" => "strike-through",
        "Squiggly" => "squiggly underline",
        "Ink" => "drawing",
        "Square" => "rectangle",
        "Circle" => "ellipse",
        "Line" => "line",
        "Polygon" => "polygon",
        "PolyLine" => "connected lines",
        "Stamp" => "stamp",
        "Caret" => "insert mark",
        "Redact" => "redaction mark",
        "FileAttachment" => "file attachment",
        "Sound" => "sound",
        "" => "comment",
        _ => subtype,
    };

    private static string Plural(int n, string word, string? plural = null) =>
        n == 1 ? $"1 {word}" : $"{n.ToString("N0", CultureInfo.InvariantCulture)} {plural ?? (word.EndsWith('s') ? word : word + "s")}";
}
