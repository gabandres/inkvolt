using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// The redaction check's search of the file's data: the values in every object of the document (strings, decoded
/// streams, the text content streams show in their own fonts, attached files), named by what holds them; in each earlier
/// version kept by incremental saves; and in the file's raw bytes with every stream decompressed.
/// </summary>
public static partial class RedactionCheck
{
    /// <summary>Largest decompressed stream or attached file part looked into (bytes).</summary>
    private const int MaxStreamBytes = 64 << 20;

    /// <summary>
    /// Finds the values in text: case and spacing ignored (any run of spaces or line breaks matches a space, soft hyphens
    /// are skipped), whole words only. A value made of digits and separators (a Social Security, phone or card number)
    /// also matches its digits written with other separators or none.
    /// </summary>
    internal sealed class ValueMatcher
    {
        private readonly Regex? _regex;
        private readonly bool[] _digits = [];
        private readonly bool[] _wordStart = [], _wordEnd = [];

        public IReadOnlyList<string> Values { get; }
        public bool IsEmpty => _regex is null;

        public ValueMatcher(IReadOnlyList<string> values)
        {
            Values = values;
            if (values.Count == 0) return;
            _digits = new bool[values.Count];
            _wordStart = new bool[values.Count];
            _wordEnd = new bool[values.Count];
            var parts = new List<string>();
            for (var i = 0; i < values.Count; i++)
            {
                var v = values[i];
                _digits[i] = v.Count(char.IsDigit) >= 5 && !v.Any(char.IsLetter);
                _wordStart[i] = char.IsLetterOrDigit(v[0]);
                _wordEnd[i] = char.IsLetterOrDigit(v[^1]);
                var pattern = _digits[i]
                    ? string.Join(@"[\s\-./()]{0,3}", v.Where(char.IsDigit).Select(c => c.ToString()))
                    : string.Join(@"[\s­]+", v.Split(' ').Select(w => string.Join(@"­?", w.Select(c => Regex.Escape(c.ToString())))));
                parts.Add($"({pattern})");
            }
            _regex = new Regex(string.Join('|', parts), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromSeconds(10));
        }

        /// <summary>Every match: which value, where.</summary>
        public IEnumerable<(int Value, int Start, int Length)> Matches(string text)
        {
            if (_regex is null || text.Length == 0) yield break;
            MatchCollection found;
            try
            {
                found = _regex.Matches(text);
                _ = found.Count; // run it here, inside the try
            }
            catch (RegexMatchTimeoutException)
            {
                yield break;
            }
            foreach (Match m in found)
            {
                var v = -1;
                for (var g = 1; g < m.Groups.Count && v < 0; g++)
                    if (m.Groups[g].Success) v = g - 1;
                if (v < 0) continue;
                int s = m.Index, e = m.Index + m.Length;
                var before = s > 0 ? text[s - 1] : ' ';
                var after = e < text.Length ? text[e] : ' ';
                if (_digits[v] ? char.IsDigit(before) || char.IsDigit(after)
                    : _wordStart[v] && char.IsLetterOrDigit(before) || _wordEnd[v] && char.IsLetterOrDigit(after)) continue;
                yield return (v, s, m.Length);
            }
        }
    }

    /// <summary>What holds an object: a page (its dictionary, its content), a comment or field, the outline, ...</summary>
    private enum Part { Page, Content, Annotation, Field, Xfa, Bookmark, Info, Attachment, Structure }

    /// <param name="Resources">For content streams (page content, forms, appearances): their resources, to read their text.</param>
    private sealed record Owner(Part Part, int Page, string Where, SanitizeItem? Fix, PdfDictionary? Resources = null);

    private sealed partial class Check
    {
        private readonly HashSet<int> _hit = []; // values found somewhere
        private int _hiddenLayers;

