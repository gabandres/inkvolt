using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

public static partial class AccessibilityCheck
{
    /// <summary>Most findings listed per condition; the rest are counted in one more finding.</summary>
    private const int MaxPerCondition = 200;

    /// <summary>Checks the document. Nothing is changed.</summary>
    /// <param name="progress">(pages done, pages).</param>
    /// <exception cref="InvalidOperationException">The file can't be read as a PDF.</exception>
    /// <exception cref="PasswordRequiredException">The password is missing or wrong.</exception>
    public static AccessibilityReport Run(byte[] data, string? password, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        if (PdfSecurity.NeedsOpenPassword(data) && string.IsNullOrEmpty(password)) throw new PasswordRequiredException(false);
        data = HybridXref.Normalize(data); // Word's files keep their tags where PDFsharp alone doesn't look
        PdfDocument doc;
        try
        {
            doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF can't be checked");
        }
        catch (InvalidOperationException) when (!string.IsNullOrEmpty(password) && PdfSecurity.NeedsOpenPassword(data))
        {
            throw new PasswordRequiredException(true);
        }
        catch (Exception ex) when (Unreadable(ex))
        {
            throw new InvalidOperationException($"This PDF can't be checked: {ex.Message}", ex);
        }
        using (doc)
        {
            try
            {
                return new Checker(data, doc, progress, cancel).Run();
            }
            catch (Exception ex) when (Unreadable(ex))
            {
                throw new InvalidOperationException($"This PDF can't be checked in full: {ex.Message}", ex);
            }
        }
    }

    /// <summary>An encrypted file's permissions (/P) against Matterhorn 26: "26-001" without them, "26-002" when they don't
    /// allow copying for accessibility (bit 10), else null.</summary>
    internal static string? PermissionsCondition(int? p) => p is not { } v ? "26-001" : (v & 512) == 0 ? "26-002" : null;

    /// <summary>What PDFsharp throws on a file it can't read (external streams, damaged objects).</summary>
    private static bool Unreadable(Exception ex) =>
        ex is NotImplementedException or NotSupportedException or InvalidCastException or ArgumentException or IndexOutOfRangeException or NullReferenceException or FormatException;

    [GeneratedRegex(@"^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$", RegexOptions.CultureInvariant)]
    private static partial Regex LanguageTag();

    /// <summary>A language tag as RFC 3066 writes them ("en", "en-US", "zh-Hant-TW", "x-klingon"): what PDF/UA-1 asks of every Lang.</summary>
    internal static bool IsLanguage(string? s) => !string.IsNullOrEmpty(s) && s.Length <= 64 && LanguageTag().IsMatch(s);

    private sealed partial class Checker(byte[] data, PdfDocument doc, IProgress<(int Done, int Total)>? progress, CancellationToken cancel)
    {
        private readonly List<AccessibilityFinding> _findings = [];
        private readonly Dictionary<string, int> _dropped = [];
        private readonly List<string> _notes = [];
        private readonly PdfDictionary _catalog = doc.Internals.Catalog;
        private PdfDictionary? _root;
        private bool _docLang; // the catalog's /Lang is a language: every text's language can be told

        private void Add(AccessibilityFinding f)
        {
            if (_findings.Count(x => x.Condition == f.Condition) >= MaxPerCondition)
            {
                _dropped[f.Condition] = _dropped.GetValueOrDefault(f.Condition) + f.Count;
                return;
            }
            _findings.Add(f);
        }

        private void Add(string condition, string problem, int page = -1, RectD box = default, string element = "Document", int count = 1, string? fix = null) =>
            Add(new AccessibilityFinding(condition, problem) { Page = page, Box = box, Element = element, Count = count, FixOverride = fix });

        public AccessibilityReport Run()
        {
            _root = PdfObj.Dict(_catalog.Elements["/StructTreeRoot"]);
            var lang = PdfObj.Text(_catalog.Elements["/Lang"]);
            _docLang = lang is not null; // present, even empty or malformed (that is reported on its own, as UA 7.2-Lang)
            if (lang is not null && !IsLanguage(lang)) Add("UA 7.2-Lang", $"The document's language is “{Short(lang)}”, which isn't a language code.");

            Header();
            if (_root is null) Add("UA 7.1", "The document has no tags (no structure tree), so screen readers can't tell its headings, lists, tables or reading order.");
            var markInfo = PdfObj.Dict(_catalog.Elements["/MarkInfo"]);
            if (markInfo is null || Bool(markInfo.Elements["/Marked"]) != true)
                Add("UA 6.2", markInfo is null ? "The document doesn't say it is tagged (no MarkInfo)." : "The document says it isn't tagged (Marked isn't true).");
            if (markInfo is not null && Bool(markInfo.Elements["/Suspects"]) == true) Add("01-007", "The document says its tags may be wrong (Suspects is true).");

            Metadata();
            ViewerPreferences();
            Security();
            OptionalContent();
            EmbeddedFiles();
            Xfa();
            Outlines();

            if (_root is not null) ReadStructure();
            Pages();
            if (_root is not null) CheckStructure();
            CheckFonts();

            foreach (var (condition, n) in _dropped)
                _findings.Add(new AccessibilityFinding(condition, $"… and {n} more like these (only the first {MaxPerCondition} are listed).") { Count = n });

            var order = Conditions.Select((c, i) => (c.Id, i)).ToDictionary(x => x.Id, x => x.i);
            var sorted = _findings.OrderBy(f => order.GetValueOrDefault(f.Condition, int.MaxValue)).ThenBy(f => f.Page < 0 ? -1 : f.Page).ToList();
            return new AccessibilityReport(sorted, _notes, doc.PageCount, _root is not null);
        }

