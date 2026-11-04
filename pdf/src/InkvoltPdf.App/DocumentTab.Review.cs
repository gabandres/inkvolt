using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>A comment in the Comments pane (replies are indented under the comment they answer).</summary>
public sealed class CommentItem(AnnotationInfo info, string pageHeader, int depth)
{
    public AnnotationInfo Info { get; } = info;
    public string PageHeader { get; } = pageHeader;
    public Thickness Indent { get; } = new(depth * 18, 0, 0, 0);
    public string Contents => Info.Contents.Trim();
    public Visibility ContentsVisibility => Contents.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public string Title => TitleOf(Info);

    /// <summary>What a comment is called ("Highlight", "Arrow", "Callout"…).</summary>
    public static string TitleOf(AnnotationInfo info) => info.ReplyTo is not null ? Strings.Review_KindReply : DrawingTitle(info) ?? info.Kind switch
    {
        AnnotationKind.Stamp => string.IsNullOrWhiteSpace(info.Subject) ? Strings.Review_KindStamp : info.Subject,
        AnnotationKind.Text => Strings.Review_KindNote,
        AnnotationKind.FreeText => Strings.Review_KindTextBox,
        AnnotationKind.StrikeOut => Strings.Review_KindStrikeOut,
        AnnotationKind.Squiggly => Strings.Review_KindSquiggly,
        AnnotationKind.FileAttachment => Strings.Review_KindAttachedFile,
        AnnotationKind.Square => Strings.Review_KindRectangle,
        AnnotationKind.Circle => Strings.Review_KindEllipse,
        AnnotationKind.PolyLine => Strings.Review_KindPolyline,
        AnnotationKind.Ink => Strings.Review_KindDrawing,
        AnnotationKind.Caret => Strings.Review_KindInsertText,
        AnnotationKind.Redact => Strings.Review_KindRedactionMark,
        AnnotationKind.Other => info.Subtype,
        _ => info.Kind.ToString(),
    };

    private static string? DrawingTitle(AnnotationInfo a) => !DrawTools.IsDrawing(a) || DrawTools.ToolOf(a) is not { } tool ? null : a.Subtype switch
    {
        "Polygon" => Strings.Review_KindPolygon,
        "PolyLine" => Strings.Review_KindPolyline,
        "FreeText" when tool == ViewerTool.TextBox && a.Style?.Color is null => Strings.Review_KindTypewriter,
        _ => DrawTools.Title(tool),
    };

    public string Meta
    {
        get
        {
            var parts = new[] { Info.Author, Info.Modified?.LocalDateTime.ToString("g") }.Where(s => !string.IsNullOrWhiteSpace(s));
            var text = string.Join(" · ", parts);
            return text.Length > 0 ? "  " + text : "";
        }
    }

    public string Glyph => DrawTools.IsDrawing(Info) && DrawTools.ToolOf(Info) is { } tool ? DrawTools.Glyph(tool) : Info.Kind switch
    {
        AnnotationKind.Highlight => "",
        AnnotationKind.Underline or AnnotationKind.Squiggly => "",
        AnnotationKind.StrikeOut => "",
        AnnotationKind.Ink => "",
        AnnotationKind.FileAttachment => "",
        _ => "",
    };

    /// <summary>The comment's own color as a swatch (light gray when it has none).</summary>
    public Brush Swatch
    {
        get
        {
            var c = Info.Color is { } k
                ? Color.FromRgb((byte)Math.Round(Math.Clamp(k.R, 0, 1) * 255), (byte)Math.Round(Math.Clamp(k.G, 0, 1) * 255), (byte)Math.Round(Math.Clamp(k.B, 0, 1) * 255))
                : Color.FromRgb(0xD8, 0xD8, 0xD8);
            var b = new SolidColorBrush(c);
            b.Freeze();
            return b;
        }
    }

    /// <summary>Dark glyph on light colors, white on dark ones.</summary>
    public Brush GlyphBrush => Info.Color is { } k && 0.299 * k.R + 0.587 * k.G + 0.114 * k.B < 0.55 ? Brushes.White : DarkGlyph;

    private static readonly Brush DarkGlyph = MakeFrozen(Color.FromRgb(0x20, 0x20, 0x20));
    private static Brush MakeFrozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    public string AccessibleName => Info.Author is { Length: > 0 } a
        ? Loc.Format(Strings.Review_CommentNameBy, Title, a, PageHeader, Contents)
        : Loc.Format(Strings.Review_CommentName, Title, PageHeader, Contents);
    public override string ToString() => AccessibleName;
}

/// <summary>A file attached to the document, in the Attachments pane.</summary>
public sealed class AttachmentItem(AttachmentInfo info, string? pageLabel)
{
    public AttachmentInfo Info { get; } = info;
    public string Name => Info.FileName;
    public bool IsPdf => Info.FileName.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) || Info.MimeType == "application/pdf";
    public string Glyph => IsPdf ? "" : "";

    public string Detail
    {
        get
        {
            var parts = new List<string> { FileActions.FormatSize(Info.Size) };
            if (pageLabel is not null) parts.Add(Loc.Format(Strings.Review_AttachmentOnPage, pageLabel));
            if (!string.IsNullOrWhiteSpace(Info.Description) && Info.Description != Info.FileName) parts.Add(Info.Description.Trim());
            return string.Join(" · ", parts);
        }
    }

    public string Tip => Info.Modified is { } m ? Loc.Format(Strings.Review_AttachmentTip, Name, m.LocalDateTime) : Name;
    public string AccessibleName => $"{Name}, {Detail}";
    public override string ToString() => AccessibleName;
}

/// <summary>A layer (or a label grouping layers) in the Layers pane.</summary>
public sealed class LayerNode(string label, LayerInfo? layer, List<LayerNode> children, bool visible, Action<LayerNode> toggled) : INotifyPropertyChanged
{
    private bool _visible = visible;

    public string Label { get; } = label;
    public LayerInfo? Layer { get; } = layer;
    public List<LayerNode> Children { get; } = children;
    public bool IsEnabled => Layer is { Locked: false };
    public string? Tip => Layer is { Locked: true } ? Strings.Review_LayerLocked : null;
    public Visibility CheckVisibility => Layer is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility GroupVisibility => Layer is null ? Visibility.Visible : Visibility.Collapsed;

    public bool IsChecked
    {
        get => _visible;
        set
        {
            if (_visible == value) return;
            _visible = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
            toggled(this);
        }
    }

    public override string ToString() => Label;
    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>A signature field and its verification result, in the Signatures pane.</summary>
public sealed class SignatureItem(SignatureInfo info, string? pageLabel, bool brokenByEdits = false)
{
    public SignatureInfo Info { get; } = info;
    public string Title => Info.Status == SignatureStatus.Unsigned ? Loc.Format(Strings.Review_SigNotSigned, Info.FieldName)
        : Info.SubFilter == "ETSI.RFC3161" ? Loc.Format(Strings.Review_SigTimestampTitle, Info.SignerName ?? Info.FieldName)
        : Info.SignerName ?? Info.FieldName;
    public string? LongTerm => Info.LongTerm?.Summary;
    public Visibility LongTermVisibility => Info.LongTerm is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility GoVisibility => Info.PageIndex >= 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SignVisibility => Info.Status == SignatureStatus.Unsigned ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>ok, warn, bad or none (drives the icon color).</summary>
    public string Severity => DocumentTab.SignatureSeverity(Info, brokenByEdits);

    public string Glyph => Severity switch { "ok" => "", "bad" => "", "none" => "", _ => "" };
    public string Status => DocumentTab.SignatureSummary(Info, brokenByEdits);

    public string Details
    {
        get
        {
            var lines = new List<string>
            {
                pageLabel is null ? Loc.Format(Strings.Review_SigFieldInvisible, Info.FieldName) : Loc.Format(Strings.Review_SigFieldOnPage, Info.FieldName, pageLabel),
            };
            if (Info.SigningTime is { } t) lines.Add(Loc.Format(Info.HasTimestamp ? Strings.Review_SigSignedTimestamped : Strings.Review_SigSignedClock, t.LocalDateTime));
            if (Info.CertificationLevel is { } p) lines.Add(p switch
            {
                1 => Strings.Review_SigCertifiedNoChanges,
                2 => Strings.Review_SigCertifiedForms,
                _ => Strings.Review_SigCertifiedComments,
            });
            if (!string.IsNullOrWhiteSpace(Info.Reason)) lines.Add(Loc.Format(Strings.Review_SigReason, Info.Reason));
            if (!string.IsNullOrWhiteSpace(Info.Location)) lines.Add(Loc.Format(Strings.Review_SigLocation, Info.Location));
            if (Info.SubFilter is { } f) lines.Add(Loc.Format(Strings.Review_SigFormat, f));
            if (Info.Status != SignatureStatus.Unsigned)
                lines.Add(Info.CoversWholeDocument ? Strings.Review_SigCoversAll
                    : Info.LongTerm?.OnlyValidationDataAfter == true ? Strings.Review_SigCoversAllLtvAfter
                    : Strings.Review_SigCoversPart);
            if (Info.Certificate is { } c)
            {
                lines.Add(Loc.Format(Strings.Review_SigCertificate, c.Subject));
                lines.Add(Loc.Format(Strings.Review_SigIssuedBy, c.Issuer));
                lines.Add(Loc.Format(Info.CertificateValidAtSigningTime == false ? Strings.Review_SigValidDatesNotAtSigning : Strings.Review_SigValidDates, c.NotBefore, c.NotAfter));
                lines.Add(Loc.Format(Strings.Review_SigTrust, Info.CertificateTrusted ? Strings.Review_SigTrustedByWindows : Info.CertificateStatus));
                lines.Add(Loc.Format(Strings.Review_SigSerial, c.SerialNumber));
                lines.Add(Loc.Format(Strings.Review_SigThumbprint, c.Thumbprint));
            }
            foreach (var check in Info.LongTerm?.Chain ?? []) lines.Add(Loc.Format(Strings.Review_SigRevocationData, check.Name, Describe(check)));
            if (!string.IsNullOrWhiteSpace(Info.Detail)) lines.Add(Info.Detail);
            return string.Join("\n", lines);
        }
    }