        /// <summary>
        /// Every object of the document, searched for the values; a hit is reported as what holds it (page content that
        /// shows it is the page text's finding already). Returns the values found in the document's objects.
        /// </summary>
        private HashSet<int> Objects(PdfDocument doc, ValueMatcher matcher)
        {
            var inFile = new HashSet<int>();
            var owners = Owners(doc, cancel);
            var used = Used(doc);
            var n = 0;
            foreach (var o in doc.Internals.GetAllObjects())
            {
                if ((++n & 255) == 0) cancel.ThrowIfCancellationRequested();
                var owner = owners.GetValueOrDefault(o);
                var text = ObjectText(o, owner);
                if (text.Length == 0) continue;
                foreach (var (v, start, length) in matcher.Matches(text).DistinctBy(m => m.Value).ToList())
                {
                    inFile.Add(v);
                    _hit.Add(v);
                    var found = Excerpt(text, start, length);
                    if (owner?.Part == Part.Content) continue; // compared with what the page shows below
                    Add(owner is not null ? Finding(owner, found) : Unowned(o, found, used.Contains(o)));
                }
            }
            HiddenInContent(matcher, owners);
            return inFile;
        }

        /// <summary>
        /// A value that a page's content draws more often than the page's text holds it is in the content where it doesn't
        /// show: a hidden layer, clipped away (text outside the page and covered text are in the page text, and were
        /// reported already).
        /// </summary>
        private void HiddenInContent(ValueMatcher matcher, Dictionary<PdfObject, Owner> owners)
        {
            foreach (var group in owners.Where(kv => kv.Value.Part == Part.Content && kv.Key is PdfDictionary { Stream: not null }).GroupBy(kv => kv.Value.Page))
            {
                var p = group.Key;
                if (p < 0 || p >= _texts.Length) continue;
                cancel.ThrowIfCancellationRequested();
                var drawn = new Dictionary<int, int>();
                foreach (var (o, owner) in group)
                {
                    byte[] bytes;
                    try
                    {
                        bytes = PdfObj.StreamBytes((PdfDictionary)o);
                    }
                    catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
                    {
                        continue;
                    }
                    var (spaced, joined) = ContentTexts(bytes, owner.Resources);
                    var a = matcher.Matches(spaced).CountBy(m => m.Value).ToDictionary();
                    var b = matcher.Matches(joined).CountBy(m => m.Value).ToDictionary();
                    foreach (var v in a.Keys.Union(b.Keys)) drawn[v] = drawn.GetValueOrDefault(v) + Math.Max(a.GetValueOrDefault(v), b.GetValueOrDefault(v));
                }
                var shown = matcher.Matches(_texts[p].Text).CountBy(m => m.Value).ToDictionary();
                foreach (var (v, count) in drawn)
                {
                    if (count <= shown.GetValueOrDefault(v)) continue;
                    _hit.Add(v);
                    Add(new RedactionFinding(RedactionLeak.HiddenText, $"Page {p + 1}, in its content but not shown", matcher.Values[v])
                        { Page = p, Box = OffPage, Sanitize = _hiddenLayers > 0 ? SanitizeItem.HiddenLayers : null });
                }
            }
        }

        private static RedactionFinding Finding(Owner o, string text)
        {
            var kind = o.Part switch
            {
                Part.Annotation => RedactionLeak.Annotation,
                Part.Field or Part.Xfa => RedactionLeak.FormField,
                Part.Bookmark => RedactionLeak.Bookmark,
                Part.Info or Part.Page => RedactionLeak.Metadata,
                Part.Attachment => RedactionLeak.Attachment,
                Part.Structure => RedactionLeak.StructureTree,
                _ => RedactionLeak.FileData,
            };
            if (o.Fix == SanitizeItem.FormValues && o.Part == Part.Annotation) kind = RedactionLeak.FormField;
            return new RedactionFinding(kind, o.Where, text) { Page = o.Page, Sanitize = o.Fix };
        }

