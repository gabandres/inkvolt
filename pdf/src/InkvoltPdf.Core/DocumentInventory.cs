using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>The parts of <see cref="DocumentInventory"/>'s report, in the order it shows them.</summary>
public enum InventorySection
{
    /// <summary>JavaScript: document scripts and script actions, with what each one calls.</summary>
    Scripts,

    /// <summary>Actions that run by themselves: when the document opens, closes, is saved or printed, a page opens or
    /// closes, a field is shown.</summary>
    Actions,

    /// <summary>Web addresses, mail addresses, other files and programs the document can reach, and how.</summary>
    Addresses,

    /// <summary>Attached files.</summary>
    Attachments,

    /// <summary>Document properties, XMP metadata, other apps' private data, comment authors.</summary>
    Metadata,

    /// <summary>Digital signatures: who signed, when, why, where.</summary>
    Signatures,

    /// <summary>Earlier versions kept by incremental saves, and the text they show that the current one doesn't.</summary>
    EarlierVersions,

    /// <summary>Hidden layers, hidden comments and fields, text that doesn't show (white, off the page, clipped).</summary>
    Hidden,

    /// <summary>Values filled into form fields.</summary>
    FormValues,

    /// <summary>Covers that hide nothing for good: text or pictures under boxes, redaction marks never applied.</summary>
    Redaction,
}

/// <summary>What sets an action off.</summary>
public enum InventoryTrigger
{
    /// <summary>Not an action (an attachment, a metadata entry).</summary>
    None,

    /// <summary>Runs by itself: the document opens, closes, is saved or printed, a page opens or closes, a field is shown.</summary>
    Automatic,

    /// <summary>The pointer passing over a link, comment or field: no click needed.</summary>
    Pointer,

    /// <summary>A click, a key typed, a field chosen or left.</summary>
    Use,
}

/// <summary>One thing the document carries.</summary>
/// <param name="What">What it is, in words ("Script", "Web address", "Author").</param>
/// <param name="Where">Where it is, or what sets it off ("When the document opens", "Page 2, a link", "Document properties").</param>
/// <param name="Detail">The thing itself: the address, the value, the script's first lines.</param>
public sealed record InventoryItem(InventorySection Section, string What, string Where, string Detail)
{
    /// <summary>Its page (index), or -1.</summary>
    public int Page { get; init; } = -1;

    public InventoryTrigger Trigger { get; init; }

    /// <summary>For a script: what it does that reaches outside the document or the reader ("opens a web page").</summary>
    public IReadOnlyList<string> Calls { get; init; } = [];

    /// <summary>The kind of content Sanitize Document removes it with; null when a rewrite (earlier versions) or a
    /// redaction (text that doesn't show, covers) removes it.</summary>
    public SanitizeItem? RemovedBy { get; init; }

    /// <summary>Reached or run without a click: by itself, or by the pointer passing over.</summary>
    public bool WithoutClick => Trigger is InventoryTrigger.Automatic or InventoryTrigger.Pointer;
}

/// <param name="Counts">What Sanitize Document finds of each kind (<see cref="Sanitizer.Scan(byte[], string?)"/>).</param>
/// <param name="Notes">What couldn't be looked at, and why.</param>
public sealed record InventoryReport(IReadOnlyList<InventoryItem> Items, SanitizeReport Counts, int Pages, IReadOnlyList<string> Notes)
{
    /// <summary>The document carries nothing but its pages.</summary>
    public bool IsEmpty => Items.Count == 0;

    public IEnumerable<InventoryItem> In(InventorySection section) => Items.Where(i => i.Section == section);

    /// <summary>"Scripts (2), web addresses (3), …", or that the document carries nothing but its pages.</summary>
    public string Summary
    {
        get
        {
            if (IsEmpty) return PdfStrings.Inventory_NothingButPages;
            var parts = Items.GroupBy(i => i.Section).OrderBy(g => g.Key).Select(g => Loc.Format(PdfStrings.Inventory_SectionCount, DocumentInventory.Lower(DocumentInventory.Title(g.Key)), g.Count()));
            var outward = Items.Count(i => i.Section == InventorySection.Addresses && i.WithoutClick);
            var text = string.Join(", ", parts);
            return char.ToUpperInvariant(text[0]) + text[1..] + "." +
                   (outward > 0 ? Loc.Plural(outward, PdfStrings.Inventory_AddressesOutward_One, PdfStrings.Inventory_AddressesOutward_Many) : "");
        }
    }
}

/// <summary>
/// What's in this PDF: one readable report of everything a file carries besides what its pages show, and what it does
/// when opened. Scripts (and what they call), actions that run by themselves, every web address, file and program it can
/// reach (and whether that happens without a click), attachments, metadata and comment authors, signatures, earlier
/// versions (and the text they show that the current one doesn't), hidden layers, comments, fields and text, form values,
/// and covers that hide nothing (the <see cref="RedactionCheck"/>'s own findings). Nothing is changed. What Sanitize
/// Document removes is said per item (<see cref="InventoryItem.RemovedBy"/>), so after sanitizing everything the report
/// is empty.
/// </summary>
public static partial class DocumentInventory
{
    /// <summary>The longest detail kept (a script's first part, a long value).</summary>
    private const int MaxDetail = 400;

    /// <summary>Most items per section (a file with 100,000 comments by one author stays readable).</summary>
    private const int MaxPerSection = 2000;