    private static string Describe(CertificateCheck c) => c.Outcome switch
    {
        CertificateCheckOutcome.Root => Strings.Review_CheckRoot,
        CertificateCheckOutcome.NoCheckNeeded => Strings.Review_CheckOcspResponder,
        CertificateCheckOutcome.Good => Strings.Review_CheckGood,
        CertificateCheckOutcome.Revoked => c.RevokedAt is { } at ? Loc.Format(Strings.Review_CheckRevokedOn, at.UtcDateTime) : Strings.Review_CheckRevoked,
        CertificateCheckOutcome.RevokedLater => Loc.Format(Strings.Review_CheckRevokedLater, c.RevokedAt?.UtcDateTime),
        CertificateCheckOutcome.Unknown => Strings.Review_CheckUnknown,
        CertificateCheckOutcome.Stale => Strings.Review_CheckStale,
        CertificateCheckOutcome.NoIssuer => Strings.Review_CheckNoIssuer,
        _ => Strings.Review_CheckNone,
    };
}

public enum ReviewPane { Comments, Attachments, Layers, Signatures }

/// <summary>Comments, attachments, layers, signatures, redaction, page labels and the document's opening preferences.</summary>
public partial class DocumentTab
{
    private int _reviewLoad;
    private bool _reviewLoadedOnce;
    private bool _hadViewState;
    private string[]? _labels;
    private object? _reviewData; // the content (DocumentSession.ContentKey) the review was read from
    private IReadOnlyList<AnnotationInfo> _annotations = [];
    private List<CommentItem> _commentItems = [];
    private IReadOnlyList<AttachmentInfo> _attachments = [];
    private IReadOnlyList<LayerInfo> _layers = [];
    private IReadOnlyList<LayerOrderNode> _layerOrder = [];
    private readonly Dictionary<string, bool> _layerChoice = [];
    private int _layerTicket;
    private PdfEngine? _viewEngine;
    private readonly List<PdfEngine> _retiredEngines = []; // replaced layer views a print or export may still read
    private IReadOnlyList<SignatureInfo> _signatures = [];
    private readonly Dictionary<string, SignatureInfo> _signaturesOnOpen = [];
    private bool _signatureBaselineStale; // reloaded from disk: the next verification is the new "on open" result
    private bool _sigBarDismissed;
    private bool _xfaBarDismissed;
    private bool _displayDocTitle;
    private string? _docTitle;

    /// <summary>The engine pages are shown, printed and exported with: the document, or a copy with the chosen layers.</summary>
    public PdfEngine ViewEngine => _viewEngine ?? Session.Engine;

    /// <summary>The tab's caption: the document title when the file asks for it (DisplayDocTitle), else the file name.</summary>
    public string DisplayTitle => _docTitle ?? Session.DisplayName;

    /// <summary>The comment author: the name set in Settings, else the Windows user name.</summary>
    public static string Author => AppSettings.Current.AuthorName is { Length: > 0 } a ? a : Environment.UserName;

    public IReadOnlyList<AnnotationInfo> Comments => _annotations;
    public IReadOnlyList<AttachmentInfo> AttachedFiles => _attachments;
    public IReadOnlyList<SignatureInfo> SignatureResults => _signatures;
    public IReadOnlyList<LayerInfo> LayerList => _layers;
    public bool HasLayerOverride => _viewEngine is not null;

    // ───────────────────────────── Page labels ─────────────────────────────

    public bool HasPageLabels => _labels is not null;

    /// <summary>The page's label (e.g. "iv"), or its number when the document has no labels.</summary>
    public string PageLabel(int index) => _labels is { } l && index >= 0 && index < l.Length ? l[index] : (index + 1).ToString();

    /// <summary>The page a typed label or number refers to: a matching label first, then a page number.</summary>
    public int? FindPage(string text)
    {
        text = text.Trim();
        if (DocumentFeatures.FindPageByLabel(_labels, text) is { } byLabel) return byLabel;
        return int.TryParse(text, out var n) && n >= 1 && n <= Viewer.PageCount ? n - 1 : null;
    }

    // ───────────────────────────── Setup ─────────────────────────────

    private void InitReview()
    {
        CommentsRail.Click += (_, _) => TogglePane(NavPaneKind.Comments);
        AttachmentsRail.Click += (_, _) => TogglePane(NavPaneKind.Attachments);
        LayersRail.Click += (_, _) => TogglePane(NavPaneKind.Layers);
        SignaturesRail.Click += (_, _) => TogglePane(NavPaneKind.Signatures);
        CommentsRail.Visibility = AttachmentsRailHost.Visibility = Session.IsPdf ? Visibility.Visible : Visibility.Collapsed;

        CommentFilter.TextChanged += (_, _) => RefreshCommentList();
        CommentList.SelectionChanged += (_, _) =>
        {
            var sel = CommentList.SelectedItem as CommentItem;
            CommentEditButton.IsEnabled = CommentEditMenu.IsEnabled = sel is not null;
            CommentDeleteButton.IsEnabled = CommentDeleteMenu.IsEnabled = sel is not null;
            if (sel is not null && !_syncingComments)
            {
                FlashComment(sel.Info);
                // A drawing picked in the list is selected on the page too (ready to move, restyle or delete).
                _syncingComments = true;
                try
                {
                    Viewer.SelectDrawing(DrawTools.IsDrawing(sel.Info) ? sel.Info.Id : null);
                    // A placed picture, signature or stamp too.
                    Viewer.SelectPlacedStamp(sel.Info.Kind == AnnotationKind.Stamp ? sel.Info.Id : null);
                }
                finally { _syncingComments = false; }
            }
        };
        CommentList.PreviewMouseLeftButtonUp += (_, e) =>
        {
            // Clicking the drawing already selected in the list selects it on the page again (after the page lost it).
            if (ItemData<CommentItem>(e.OriginalSource) is { } c && c == CommentList.SelectedItem && DrawTools.IsDrawing(c.Info) && Viewer.SelectedDrawing?.Id != c.Info.Id)
                Viewer.SelectDrawing(c.Info.Id);
        };
        CommentList.MouseDoubleClick += (_, e) =>
        {
            if (ItemData<CommentItem>(e.OriginalSource) is { } c) _ = EditComment(c.Info);
        };
        CommentList.KeyDown += (_, e) =>
        {
            if (CommentList.SelectedItem is not CommentItem c || Keyboard.Modifiers != ModifierKeys.None) return;
            if (e.Key == Key.Delete) _ = DeleteComment(c.Info);
            else if (e.Key == Key.Enter) _ = EditComment(c.Info);
            else return;
            e.Handled = true;
        };
        CommentEditButton.Click += (_, _) => { if (CommentList.SelectedItem is CommentItem c) _ = EditComment(c.Info); };
        CommentEditMenu.Click += (_, _) => { if (CommentList.SelectedItem is CommentItem c) _ = EditComment(c.Info); };
        CommentDeleteButton.Click += (_, _) => { if (CommentList.SelectedItem is CommentItem c) _ = DeleteComment(c.Info); };
        CommentDeleteMenu.Click += (_, _) => { if (CommentList.SelectedItem is CommentItem c) _ = DeleteComment(c.Info); };

        AttachmentList.SelectionChanged += (_, _) => UpdateAttachmentButtons();
        AttachmentList.MouseDoubleClick += (_, e) =>
        {
            if (ItemData<AttachmentItem>(e.OriginalSource) is not { } a) return;
            if (a.IsPdf) _ = OpenAttachment(a.Info);
            else _ = SaveAttachment(a.Info);
        };
        AttachmentList.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Delete || AttachmentList.SelectedItem is not AttachmentItem a) return;
            _ = RemoveAttachment(a.Info);
            e.Handled = true;
        };
        AttachSaveButton.Click += (_, _) => { if (AttachmentList.SelectedItem is AttachmentItem a) _ = SaveAttachment(a.Info); };
        AttachOpenButton.Click += (_, _) => { if (AttachmentList.SelectedItem is AttachmentItem a) _ = OpenAttachment(a.Info); };
        AttachRemoveButton.Click += (_, _) => { if (AttachmentList.SelectedItem is AttachmentItem a) _ = RemoveAttachment(a.Info); };
        AttachAddButton.Click += (_, _) => _ = AddAttachment();

        var layerItemStyle = new Style(typeof(TreeViewItem), LayerTree.TryFindResource(typeof(TreeViewItem)) as Style);
        layerItemStyle.Setters.Add(new Setter(TreeViewItem.IsExpandedProperty, true));
        layerItemStyle.Setters.Add(new Setter(System.Windows.Automation.AutomationProperties.NameProperty, new Binding(nameof(LayerNode.Label))));
        LayerTree.ItemContainerStyle = layerItemStyle;
        LayersResetButton.Click += (_, _) => ResetLayers();
        LayersSaveButton.Click += (_, _) => _ = SaveLayersAsDefault();

        SigBarClose.Click += (_, _) =>
        {
            _sigBarDismissed = true;
            SigBar.Visibility = Visibility.Collapsed;
        };
        SigBarDetails.Click += (_, _) => ShowPane(NavPaneKind.Signatures);
        XfaBarClose.Click += (_, _) =>
        {
            _xfaBarDismissed = true;
            XfaBar.Visibility = Visibility.Collapsed;
        };

        RedactClear.Click += (_, _) => Viewer.ClearRedactions();
        RedactApply.Click += (_, _) => _ = ApplyRedactions();
        RedactDone.Click += (_, _) =>
        {
            if (Viewer.Tool == ViewerTool.Redact) Viewer.Tool = ViewerTool.Hand;
            UpdateRedactBar();
        };
        RedactHitsButton.Click += (_, _) => RedactSearchHits();
        Viewer.RedactionsChanged += (_, _) => UpdateRedactBar();
        Viewer.ToolChanged += (_, _) => UpdateRedactBar();
        Viewer.NoteRequested += (_, n) => _ = AddNoteAt(n.PageIndex, n.X, n.Y, null);
        Viewer.AnnotationActivated += (_, a) => _ = EditComment(a);