        /// <summary>An object no walk from the catalog named: classified by its own type.</summary>
        private static RedactionFinding Unowned(PdfObject o, string text, bool used)
        {
            var d = o as PdfDictionary;
            var type = d is null ? "" : PdfObj.NameOf(d, "/Type");
            var number = o.Reference?.ObjectNumber ?? 0;
            if (type == "/Metadata") return new(RedactionLeak.Metadata, "XMP metadata", text) { Sanitize = SanitizeItem.Metadata };
            if (d is not null && (d.Elements.ContainsKey("/JS") || PdfObj.NameOf(d, "/S") == "/JavaScript"))
                return new(RedactionLeak.FileData, "A script (JavaScript)", text) { Sanitize = SanitizeItem.ActiveContent };
            if (type is "/Filespec" or "/EmbeddedFile") return new(RedactionLeak.Attachment, "An attached file", text) { Sanitize = SanitizeItem.EmbeddedFiles };
            if (type == "/Annot") return new(RedactionLeak.Annotation, "A comment", text) { Sanitize = SanitizeItem.Comments };
            if (type == "/StructElem") return new(RedactionLeak.StructureTree, "Tags (structure tree)", text);
            if (!used) return new(RedactionLeak.FileData, $"Object {number}, which nothing in the document uses", text) { Rewrite = true };
            return new(RedactionLeak.FileData, $"Object {number} of the file", text);
        }

        /// <summary>The objects the document reaches from its catalog and its properties.</summary>
        private static HashSet<PdfObject> Used(PdfDocument doc)
        {
            var used = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance) { doc.Internals.Catalog, doc.Info };
            try
            {
                foreach (var root in new PdfObject[] { doc.Internals.Catalog, doc.Info })
                    foreach (object o in doc.Internals.GetClosure(root))
                        if ((o is PdfReference r ? r.Value : o) is PdfObject obj) used.Add(obj);
            }
            catch (Exception ex) when (ex is InvalidOperationException or NullReferenceException)
            {
                // A closure that can't be walked: count everything as used (nothing is called unused wrongly).
                foreach (var o in doc.Internals.GetAllObjects()) used.Add(o);
            }
            return used;
        }

        /// <summary>What matched, with up to 20 characters around it from the same line (string), 80 at most.</summary>
        private static string Excerpt(string text, int start, int length)
        {
            var lineStart = text.LastIndexOf('\n', Math.Max(0, start - 1)) + 1;
            var lineEnd = text.IndexOf('\n', start + length) is var n and >= 0 ? n : text.Length;
            var s = Math.Max(lineStart, start - 20);
            var e = Math.Min(lineEnd, start + length + 20);
            if (length >= 60) (s, e) = (start, Math.Min(lineEnd, start + 80));
            var part = string.Join(' ', text[s..e].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            return (s > lineStart ? "…" : "") + part + (e < lineEnd ? "…" : "");
        }

        /// <summary>
        /// The earlier versions of the file (kept by incremental saves), each opened on its own: the values in their
        /// objects that the current version no longer holds, and text their pages showed that the current pages don't.
        /// </summary>
        private void EarlierVersions(PdfEngine engine, ValueMatcher? matcher, HashSet<int> inFile, List<int> ends)
        {
            if (ends.Count == 0) return;
            if (ends.Count > MaxRevisions) _notes.Add($"Only the last {MaxRevisions} of the file's {ends.Count} earlier versions were checked.");
            var current = new HashSet<string>(_texts.SelectMany(t => Words(t.Text)));
            var reported = new HashSet<int>();
            var first = Math.Max(0, ends.Count - MaxRevisions);
            for (var k = first; k < ends.Count; k++)
            {
                cancel.ThrowIfCancellationRequested();
                var prefix = data.AsSpan(0, ends[k]).ToArray();
                var where = $"Earlier version {k + 1} of the file";
                try
                {
                    if (matcher is not null)
                    {
                        using var old = PdfObj.Open(prefix, password, PdfDocumentOpenMode.Import);
                        var owners = Owners(old, cancel);
                        foreach (var o in old.Internals.GetAllObjects())
                        {
                            var text = ObjectText(o, owners.GetValueOrDefault(o));
                            foreach (var (v, start, length) in matcher.Matches(text).DistinctBy(m => m.Value).ToList())
                            {
                                if (inFile.Contains(v) || !reported.Add(v)) continue;
                                _hit.Add(v);
                                Add(new RedactionFinding(RedactionLeak.EarlierRevision, where, Excerpt(text, start, length)) { Rewrite = true });
                            }
                        }
                    }
                    using var pages = PdfEngine.Open(prefix, InputFileTypes.PDF, password);
                    for (var p = 0; p < pages.PageCount; p++)
                    {
                        var gone = Words(pages.GetText(p, cache: false, cancel).Text).Where(w => !current.Contains(w)).Distinct().ToList();
                        if (gone.Count == 0) continue;
                        Add(new RedactionFinding(RedactionLeak.EarlierRevision, $"{where}, page {p + 1}",
                            "Text no longer on the pages: " + string.Join(" ", gone.Take(12)) + (gone.Count > 12 ? " …" : "")) { Rewrite = true });
                    }
                }
                catch (Exception ex) when (ex is InvalidOperationException or MuPDFException or PasswordRequiredException or PdfSharp.PdfSharpException or ArgumentException)
                {
                    _notes.Add($"{where} couldn't be read on its own.");
                }
                Step();
            }
        }

        private static IEnumerable<string> Words(string text) =>
            WordPattern().Matches(text).Where(m => m.Length >= 3).Select(m => m.Value.ToLowerInvariant());

        /// <summary>
        /// The file's raw bytes, every stream in them decompressed, for values found nowhere else: bytes outside the objects
        /// the document reads (an unencrypted file only; an encrypted one's bytes are ciphertext).
        /// </summary>
        private void RawBytes(PdfDocument doc, ValueMatcher matcher, HashSet<int> inFile)
        {
            if (doc.SecurityHandler.Elements.ContainsKey("/Filter")) return;
            if (Enumerable.Range(0, matcher.Values.Count).All(_hit.Contains)) return;
            var text = RawText(data, cancel);
            foreach (var (v, start, length) in matcher.Matches(text).DistinctBy(m => m.Value).ToList())
            {
                if (!_hit.Add(v) || inFile.Contains(v)) continue;
                Add(new RedactionFinding(RedactionLeak.FileData, "The file's bytes, outside the objects the document reads", Excerpt(text, start, length)) { Rewrite = true });
            }
        }
    }