    public static string Title(InventorySection s) => s switch
    {
        InventorySection.Scripts => PdfStrings.Inventory_Scripts,
        InventorySection.Actions => PdfStrings.Inventory_Actions,
        InventorySection.Addresses => PdfStrings.Inventory_Addresses,
        InventorySection.Attachments => PdfStrings.Inventory_Attachments,
        InventorySection.Metadata => PdfStrings.Inventory_Metadata,
        InventorySection.Signatures => PdfStrings.Inventory_Signatures,
        InventorySection.EarlierVersions => PdfStrings.Inventory_EarlierVersions,
        InventorySection.Hidden => PdfStrings.Inventory_Hidden,
        InventorySection.FormValues => PdfStrings.Inventory_FormValues,
        InventorySection.Redaction => PdfStrings.Inventory_Covers,
        _ => s.ToString(),
    };

    public static string Name(InventoryTrigger t) => t switch
    {
        InventoryTrigger.Automatic => PdfStrings.Inventory_ByItself,
        InventoryTrigger.Pointer => PdfStrings.Inventory_OnPointer,
        InventoryTrigger.Use => PdfStrings.Inventory_OnUse,
        _ => "",
    };

    /// <summary>Looks at the whole document. Nothing is changed.</summary>
    /// <param name="progress">(steps done, steps): the redaction check's pages and earlier versions.</param>
    /// <exception cref="PasswordRequiredException">The password is missing or wrong.</exception>
    public static InventoryReport Run(byte[] data, string? password, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var counts = Sanitizer.Scan(data, password);
        var notes = new List<string>(counts.Notes);
        var walk = new Walk();
        int pages;
        using (var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, PdfStrings.Inventory_CantRead))
        {
            pages = doc.PageCount;
            walk.Run(doc, cancel);
        }
        var items = walk.Items;

        foreach (var a in Attachments.List(data, password))
            items.Add(new InventoryItem(InventorySection.Attachments, PdfStrings.Inventory_AttachedFile, a.PageIndex >= 0 ? Loc.Format(PdfStrings.Inventory_PageAttachmentComment, a.PageIndex + 1) : PdfStrings.Inventory_DocumentAttachments,
                $"{a.FileName} ({Size(a.Size)}{(string.IsNullOrWhiteSpace(a.Description) ? "" : ", " + a.Description)})") { Page = a.PageIndex, RemovedBy = SanitizeItem.EmbeddedFiles });

        if (counts.EarlierRevisions > 0)
            items.Add(new InventoryItem(InventorySection.EarlierVersions, PdfStrings.Inventory_EarlierVersions, PdfStrings.Inventory_KeptByIncremental,
                Loc.Plural(counts.EarlierRevisions, PdfStrings.Inventory_EarlierVersions_One, PdfStrings.Inventory_EarlierVersions_Many)));

        // The redaction check's own findings: what the pages hold that doesn't show, covers, earlier versions' text. (Its
        // echoes of that text elsewhere in the file are left out: those places are listed here in their own right.)
        var check = RedactionCheck.Run(data, password, new RedactionCheckOptions(), progress, cancel);
        foreach (var f in check.Findings)
        {
            var section = f.Kind switch
            {
                RedactionLeak.HiddenText => InventorySection.Hidden,
                RedactionLeak.EarlierRevision => InventorySection.EarlierVersions,
                RedactionLeak.CoveredText or RedactionLeak.CoveredContent or RedactionLeak.UnappliedMark or RedactionLeak.GlyphSpacing or RedactionLeak.AreaNotRemoved
                    => InventorySection.Redaction,
                _ => (InventorySection?)null,
            };
            if (section is { } s) items.Add(new InventoryItem(s, RedactionCheck.Name(f.Kind), f.Where, Clip(f.Text)) { Page = f.Page, RemovedBy = f.Sanitize });
        }
        notes.AddRange(check.Notes);