        CtxRedactText.Click += (_, _) => _ = RedactSelection();
        Viewer.ContextMenuOpening += (_, _) =>
        {
            var markup = Session.IsPdf && Viewer.HasSelection;
            foreach (var item in new FrameworkElement[] { CtxHighlight, CtxUnderline, CtxStrikeOut, CtxLinkText, CtxRedactText, CtxMarkupSeparator })
                item.Visibility = markup ? Visibility.Visible : Visibility.Collapsed;
        };
        InitSigning();
        InitDrawing();
        InitMeasure();
        InitInsert();
        InitStamps();
        _ = LoadReviewAsync();
    }

    private static T? ItemData<T>(object source) where T : class
    {
        for (var d = source as DependencyObject; d is not null; d = d is Visual ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
        {
            if (d is ListBoxItem { DataContext: T t }) return t;
            if (d is ListBox) return null;
        }
        return null;
    }

    // ───────────────────────────── Loading ─────────────────────────────

    private sealed record ReviewInfo(
        string[]? Labels,
        IReadOnlyList<AnnotationInfo> Annotations,
        IReadOnlyList<AttachmentInfo> Attachments,
        IReadOnlyList<LayerInfo> Layers,
        IReadOnlyList<LayerOrderNode> LayerOrder,
        IReadOnlyList<SignatureInfo>? Signatures,
        (bool HasXfa, bool XfaOnly)? Xfa,
        ViewerPrefs? Prefs,
        string? Title,
        IReadOnlyList<TextStamp> SignatureStamps,
        IReadOnlyList<LinkInfo> Links);

    /// <summary>Reads labels, comments, attachments, layers and signatures off the UI thread (the latest request wins).</summary>
    private async Task LoadReviewAsync()
    {
        if (!Session.IsPdf || _disposed) return;
        var ticket = ++_reviewLoad;
        var session = Session;
        var content = Session.ContentKey;
        var pw = Session.Password;
        var first = !_reviewLoadedOnce;
        var wantTitle = first || _displayDocTitle;
        ReviewInfo info;
        try
        {
            var online = _onlineRevocation;
            info = await Task.Run(() => ReadReview(session, pw, first, wantTitle, online));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reading document features failed: {ex.Message}");
            return;
        }
        if (ticket != _reviewLoad || _disposed) return;
        _reviewLoadedOnce = true;
        _reviewData = content;

        _labels = info.Labels is { } l && l.Length == Viewer.PageCount ? l : null;
        foreach (var t in _thumbs) t.SetLabel(PageLabel(t.Index), Viewer.PageCount);

        _annotations = info.Annotations;
        Viewer.SetSignatureStamps(info.SignatureStamps);
        Viewer.SetLinkAnnotations(info.Links);
        Viewer.SetAnnotations([.. _annotations.Where(a => !a.IsInkvoltPdfStamp)]);
        RefreshCommentList();

        _attachments = info.Attachments;
        RefreshAttachments();

        _layers = info.Layers;
        _layerOrder = info.LayerOrder;
        RefreshLayerTree();
        if (_layerChoice.Count > 0 && _viewEngine is null) _ = ApplyLayersAsync();

        if (info.Signatures is { } sigs)
        {
            ShowSignatures(sigs, first || _signatureBaselineStale);
            _signatureBaselineStale = false;
        }

        if (first)
        {
            if (info.Xfa is { XfaOnly: true } && !_xfaBarDismissed) XfaBar.Visibility = Visibility.Visible;
            if (info.Prefs is { } prefs)
            {
                _displayDocTitle = prefs.DisplayDocTitle;
                if (!_hadViewState) ApplyOpenPrefs(prefs);
            }
        }
        if (_displayDocTitle && wantTitle) _docTitle = string.IsNullOrWhiteSpace(info.Title) ? null : info.Title.Trim();
        RaiseState();
    }

    /// <summary>
    /// What the review panes show, read from the session's bytes. A huge file opened in place is read (and parsed) only
    /// for what its bytes mention: a reader none of whose names it mentions gets what it returns for a file without them.
    /// </summary>
    private static ReviewInfo ReadReview(DocumentSession session, string? pw, bool first, bool wantTitle, RevocationSnapshot? online)
    {
        T Try<T>(string what, string[] names, Func<byte[], T> read, T fallback, T absent)
        {
            if (!names.Any(session.MayContain)) return absent;
            try
            {
                return read(session.Data);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                Log.Write($"Reading {what} failed: {ex.Message}");
                return fallback;
            }
        }
        string[] annots = ["/Annots"];
        var labels = Try("page labels", ["/PageLabels"], d => DocumentFeatures.PageLabels(d, pw), null, null);
        var comments = Try<IReadOnlyList<AnnotationInfo>>("comments", annots, d => Annotations.Read(d, pw), [], []);
        var files = Try<IReadOnlyList<AttachmentInfo>>("attachments", ["/EmbeddedFiles", "/Annots"], d => Attachments.List(d, pw), [], []);
        var layers = Try<IReadOnlyList<LayerInfo>>("layers", ["/OCProperties"], d => Layers.List(d, pw), [], []);
        var order = layers.Count > 0 ? Try<IReadOnlyList<LayerOrderNode>>("layer order", ["/OCProperties"], d => Layers.ReadOrder(d, pw), [], []) : [];
        var sigs = Try<IReadOnlyList<SignatureInfo>?>("signatures", ["/ByteRange"], d => Signatures.Verify(d, pw, online), null, []);
        var xfa = first ? Try<(bool, bool)?>("XFA", ["/XFA"], d => FormEditor.HasXfa(d, pw), null, (false, false)) : null;
        var prefs = first
            ? Try<ViewerPrefs?>("opening settings", ["/PageMode", "/PageLayout", "/ViewerPreferences", "/OpenAction"], d => DocumentFeatures.ReadViewerPrefs(d, pw), null,
                new ViewerPrefs(null, null, null, false))
            : null;
        var title = wantTitle ? Try<string?>("title", ["/Title"], d => PageEditor.ReadMetadata(d, pw).Title, null, "") : null;
        var sigStamps = Try<IReadOnlyList<TextStamp>>("signature stamps", annots, d => SignatureStamps.Read(d, pw), [], []);
        var links = Try<IReadOnlyList<LinkInfo>>("links", annots, d => Links.Read(d, pw), [], []);
        return new ReviewInfo(labels, comments, files, layers, order, sigs, xfa, prefs, title, sigStamps, links);
    }

    /// <summary>Honors the document's opening settings (only for files without a remembered position).</summary>
    private void ApplyOpenPrefs(ViewerPrefs prefs)
    {
        var pane = prefs.PageMode switch
        {
            PageModeKind.Outlines => NavPaneKind.Bookmarks,
            PageModeKind.Thumbs => NavPaneKind.Pages,
            PageModeKind.Attachments => NavPaneKind.Attachments,
            PageModeKind.Layers when _layers.Count > 0 => NavPaneKind.Layers,
            _ => (NavPaneKind?)null,
        };
        if (pane is { } p && !IsOrganizing) ShowPane(p);

        if (prefs.PageLayout is { } layout)
            Viewer.SetLayout(layout switch
            {
                PageLayoutKind.SinglePage => ViewLayout.SinglePage,
                PageLayoutKind.TwoColumnLeft or PageLayoutKind.TwoPageLeft => ViewLayout.Facing,
                PageLayoutKind.TwoColumnRight or PageLayoutKind.TwoPageRight => ViewLayout.FacingCover,
                _ => ViewLayout.Continuous,
            });

        // Only if the reader hasn't moved yet (the settings arrive a moment after the first pages).
        if (prefs.OpenAction is { } dest && dest.PageIndex >= 0 && dest.PageIndex < Viewer.PageCount && Viewer.CurrentPage == 0)
        {
            switch (dest.Kind)
            {
                case ZoomKind.Fit or ZoomKind.FitB:
                    Viewer.SetZoomMode(ZoomMode.FitPage);
                    break;
                case ZoomKind.FitH or ZoomKind.FitBH:
                    Viewer.SetZoomMode(ZoomMode.FitWidth);
                    break;
                case ZoomKind.XYZ when dest.Zoom is > 0 and < 64:
                    Viewer.SetZoom(dest.Zoom.Value);
                    break;
            }
            Viewer.GoToPage(dest.PageIndex, dest.Kind is ZoomKind.Fit or ZoomKind.FitB ? null : dest.Y, record: false);
        }
    }

    // ───────────────────────────── Comments ─────────────────────────────

    private bool _syncingComments;

    private void RefreshCommentList()
    {
        var byId = _annotations.Where(a => !a.IsInkvoltPdfStamp).ToDictionary(a => a.Id);
        var replies = byId.Values.Where(a => a.ReplyTo is not null && byId.ContainsKey(a.ReplyTo)).ToLookup(a => a.ReplyTo!);
        var items = new List<CommentItem>();
        void Add(AnnotationInfo a, int depth, HashSet<string> seen)
        {
            if (!seen.Add(a.Id)) return;
            items.Add(new CommentItem(a, Loc.Format(Strings.Review_PageHeader, PageLabel(a.PageIndex)), Math.Min(depth, 4)));
            foreach (var r in replies[a.Id].OrderBy(r => r.Modified ?? DateTimeOffset.MinValue)) Add(r, depth + 1, seen);
        }
        var seen = new HashSet<string>();
        foreach (var a in byId.Values.Where(a => a.ReplyTo is null || !byId.ContainsKey(a.ReplyTo)).OrderBy(a => a.PageIndex).ThenBy(a => a.Rect.Y).ThenBy(a => a.Rect.X))
            Add(a, 0, seen);
        _commentItems = items;

        var q = CommentFilter.Text.Trim();
        var shown = q.Length == 0 ? items : items.Where(c => $"{c.Title} {c.Info.Author} {c.Contents}".Contains(q, StringComparison.CurrentCultureIgnoreCase)).ToList();
        var selectedId = (CommentList.SelectedItem as CommentItem)?.Info.Id;
        var view = new ListCollectionView(shown);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(CommentItem.PageHeader)));
        _syncingComments = true;
        CommentList.ItemsSource = view;
        if (selectedId is not null && shown.FirstOrDefault(c => c.Info.Id == selectedId) is { } again) CommentList.SelectedItem = again;
        _syncingComments = false;
        CommentsEmpty.Text = items.Count == 0
            ? Strings.Review_NoComments
            : shown.Count == 0 ? Strings.Review_NoCommentsMatch : "";
        CommentsEmpty.Visibility = CommentsEmpty.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdatePaneDetail();
    }

    private void FlashComment(AnnotationInfo a)
    {
        if (a.PageIndex < 0 || a.PageIndex >= Viewer.PageCount) return;
        var rect = a.QuadRects.Count > 0 ? a.QuadRects.Aggregate(default(RectD), (acc, r) => acc.Union(r)) : a.Rect;
        ActivatePane(second: false); // comments are selected and edited in the main pane
        Viewer.Flash(a.PageIndex, rect);
    }

    /// <summary>True when the comments shown were read from the current bytes (their ids are valid for edits).</summary>
    private bool ReviewIsCurrent()
    {
        if (ReferenceEquals(_reviewData, Session.ContentKey)) return true;
        Notify(Strings.Review_StillRefreshing);
        return false;
    }

    public bool CanMarkup => Session.IsPdf && !IsOrganizing && Viewer.HasSelection;

    /// <summary>Highlights, underlines or strikes out the selected text (one undo step, even across pages).</summary>
    public async Task<bool> MarkupSelection(TextMarkupKind kind)
    {
        if (!CanMarkup) return false;
        if (Viewer.SelectedPageCount > 50)
        {
            Notify(Strings.Review_MarkupTooMany, error: true);
            return false;
        }
        if (await SelectionLineRects(Strings.Review_MarkingUp) is not { } parts) return false;
        if (parts.Count == 0)
        {
            Notify(Strings.Review_NoTextToMark);
            return false;
        }
        var color = kind switch
        {
            TextMarkupKind.Underline => new AnnotColor(0.1, 0.55, 0.2),
            TextMarkupKind.StrikeOut => AnnotColor.Red,
            TextMarkupKind.Squiggly => new AnnotColor(0.1, 0.45, 0.85),
            _ => AnnotColor.Yellow,
        };
        var author = Author;
        var label = kind switch
        {
            TextMarkupKind.Underline => Strings.Review_UndoUnderline, TextMarkupKind.StrikeOut => Strings.Review_UndoStrikeOut,
            TextMarkupKind.Squiggly => Strings.Review_UndoSquiggly, _ => Strings.Review_UndoHighlight,
        };
        var ok = await RunEdit(label, (d, pw) =>
        {
            foreach (var (page, rects) in parts) d = Annotations.AddTextMarkup(d, pw, page, kind, rects, color, null, author);
            return d;
        }, contentOnly: true);
        if (ok) Viewer.ClearSelection();
        return ok;
    }

    /// <summary>Asks for a note's text (unless given) and puts a sticky note with its top-left at (x, y).</summary>
    public async Task<bool> AddNoteAt(int page, double x, double y, string? text)
    {
        if (!Session.IsPdf || page < 0 || page >= Viewer.PageCount) return false;
        if (text is null)
        {
            if (Window.GetWindow(this) is not { } owner) return false;
            var dlg = new FormDialog(owner, Strings.Review_AddNoteTitle, Strings.Common_Add);
            var box = NoteBox(dlg, "");
            dlg.AddNote(Loc.Format(Strings.Review_AddNoteNote, PageLabel(page), Author));
            dlg.Validate(() => box.Text.Trim().Length == 0 ? Strings.Review_AddNoteEmpty : null);
            if (!dlg.ShowModal()) return false;
            text = box.Text.Trim();
        }
        var g = Viewer.Engine!.GetPage(page);
        x = Math.Clamp(x, 0, Math.Max(0, g.Width - 20));
        y = Math.Clamp(y, 0, Math.Max(0, g.Height - 20));
        var author = Author;
        var note = text;
        var ok = await RunEdit(Strings.Review_AddNoteTitle, (d, pw) => Annotations.AddNote(d, pw, page, x, y, note, author), contentOnly: true);
        if (ok && Viewer.Tool == ViewerTool.AddNote) Viewer.Tool = ViewerTool.Hand; // one note per click, like other editors
        return ok;
    }

    private static TextBox NoteBox(FormDialog dlg, string text)
    {
        var box = dlg.AddText(Strings.Review_NoteText, text);
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.MinHeight = 110;
        box.MaxHeight = 320;
        box.VerticalContentAlignment = VerticalAlignment.Top;
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        return box;
    }

    public async Task<bool> EditComment(AnnotationInfo a, string? newText = null)
    {
        if (a.IsInkvoltPdfStamp || !ReviewIsCurrent()) return false;
        if (newText is null)
        {
            if (Window.GetWindow(this) is not { } owner) return false;
            var dlg = new FormDialog(owner, a.Kind == AnnotationKind.Text ? Strings.Review_EditNote : Strings.Review_EditComment, Strings.Common_Save);
            var box = NoteBox(dlg, a.Contents);
            var who = string.Join(" · ", new[] { a.Author, a.Modified?.LocalDateTime.ToString("g") }.Where(s => !string.IsNullOrWhiteSpace(s)));
            dlg.AddNote(who.Length > 0 ? Loc.Format(Strings.Review_EditNoteWho, PageLabel(a.PageIndex), who) : Loc.Format(Strings.Review_PageHeader, PageLabel(a.PageIndex)));
            if (!dlg.ShowModal()) return false;
            newText = box.Text.TrimEnd();
        }
        if (newText == a.Contents) return false;
        var text = newText;
        return await RunEdit(Strings.Review_EditComment, (d, pw) => Annotations.SetContents(d, pw, a.Id, text), contentOnly: true);
    }

    public async Task<bool> DeleteComment(AnnotationInfo a)
    {
        if (!ReviewIsCurrent()) return false;
        var replies = _annotations.Count(x => x.ReplyTo == a.Id);
        return await RunEdit(replies > 0 ? Loc.Plural(replies, Strings.Review_UndoDeleteReplies_One, Strings.Review_UndoDeleteReplies_Many) : Strings.Review_UndoDeleteComment,
            (d, pw) => Annotations.Delete(d, pw, a.Id), contentOnly: true);
    }

    // ───────────────────────────── Attachments ─────────────────────────────

    private void RefreshAttachments()
    {
        var selected = (AttachmentList.SelectedItem as AttachmentItem)?.Info.Key;
        var items = _attachments.Select(a => new AttachmentItem(a, a.PageIndex >= 0 ? PageLabel(a.PageIndex) : null)).ToList();
        AttachmentList.ItemsSource = items;
        if (items.FirstOrDefault(i => i.Info.Key == selected) is { } again) AttachmentList.SelectedItem = again;
        AttachmentsEmpty.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        AttachmentsBadge.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AttachmentsBadgeText.Text = items.Count > 99 ? "99+" : items.Count.ToString();
        AttachmentsRail.ToolTip = items.Count == 0 ? Strings.Review_Attachments : Loc.Plural(items.Count, Strings.Review_AttachmentsCount_One, Strings.Review_AttachmentsCount_Many);
        System.Windows.Automation.AutomationProperties.SetName(AttachmentsRail, (string)AttachmentsRail.ToolTip);
        UpdateAttachmentButtons();
        UpdatePaneDetail();
    }

    private void UpdateAttachmentButtons()
    {
        var sel = AttachmentList.SelectedItem as AttachmentItem;
        AttachSaveButton.IsEnabled = AttachRemoveButton.IsEnabled = sel is not null;
        AttachOpenButton.IsEnabled = sel is { IsPdf: true };
    }

    /// <summary>Writes an attachment to a file the user picks. Attachments are never opened or run by Inkvolt PDF itself.</summary>
    public async Task SaveAttachment(AttachmentInfo a, string? path = null)
    {
        if (!ReviewIsCurrent()) return;
        if (path is null && DevScript.TakeSavePath(out var scripted))
        {
            if (scripted is null) return;
            path = scripted;
        }
        while (path is null)
        {
            var dlg = new SaveFileDialog
            {
                Title = Strings.Review_SaveAttachmentTitle,
                FileName = SafeFileName(a.FileName),
                Filter = Strings.Review_AllFilesFilter,
                InitialDirectory = AppSettings.Current.LastFolder is { Length: > 0 } dir && Directory.Exists(dir) ? dir : null,
            };
            if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
            if (!PdfFiles.IsOpenInTab(dlg.FileName))
            {
                path = dlg.FileName;
                break;
            }
            OpenInTabRefused(dlg.FileName);
        }
        // Writing over a document open in a tab would swap the file under it (and the tab wouldn't know).
        if (PdfFiles.IsOpenInTab(path))
        {
            OpenInTabRefused(path);
            return;
        }
        if (_disposed) return;
        try
        {
            var data = Session.Data;
            var pw = Session.Password;
            var target = Path.GetFullPath(path);
            var zone = ZoneIdentifierFor(Session.FilePath);
            // Atomic (no half-written file), and marked as coming from the internet, like a download: Windows and other
            // apps then treat it with the same care (SmartScreen, Office Protected View) as the PDF it came from.
            await Task.Run(() => AtomicFile.WriteAllBytes(target, Attachments.Extract(data, pw, a.Key), tmp => WriteZoneIdentifier(tmp, zone)));
            await Task.Run(() => WriteZoneIdentifier(target, zone));
            Notify(Loc.Format(Strings.Review_SavedFile, Path.GetFileName(path)));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Prompt.Error(Window.GetWindow(this), Strings.Review_SaveAttachmentFailed, ex.Message);
        }
    }

    private void OpenInTabRefused(string path) =>
        Prompt.Info(Window.GetWindow(this), Loc.Format(Strings.Review_OpenInTabTitle, Path.GetFileName(path)), Strings.Review_OpenInTabBody);

    /// <summary>
    /// The Mark of the Web for a file taken out of the document at <paramref name="source"/>: Internet zone (3) or the
    /// source's own zone if stricter, the source as ReferrerUrl, and its HostUrl when it has one (as Windows does when
    /// extracting from a downloaded zip).
    /// </summary>
    private static string ZoneIdentifierFor(string? source)
    {
        var zone = 3;
        string? host = null;
        if (source is not null)
        {
            try
            {
                foreach (var line in File.ReadAllLines(source + ":Zone.Identifier"))
                {
                    if (line.StartsWith("ZoneId=", StringComparison.OrdinalIgnoreCase) && int.TryParse(line[7..], out var z)) zone = Math.Max(zone, z);
                    else if (line.StartsWith("HostUrl=", StringComparison.OrdinalIgnoreCase)) host = line[8..];
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
            {
                // No mark on the source (or a file system without streams): Internet zone is the safe default.
            }
        }
        var text = new System.Text.StringBuilder($"[ZoneTransfer]\r\nZoneId={zone}\r\n");
        if (source is not null) text.Append($"ReferrerUrl={source}\r\n");
        if (host is not null) text.Append($"HostUrl={host}\r\n");
        return text.ToString();
    }

    private static void WriteZoneIdentifier(string path, string zone)
    {
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", zone);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            Log.Write($"Couldn't mark {Log.Name(path)} as downloaded (Zone.Identifier): {ex.Message}"); // e.g. FAT or a network share
        }
    }

    /// <summary>Opens an attached PDF in a new tab (an unsaved copy: nothing is written but its recovery copy, see Autosave).</summary>
    public async Task OpenAttachment(AttachmentInfo a)
    {
        if (!ReviewIsCurrent() || Window.GetWindow(this) is not MainWindow main) return;
        try
        {
            var data = Session.Data;
            var pw = Session.Password;
            var bytes = await Task.Run(() => Attachments.Extract(data, pw, a.Key));
            DocumentSession session;
            string? password = null;
            while (true)
            {
                try
                {
                    var p = password;
                    session = await Task.Run(() => DocumentSession.FromBytes(bytes, SafeFileName(a.FileName), p));
                    break;
                }
                catch (PasswordRequiredException ex)
                {
                    password = PdfFiles.PromptPassword(main, a.FileName, password is not null || ex.WrongPassword);
                    if (password is null) return;
                }
            }
            main.OpenSession(session);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Prompt.Error(Window.GetWindow(this), Loc.Format(Strings.Review_OpenAttachmentFailed, a.FileName), ex.Message);
        }
    }

    public async Task<bool> AddAttachment(string? path = null, string? description = null)
    {
        if (!Session.IsPdf) return false;
        if (path is null)
        {
            var dlg = new OpenFileDialog { Title = Strings.Review_AttachTitle, Filter = Strings.Review_AllFilesFilter };
            if (dlg.ShowDialog(Window.GetWindow(this)) != true) return false;
            path = dlg.FileName;
        }
        byte[] bytes;
        try
        {
            var info = new FileInfo(path);
            if (info.Length > 512L * 1024 * 1024) throw new IOException(Strings.Review_AttachTooBig);
            var source = path;
            bytes = await Task.Run(() => File.ReadAllBytes(source));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(Window.GetWindow(this), Strings.Review_ReadFileFailed, ex.Message);
            return false;
        }
        var name = Path.GetFileName(path);
        var modified = File.GetLastWriteTime(path);
        var ok = await RunEdit(Loc.Format(Strings.Review_UndoAttach, name), (d, pw) => Attachments.Add(d, pw, name, bytes, description, modified), contentOnly: true);
        if (ok) ShowPane(NavPaneKind.Attachments);
        return ok;
    }

    public async Task<bool> RemoveAttachment(AttachmentInfo a)
    {
        if (!ReviewIsCurrent()) return false;
        return await RunEdit(Loc.Format(Strings.Review_UndoRemoveAttachment, a.FileName), (d, pw) => Attachments.Remove(d, pw, a.Key), contentOnly: true);
    }

    private static string SafeFileName(string name)
    {
        // Embedded names come from the file: no folders, no invalid or control characters, no "." / ".." or trailing dots.
        var clean = string.Concat(Path.GetFileName(name.Replace('/', '\\')).Select(c => Path.GetInvalidFileNameChars().Contains(c) || char.IsControl(c) ? '_' : c))
            .Trim().TrimEnd('.', ' ');
        return clean.Length == 0 ? "attachment" : clean;
    }

    // ───────────────────────────── Layers ─────────────────────────────

    private void RefreshLayerTree()
    {
        LayersRail.Visibility = _layers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_layers.Count == 0 && _pane == NavPaneKind.Layers) ShowPane(NavPaneKind.Pages);
        var byId = _layers.ToDictionary(l => l.Id);
        var used = new HashSet<int>();
        List<LayerNode> Build(IEnumerable<LayerOrderNode> nodes) =>
        [
            .. nodes.Select(n =>
            {
                var layer = n.LayerId is { } id && byId.TryGetValue(id, out var l) ? l : null;
                if (layer is not null) used.Add(layer.Id);
                return new LayerNode(layer?.Name ?? n.Label ?? "", layer, Build(n.Children), layer is not null && IsLayerVisible(layer), OnLayerToggled);
            }).Where(n => n.Layer is not null || n.Children.Count > 0),
        ];
        var roots = Build(_layerOrder);
        // Layers the order tree leaves out still get a row.
        roots.AddRange(_layers.Where(l => !used.Contains(l.Id)).Select(l => new LayerNode(l.Name, l, [], IsLayerVisible(l), OnLayerToggled)));
        LayerTree.ItemsSource = roots;
        LayersResetButton.IsEnabled = LayersSaveButton.IsEnabled = _layerChoice.Count > 0;
        UpdatePaneDetail();
    }

    private bool IsLayerVisible(LayerInfo l) => _layerChoice.TryGetValue(l.Name, out var on) ? on : l.DefaultVisible;

    private void OnLayerToggled(LayerNode node)
    {
        if (node.Layer is not { } layer) return;
        // Remembered by name: layer ids are object numbers, which change when the file is rewritten by an edit.
        if (node.IsChecked == layer.DefaultVisible) _layerChoice.Remove(layer.Name);
        else _layerChoice[layer.Name] = node.IsChecked;
        LayersResetButton.IsEnabled = LayersSaveButton.IsEnabled = _layerChoice.Count > 0;
        _ = ApplyLayersAsync();
    }

    /// <summary>Sets a layer's visibility for viewing (by name); used by the pane and the dev script.</summary>
    public void SetLayerVisible(string name, bool visible)
    {
        if (_layers.FirstOrDefault(l => l.Name == name) is not { Locked: false } layer) return;
        if (visible == layer.DefaultVisible) _layerChoice.Remove(name);
        else _layerChoice[name] = visible;
        RefreshLayerTree();
        _ = ApplyLayersAsync();
    }

    private void ResetLayers()
    {
        _layerChoice.Clear();
        RefreshLayerTree();
        _ = ApplyLayersAsync();
    }

    /// <summary>
    /// Shows the document with the chosen layers through a separate view engine (a copy with that default layer
    /// configuration); the document's own bytes and undo history are untouched. Printing and exporting use the same engine.
    /// </summary>
    private async Task ApplyLayersAsync()
    {
        var ticket = ++_layerTicket;
        var visibility = _layers.Where(l => _layerChoice.TryGetValue(l.Name, out var on) && on != l.DefaultVisible)
            .ToDictionary(l => l.Id, l => _layerChoice[l.Name]);
        PdfEngine? engine = null;
        var data = Session.Data;
        if (visibility.Count > 0)
        {
            var pw = Session.Password;
            try
            {
                engine = await Task.Run(() =>
                {
                    var bytes = Layers.WithVisibility(data, pw, visibility);
                    try
                    {
                        return PdfEngine.Open(bytes, MuPDFCore.InputFileTypes.PDF, pw);
                    }
                    catch (PasswordRequiredException)
                    {
                        return PdfEngine.Open(bytes, MuPDFCore.InputFileTypes.PDF, null);
                    }
                });
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                Log.Write($"Showing layers failed: {ex}");
                if (ticket == _layerTicket) Notify(Loc.Format(Strings.Review_LayersFailed, ex.Message), error: true);
                return;
            }
        }
        if (ticket != _layerTicket || _disposed || !ReferenceEquals(data, Session.Data) || engine is not null && engine.PageCount != Session.Engine.PageCount)
        {
            engine?.Dispose();
            return;
        }
        SetViewEngine(engine);
    }

    private void SetViewEngine(PdfEngine? engine)
    {
        var old = _viewEngine;
        if (old is null && engine is null) return;
        _viewEngine = engine;
        Viewer.SetEngine(ViewEngine, _scheduler, keepPosition: true, contentOnly: true);
        RebuildThumbs();
        if (IsOrganizing) Organizer.Load(Session.Engine, Organizer.SelectedPages, Viewer.CurrentPage);
        if (old is not null) RetireEngine(old);
        RaiseState();
    }

    /// <summary>The document changed: the layer view (made from the old bytes) is stale; it is rebuilt once the layers are re-read.</summary>
    private void DropViewEngine()
    {
        _layerTicket++;
        if (_viewEngine is null) return;
        var old = _viewEngine;
        _viewEngine = null;
        RetireEngine(old);
    }

    /// <summary>
    /// Lets a layer view go. Printing and exporting read <see cref="ViewEngine"/> while the tab is busy, so one replaced
    /// meanwhile is disposed once the tab is idle (see <see cref="UpdateBusy"/>).
    /// </summary>
    private void RetireEngine(PdfEngine engine)
    {
        if (IsBusy && !_disposed) _retiredEngines.Add(engine);
        else engine.Dispose();
    }

    private void DisposeRetiredEngines()
    {
        foreach (var engine in _retiredEngines) engine.Dispose();
        _retiredEngines.Clear();
    }

    private async Task SaveLayersAsDefault()
    {
        if (!ReviewIsCurrent() || _layerChoice.Count == 0) return;
        var visibility = _layers.Where(l => _layerChoice.ContainsKey(l.Name)).ToDictionary(l => l.Id, l => _layerChoice[l.Name]);
        var choice = new Dictionary<string, bool>(_layerChoice);
        _layerChoice.Clear(); // the saved defaults are what shows now
        if (!await RunEdit(Strings.Review_UndoLayerVisibility, (d, pw) => Layers.SetDefaultVisibility(d, pw, visibility)))
        {
            foreach (var (k, v) in choice) _layerChoice[k] = v;
            return;
        }
        RefreshLayerTree();
    }

    // ───────────────────────────── Signatures and XFA ─────────────────────────────

    public bool IsSigned => _signatures.Any(s => s.Status != SignatureStatus.Unsigned);

    /// <summary>
    /// The signature verified when the document was opened (or reloaded) but no longer does after this tab's edits.
    /// That's the expected effect of editing a signed file, not tampering, so it is reported as such.
    /// </summary>
    internal bool BrokenByEdits(SignatureInfo s) =>
        s.Status is SignatureStatus.Invalid or SignatureStatus.DisallowedChanges
        && _signaturesOnOpen.TryGetValue(s.FieldName, out var before)
        && before.Status is SignatureStatus.Valid or SignatureStatus.ModifiedAfterSigning;

    /// <summary>Valid when opened and still intact: this tab's edits were appended after the signed bytes.</summary>
    private bool AppendedByEdits(SignatureInfo s) =>
        s.Status == SignatureStatus.ModifiedAfterSigning
        && _signaturesOnOpen.TryGetValue(s.FieldName, out var before) && before.Status == SignatureStatus.Valid;

    internal static string SignatureSeverity(SignatureInfo s, bool brokenByEdits = false) => brokenByEdits ? "warn" : s.Status switch
    {
        SignatureStatus.Unsigned => "none",
        SignatureStatus.Invalid or SignatureStatus.DisallowedChanges => "bad",
        SignatureStatus.Valid when s.CertificateTrusted => "ok",
        _ => "warn",
    };

    internal static string SignatureSummary(SignatureInfo s, bool brokenByEdits = false) => brokenByEdits
        ? Strings.Review_SigBrokenByEdits
        : s.Status switch
    {
        SignatureStatus.Unsigned => Strings.Review_SigEmpty,
        SignatureStatus.Invalid => Strings.Review_SigInvalid,
        SignatureStatus.DisallowedChanges => Strings.Review_SigDisallowed,
        SignatureStatus.Unsupported => Strings.Review_SigUnsupported,
        SignatureStatus.ModifiedAfterSigning => s.CertificateTrusted
            ? Strings.Review_SigModified
            : Strings.Review_SigModifiedUntrusted,
        _ when !s.CertificateTrusted => Loc.Format(Strings.Review_SigUntrusted, s.CertificateStatus),
        _ when s.SubFilter == "ETSI.RFC3161" => Strings.Review_SigValidTimestamp,
        _ => Strings.Review_SigValid,
    };

    private string ShortStatus(SignatureInfo s) => BrokenByEdits(s) ? Strings.Review_SigShortBroken : s.Status switch
    {
        SignatureStatus.ModifiedAfterSigning when AppendedByEdits(s) => Strings.Review_SigShortAppended,
        SignatureStatus.Invalid => Strings.Review_SigShortInvalid,
        SignatureStatus.DisallowedChanges => Strings.Review_SigShortDisallowed,
        SignatureStatus.Unsupported => Strings.Review_SigShortUnsupported,
        SignatureStatus.ModifiedAfterSigning => Strings.Review_SigShortModified,
        _ when !s.CertificateTrusted => Strings.Review_SigShortUntrusted,
        _ => Strings.Review_SigShortValid,
    };

    private void ShowSignatures(IReadOnlyList<SignatureInfo> sigs, bool onOpen)
    {
        // A signature our edits broke may no longer parse: keep naming its signer and certificate as they were.
        sigs = [.. sigs.Select(s => !onOpen && BrokenByEdits(s) && _signaturesOnOpen[s.FieldName] is var o
            ? s.Certificate is null
                ? s with { SignerName = s.SignerName ?? o.SignerName, SigningTime = s.SigningTime ?? o.SigningTime, Certificate = o.Certificate, CertificateTrusted = o.CertificateTrusted, CertificateStatus = o.CertificateStatus }
                : s with { SignerName = s.SignerName ?? o.SignerName, SigningTime = s.SigningTime ?? o.SigningTime }
            : s)];
        _signatures = sigs;
        if (onOpen)
        {
            Session.SignedOnOpen = IsSigned;
            _signaturesOnOpen.Clear();
            foreach (var s in sigs) _signaturesOnOpen[s.FieldName] = s;
        }
        SignaturesRail.Visibility = sigs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SignatureList.ItemsSource = sigs.Select(s => new SignatureItem(s, s.PageIndex >= 0 ? PageLabel(s.PageIndex) : null, BrokenByEdits(s))).ToList();
        if (sigs.Count == 0 && _pane == NavPaneKind.Signatures) ShowPane(NavPaneKind.Pages);

        var signed = sigs.Where(s => s.Status != SignatureStatus.Unsigned).ToList();
        if (signed.Count == 0)
        {
            SigBar.Visibility = Visibility.Collapsed;
            UpdatePaneDetail();
            return;
        }
        // The bar speaks of the signatures: document timestamps are in the pane, and in the bar only when one is broken.
        var people = signed.Where(s => s.SubFilter != "ETSI.RFC3161" || SignatureSeverity(s, BrokenByEdits(s)) == "bad").ToList();
        if (people.Count > 0) signed = people;
        string text;
        if (signed.Count == 1)
        {
            var s = signed[0];
            text = Loc.Format(Strings.Review_SigBarOne, s.SignerName ?? s.FieldName, ShortStatus(s));
        }
        else if (signed.All(BrokenByEdits))
        {
            text = Loc.Format(Strings.Review_SigBarAllBroken, signed.Count);
        }
        else
        {
            var problems = signed.Count(s => SignatureSeverity(s, BrokenByEdits(s)) != "ok");
            text = problems == 0
                ? Loc.Format(Strings.Review_SigBarAllValid, signed.Count)
                : Loc.Plural(problems, Strings.Review_SigBarProblems_One, Strings.Review_SigBarProblems_Many, signed.Count,
                    string.Join("; ", signed.Where(s => SignatureSeverity(s, BrokenByEdits(s)) != "ok").Take(3)
                        .Select(s => Loc.Format(Strings.Review_SigBarProblem, s.SignerName ?? s.FieldName, ShortStatus(s)))));
        }
        var severities = signed.Select(s => SignatureSeverity(s, BrokenByEdits(s))).ToList();
        var worst = severities.Contains("bad") ? "bad" : severities.Contains("warn") ? "warn" : "ok";
        SigBarText.Text = text;
        SigBarIcon.SetResourceReference(TextBlock.ForegroundProperty,
            worst switch { "ok" => "SystemFillColorSuccessBrush", "bad" => "SystemFillColorCriticalBrush", _ => "SystemFillColorCautionBrush" });
        System.Windows.Automation.AutomationProperties.SetName(SigBar, text);
        SigBar.Visibility = _sigBarDismissed ? Visibility.Collapsed : Visibility.Visible;
        UpdatePaneDetail();
    }

    private void OnGoToSignature(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SignatureItem s } && s.Info.PageIndex >= 0) Viewer.Flash(s.Info.PageIndex, s.Info.Rect);
    }

    /// <summary>
    /// A removal (pages, a comment, an attachment) appended to a signed document leaves the item in the file's earlier,
    /// signed revision: say so, and offer the rewrite that removes it for good.
    /// </summary>
    private void NotifyRemovedItemKept() =>
        Notify(Strings.Review_RemovedItemKept, Strings.Review_FlattenAction, () => _ = FlattenRevisionsAsync());

    private async Task FlattenRevisionsAsync()
    {
        if (_disposed || IsBusy) return;
        if (!Prompt.Confirm(Window.GetWindow(this), Strings.Review_FlattenTitle, Strings.Review_FlattenBody, Strings.Review_FlattenButton, warning: true)) return;
        await RunEdit(Strings.Review_UndoFlatten, SignedEdits.Flatten);
    }

    // ───────────────────────────── Redaction ─────────────────────────────

    private void UpdateRedactBar()
    {
        var marks = Viewer.Redactions;
        var tool = Viewer.Tool == ViewerTool.Redact;
        RedactBar.Visibility = tool || marks.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var pages = marks.Select(m => m.PageIndex).Distinct().Count();
        RedactBarText.Text = marks.Count == 0
            ? Strings.Review_RedactBarEmpty
            : marks.Count == 1 ? Strings.Review_RedactBarOne
            : Loc.Format(pages == 1 ? Strings.Review_RedactBarOnePage : Strings.Review_RedactBarManyPages, marks.Count, pages);
        RedactApply.IsEnabled = RedactClear.IsEnabled = marks.Count > 0;
        RedactHitsButton.Visibility = _results.Count > 0 && Session.IsPdf ? Visibility.Visible : Visibility.Collapsed;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// The selection's line boxes, read in the background; a progress window with Cancel shows if that takes a while.
    /// Null when cancelled or the document changed meanwhile.
    /// </summary>
    private async Task<List<(int Page, List<RectD> Rects)>?> SelectionLineRects(string title)
    {
        var engine = Viewer.Engine;
        using var prompt = new ProgressPrompt(Window.GetWindow(this), title, Strings.Review_ReadingSelection);
        try
        {
            var parts = await Viewer.GetSelectionLineRectsAsync(
                new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.Review_ReadingPage, p.Done, p.Total), (double)p.Done / p.Total)), prompt.Token);
            return ReferenceEquals(engine, Viewer.Engine) ? parts : null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (ObjectDisposedException)
        {
            Notify(Strings.Review_ChangedSelectAgain);
            return null;
        }
    }

    /// <summary>Marks the selected text's lines for redaction. Returns the number of marks, -1 when cancelled.</summary>
    public async Task<int> RedactSelection()
    {
        if (!Session.IsPdf || !Viewer.HasSelection) return 0;
        if (await SelectionLineRects(Strings.Review_MarkingForRedaction) is not { } parts) return -1;
        var marks = parts.SelectMany(p => p.Rects.Select(r => new RedactMark(p.Page, r.Inflate(0.5)))).ToList();
        Viewer.AddRedactions(marks);
        Viewer.ClearSelection();
        return marks.Count;
    }

    /// <summary>Search &amp; redact: marks every hit of the current search.</summary>
    public int RedactSearchHits()
    {
        if (!Session.IsPdf) return 0;
        var marks = _results.SelectMany(h => h.Rects.Select(r => new RedactMark(h.Page, r.Inflate(0.5)))).ToList();
        Viewer.AddRedactions(marks);
        if (marks.Count > 0) Notify(Loc.Plural(_results.Count, Strings.Review_MarkedMatches_One, Strings.Review_MarkedMatches_Many));
        return marks.Count;
    }

    /// <summary>
    /// Searches by pattern in the background (a progress window with Cancel shows if that takes a while), scans through
    /// text recognition. Null when cancelled or stopped: a search that stopped must never read as one that found nothing.
    /// </summary>
    internal async Task<RedactionSearchResult?> SearchPatterns(RedactionPatternOptions options)
    {
        if (!Session.IsPdf || Viewer.Engine is not { } engine) return null;
        var ocr = PageOcr.For(AppSettings.Current.OcrLanguage);
        RedactionSearchResult found;
        using (var prompt = new ProgressPrompt(Window.GetWindow(this), Strings.Review_RedactPatternTitle, Strings.Review_SearchingPages))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.Review_SearchingPage, p.Done, p.Total), (double)p.Done / p.Total));
                found = await Task.Run(() => RedactionSearch.Find(engine, options, ocr, progress, prompt.Token), prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (ObjectDisposedException)
            {
                Notify(Strings.Review_ChangedTryAgain);
                return null;
            }
            catch (Exception ex) when (ex is TimeoutException or TooManyHitsException or ArgumentException or InvalidOperationException or MuPDFCore.MuPDFException)
            {
                Log.Write($"Redact by pattern stopped: {ex.GetType().Name}");
                Prompt.Error(Window.GetWindow(this), Strings.Review_SearchStopped, ex is MuPDFCore.MuPDFException ? Strings.Review_SearchDamaged : ex.Message);
                return null;
            }
        }
        return ReferenceEquals(engine, Viewer.Engine) ? found : null;
    }

    /// <summary>
    /// Redact by pattern, start to end: search; every hit listed to accept or skip, with the pages to look at by hand;
    /// apply; read the result back and search it again; the report. Returns whether anything was applied.
    /// </summary>
    public async Task<bool> RedactByPattern(RedactionPatternOptions options)
    {
        if (await SearchPatterns(options) is not { } found || Window.GetWindow(this) is not { } owner) return false;
        if (found.Hits.Count == 0 && found.Looks.Count == 0)
        {
            Notify(Strings.Review_NothingMatching);
            return false;
        }
        var earlier = Viewer.Redactions.ToList();
        if (RedactReviewDialog.Show(owner, this, found, earlier) is not { } review) return false;
        var name = Session.DisplayName;
        if (review.Accepted.Count == 0 && review.LookAreas.Count == 0 && review.EarlierApplied.Count == 0)
        {
            var nothing = new RedactionFileReport(name, [.. review.Skipped.Select(h => RedactionReport.Row(h, RedactionOutcome.Kept))], found.Looks, null);
            RedactionReportDialog.Show(owner, new RedactionReport([nothing]), Path.GetFileNameWithoutExtension(name));
            return false;
        }

        var marks = review.Accepted.SelectMany(m => RedactionSearch.Areas([m]).SelectMany(kv => kv.Value.Select(r => new RedactMark(kv.Key, r)))).Concat(review.LookAreas).ToList();
        var before = Session.Data;
        Viewer.ClearRedactions();
        Viewer.AddRedactions(marks.Concat(review.EarlierApplied));
        if (!await ApplyRedactions(confirm: false, check: false))
        {
            Viewer.ClearRedactions();
            Viewer.AddRedactions(earlier);
            return false;
        }

        // What the person unticked stays a mark, not applied.
        if (review.EarlierKept.Count > 0) Viewer.AddRedactions(review.EarlierKept);
        var areas = marks.Concat(review.EarlierApplied).GroupBy(m => m.PageIndex).ToDictionary(g => g.Key, g => (IReadOnlyList<RectD>)[.. g.Select(m => m.Rect)]);
        var (read, check, checkOptions) = await ReadBackPatterns(options, review, found, areas, before);
        var report = read with { MarkedAreas = review.EarlierApplied.Count };
        LastRedactionReport = report;
        RedactionReportDialog.Show(owner, new RedactionReport([report]), Path.GetFileNameWithoutExtension(name));
        // What is left outside the pages has a fix of its own, the check's.
        if (check is { IsClean: false } && !IsDisposed) await RedactionCheckActions.Show(this, check, checkOptions);
        return true;
    }

    /// <summary>The last report of Redact by Pattern (masked values only), for the developer script.</summary>
    internal RedactionFileReport? LastRedactionReport { get; private set; }

    /// <summary>
    /// Reads the redacted document back, searches it again, then looks for what was removed everywhere else in the file. A
    /// remaining hit, or a read-back that didn't finish, is the report's failure. Skipped hits don't count: the person kept them.
    /// </summary>
    private async Task<(RedactionFileReport Report, RedactionCheckReport? Check, RedactionCheckOptions Options)> ReadBackPatterns(
        RedactionPatternOptions options, RedactReview review, RedactionSearchResult found, Dictionary<int, IReadOnlyList<RectD>> areas, byte[] before)
    {
        var data = Session.Data;
        var password = Session.Password;
        var ocr = PageOcr.For(AppSettings.Current.OcrLanguage);
        var kept = RedactionSearch.Values(review.Skipped);
        var skippedKeys = new HashSet<string>(kept, StringComparer.OrdinalIgnoreCase);
        var checkOptions = new RedactionCheckOptions
        {
            Values = [.. RedactionSearch.SoughtValues(review.Accepted).Where(v => !skippedKeys.Contains(v))],
            Kept = kept,
            Areas = areas,
            Original = before,
            Patterns = options,
        };
        var rows = review.Accepted.Select(h => RedactionReport.Row(h, RedactionOutcome.Removed)).Concat(review.Skipped.Select(h => RedactionReport.Row(h, RedactionOutcome.Kept))).ToList();
        var name = Session.DisplayName;
        string? failure = null;
        RedactionCheckReport? check = null;
        using var prompt = new ProgressPrompt(Window.GetWindow(this), Strings.Review_RedactPatternTitle, Strings.Review_ReadingBack);
        try
        {
            var progress = new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.Review_ReadingBackPage, p.Done, p.Total), (double)p.Done / Math.Max(1, p.Total)));
            var remaining = await Task.Run(() =>
            {
                // A page the app has just recognized has its words again in the text; one without (no OCR, or OCR cancelled) is read now.
                using var engine = PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, password);
                var unread = areas.Keys.Where(p => p < engine.PageCount && !TextLayer.HasText(engine, p)).ToHashSet();
                return RedactionSearch.ReadBack(data, password, options, ocr, unread, review.Skipped, progress, prompt.Token);
            }, prompt.Token);
            if (remaining.Count > 0)
            {
                rows.AddRange(remaining.Select(h => RedactionReport.Row(h, RedactionOutcome.StillThere)));
                failure = Loc.Plural(remaining.Count, Strings.Review_StillThere_One, Strings.Review_StillThere_Many, RedactionReport.Pages(remaining.Select(h => h.Page)));
            }
            prompt.Report(Strings.Review_LookingThroughRest, 1);
            check = await Task.Run(() => RedactionCheck.Run(data, password, checkOptions, null, prompt.Token), prompt.Token);
            // Only what was removed being left fails it; what else the check finds in the file opens its own report next.
            if (check.Findings.Any(f => RedactionCheck.IsLeftover(f.Kind))) failure ??= Loc.Format(Strings.Review_ElsewhereInFile, check.Summary);
            else if (check.Incomplete) failure ??= string.Join(" ", check.Notes);
        }
        catch (OperationCanceledException)
        {
            failure = Strings.Review_ReadBackCancelled;
        }
        catch (Exception ex) when (ex is TimeoutException or TooManyHitsException or InvalidOperationException or PasswordRequiredException or MuPDFCore.MuPDFException or ObjectDisposedException or NotSupportedException or StreamTooLargeException)
        {
            Log.Write($"Reading a redaction back failed: {ex.GetType().Name}");
            failure = Strings.Review_ReadBackFailed;
        }
        return (new RedactionFileReport(name, rows, found.Looks, failure), check, checkOptions);
    }

    public bool HasSearchResults => _results.Count > 0;

    public void MarkRedaction(int page, RectD rect) => Viewer.AddRedactions([new RedactMark(page, rect)]);

    /// <summary>Confirms, then blacks out every marked area for good (the affected pages become images).</summary>
    /// <param name="check">Check the result afterwards (<see cref="RedactionCheck"/>, in the background): a report when
    /// anything of what was redacted is left in the file, a toast when nothing is.</param>
    public async Task<bool> ApplyRedactions(bool confirm = true, bool check = true)
    {
        var marks = Viewer.Redactions.ToList();
        if (marks.Count == 0 || !Session.IsPdf) return false;
        var pages = marks.Select(m => m.PageIndex).Distinct().Order().ToList();
        var list = string.Join(", ", pages.Take(12).Select(PageLabel)) + (pages.Count > 12 ? "…" : "");
        if (confirm && !Prompt.Confirm(Window.GetWindow(this), Loc.Plural(marks.Count, Strings.Review_ApplyTitle_One, Strings.Review_ApplyTitle_Many),
                Loc.Format(pages.Count == 1 ? Strings.Review_ApplyBodyPage : Strings.Review_ApplyBodyPages, list)
                    + (Session.SignedOnOpen ? "\n\n" + Strings.Review_ApplyBodySigned : "") + "\n\n" + Strings.Review_ApplyBodyUndo,
                Strings.Review_ApplyButton, warning: true)) return false;
        var areas = marks.GroupBy(m => m.PageIndex).ToDictionary(g => g.Key, g => (IReadOnlyList<RectD>)[.. g.Select(m => m.Rect)]);
        // What is about to be redacted, for the check afterwards: the text under the marks, the document as it is.
        var before = Session.Data;
        var values = check && Viewer.Engine is { } engine ? RedactionCheck.ValuesUnder(engine, areas) : [];
        var ocr = PageOcr.Engine;
        var recognized = 0;
        var ocrSkipped = false;
        var ok = await RunEdit(Loc.Plural(marks.Count, Strings.Review_UndoRedact_One, Strings.Review_UndoRedact_Many), (d, pw) =>
        {
            var redacted = Redaction.Apply(d, pw, areas);
            if (ocr is null) return redacted;
            // The redacted pages are images now: recognize what's left on them and lay it back as invisible text, so they
            // stay searchable and selectable. Part of the same edit (one undo step). Cancel skips only this part.
            var progress = Dispatcher.Invoke(() => new ProgressPrompt(Window.GetWindow(this), Strings.Review_ApplyingTitle, Strings.Review_RecognizingText));
            try
            {
                var words = RecognizePages(ocr, redacted, pw, pages, progress, Strings.Review_RecognizingRedacted, areas).Words;
                recognized = words.Values.Sum(w => w.Count);
                return recognized == 0 ? redacted : TextLayer.AddInvisibleText(redacted, pw, words);
            }
            catch (OperationCanceledException)
            {
                ocrSkipped = true;
                return redacted;
            }
            finally
            {
                Dispatcher.Invoke(progress.Dispose);
            }
        }, signaturesWarned: confirm);
        if (ok)
        {
            Viewer.ClearRedactions();
            if (Viewer.Tool == ViewerTool.Redact) Viewer.Tool = ViewerTool.Hand;
            if (ocr is null) Notify(Strings.Review_RedactedNoOcr);
            else if (ocrSkipped) Notify(Strings.Review_RedactedOcrCancelled);
            if (check) _ = CheckAfterApply(new RedactionCheckOptions { Values = values, Areas = areas, Original = before });
        }
        return ok;
    }

    /// <summary>
    /// The redaction check after Apply, in the background: the report when something of what was redacted is still in the
    /// file (in other places, or in what the document carries besides its pages), a toast when nothing is. Nothing shows
    /// if the document changed meanwhile (an undo, another edit).
    /// </summary>
    private async Task CheckAfterApply(RedactionCheckOptions options)
    {
        var data = Session.Data;
        var password = Session.Password;
        RedactionCheckReport report;
        try
        {
            report = await Task.Run(() => RedactionCheck.Run(data, password, options));
        }
        catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or MuPDFCore.MuPDFException or ObjectDisposedException)
        {
            Log.Write($"Redaction check after apply failed: {ex}");
            return;
        }
        if (_disposed || !ReferenceEquals(data, Session.Data)) return;
        if (report.IsClean) Notify(Strings.Review_RedactionChecked);
        else await RedactionCheckActions.Show(this, report, options);
    }

    /// <summary>
    /// Fixes what the redaction check found: redacts the areas (marked, then applied as usual, with text recognition on the
    /// pages that become images), then sanitizes the kinds that hold leftovers in one rewrite, then checks again.
    /// </summary>
    public async Task FixRedactionLeftovers(IReadOnlyList<RedactionFinding> findings, RedactionCheckOptions options)
    {
        var areas = RedactionCheck.RedactAreas(findings);
        var items = RedactionCheck.SanitizeItems(findings);
        if (areas.Count > 0)
        {
            Viewer.AddRedactions(areas.SelectMany(kv => kv.Value.Select(r => new RedactMark(kv.Key, r))));
            if (!await ApplyRedactions(confirm: false, check: false)) return;
        }
        if (items.Count > 0 || findings.Any(f => f.Fix == RedactionFix.Rewrite))
        {
            var outcome = await TryEdit(Strings.Review_UndoRemoveLeftovers, (d, pw) =>
                SignedEdits.Run(() => Sanitizer.Sanitize(d, pw, items).Data, allowRewrite: true).Data, signaturesWarned: true);
            if (outcome is not (EditOutcome.Done or EditOutcome.NoChange)) return;
        }
        // Checked again with what was redacted, not where (the fix redacted more, and earlier areas are images now).
        if (await RedactionCheckActions.Run(this, options with { Areas = null, Original = null }) is not { } again) return;
        if (again.IsClean) Notify(Strings.Review_LeftoversFixed);
        else await RedactionCheckActions.Show(this, again, options);
    }

    /// <summary>
    /// Recognize Text (OCR): for scanned pages (no text), recognizes the words and adds them as an invisible text layer,
    /// so the pages become searchable and selectable while looking the same. Each page is straightened, turned upright,
    /// despeckled and whitened first (unless the user turns that off); the cleaned page can replace the scan (off by
    /// default). Suspect words are marked for review in the Suspect words pane. One undo step; Cancel changes nothing.
    /// </summary>
    public async Task<bool> RecognizeText()
    {
        if (!Session.IsPdf || IsBusy || Window.GetWindow(this) is not { } owner) return false;
        if (PageOcr.Engine is not { } fallback)
        {
            Prompt.Info(owner, Strings.Review_OcrUnavailable, PageOcr.Unavailable);
            return false;
        }
        var count = Viewer.PageCount;
        var current = Viewer.CurrentPage;
        var settings = AppSettings.Current;
        var dlg = new FormDialog(owner, Strings.Review_OcrTitle, Strings.Review_OcrButton, 480);
        var which = dlg.AddChoice(Strings.Common_Pages, [Strings.Review_OcrAllWithoutText, Loc.Format(Strings.Review_OcrCurrentPage, PageLabel(current)), Strings.Review_OcrPageRange]);
        var range = dlg.Add(Strings.Review_OcrPageRange, new TextBox { Text = Core.PageRange.Format(SelectedPages.Length > 1 ? SelectedPages : [current]) });
        range.GotKeyboardFocus += (_, _) => which.SelectedIndex = 2;
        var languages = PageOcr.Languages;
        var chosen = PageOcr.For(settings.OcrLanguage) ?? fallback;
        var language = dlg.AddChoice(Strings.Review_OcrLanguage, languages.Select(l => l.Name),
            Math.Max(0, languages.ToList().FindIndex(l => string.Equals(l.Tag, chosen.Language, StringComparison.OrdinalIgnoreCase))));
        System.Windows.Automation.AutomationProperties.SetHelpText(language,
            Strings.Review_OcrLanguageHelp);
        var clean = dlg.AddCheck(Strings.Review_OcrClean, settings.OcrClean);
        System.Windows.Automation.AutomationProperties.SetHelpText(clean, Strings.Review_OcrCleanHelp);
        var suspects = dlg.AddCheck(Strings.Review_OcrSuspects, settings.OcrSuspects);
        System.Windows.Automation.AutomationProperties.SetHelpText(suspects, Strings.Review_OcrSuspectsHelp);
        var writeBack = dlg.AddCheck(Strings.Review_OcrWriteBack, false);
        System.Windows.Automation.AutomationProperties.SetHelpText(writeBack, Strings.Review_OcrWriteBackHelp);
        writeBack.IsEnabled = clean.IsChecked == true;
        clean.Checked += (_, _) => writeBack.IsEnabled = true;
        clean.Unchecked += (_, _) => { writeBack.IsEnabled = false; writeBack.IsChecked = false; };
        dlg.AddNote(Strings.Review_OcrNote);
        int[] pages = [];
        dlg.Validate(() =>
        {
            switch (which.SelectedIndex)
            {
                case 0:
                    pages = [.. Enumerable.Range(0, count)];
                    return null;
                case 1:
                    pages = [current];
                    return null;
                default:
                    return Core.PageRange.TryParse(range.Text, count, out pages, out var err) ? null : err;
            }
        });
        if (!dlg.ShowModal()) return false;

        if (language.SelectedIndex >= 0 && language.SelectedIndex < languages.Count) settings.OcrLanguage = languages[language.SelectedIndex].Tag;
        settings.OcrClean = clean.IsChecked == true;
        settings.OcrSuspects = suspects.IsChecked == true;
        settings.Save();
        var ocr = PageOcr.For(settings.OcrLanguage) ?? fallback;
        var options = new RecognizeOptions(Clean: settings.OcrClean, CheckWords: settings.OcrSuspects, KeepCleanedImage: writeBack.IsChecked == true);
        var spelling = options.CheckWords ? PageOcr.Spelling(ocr.Language) : null;

        var found = 0;
        var suspect = 0;
        var pagesWithWords = 0;
        var hadText = 0;
        var replaced = 0;
        var chosenPages = pages;
        var outcome = await TryEdit(Strings.Review_UndoOcr, (d, pw) =>
        {
            var progress = Dispatcher.Invoke(() => new ProgressPrompt(owner, Strings.Review_RecognizingTitle, Strings.Review_Starting));
            try
            {
                var result = RecognizePages(ocr, d, pw, chosenPages, progress, Strings.Review_RecognizingTitle, options: options, spelling: spelling);
                hadText = result.HadText;
                pagesWithWords = result.Words.Count;
                found = result.Words.Values.Sum(w => w.Count);
                suspect = result.Words.Values.Sum(w => w.Count(x => x.Suspect != SuspectReasons.None));
                replaced = result.Cleaned.Count;
                if (replaced > 0) d = ScanPage.WriteBack(d, pw, result.Cleaned);
                return found == 0 ? d : TextLayer.AddInvisibleText(d, pw, result.Words, ocr.Language);
            }
            finally
            {
                Dispatcher.Invoke(progress.Dispose);
            }
        }, quiet: true);
        switch (outcome)
        {
            case EditOutcome.Done when found > 0:
                var cleaned = replaced > 0 ? " " + Loc.Plural(replaced, Strings.Review_OcrReplaced_One, Strings.Review_OcrReplaced_Many) : "";
                var recognizedWords = found == 1 ? Loc.Format(Strings.Review_OcrRecognizedOneWord, found, pagesWithWords)
                    : Loc.Plural(pagesWithWords, Strings.Review_OcrRecognized_OnePage, Strings.Review_OcrRecognized_ManyPages, found);
                if (suspect > 0)
                {
                    SuspectRail.Visibility = Visibility.Visible;
                    Notify(Loc.Plural(suspect, Strings.Review_OcrWithSuspects_One, Strings.Review_OcrWithSuspects_Many, recognizedWords) + cleaned,
                        Strings.Review_OcrReviewAction, () => _ = ShowSuspectWordsAsync());
                }
                else
                {
                    var undoLabel = Strings.Review_UndoOcr;
                    Notify((hadText > 0 ? Loc.Format(Strings.Review_OcrDoneHadText, recognizedWords, hadText) : Loc.Format(Strings.Review_OcrDone, recognizedWords)) + cleaned,
                        Strings.Common_Undo, () => { if (!IsBusy && Session.UndoLabel == undoLabel) Undo(); });
                }
                return true;
            case EditOutcome.Done:
                Notify(Strings.Review_OcrNone + (replaced > 0 ? " " + Loc.Plural(replaced, Strings.Review_OcrReplaced_One, Strings.Review_OcrReplaced_Many) : ""));
                return true;
            case EditOutcome.NoChange:
                Notify(hadText == chosenPages.Length
                    ? (chosenPages.Length == 1 ? Strings.Review_OcrPageHasText : Strings.Review_OcrPagesHaveText)
                    : Strings.Review_OcrNone);
                return false;
            case EditOutcome.Declined:
                Notify(Strings.Review_OcrCancelled);
                return false;
            default:
                return false;
        }
    }

    /// <summary>What <see cref="RecognizePages"/> found: words per page, how many pages already had text, cleaned pages to write back.</summary>
    internal sealed record RecognizedPages(Dictionary<int, IReadOnlyList<OcrWord>> Words, int HadText, Dictionary<int, CleanedPageImage> Cleaned);

    /// <summary>
    /// OCR of <paramref name="pages"/> in <paramref name="data"/> (runs on a worker thread). Pages that already have text are
    /// skipped; words mostly inside a <paramref name="exclude"/> area (blacked-out redactions) are dropped. Without
    /// <paramref name="options"/>: cleaned pages, no suspect words, nothing to write back.
    /// </summary>
    /// <exception cref="OperationCanceledException">The user pressed Cancel in <paramref name="progress"/>.</exception>
    internal static RecognizedPages RecognizePages(InkvoltPrint.Core.Imaging.ITextRecognizer ocr, byte[] data, string? pw, IReadOnlyList<int> pages,
        ProgressPrompt progress, string title, IReadOnlyDictionary<int, IReadOnlyList<RectD>>? exclude = null, RecognizeOptions? options = null,
        InkvoltPrint.Core.Imaging.ISpelling? spelling = null)
    {
        options ??= new RecognizeOptions(CheckWords: false);
        var result = new Dictionary<int, IReadOnlyList<OcrWord>>();
        var cleaned = new Dictionary<int, CleanedPageImage>();
        var hadText = 0;
        using var engine = PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, pw);
        for (var i = 0; i < pages.Count; i++)
        {
            progress.Token.ThrowIfCancellationRequested();
            progress.Report(Loc.Format(Strings.Review_OcrProgress, title, i + 1, pages.Count), (double)i / pages.Count);
            var page = pages[i];
            if (page < 0 || page >= engine.PageCount) continue;
            if (TextLayer.HasText(engine, page))
            {
                hadText++;
                continue;
            }
            var read = ScanText.Recognize(engine, page, ocr, options, spelling, progress.Token);
            var words = read.Words.ToList();
            if (exclude is not null && exclude.TryGetValue(page, out var blacked))
                // A letter or two touching a black box is a recognizer reading the box's edge, not a word.
                words.RemoveAll(w => blacked.Any(b => Overlap(w.Rect, b) > (w.Text.Trim().Length <= 2 ? 0 : 0.3 * w.Rect.Width * w.Rect.Height)));
            if (words.Count > 0) result[page] = words;
            if (read.Cleaned is { } image) cleaned[page] = image;
        }
        return new RecognizedPages(result, hadText, cleaned);

        static double Overlap(RectD a, RectD b) =>
            Math.Max(0, Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X)) * Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y));
    }
}