    /// <summary>
    /// Where the earlier versions of the file end (after each %%EOF that closes a version), oldest first, the current
    /// version left out; a linearized file's first-page section isn't a version.
    /// </summary>
    internal static List<int> Revisions(byte[] data)
    {
        var ends = new List<int>();
        var span = data.AsSpan();
        for (var at = 0; ;)
        {
            var i = span[at..].IndexOf("%%EOF"u8);
            if (i < 0) break;
            var pos = at + i;
            var end = pos + 5;
            while (end < data.Length && data[end] is (byte)'\r' or (byte)'\n') end++;
            if (span[Math.Max(0, pos - 64)..pos].IndexOf("startxref"u8) >= 0) ends.Add(end);
            at = pos + 5;
        }
        // The last one closes the current version (whatever junk follows it).
        if (ends.Count > 0) ends.RemoveAt(ends.Count - 1);
        if (ends.Count > 0 && data.AsSpan(0, Math.Min(data.Length, 2048)).IndexOf("/Linearized"u8) >= 0) ends.RemoveAt(0);
        return ends;
    }

    /// <summary>
    /// What holds each object, found by walking from the catalog: pages (their content, the forms it draws), comments
    /// and fields (their appearances), the form's XFA, the outline, the properties, attached files, the structure tree.
    /// </summary>
    private static Dictionary<PdfObject, Owner> Owners(PdfDocument doc, CancellationToken cancel)
    {
        var map = new Dictionary<PdfObject, Owner>(ReferenceEqualityComparer.Instance);
        void Set(PdfItem? item, Owner o)
        {
            if (PdfObj.Resolve(item) is PdfObject obj) map.TryAdd(obj, o);
        }
        void Forms(PdfDictionary? resources, Owner o, int depth)
        {
            if (depth > 8 || PdfObj.Dict(resources?.Elements["/XObject"]) is not { } xobjects) return;
            foreach (var key in xobjects.Elements.Keys.ToList())
            {
                if (PdfObj.Dict(xobjects.Elements[key]) is not { Stream: not null } form || PdfObj.NameOf(form, "/Subtype") != "/Form") continue;
                var res = PdfObj.Dict(form.Elements["/Resources"]) ?? resources;
                if (map.TryAdd(form, o with { Resources = res })) Forms(res, o, depth + 1);
            }
        }
        void Content(PdfItem? item, Owner o)
        {
            switch (PdfObj.Resolve(item))
            {
                case PdfDictionary { Stream: not null } s:
                    map.TryAdd(s, o);
                    Forms(o.Resources, o, 0);
                    break;
                case PdfArray a:
                    foreach (var e in a.Elements) Content(e, o);
                    break;
            }
        }

        // Attached files first: a file-attachment comment's file is named by its file specification.
        foreach (var o in doc.Internals.GetAllObjects())
        {
            if (o is not PdfDictionary d || (PdfObj.NameOf(d, "/Type") != "/Filespec" && !d.Elements.ContainsKey("/EF"))) continue;
            var name = PdfObj.Text(d.Elements["/UF"]) ?? PdfObj.Text(d.Elements["/F"]) ?? "";
            var owner = new Owner(Part.Attachment, -1, name.Length > 0 ? $"Attached file '{name}'" : "An attached file", SanitizeItem.EmbeddedFiles);
            map.TryAdd(d, owner);
            if (PdfObj.Dict(d.Elements["/EF"]) is { } ef)
                foreach (var key in ef.Elements.Keys.ToList()) Set(ef.Elements[key], owner);
        }

        for (var p = 0; p < doc.PageCount; p++)
        {
            cancel.ThrowIfCancellationRequested();
            var page = doc.Pages[p];
            map.TryAdd(page, new Owner(Part.Page, p, $"Page {p + 1}'s own data", SanitizeItem.Metadata));
            Content(page.Elements["/Contents"], new Owner(Part.Content, p, $"Page {p + 1}", null, PdfObj.Dict(page.Elements["/Resources"])));
            if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) continue;
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
            {
                var owner = AnnotOwner(a, p);
                map.TryAdd(a, owner);
                if (PdfObj.Dict(a.Elements["/AP"]) is { } ap)
                    foreach (var key in new[] { "/N", "/R", "/D" })
                    {
                        var states = PdfObj.Dict(ap.Elements[key]);
                        var streams = states is { Stream: not null } ? [states] : states?.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>().Where(s => s.Stream is not null).ToList() ?? [];
                        foreach (var s in streams)
                        {
                            var res = PdfObj.Dict(s.Elements["/Resources"]);
                            if (map.TryAdd(s, owner with { Resources = res })) Forms(res, owner, 0);
                        }
                    }
                Set(a.Elements["/Popup"], owner);
            }
        }