        // ───────────────────────────── document ─────────────────────────────

        /// <summary>PDF/UA-1 is PDF 1.7: the file's header is "%PDF-1.n" with n from 0 to 7.</summary>
        private void Header()
        {
            var start = Encoding.Latin1.GetString(data, 0, Math.Min(data.Length, 1024));
            var at = start.IndexOf("%PDF-", StringComparison.Ordinal);
            var head = at < 0 ? "" : start[at..].Split('\r', '\n')[0].TrimEnd();
            if (head.Length == 8 && head.StartsWith("%PDF-1.", StringComparison.Ordinal) && head[7] is >= '0' and <= '7') return;
            Add("UA 6.1", head.StartsWith("%PDF-2", StringComparison.Ordinal) ? "The file is PDF 2.0; PDF/UA-1 is based on PDF 1.7 (PDF 2.0 files follow PDF/UA-2)."
                : at >= 0 ? $"The file's header is “{Short(head)}”, not “%PDF-1.n” (n from 0 to 7)."
                : "The file doesn't start with a PDF header.");
        }

        private static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
        private static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
        private static readonly XNamespace PdfUaId = "http://www.aiim.org/pdfua/ns/id/";
        private static readonly XNamespace XmlNs = XNamespace.Xml;

        private void Metadata()
        {
            if (PdfObj.Dict(_catalog.Elements["/Metadata"]) is not { Stream: not null })
            {
                Add("06-001", "The document has no XMP metadata, so it can't say it is PDF/UA or give its title there.");
                return;
            }
            var xmp = Xmp.Read(doc);
            if (xmp is null)
            {
                Add("06-001", "The document's XMP metadata can't be read (it isn't well-formed XML).");
                return;
            }
            var descriptions = xmp.Descendants(Rdf + "Description").ToList();
            // pdfuaid:part, as an attribute of a description or an element inside it.
            var part = descriptions.Select(d => d.Attribute(PdfUaId + "part")?.Value).FirstOrDefault(v => v is not null)
                       ?? xmp.Descendants(PdfUaId + "part").Select(e => e.Value).FirstOrDefault();
            if (part is null) Add("06-002", "The metadata doesn't say the document is PDF/UA (it has no pdfuaid:part).");
            else if (part.Trim() != "1") Add("06-002", $"The metadata says the document follows PDF/UA part {Short(part.Trim())}, not part 1.");
            else
            {
                var prefix = PrefixOf(xmp, PdfUaId);
                if (prefix is not null && prefix != "pdfuaid") Add("06-002", $"The PDF/UA identifier is written with the prefix “{prefix}”; PDF/UA asks for “pdfuaid”.");
            }

            var title = xmp.Descendants(Dc + "title").FirstOrDefault();
            if (title is null) Add("06-003", "The metadata has no title (dc:title).");

            // Metadata text whose only language alternative is x-default: its language comes from the document's.
            if (!_docLang)
                foreach (var alt in xmp.Descendants(Rdf + "Alt"))
                    if (alt.Elements(Rdf + "li").ToList() is [var only] && (string?)only.Attribute(XmlNs + "lang") == "x-default")
                        Add("11-006", $"The metadata's {alt.Parent?.Name.LocalName ?? "text"} has no language of its own, and the document has none.");
        }

        private static string? PrefixOf(XDocument xmp, XNamespace ns)
        {
            foreach (var e in xmp.Descendants())
                foreach (var a in e.Attributes())
                    if (a.IsNamespaceDeclaration && a.Value == ns.NamespaceName) return a.Name.LocalName;
            return null;
        }

