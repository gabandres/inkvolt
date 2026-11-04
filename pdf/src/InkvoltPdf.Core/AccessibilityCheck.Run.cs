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

    /// <summary>Drawing steps in the whole document (minutes of work; a real file comes well under it): a file's pages can all draw the same long content.</summary>
    private const long MaxDocumentOperators = 500_000_000;

    /// <summary>Checks the document. Nothing is changed.</summary>
    /// <param name="progress">(pages done, pages).</param>
    /// <exception cref="InvalidOperationException">The file can't be read as a PDF.</exception>
    /// <exception cref="PasswordRequiredException">The password is missing or wrong.</exception>
    public static AccessibilityReport Run(byte[] data, string? password, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default) =>
        Run(data, password, progress, cancel, MaxDocumentOperators);

    internal static AccessibilityReport Run(byte[] data, string? password, IProgress<(int Done, int Total)>? progress, CancellationToken cancel, long maxDocumentOperators)
    {
        if (PdfSecurity.NeedsOpenPassword(data) && string.IsNullOrEmpty(password)) throw new PasswordRequiredException(false);
        data = HybridXref.Normalize(data); // Word's files keep their tags where PDFsharp alone doesn't look
        PdfDocument doc;
        try
        {
            doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, PdfStrings.A11y_CantCheck);
        }
        catch (InvalidOperationException) when (!string.IsNullOrEmpty(password) && PdfSecurity.NeedsOpenPassword(data))
        {
            throw new PasswordRequiredException(true);
        }
        catch (Exception ex) when (Unreadable(ex))
        {
            throw new InvalidOperationException(Loc.Format(PdfStrings.A11y_CantCheckWhy, ex.Message), ex);
        }
        using (doc)
        {
            try
            {
                return new Checker(data, doc, progress, cancel, maxDocumentOperators).Run();
            }
            catch (Exception ex) when (Unreadable(ex))
            {
                throw new InvalidOperationException(Loc.Format(PdfStrings.A11y_CantCheckInFull, ex.Message), ex);
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

    private sealed partial class Checker(byte[] data, PdfDocument doc, IProgress<(int Done, int Total)>? progress, CancellationToken cancel, long maxDocumentOperators)
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

        /// <summary>What wasn't checked, said once however often it comes up: any note means the file doesn't pass.</summary>
        private void NoteOnce(string note)
        {
            if (!_notes.Contains(note)) _notes.Add(note);
        }

        private void Add(string condition, string problem, int page = -1, RectD box = default, string? element = null, int count = 1, string? fix = null) =>
            Add(new AccessibilityFinding(condition, problem) { Page = page, Box = box, Element = element ?? PdfStrings.A11y_Document, Count = count, FixOverride = fix });

        public AccessibilityReport Run()
        {
            _root = PdfObj.Dict(_catalog.Elements["/StructTreeRoot"]);
            var lang = PdfObj.Text(_catalog.Elements["/Lang"]);
            _docLang = lang is not null; // present, even empty or malformed (that is reported on its own, as UA 7.2-Lang)
            if (lang is not null && !IsLanguage(lang)) Add("UA 7.2-Lang", Loc.Format(PdfStrings.A11y_LangNotCode, Short(lang)));

            Header();
            if (_root is null) Add("UA 7.1", PdfStrings.A11y_NoTags);
            var markInfo = PdfObj.Dict(_catalog.Elements["/MarkInfo"]);
            if (markInfo is null || Bool(markInfo.Elements["/Marked"]) != true)
                Add("UA 6.2", markInfo is null ? PdfStrings.A11y_NoMarkInfo : PdfStrings.A11y_MarkedNotTrue);
            if (markInfo is not null && Bool(markInfo.Elements["/Suspects"]) == true) Add("01-007", PdfStrings.A11y_SuspectsTrue);

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
                _findings.Add(new AccessibilityFinding(condition, Loc.Format(PdfStrings.A11y_MoreLikeThese, n, MaxPerCondition)) { Count = n });

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
            Add("UA 6.1", head.StartsWith("%PDF-2", StringComparison.Ordinal) ? PdfStrings.A11y_Pdf20
                : at >= 0 ? Loc.Format(PdfStrings.A11y_HeaderIs, Short(head))
                : PdfStrings.A11y_NoHeader);
        }

        private static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
        private static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
        private static readonly XNamespace PdfUaId = "http://www.aiim.org/pdfua/ns/id/";
        private static readonly XNamespace XmlNs = XNamespace.Xml;

        private void Metadata()
        {
            if (PdfObj.Dict(_catalog.Elements["/Metadata"]) is not { Stream: not null })
            {
                Add("06-001", PdfStrings.A11y_NoXmp);
                return;
            }
            var xmp = Xmp.Read(doc);
            if (xmp is null)
            {
                Add("06-001", PdfStrings.A11y_XmpUnreadable);
                return;
            }
            var descriptions = xmp.Descendants(Rdf + "Description").ToList();
            // pdfuaid:part, as an attribute of a description or an element inside it.
            var part = descriptions.Select(d => d.Attribute(PdfUaId + "part")?.Value).FirstOrDefault(v => v is not null)
                       ?? xmp.Descendants(PdfUaId + "part").Select(e => e.Value).FirstOrDefault();
            if (part is null) Add("06-002", PdfStrings.A11y_NoPdfUaPart);
            else if (part.Trim() != "1") Add("06-002", Loc.Format(PdfStrings.A11y_PdfUaPartN, Short(part.Trim())));
            else
            {
                var prefix = PrefixOf(xmp, PdfUaId);
                if (prefix is not null && prefix != "pdfuaid") Add("06-002", Loc.Format(PdfStrings.A11y_PdfUaPrefix, prefix));
            }

            var title = xmp.Descendants(Dc + "title").FirstOrDefault();
            if (title is null) Add("06-003", PdfStrings.A11y_NoDcTitle);

            // Metadata text whose only language alternative is x-default: its language comes from the document's.
            if (!_docLang)
                foreach (var alt in xmp.Descendants(Rdf + "Alt"))
                    if (alt.Elements(Rdf + "li").ToList() is [var only] && (string?)only.Attribute(XmlNs + "lang") == "x-default")
                        Add("11-006", alt.Parent?.Name.LocalName is { } property ? Loc.Format(PdfStrings.A11y_XmpNoLang, property) : PdfStrings.A11y_XmpNoLangText);
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
            if (display is null) Add("07-001", PdfStrings.A11y_DisplayDocTitleMissing);
            else if (display == false) Add("07-002", PdfStrings.A11y_DisplayDocTitleFalse);
        }

        private void Security()
        {
            var handler = doc.SecurityHandler;
            if (!handler.Elements.ContainsKey("/Filter")) return;
            switch (PermissionsCondition(PdfObj.Int(handler.Elements["/P"])))
            {
                case "26-001":
                    Add("26-001", PdfStrings.A11y_NoPermissions);
                    break;
                case "26-002":
                    Add("26-002", PdfStrings.A11y_NoCopyForAccessibility);
                    break;
            }
        }

        private void OptionalContent()
        {
            if (PdfObj.Dict(_catalog.Elements["/OCProperties"]) is not { } oc) return;
            void Config(PdfDictionary? c, string condition, string which)
            {
                if (c is null) return;
                var isDefault = which == "default";
                if (string.IsNullOrEmpty(PdfObj.Text(c.Elements["/Name"]))) Add(condition, isDefault ? PdfStrings.A11y_DefaultLayerNoName : PdfStrings.A11y_OtherLayerNoName);
                if (c.Elements.ContainsKey("/AS")) Add("20-003", isDefault ? PdfStrings.A11y_DefaultLayerAs : PdfStrings.A11y_OtherLayerAs);
            }
            Config(PdfObj.Dict(oc.Elements["/D"]), "20-002", "default");
            if (PdfObj.Array(oc.Elements["/Configs"]) is { } configs)
            {
                foreach (var c in configs.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Take(256)) Config(c, "20-001", "other");
                if (configs.Elements.Count > 256) NoteOnce(PdfStrings.A11y_ManyLayerConfigs);
            }
        }

        private void EmbeddedFiles()
        {
            var names = PdfObj.Dict(PdfObj.Dict(_catalog.Elements["/Names"])?.Elements["/EmbeddedFiles"]);
            var attached = 0;
            foreach (var (key, value) in PdfObj.NameTree(names))
            {
                if (++attached > 10_000)
                {
                    NoteOnce(PdfStrings.A11y_ManyAttachments);
                    break;
                }
                if (PdfObj.Dict(value) is { } spec && spec.Elements.ContainsKey("/EF") && !HasBothNames(spec))
                    Add("21-001", Loc.Format(spec.Elements.ContainsKey("/UF") ? PdfStrings.A11y_AttachedNoF : PdfStrings.A11y_AttachedNoUF, Short(key)), element: PdfStrings.A11y_ElementAttachedFile);
            }
        }

        private static bool HasBothNames(PdfDictionary spec) =>
            !string.IsNullOrEmpty(PdfObj.Text(spec.Elements["/F"])) && !string.IsNullOrEmpty(PdfObj.Text(spec.Elements["/UF"]));

        private void Xfa()
        {
            var xfa = PdfObj.Resolve(PdfObj.Dict(_catalog.Elements["/AcroForm"])?.Elements["/XFA"]);
            var parts = new List<byte[]>();
            var read = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance); // each stream once, however often it is listed
            switch (xfa)
            {
                case PdfDictionary { Stream: not null } s:
                    parts.Add(PdfObj.StreamBytes(s));
                    break;
                case PdfArray a:
                    for (var i = 1; i < a.Elements.Count; i += 2)
                        if (PdfObj.Dict(a.Elements[i]) is { Stream: not null } s2 && read.Add(s2)) parts.Add(PdfObj.StreamBytes(s2));
                    break;
                default:
                    return;
            }
            var text = string.Concat(parts.Select(Encoding.UTF8.GetString));
            try
            {
                if (Regex.IsMatch(text, @"<dynamicRender[^>]*>\s*required\s*</dynamicRender\s*>", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(2)))
                    Add("25-001", PdfStrings.A11y_DynamicXfa);
            }
            catch (RegexMatchTimeoutException)
            {
                _notes.Add(PdfStrings.A11y_XfaTooLong);
            }
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
            Add("11-003", Loc.Plural(count, PdfStrings.A11y_BookmarksNoLang_One, PdfStrings.A11y_BookmarksNoLang_Many), element: PdfStrings.A11y_ElementBookmarks, count: count);
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