        var catalog = doc.Internals.Catalog;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        if (PdfObj.Dict(catalog.Elements["/AcroForm"]) is { } acro)
        {
            void Field(PdfDictionary f, int depth)
            {
                if (depth > 32 || !seen.Add(f)) return;
                map.TryAdd(f, new Owner(Part.Field, -1, $"Form field '{FieldName(f)}'", SanitizeItem.FormValues));
                if (PdfObj.Array(f.Elements["/Kids"]) is { } kids)
                    foreach (var k in kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) Field(k, depth + 1);
            }
            foreach (var f in PdfObj.Array(acro.Elements["/Fields"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>() ?? []) Field(f, 0);
            var xfa = new Owner(Part.Xfa, -1, "The form's XFA data", SanitizeItem.FormValues);
            switch (PdfObj.Resolve(acro.Elements["/XFA"]))
            {
                case PdfDictionary { Stream: not null } s:
                    map.TryAdd(s, xfa);
                    break;
                case PdfArray a:
                    foreach (var e in a.Elements) Set(e, xfa);
                    break;
            }
        }

        // The outline: siblings by /Next, children by /First, each item once.
        var bookmark = new Owner(Part.Bookmark, -1, "Bookmark", SanitizeItem.Bookmarks);
        var stack = new Stack<PdfDictionary>();
        if (PdfObj.Dict(PdfObj.Dict(catalog.Elements["/Outlines"])?.Elements["/First"]) is { } top) stack.Push(top);
        for (var guard = 0; stack.Count > 0 && guard < 200_000; guard++)
        {
            var item = stack.Pop();
            if (!seen.Add(item)) continue;
            map.TryAdd(item, bookmark);
            if (PdfObj.Dict(item.Elements["/Next"]) is { } next) stack.Push(next);
            if (PdfObj.Dict(item.Elements["/First"]) is { } child) stack.Push(child);
        }

        map.TryAdd(doc.Info, new Owner(Part.Info, -1, "Document properties", SanitizeItem.Metadata));

        var structure = new Owner(Part.Structure, -1, "Tags (structure tree)", null);
        var elems = new Stack<(PdfItem? Item, int Depth)>();
        elems.Push((PdfObj.Dict(catalog.Elements["/StructTreeRoot"])?.Elements["/K"], 0));
        for (var guard = 0; elems.Count > 0 && guard < 500_000; guard++)
        {
            var (item, depth) = elems.Pop();
            if (depth > 256) continue;
            switch (PdfObj.Resolve(item))
            {
                case PdfArray a:
                    foreach (var e in a.Elements) elems.Push((e, depth + 1));
                    break;
                case PdfDictionary d when PdfObj.NameOf(d, "/Type") is not ("/MCR" or "/OBJR") && seen.Add(d):
                    map.TryAdd(d, structure);
                    elems.Push((d.Elements["/K"], depth + 1));
                    break;
            }
        }
        return map;
    }

    private static Owner AnnotOwner(PdfDictionary a, int p)
    {
        var subtype = PdfObj.NameOf(a, "/Subtype").TrimStart('/');
        var flags = PdfObj.Int(a.Elements["/F"]) ?? 0;
        if (subtype == "Widget" || a.Elements.ContainsKey("/FT"))
            return new Owner(Part.Annotation, p, $"Form field '{FieldName(a)}' on page {p + 1}", (flags & (2 | 32)) != 0 ? SanitizeItem.HiddenAnnotations : SanitizeItem.FormValues);
        var what = subtype switch
        {
            "Text" => "Note",
            "FreeText" => "Text box",
            "Square" => "Rectangle",
            "Circle" => "Ellipse",
            "Ink" => "Drawing",
            "Popup" => "Pop-up note",
            "FileAttachment" => "Attached file (comment)",
            "" => "Comment",
            _ => subtype,
        };
        if ((flags & (2 | 32)) != 0) return new Owner(Part.Annotation, p, $"Hidden {what.ToLowerInvariant()} on page {p + 1}", SanitizeItem.HiddenAnnotations);
        return subtype switch
        {
            "Link" => new Owner(Part.Annotation, p, $"Link on page {p + 1}", SanitizeItem.ExternalLinks),
            "FileAttachment" => new Owner(Part.Annotation, p, $"{what} on page {p + 1}", SanitizeItem.EmbeddedFiles),
            _ => new Owner(Part.Annotation, p, $"{what} on page {p + 1}", SanitizeItem.Comments),
        };
    }

    /// <summary>A field's full name (its own name and its parents', joined by dots).</summary>
    private static string FieldName(PdfDictionary f)
    {
        var parts = new List<string>();
        for (var (d, guard) = (f, 0); d is not null && guard < 32; d = PdfObj.Dict(d.Elements["/Parent"]), guard++)
            if (PdfObj.Text(d.Elements["/T"]) is { Length: > 0 } t) parts.Insert(0, t);
        return parts.Count > 0 ? string.Join('.', parts) : "(unnamed)";
    }

    /// <summary>
    /// The text an object holds: its strings (in nested dictionaries and arrays too, references not followed), and its
    /// stream decoded: content streams as the text they show (in their own fonts) and as bytes; attached files by their
    /// kind (zipped Office files and PDFs looked inside); XML and text as they are. Pictures and font programs are skipped.
    /// </summary>
    private static string ObjectText(PdfObject o, Owner? owner)
    {
        var sb = new StringBuilder();
        var signature = o is PdfDictionary sig && sig.Elements.ContainsKey("/ByteRange");
        Strings(o, sb, signature, 0);
        if (o is not PdfDictionary { Stream: not null } d) return sb.ToString();
        var type = PdfObj.NameOf(d, "/Type");
        var subtype = PdfObj.NameOf(d, "/Subtype");
        if (subtype == "/Image" || type is "/XRef" or "/ObjStm" || d.Elements.ContainsKey("/Length1") || d.Elements.ContainsKey("/Length2")
            || subtype is "/Type1C" or "/CIDFontType0C" or "/OpenType" || (d.Elements.ContainsKey("/N") && d.Elements.ContainsKey("/Alternate")))
            return sb.ToString();
        byte[] bytes;
        try
        {
            bytes = PdfObj.StreamBytes(d);
        }
        catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
        {
            return sb.ToString(); // a filter that fails on its data
        }
        if (bytes.Length > MaxStreamBytes) bytes = bytes[..MaxStreamBytes];
        sb.Append('\n');
        if (owner is { Part: Part.Content or Part.Annotation or Part.Field } && subtype is "" or "/Form") sb.Append(ContentText(bytes, owner.Resources)).Append('\n');
        if (type == "/EmbeddedFile" || owner?.Part == Part.Attachment) sb.Append(FileText(bytes));
        else sb.Append(PlainText(bytes));
        return sb.ToString();
    }

    private static void Strings(PdfItem? item, StringBuilder sb, bool signature, int depth)
    {
        if (depth > 16) return;
        switch (item)
        {
            case PdfString s:
                sb.Append(s.Value).Append('\n');
                break;
            case PdfDictionary d:
                foreach (var (key, value) in d.Elements)
                    if (!(signature && key == "/Contents") && value is not PdfReference) Strings(value, sb, signature, depth + 1);
                break;
            case PdfArray a:
                foreach (var e in a.Elements)
                    if (e is not PdfReference) Strings(e, sb, signature, depth + 1);
                break;
        }
    }

    /// <summary>
    /// The text a content stream shows, each string decoded in its font: twice, with a space wherever the text moves and
    /// with none (a word placed letter by letter reads whole in the second).
    /// </summary>
    private static string ContentText(byte[] content, PdfDictionary? resources)
    {
        var (spaced, joined) = ContentTexts(content, resources);
        return spaced + "\n" + joined;
    }

    private static (string Spaced, string Joined) ContentTexts(byte[] content, PdfDictionary? resources)
    {
        var spaced = new StringBuilder();
        var joined = new StringBuilder();
        TextFont? font = null;
        try
        {
            foreach (var op in ContentLexer.Parse(content))
            {
                switch (op.Name)
                {
                    case "Tf" when op.Operands.Count >= 1:
                        font = PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Font"])?.Elements["/" + op.Operands[0].Name]) is { } fd ? TextFont.For(fd) : null;
                        break;
                    case "Td" or "TD" or "Tm" or "T*" or "BT" or "ET":
                        spaced.Append(' ');
                        break;
                    case "Tj" or "'" or "\"" when op.Operands.Count > 0:
                        if (op.Name != "Tj") spaced.Append(' ');
                        Show(op.Operands[^1]);
                        break;
                    case "TJ" when op.Operands.Count > 0 && op.Operands[^1].Kind == CKind.Array:
                        foreach (var e in op.Operands[^1].Items)
                        {
                            if (e.Kind == CKind.Number && e.Num < -200) spaced.Append(' ');
                            else Show(e);
                        }
                        break;
                }
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IndexOutOfRangeException or NotSupportedException)
        {
            // A font or content that can't be read: what was read so far.
        }
        return (spaced.ToString(), joined.ToString());

        void Show(CObj s)
        {
            if (s.Kind != CKind.String) return;
            if (font is null)
            {
                var latin = Encoding.Latin1.GetString(s.Bytes);
                spaced.Append(latin);
                joined.Append(latin);
                return;
            }
            foreach (var g in font.Decode(s.Bytes))
            {
                spaced.Append(g.Text);
                joined.Append(g.Text);
            }
        }
    }

    /// <summary>Bytes as text: by their byte-order mark, else as Latin-1 and (when it is valid) UTF-8.</summary>
    private static string PlainText(byte[] bytes)
    {
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        var latin = Encoding.Latin1.GetString(bytes);
        if (!bytes.Any(b => b >= 0x80)) return latin;
        try
        {
            return latin + "\n" + new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return latin;
        }
    }

    /// <summary>An attached file's text: a PDF's raw bytes with its streams decompressed, a zip's (Office) parts with
    /// their markup taken out, else the bytes as text (UTF-16 too when it looks like it).</summary>
    private static string FileText(byte[] bytes)
    {
        if (bytes.AsSpan(0, Math.Min(bytes.Length, 1024)).IndexOf("%PDF-"u8) >= 0) return RawText(bytes, default);
        if (bytes.Length > 4 && bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == 3 && bytes[3] == 4)
        {
            try
            {
                var sb = new StringBuilder();
                using var zip = new ZipArchive(new MemoryStream(bytes, false), ZipArchiveMode.Read);
                long total = 0;
                foreach (var entry in zip.Entries.Take(2000))
                {
                    if (entry.Length > MaxStreamBytes || (total += entry.Length) > MaxStreamBytes) break;
                    using var s = entry.Open();
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    var text = PlainText(ms.ToArray());
                    sb.Append(text).Append('\n').Append(Markup().Replace(text, "")).Append('\n');
                }
                return sb.ToString();
            }
            catch (Exception ex) when (ex is InvalidDataException or IOException or NotSupportedException)
            {
                // not a zip after all
            }
        }
        var plain = PlainText(bytes);
        var zeros = bytes.Take(4096).Count(b => b == 0);
        return zeros > Math.Min(bytes.Length, 4096) / 4 ? plain + "\n" + Encoding.Unicode.GetString(bytes) + "\n" + Encoding.BigEndianUnicode.GetString(bytes) : plain;
    }

    /// <summary>A PDF's raw bytes as Latin-1, followed by every stream in them that inflates (zlib), decompressed.</summary>
    internal static string RawText(byte[] data, CancellationToken cancel)
    {
        var sb = new StringBuilder(Encoding.Latin1.GetString(data));
        var span = data.AsSpan();
        long total = 0;
        for (var at = 0; ;)
        {
            cancel.ThrowIfCancellationRequested();
            var i = span[at..].IndexOf("stream"u8);
            if (i < 0) break;
            var start = at + i + 6;
            at = start;
            if (start >= 9 && span[(start - 9)..(start - 6)].SequenceEqual("end"u8)) continue; // "endstream"
            if (start < data.Length && data[start] == '\r') start++;
            if (start < data.Length && data[start] == '\n') start++;
            var end = span[start..].IndexOf("endstream"u8);
            if (end <= 0) continue;
            try
            {
                using var z = new ZLibStream(new MemoryStream(data, start, end, false), CompressionMode.Decompress);
                using var ms = new MemoryStream();
                var buffer = new byte[81920];
                for (int n; (n = z.Read(buffer)) > 0 && ms.Length < MaxStreamBytes;) ms.Write(buffer, 0, n);
                if ((total += ms.Length) > 512L << 20) break;
                sb.Append('\n').Append(Encoding.Latin1.GetString(ms.GetBuffer(), 0, (int)ms.Length));
            }
            catch (Exception ex) when (ex is InvalidDataException or IOException)
            {
                // not zlib (another filter, or not compressed): its bytes are in the raw text already
            }
            at = start + end;
        }
        return sb.ToString();
    }

    [GeneratedRegex(@"[\p{L}\p{N}][\p{L}\p{N}@._'\-]*[\p{L}\p{N}]")]
    private static partial Regex WordPattern();

    [GeneratedRegex("<[^>]*>")]
    private static partial Regex Markup();
}