        private void ViewerPreferences()
        {
            var prefs = PdfObj.Dict(_catalog.Elements["/ViewerPreferences"]);
            var display = prefs is null ? null : Bool(prefs.Elements["/DisplayDocTitle"]);
            if (display is null) Add("07-001", "The document doesn't ask viewers to show its title in the window (DisplayDocTitle is missing): they show the file name.");
            else if (display == false) Add("07-002", "The document asks viewers to show the file name in the window instead of its title (DisplayDocTitle is false).");
        }

        private void Security()
        {
            var handler = doc.SecurityHandler;
            if (!handler.Elements.ContainsKey("/Filter")) return;
            switch (PermissionsCondition(PdfObj.Int(handler.Elements["/P"])))
            {
                case "26-001":
                    Add("26-001", "The file is encrypted but doesn't say what readers may do (no P entry).");
                    break;
                case "26-002":
                    Add("26-002", "The file's protection doesn't allow copying text for accessibility, so screen readers may refuse to read it.");
                    break;
            }
        }

        private void OptionalContent()
        {
            if (PdfObj.Dict(_catalog.Elements["/OCProperties"]) is not { } oc) return;
            void Config(PdfDictionary? c, string condition, string which)
            {
                if (c is null) return;
                if (string.IsNullOrEmpty(PdfObj.Text(c.Elements["/Name"]))) Add(condition, $"The {which} layer configuration has no name.");
                if (c.Elements.ContainsKey("/AS")) Add("20-003", $"The {which} layer configuration switches layers automatically (it has an AS entry).");
            }
            Config(PdfObj.Dict(oc.Elements["/D"]), "20-002", "default");
            if (PdfObj.Array(oc.Elements["/Configs"]) is { } configs)
                foreach (var c in configs.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Take(256)) Config(c, "20-001", "other");
        }

        private void EmbeddedFiles()
        {
            var names = PdfObj.Dict(PdfObj.Dict(_catalog.Elements["/Names"])?.Elements["/EmbeddedFiles"]);
            foreach (var (key, value) in PdfObj.NameTree(names).Take(10_000))
                if (PdfObj.Dict(value) is { } spec && spec.Elements.ContainsKey("/EF") && !HasBothNames(spec))
                    Add("21-001", $"The attached file “{Short(key)}” lacks {(spec.Elements.ContainsKey("/UF") ? "its F name" : "its UF (Unicode) name")}.", element: "Attached file");
        }

        private static bool HasBothNames(PdfDictionary spec) =>
            !string.IsNullOrEmpty(PdfObj.Text(spec.Elements["/F"])) && !string.IsNullOrEmpty(PdfObj.Text(spec.Elements["/UF"]));

        private void Xfa()
        {
            var xfa = PdfObj.Resolve(PdfObj.Dict(_catalog.Elements["/AcroForm"])?.Elements["/XFA"]);
            var parts = new List<byte[]>();
            switch (xfa)
            {
                case PdfDictionary { Stream: not null } s:
                    parts.Add(PdfObj.StreamBytes(s));
                    break;
                case PdfArray a:
                    for (var i = 1; i < a.Elements.Count; i += 2)
                        if (PdfObj.Dict(a.Elements[i]) is { Stream: not null } s2) parts.Add(PdfObj.StreamBytes(s2));
                    break;
                default:
                    return;
            }
            var text = string.Concat(parts.Select(Encoding.UTF8.GetString));
            if (Regex.IsMatch(text, @"<dynamicRender[^>]*>\s*required\s*</dynamicRender\s*>", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(2)))
                Add("25-001", "The file holds a dynamic XFA form (dynamicRender is required), which most readers and screen readers can't use.");
        }

        private void Outlines()
        {
            if (_docLang) return;
            var first = PdfObj.Dict(PdfObj.Dict(_catalog.Elements["/Outlines"])?.Elements["/First"]);
            if (first is null) return;
            var count = 0;
            var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            var stack = new Stack<PdfDictionary>([first]);
            while (stack.Count > 0 && count < 100_000)
            {
                var item = stack.Pop();
                if (!seen.Add(item)) continue;
                count++;
                if (PdfObj.Dict(item.Elements["/Next"]) is { } next) stack.Push(next);
                if (PdfObj.Dict(item.Elements["/First"]) is { } kid) stack.Push(kid);
            }
            Add("11-003", $"The document has no language, so the language of its {count} {(count == 1 ? "bookmark" : "bookmarks")} can't be told.", element: "Bookmarks", count: count);
        }

        private static bool? Bool(PdfItem? item) => PdfObj.Resolve(item) switch
        {
            PdfBoolean b => b.Value,
            PdfBooleanObject bo => bo.Value,
            _ => null,
        };

        private static string Short(string s) => s.Length <= 60 ? s : s[..57] + "…";

        private CancellationToken Cancel => cancel;

        private void Step(int done) => progress?.Report((done, doc.PageCount));
    }
}