        var kept = new List<InventoryItem>();
        foreach (var g in items.GroupBy(i => i.Section).OrderBy(g => g.Key))
        {
            var list = g.ToList();
            kept.AddRange(list.Take(MaxPerSection));
            if (list.Count > MaxPerSection) notes.Add(Loc.Format(PdfStrings.Inventory_OnlyFirstListed, Title(g.Key), MaxPerSection, list.Count));
        }
        return new InventoryReport(kept, counts, pages, [.. notes.Distinct()]);
    }

    // ───────────────────────────── the walk ─────────────────────────────

    private sealed class Walk
    {
        private const int AnnotHidden = 2, AnnotNoView = 32, FfPushButton = 1 << 16;
        private static readonly ReferenceEqualityComparer RefEq = ReferenceEqualityComparer.Instance;

        public readonly List<InventoryItem> Items = [];
        private readonly HashSet<PdfDictionary> _actions = new(RefEq);
        private readonly HashSet<string> _addresses = [];
        private PdfDocument _doc = null!;

        public void Run(PdfDocument doc, CancellationToken cancel)
        {
            _doc = doc;
            var catalog = doc.Internals.Catalog;
            Document(catalog);
            for (var p = 0; p < doc.PageCount; p++)
            {
                cancel.ThrowIfCancellationRequested();
                Page(doc.Pages[p], p);
            }
            Outline(catalog);
            Form(catalog);
            Layers(catalog);
            Metadata(doc, catalog);
            ExternalStreams(doc);
        }

        // ── actions ──

        /// <summary>An action (with the ones after it) at <paramref name="where"/>, set off by <paramref name="trigger"/>.</summary>
        private void Action(PdfItem? item, string where, InventoryTrigger trigger, int page)
        {
            var chain = new List<PdfDictionary>();
            Flatten(item, chain, 0);
            foreach (var a in chain)
            {
                if (!_actions.Add(a)) continue;
                var s = PdfObj.NameOf(a, "/S");
                if (s == "/JavaScript" || a.Elements.ContainsKey("/JS"))
                {
                    Script(PdfObj.Text(a.Elements["/JS"]) ?? "", where, trigger, page);
                    continue;
                }
                var (what, target, removedBy) = Describe(a, s);
                // Going to a page of this document by itself is ordinary navigation: not listed.
                if (trigger == InventoryTrigger.Automatic && s != "/GoTo")
                    Items.Add(new InventoryItem(InventorySection.Actions, what, where, target ?? Words(s)) { Page = page, Trigger = trigger, RemovedBy = removedBy });
                if (target is not null && s is "/URI" or "/SubmitForm" or "/GoToR" or "/GoToE" or "/Launch" or "/ImportData" or "/Thread")
                    Address(target, what, where, trigger, page, removedBy ?? SanitizeItem.ExternalLinks);
                else if (trigger != InventoryTrigger.Automatic && removedBy == SanitizeItem.ActiveContent)
                    Items.Add(new InventoryItem(InventorySection.Scripts, what, where, target ?? Words(s)) { Page = page, Trigger = trigger, RemovedBy = removedBy });
            }
        }

        private static void Flatten(PdfItem? item, List<PdfDictionary> chain, int depth)
        {
            if (depth > 32 || PdfObj.Dict(item) is not { } a || chain.Contains(a, RefEq)) return;
            chain.Add(a);
            switch (PdfObj.Resolve(a.Elements["/Next"]))
            {
                case PdfDictionary next:
                    Flatten(next, chain, depth + 1);
                    break;
                case PdfArray list:
                    foreach (var n in list.Elements) Flatten(n, chain, depth + 1);
                    break;
            }
        }

        /// <summary>An action in words, its target (an address, a file, a page) and what Sanitize removes it as.</summary>
        private (string What, string? Target, SanitizeItem? RemovedBy) Describe(PdfDictionary a, string s) => s switch
        {
            "/URI" => (PdfStrings.Inventory_OpensWebAddress, Clean(PdfObj.Str(a.Elements["/URI"])), SanitizeItem.ExternalLinks),
            "/SubmitForm" => (PdfStrings.Inventory_SendsFormData, FileName(a.Elements["/F"]), SanitizeItem.ActiveContent),
            "/ImportData" => (PdfStrings.Inventory_ReadsFormData, FileName(a.Elements["/F"]), SanitizeItem.ActiveContent),
            "/Launch" => (PdfStrings.Inventory_StartsProgram, FileName(a.Elements["/F"]) ?? FileName(PdfObj.Dict(a.Elements["/Win"])?.Elements["/F"]), SanitizeItem.ActiveContent),
            "/GoToR" => (PdfStrings.Inventory_OpensOtherPdf, FileName(a.Elements["/F"]), SanitizeItem.ExternalLinks),
            "/GoToE" => (PdfStrings.Inventory_OpensEmbeddedPdf, FileName(a.Elements["/F"]) ?? PdfStrings.Inventory_AnAttachedPdf, SanitizeItem.ExternalLinks),
            "/Thread" when a.Elements.ContainsKey("/F") => (PdfStrings.Inventory_OpensArticle, FileName(a.Elements["/F"]), SanitizeItem.ExternalLinks),
            "/Rendition" or "/Movie" or "/Sound" or "/RichMediaExecute" or "/GoTo3DView" => (PdfStrings.Inventory_PlaysMedia, null, SanitizeItem.ActiveContent),
            "/GoTo" => (PdfStrings.Inventory_GoesToPage, DocumentFeatures.ResolveDestination(_doc, a.Elements["/D"]) is { } d ? Loc.Format(PdfStrings.Inventory_PageNPage, d.PageIndex + 1) : null, null),
            "/Named" => (PdfStrings.Inventory_RunsViewerCommand, PdfObj.Name(a.Elements["/N"]), null),
            "/Hide" => (PdfStrings.Inventory_ShowsHidesFields, null, null),
            "/ResetForm" => (PdfStrings.Inventory_ClearsForm, null, null),
            "/SetOCGState" => (PdfStrings.Inventory_ShowsHidesLayers, null, null),
            _ => (PdfStrings.Inventory_Action, s.TrimStart('/'), null),
        };

        private static string Words(string s) => s.Length > 1 ? s[1..] : PdfStrings.Inventory_NoType;

        private static string? FileName(PdfItem? f) => PdfObj.Resolve(f) switch
        {
            PdfString or PdfStringObject => Clean(PdfObj.Str(f)),
            PdfDictionary fs => Clean(PdfObj.Str(fs.Elements["/UF"]) ?? PdfObj.Str(fs.Elements["/F"]) ?? PdfObj.Str(fs.Elements["/DOS"]) ?? PdfObj.Str(fs.Elements["/Unix"])),
            _ => null,
        };

        private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : Clip(s.Trim());

        private void Address(string target, string what, string where, InventoryTrigger trigger, int page, SanitizeItem? removedBy)
        {
            if (!_addresses.Add($"{target}\n{where}\n{trigger}")) return;
            Items.Add(new InventoryItem(InventorySection.Addresses, what, where, target) { Page = page, Trigger = trigger, RemovedBy = removedBy });
        }

        private void Script(string source, string where, InventoryTrigger trigger, int page)
        {
            var calls = ScriptCalls(source);
            Items.Add(new InventoryItem(InventorySection.Scripts, PdfStrings.Inventory_Script, where, Clip(source.Trim()))
            {
                Page = page,
                Trigger = trigger,
                Calls = calls,
                RemovedBy = SanitizeItem.ActiveContent,
            });
            foreach (Match m in UrlPattern().Matches(source))
                Address(m.Value.TrimEnd('.', ',', ';'), PdfStrings.Inventory_WebAddressInScript, where, trigger, page, SanitizeItem.ActiveContent);
        }

        /// <summary>The additional actions (/AA) of a document, page, comment or field.</summary>
        private void AdditionalActions(PdfDictionary owner, Func<string, (string Where, InventoryTrigger Trigger)?> name, int page)
        {
            if (PdfObj.Dict(owner.Elements["/AA"]) is not { } aa) return;
            foreach (var key in aa.Elements.Keys)
                if (name(key) is { } n) Action(aa.Elements[key], n.Where, n.Trigger, page);
        }

        // ── document, pages ──

        private void Document(PdfDictionary catalog)
        {
            switch (PdfObj.Resolve(catalog.Elements["/OpenAction"]))
            {
                case PdfDictionary:
                    Action(catalog.Elements["/OpenAction"], PdfStrings.Inventory_WhenDocOpens, InventoryTrigger.Automatic, -1);
                    break;
            }
            AdditionalActions(catalog, key => key switch
            {
                "/WC" => (PdfStrings.Inventory_BeforeDocCloses, InventoryTrigger.Automatic),
                "/WS" => (PdfStrings.Inventory_BeforeDocSaved, InventoryTrigger.Automatic),
                "/DS" => (PdfStrings.Inventory_AfterDocSaved, InventoryTrigger.Automatic),
                "/WP" => (PdfStrings.Inventory_BeforeDocPrinted, InventoryTrigger.Automatic),
                "/DP" => (PdfStrings.Inventory_AfterDocPrinted, InventoryTrigger.Automatic),
                _ => (Loc.Format(PdfStrings.Inventory_DocumentEvent, key.TrimStart('/')), InventoryTrigger.Automatic),
            }, -1);

            var names = PdfObj.Dict(catalog.Elements["/Names"]);
            foreach (var (key, value) in PdfObj.NameTree(PdfObj.Dict(names?.Elements["/JavaScript"])))
                Action(value, Loc.Format(PdfStrings.Inventory_WhenDocOpensScript, key), InventoryTrigger.Automatic, -1);
            if (PdfObj.Str(PdfObj.Dict(catalog.Elements["/URI"])?.Elements["/Base"]) is { Length: > 0 } baseUri)
                Address(baseUri, PdfStrings.Inventory_BaseAddress, PdfStrings.Inventory_TheDocument, InventoryTrigger.None, -1, SanitizeItem.ExternalLinks);
        }

        private void Page(PdfPage page, int p)
        {
            AdditionalActions(page, key => key switch
            {
                "/O" => (Loc.Format(PdfStrings.Inventory_WhenPageOpens, p + 1), InventoryTrigger.Automatic),
                "/C" => (Loc.Format(PdfStrings.Inventory_WhenPageCloses, p + 1), InventoryTrigger.Automatic),
                _ => null,
            }, p);
            if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) return;
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
            {
                var subtype = PdfObj.NameOf(a, "/Subtype");
                if (subtype == "/Popup") continue;
                var kind = subtype switch
                {
                    "/Link" => PdfStrings.Inventory_ALink,
                    "/Widget" => FieldNameOf(a) is { } f ? Loc.Format(PdfStrings.Inventory_FieldNamed, f) : PdfStrings.Inventory_AFormField,
                    _ => PdfStrings.Inventory_AComment,
                };
                var at = Loc.Format(PdfStrings.Inventory_PageKind, p + 1, kind);
                if (subtype != "/Widget") // a widget's actions go with its field (Form)
                {
                    Action(a.Elements["/A"], Loc.Format(PdfStrings.Inventory_WhenClicked, kind, p + 1), InventoryTrigger.Use, p);
                    AdditionalActions(a, key => Event(key, at, p, null), p);
                }
                if (subtype is "/RichMedia" or "/3D" or "/Sound" or "/Movie" or "/Screen")
                    Items.Add(new InventoryItem(InventorySection.Scripts, PdfStrings.Inventory_Multimedia, at, subtype.TrimStart('/')) { Page = p, Trigger = InventoryTrigger.Use, RemovedBy = SanitizeItem.ActiveContent });
                var flags = PdfObj.Int(a.Elements["/F"]) ?? 0;
                if ((flags & (AnnotHidden | AnnotNoView)) != 0)
                    Items.Add(new InventoryItem(InventorySection.Hidden, subtype == "/Widget" ? PdfStrings.Inventory_HiddenField : PdfStrings.Inventory_HiddenComment, at,
                        Clip(PdfObj.Text(a.Elements["/Contents"]) ?? PdfObj.Str(FormEditor.Inherited(a, "/V")) ?? subtype.TrimStart('/'))) { Page = p, RemovedBy = SanitizeItem.HiddenAnnotations });
            }
        }

        /// <summary>An annotation or field event (/AA key) in words.</summary>
        private static (string Where, InventoryTrigger Trigger)? Event(string key, string at, int p, string? field) => key switch
        {
            "/E" => (Loc.Format(PdfStrings.Inventory_PointerEnters, at), InventoryTrigger.Pointer),
            "/X" => (Loc.Format(PdfStrings.Inventory_PointerLeaves, at), InventoryTrigger.Pointer),
            "/D" => (Loc.Format(PdfStrings.Inventory_MousePressed, at), InventoryTrigger.Use),
            "/U" => (Loc.Format(PdfStrings.Inventory_Clicked, at), InventoryTrigger.Use),
            "/Fo" => (Loc.Format(PdfStrings.Inventory_GetsFocus, at), InventoryTrigger.Use),
            "/Bl" => (Loc.Format(PdfStrings.Inventory_LosesFocus, at), InventoryTrigger.Use),
            "/PO" => (Loc.Format(PdfStrings.Inventory_AtPageOpens, at, p + 1), InventoryTrigger.Automatic),
            "/PC" => (Loc.Format(PdfStrings.Inventory_AtPageCloses, at, p + 1), InventoryTrigger.Automatic),
            "/PV" => (Loc.Format(PdfStrings.Inventory_AtPageInView, at, p + 1), InventoryTrigger.Automatic),
            "/PI" => (Loc.Format(PdfStrings.Inventory_AtPageOutOfView, at, p + 1), InventoryTrigger.Automatic),
            "/K" when field is not null => (Loc.Format(PdfStrings.Inventory_FieldTyped, field), InventoryTrigger.Use),
            "/V" when field is not null => (Loc.Format(PdfStrings.Inventory_FieldChanges, field), InventoryTrigger.Use),
            "/C" when field is not null => (Loc.Format(PdfStrings.Inventory_FieldRecalculates, field), InventoryTrigger.Use),
            "/F" when field is not null => (Loc.Format(PdfStrings.Inventory_FieldShown, field), InventoryTrigger.Automatic),
            _ => null,
        };

        private static string? FieldNameOf(PdfDictionary widget)
        {
            var parts = new List<string>();
            var guard = 0;
            for (var d = widget; d is not null && guard++ < 64; d = PdfObj.Dict(d.Elements["/Parent"]))
                if (PdfObj.Str(d.Elements["/T"]) is { } t) parts.Insert(0, t);
            return parts.Count > 0 ? string.Join(".", parts) : null;
        }

        private int PageOf(PdfDictionary widget) => PdfObj.PageIndexOf(_doc, widget.Elements["/P"]) is var p and >= 0 ? p
            : Enumerable.Range(0, _doc.PageCount).FirstOrDefault(i => PdfObj.Array(_doc.Pages[i].Elements["/Annots"])?.Elements.Any(e => ReferenceEquals(PdfObj.Dict(e), widget)) == true, -1);

        // ── bookmarks, form, layers ──

        private void Outline(PdfDictionary catalog)
        {
            if (PdfObj.Dict(catalog.Elements["/Outlines"]) is not { } outlines) return;
            var seen = new HashSet<PdfDictionary>(RefEq) { outlines };
            var stack = new Stack<PdfDictionary>();
            if (PdfObj.Dict(outlines.Elements["/First"]) is { } first) stack.Push(first);
            var n = 0;
            while (stack.Count > 0 && n < 200_000)
                for (var item = stack.Pop(); item is not null && seen.Add(item) && n++ < 200_000; item = PdfObj.Dict(item.Elements["/Next"]))
                {
                    Action(item.Elements["/A"], Loc.Format(PdfStrings.Inventory_WhenBookmark, Clip(PdfObj.Str(item.Elements["/Title"]) ?? "", 80)), InventoryTrigger.Use, -1);
                    if (PdfObj.Dict(item.Elements["/First"]) is { } child) stack.Push(child);
                }
        }

        private void Form(PdfDictionary catalog)
        {
            if (PdfObj.Dict(catalog.Elements["/AcroForm"]) is not { } acro) return;
            var fields = new List<FormEditor.Field>();
            FormEditor.Collect(_doc, acro, fields);
            foreach (var f in fields)
            {
                var widgets = f.Widgets.Count > 0 ? f.Widgets : [f.Dict];
                var page = widgets.Select(PageOf).FirstOrDefault(p => p >= 0, -1);
                var at = page >= 0 ? Loc.Format(PdfStrings.Inventory_FieldWherePage, f.Name, page + 1) : Loc.Format(PdfStrings.Inventory_FieldWhere, f.Name);
                // The field's own actions and each widget's (a widget may be the field itself).
                foreach (var node in widgets.Prepend(f.Dict).Distinct(RefEq).Cast<PdfDictionary>())
                {
                    Action(node.Elements["/A"], Loc.Format(PdfStrings.Inventory_FieldClicked, f.Name), InventoryTrigger.Use, page);
                    AdditionalActions(node, key => Event(key, at, Math.Max(page, 0), f.Name), page);
                }
                if (f.Type == "/Sig")
                {
                    if (PdfObj.Dict(FormEditor.Inherited(f.Dict, "/V")) is { } sig) Signature(sig, at, page);
                    continue;
                }
                if (Value(f) is { } value)
                    Items.Add(new InventoryItem(InventorySection.FormValues, PdfStrings.Inventory_Value, at, Clip(value)) { Page = page, RemovedBy = SanitizeItem.FormValues });
            }
            if (acro.Elements.ContainsKey("/XFA"))
                Items.Add(new InventoryItem(InventorySection.Scripts, PdfStrings.Inventory_XfaForm, PdfStrings.Inventory_TheDocumentsForm,
                    PdfStrings.Inventory_XfaFormDetail) { RemovedBy = fields.Count > 0 ? SanitizeItem.ActiveContent : null });
        }

        private void Signature(PdfDictionary sig, string at, int page)
        {
            var parts = new List<string>();
            if (PdfObj.Str(sig.Elements["/Name"]) is { Length: > 0 } name) parts.Add(name);
            if (PdfObj.ParseDate(PdfObj.Str(sig.Elements["/M"])) is { } when) parts.Add(when.ToString(PdfStrings.Inventory_DateFormat, PdfLanguage.Culture));
            if (PdfObj.Str(sig.Elements["/Reason"]) is { Length: > 0 } reason) parts.Add(Loc.Format(PdfStrings.Inventory_Reason, reason));
            if (PdfObj.Str(sig.Elements["/Location"]) is { Length: > 0 } location) parts.Add(Loc.Format(PdfStrings.Inventory_At, location));
            if (PdfObj.Str(sig.Elements["/ContactInfo"]) is { Length: > 0 } contact) parts.Add(Loc.Format(PdfStrings.Inventory_Contact, contact));
            if (parts.Count == 0) parts.Add(PdfStrings.Inventory_ASignature);
            Items.Add(new InventoryItem(InventorySection.Signatures, PdfStrings.Inventory_Signed, at, Clip(string.Join(", ", parts))) { Page = page, RemovedBy = SanitizeItem.Signatures });
        }

        /// <summary>A field's value in words (as Sanitize counts values: text, choices, a box that is on, a default).</summary>
        private static string? Value(FormEditor.Field f)
        {
            switch (f.Type)
            {
                case "/Tx" or "/Ch":
                    var v = Text(FormEditor.Inherited(f.Dict, "/V"));
                    var dv = Text(f.Dict.Elements["/DV"]);
                    return v is { Length: > 0 } ? v : dv is { Length: > 0 } ? Loc.Format(PdfStrings.Inventory_ItsDefault, dv) : null;
                case "/Btn" when (f.Flags & FfPushButton) == 0:
                    var on = PdfObj.Name(FormEditor.Inherited(f.Dict, "/V")) is { } n && n != "Off" ? n
                        : f.Widgets.Select(w => PdfObj.Name(w.Elements["/AS"])).FirstOrDefault(s => s is not null && s != "Off");
                    return on is null ? null : Loc.Format(PdfStrings.Inventory_On, on);
                default:
                    return null;
            }

            static string? Text(PdfItem? item) => PdfObj.Resolve(item) switch
            {
                PdfArray a => string.Join("; ", a.Elements.Select(PdfObj.Str).Where(s => !string.IsNullOrEmpty(s))),
                PdfDictionary { Stream: not null } d => PdfObj.Text(d),
                var x => PdfObj.Str(x),
            };
        }

        private void Layers(PdfDictionary catalog)
        {
            var props = PdfObj.Dict(catalog.Elements["/OCProperties"]);
            if (PdfObj.Array(props?.Elements["/OCGs"]) is not { } list) return;
            var d = PdfObj.Dict(props!.Elements["/D"]);
            var on = Members(d?.Elements["/ON"]);
            var off = Members(d?.Elements["/OFF"]);
            var baseOff = PdfObj.Name(d?.Elements["/BaseState"]) == "OFF";
            foreach (var ocg in list.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Distinct(RefEq).Cast<PdfDictionary>())
                if (off.Contains(ocg) || (baseOff && !on.Contains(ocg)))
                    Items.Add(new InventoryItem(InventorySection.Hidden, PdfStrings.Inventory_HiddenLayer, PdfStrings.Inventory_TheDocumentsLayers,
                        Loc.Format(PdfStrings.Inventory_LayerOff, Clip(PdfObj.Str(ocg.Elements["/Name"]) ?? PdfStrings.Inventory_NoName, 120))) { RemovedBy = SanitizeItem.HiddenLayers });
        }

        private static HashSet<PdfDictionary> Members(PdfItem? item) => PdfObj.Resolve(item) switch
        {
            PdfArray a => new HashSet<PdfDictionary>(a.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>(), RefEq),
            PdfDictionary one => new HashSet<PdfDictionary>(RefEq) { one },
            _ => new HashSet<PdfDictionary>(RefEq),
        };

        // ── metadata ──

        private void Metadata(PdfDocument doc, PdfDictionary catalog)
        {
            var info = doc.Info.Elements;
            foreach (var key in info.Keys)
            {
                var value = PdfObj.Str(info[key]) ?? PdfObj.Resolve(info[key])?.ToString() ?? "";
                if (key is "/Producer" or "/Creator" && value.StartsWith("PDFsharp", StringComparison.Ordinal)) continue; // what a save writes itself
                if (key is "/CreationDate" or "/ModDate" && PdfObj.ParseDate(value) is { } t) value = t.ToString(PdfStrings.Inventory_DateFormatZone, PdfLanguage.Culture);
                Items.Add(new InventoryItem(InventorySection.Metadata, InfoName(key), PdfStrings.Inventory_DocumentProperties, Clip(value)) { RemovedBy = SanitizeItem.Metadata });
            }

            var authors = new Dictionary<string, (int Count, SortedSet<int> Pages)>();
            var objects = new HashSet<PdfDictionary>(RefEq);
            // Pages are pushed last so they are walked first: what they hold is listed with its page.
            var stack = new Stack<(PdfItem Item, int Depth, int Page)>();
            stack.Push((catalog, 0, -1));
            for (var p = doc.PageCount - 1; p >= 0; p--) stack.Push((doc.Pages[p], 0, p));
            while (stack.Count > 0)
            {
                var (item, depth, page) = stack.Pop();
                var where = page >= 0 ? Loc.Format(PdfStrings.Inventory_PageN, page + 1) : PdfStrings.Inventory_TheDocument;
                if (depth > 64) continue;
                var dict = PdfObj.Dict(item);
                if (dict is null)
                {
                    if (PdfObj.Resolve(item) is PdfArray arr)
                        foreach (var e in arr.Elements) if (e is PdfReference or PdfDictionary or PdfArray) stack.Push((e, depth + 1, page));
                    continue;
                }
                if (!objects.Add(dict) || PdfObj.NameOf(dict, "/Type") is "/Pages" || (depth > 0 && (dict is PdfPage || PdfObj.NameOf(dict, "/Type") == "/Page"))) continue;

                var subtype = PdfObj.NameOf(dict, "/Subtype");
                var owner = Owner(dict, subtype, where, ReferenceEquals(dict, catalog));
                if (dict.Elements.ContainsKey("/Rect") && subtype.Length > 0 && subtype is not ("/Widget" or "/Link" or "/Popup") && !dict.Elements.ContainsKey("/BBox")
                    && PdfObj.Str(dict.Elements["/T"]) is { Length: > 0 } author)
                {
                    var (c, pages) = authors.TryGetValue(author, out var known) ? known : (0, new SortedSet<int>());
                    if (page >= 0) pages.Add(page + 1);
                    authors[author] = (c + 1, pages);
                }
                if (PdfObj.Dict(dict.Elements["/PieceInfo"]) is { } piece)
                    Items.Add(new InventoryItem(InventorySection.Metadata, PdfStrings.Inventory_PrivateData, owner,
                        string.Join(", ", piece.Elements.Keys.Select(k => k.TrimStart('/')))) { RemovedBy = SanitizeItem.Metadata });
                if (PdfObj.Dict(dict.Elements["/Metadata"]) is { Stream: not null } xmp)
                {
                    var props = Sanitizer.XmpProperties(xmp);
                    if (props is null)
                        Items.Add(new InventoryItem(InventorySection.Metadata, PdfStrings.Inventory_XmpMetadata, owner, PdfStrings.Inventory_PacketUnreadable) { RemovedBy = SanitizeItem.Metadata });
                    else if (props.Count > 0)
                        foreach (var (name, value) in props)
                            Items.Add(new InventoryItem(InventorySection.Metadata, XmpName(name), Loc.Format(PdfStrings.Inventory_OwnerXmp, owner), Clip(value)) { RemovedBy = SanitizeItem.Metadata });
                    else if (!ReferenceEquals(dict, catalog))
                        Items.Add(new InventoryItem(InventorySection.Metadata, PdfStrings.Inventory_XmpMetadata, owner, PdfStrings.Inventory_PacketEmpty) { RemovedBy = SanitizeItem.Metadata });
                }
                if (PdfObj.Array(dict.Elements["/AF"]) is { Elements.Count: > 0 } af)
                    Items.Add(new InventoryItem(InventorySection.Attachments, PdfStrings.Inventory_AssociatedFile, owner,
                        string.Join(", ", af.Elements.Select(e => FileName(e) ?? PdfStrings.Inventory_NoName))) { RemovedBy = SanitizeItem.EmbeddedFiles });

                foreach (var (key, v) in dict.Elements)
                {
                    if (key is "/Parent" or "/P" or "/Metadata" or "/Prev" or "/Last" or "/Dest" or "/D") continue;
                    if (v is PdfReference or PdfDictionary or PdfArray) stack.Push((v, depth + 1, page));
                }
            }
            foreach (var (author, (count, pages)) in authors.OrderByDescending(a => a.Value.Count))
            {
                var pageList = string.Join(", ", pages.Take(20)) + (pages.Count > 20 ? ", …" : "");
                Items.Add(new InventoryItem(InventorySection.Metadata, PdfStrings.Inventory_CommentAuthor, Loc.Plural(count, PdfStrings.Inventory_CommentsCount_One, PdfStrings.Inventory_CommentsCount_Many),
                    pages.Count > 0 ? Loc.Plural(pages.Count, PdfStrings.Inventory_AuthorPages_One, PdfStrings.Inventory_AuthorPages_Many, author, pageList) : author) { RemovedBy = SanitizeItem.Metadata });
            }

            if (PdfObj.Array(catalog.Elements["/Threads"]) is { } threads)
                foreach (var t in threads.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
                    if (PdfObj.Dict(t.Elements["/I"]) is { Elements.Count: > 0 } ti)
                        foreach (var (key, v) in ti.Elements)
                            Items.Add(new InventoryItem(InventorySection.Metadata, InfoName(key), PdfStrings.Inventory_ArticleProperties, Clip(PdfObj.Str(v) ?? v?.ToString() ?? "")) { RemovedBy = SanitizeItem.Metadata });
        }

        private static string Owner(PdfDictionary d, string subtype, string where, bool catalog) =>
            catalog ? PdfStrings.Inventory_TheDocument :
            d is PdfPage ? where :
            subtype switch
            {
                "/Image" => Loc.Format(PdfStrings.Inventory_WherePicture, where),
                "/Form" => Loc.Format(PdfStrings.Inventory_WhereDrawing, where),
                "/Widget" => Loc.Format(PdfStrings.Inventory_WhereFormField, where),
                "/Type1" or "/TrueType" or "/Type0" or "/Type3" or "/CIDFontType0" or "/CIDFontType2" => Loc.Format(PdfStrings.Inventory_WhereFont, where),
                _ when d.Elements.ContainsKey("/Rect") => Loc.Format(PdfStrings.Inventory_WhereComment, where),
                _ when PdfObj.NameOf(d, "/Type") == "/FontDescriptor" => Loc.Format(PdfStrings.Inventory_WhereFont, where),
                _ => Loc.Format(PdfStrings.Inventory_WhereObject, where),
            };

        private static string InfoName(string key) => key switch
        {
            "/Title" => PdfStrings.Inventory_Title,
            "/Author" => PdfStrings.Inventory_Author,
            "/Subject" => PdfStrings.Inventory_Subject,
            "/Keywords" => PdfStrings.Inventory_Keywords,
            "/Creator" => PdfStrings.Inventory_MadeWith,
            "/Producer" => PdfStrings.Inventory_WrittenBy,
            "/CreationDate" => PdfStrings.Inventory_Created,
            "/ModDate" => PdfStrings.Inventory_Modified,
            "/Trapped" => PdfStrings.Inventory_Trapped,
            _ => key.TrimStart('/'),
        };

        private static string XmpName(string name) => name switch
        {
            "creator" => PdfStrings.Inventory_XmpAuthor,
            "title" => PdfStrings.Inventory_XmpTitle,
            "description" => PdfStrings.Inventory_XmpSubject,
            "subject" => PdfStrings.Inventory_XmpKeywords,
            "rights" => PdfStrings.Inventory_XmpRights,
            "CreateDate" => PdfStrings.Inventory_XmpCreated,
            "ModifyDate" => PdfStrings.Inventory_XmpModified,
            "MetadataDate" => PdfStrings.Inventory_XmpMetadataDate,
            "DocumentID" => PdfStrings.Inventory_XmpDocumentId,
            "InstanceID" => PdfStrings.Inventory_XmpInstanceId,
            "OriginalDocumentID" => PdfStrings.Inventory_XmpOriginalId,
            "History" => PdfStrings.Inventory_XmpHistory,
            "DerivedFrom" => PdfStrings.Inventory_XmpDerivedFrom,
            _ => Loc.Format(PdfStrings.Inventory_XmpOther, name),
        };

        /// <summary>Streams whose data is in another file or on the web (/F): read when the page is drawn.</summary>
        private void ExternalStreams(PdfDocument doc)
        {
            foreach (var o in doc.Internals.GetAllObjects())
                if (o is PdfDictionary { Stream: not null } d && d.Elements.ContainsKey("/F") && FileName(d.Elements["/F"]) is { } target)
                    Address(target, PdfStrings.Inventory_ExternalData, PdfStrings.Inventory_WhenPageDrawn, InventoryTrigger.Automatic, -1, null);
        }
    }

    // ───────────────────────────── scripts ─────────────────────────────

    /// <summary>What a script calls that reaches outside the document or acts on the reader, in words, each once.</summary>
    internal static List<string> ScriptCalls(string source)
    {
        var calls = new List<string>();
        foreach (var (pattern, says) in Calls)
            if (pattern.IsMatch(source) && says() is var words && !calls.Contains(words)) calls.Add(words);
        return calls;
    }

    private static readonly (Regex Pattern, Func<string> Words)[] Calls =
    [
        (new(@"\b(launchURL|getURL)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallOpensWebAddress),
        (new(@"\bsubmitForm\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallSendsFormData),
        (new(@"\b(mailDoc|mailForm|mailMsg|mailGetAddrs)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallSendsEmail),
        (new(@"\b(Net\.HTTP|SOAP\.|Net\.SOAP|Net\.Discovery|Collab\.)", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallConnects),
        (new(@"\bopenDoc\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallOpensFile),
        (new(@"\b(exportDataObject|exportAsFDF|exportAsXFDF|exportAsText|exportXFAData|saveAs|extractPages)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallWritesFile),
        (new(@"\b(importDataObject|importAnFDF|importAnXFDF|importTextData|importXFAData|importIcon|importSound|readFileIntoStream|browseForDoc)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallReadsFile),
        (new(@"\b(launch|openDataObject)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallOpensAttached),
        (new(@"\b(print|printWithParams)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallPrints),
        (new(@"\bexecMenuItem\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallMenuCommand),
        (new(@"\b(setTimeOut|setInterval)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallTimer),
        (new(@"\b(eval|Function)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallBuildsCode),
        (new(@"\b(addScript|setAction|setPageAction)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallAddsScripts),
        (new(@"\b(alert|response)\s*\(", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallMessage),
        (new(@"\b(identity|app\.platform|app\.viewerVersion)\b", RegexOptions.CultureInvariant), () => PdfStrings.Inventory_CallIdentity),
    ];

    [GeneratedRegex(@"(?:https?|ftp)://[^\s'""\\()<>\[\]{}]+|mailto:[^\s'""\\()<>\[\]{}]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex UrlPattern();

    // ───────────────────────────── words ─────────────────────────────

    internal static string Clip(string s, int max = MaxDetail)
    {
        s = s.Replace("\r\n", "\n").Replace('\r', '\n');
        return s.Length <= max ? s : s[..max].TrimEnd() + "…";
    }

    internal static string Lower(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];

    private static string Size(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} bytes",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        _ => $"{bytes / (1024.0 * 1024):0.#} MB",
    };
}
