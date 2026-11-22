using System.IO;
using System.Windows;
using System.Windows.Automation.Peers;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Edit Text &amp; Images: the bar and the page reading around the page view's <see cref="ViewerTool.EditContent"/> mode.
/// Each change (text replaced in its own font, a paragraph rewrapped in its box, a picture moved, resized, replaced or deleted) is one edit through
/// <see cref="DocumentTab.TryEdit"/> (undo, signed files appended to with a warning, protected files kept protected).
/// </summary>
public partial class DocumentTab
{
    private byte[]? _contentData;                 // the bytes the shown text and pictures were read from
    private readonly HashSet<int> _contentWanted = [];
    private bool _contentLoading;
    private bool _angleSettled; // the angle box's Enter or Esc already dealt with what was typed

    private void InitEditContent()
    {
        EditContentReplace.Click += (_, _) => _ = OnContentAction(ContentAction.Replace);
        EditContentDelete.Click += (_, _) => _ = OnContentAction(ContentAction.Delete);
        EditContentCrop.Click += (_, _) => _ = OnContentAction(ContentAction.Crop);
        EditContentDone.Click += (_, _) => SetEditContent(false);
        Viewer.ToolChanged += (_, _) => UpdateEditContentUi();
        Viewer.ContentNeeded += (_, page) => RequestContent(page);
        Viewer.RunEdited += (_, e) => _ = EditRun(e);
        Viewer.ParagraphEdited += (_, e) => _ = EditParagraph(e);
        Viewer.ParagraphPictureRequested += (_, _) => _ = InsertParagraphPicture();
        Viewer.ImageMoved += (_, m) => _ = MoveImage(m);
        Viewer.ImageCropped += (_, m) => _ = CropImage(m);
        Viewer.ContentActionRequested += (_, a) => _ = OnContentAction(a);
        Viewer.ContentRefused += (_, message) =>
        {
            Notify(message);
            AnnounceContent(message);
        };
        Viewer.ContentAnnounce += (_, message) => AnnounceContent(message);
        Viewer.ContentSelectionChanged += (_, _) => UpdateContentButtons();
        Viewer.ContentTurned += (_, t) => _ = TurnContent(t);
        EditContentAngle.PreviewKeyDown += (_, e) =>
        {
            // Enter applies once (not again as focus leaves); Esc puts the angle back and applies nothing.
            if (e.Key == System.Windows.Input.Key.Enter)
            {
                ApplyAngle();
                _angleSettled = true;
                Viewer.Focus();
                e.Handled = true;
            }
            else if (e.Key == System.Windows.Input.Key.Escape)
            {
                _angleSettled = true;
                EditContentAngle.Text = Viewer.TurnSubject is { } t ? ContentTurn.Format(t.Angle) : "";
                Viewer.Focus();
                e.Handled = true;
            }
        };
        EditContentAngle.GotKeyboardFocus += (_, _) => _angleSettled = false;
        EditContentAngle.LostKeyboardFocus += (_, _) =>
        {
            if (!_angleSettled) ApplyAngle();
            _angleSettled = false;
        };
        Viewer.DocumentLanguage = DocumentLanguage;
        // The document's language is read as it opens, and again when its bytes change (an edit, undo, a reload: a
        // document made accessible says its language); form values and comments don't change it.
        ReadDocumentLanguage();
        Session.ContentChanged += (_, e) =>
        {
            if (!e.ContentOnly) ReadDocumentLanguage();
        };
    }

    /// <summary>Larger than this, the document isn't opened a second time just for its language: the interface's is used.</summary>
    private const long MaxLanguageRead = 256L << 20;

    private Task<string?>? _documentLanguage;
    private string? _lastDocumentLanguage;

    /// <summary>Reads the document's language off the UI thread (spell check on, a PDF of reasonable size).</summary>
    private void ReadDocumentLanguage()
    {
        if (!Spelling.On || !Session.IsPdf || _disposed || Session.Data.Length > MaxLanguageRead) return;
        var (data, pw) = (Session.Data, Session.Password);
        var read = _documentLanguage = Task.Run(() => SpellChecker.DocumentLanguage(data, pw));
        _ = read.ContinueWith(t =>
        {
            if (ReferenceEquals(read, _documentLanguage) && t.IsCompletedSuccessfully) _lastDocumentLanguage = t.Result;
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>
    /// The language the document says its text is in, for spell check (roadmap 4.1); while a new read is under way, what the
    /// last one said. Null when it says none (or isn't read: spell check off, a huge file).
    /// </summary>
    internal string? DocumentLanguage()
    {
        if (!Spelling.On || !Session.IsPdf || _disposed) return null;
        if (_documentLanguage is null) ReadDocumentLanguage(); // spell check was off as the document opened
        return _documentLanguage is { IsCompletedSuccessfully: true } done ? done.Result : _lastDocumentLanguage;
    }

    public bool IsEditingContent => Viewer.IsEditingContent;

    /// <summary>Enters or leaves Edit Text &amp; Images.</summary>
    public void SetEditContent(bool on)
    {
        if (!on)
        {
            if (IsEditingContent) Viewer.Tool = ViewerTool.Hand;
            return;
        }
        if (IsEditingContent) return;
        if (!Session.IsPdf)
        {
            Notify(Strings.EditContent_PdfOnly);
            return;
        }
        if (IsOrganizing) SetOrganizing(false);
        Viewer.Tool = ViewerTool.EditContent;
        Viewer.Focus();
        Notify(Strings.EditContent_Hint);
    }

    private void UpdateEditContentUi()
    {
        var on = IsEditingContent;
        var vis = on ? Visibility.Visible : Visibility.Collapsed;
        if (EditContentBar.Visibility == vis) return;
        EditContentBar.Visibility = vis;
        // The pages make room for the bar rather than lying under it.
        if (on) Viewer.Margin = new Thickness(0, 52, 0, 0);
        else if (!IsDesigningForm) Viewer.Margin = default;
        _contentWanted.Clear();
        _contentData = null;
        UpdateContentButtons();
    }

    private void UpdateContentButtons()
    {
        var image = Viewer.SelectedImage;
        EditContentReplace.IsEnabled = EditContentDelete.IsEnabled = image is { Blocked: null };
        EditContentCrop.IsEnabled = image is { Blocked: null, Turned: false };
        EditContentCrop.FontWeight = Viewer.CroppingImage ? FontWeights.SemiBold : FontWeights.Normal;
        var turn = Viewer.TurnSubject;
        EditContentAngle.IsEnabled = turn is not null;
        if (!EditContentAngle.IsKeyboardFocusWithin) EditContentAngle.Text = turn is { } t ? ContentTurn.Format(t.Angle) : "";
    }

    /// <summary>The bar's angle box, typed: the picture or paragraph turned to it (a typed angle that isn't one changes nothing).</summary>
    private void ApplyAngle()
    {
        if (!EditContentAngle.IsEnabled || Viewer.TurnSubject is not { } t) return;
        if (ContentTurn.Parse(EditContentAngle.Text) is { } wanted && ContentTurn.TurnBy(t.Angle, wanted) is not null) Viewer.TurnTo(wanted);
        else EditContentAngle.Text = ContentTurn.Format(t.Angle);
    }

    /// <summary>Edit › Turn to Angle: the bar's angle box, ready for typing.</summary>
    internal void FocusTurnAngle()
    {
        UpdateContentButtons();
        if (!EditContentAngle.IsEnabled) return;
        EditContentAngle.Focus();
        EditContentAngle.SelectAll();
    }

    public bool CanTurnContent => IsEditingContent && Viewer.TurnSubject is not null;

    /// <summary>A picture or paragraph turned (the handle, or the angle box): one edit.</summary>
    private async Task TurnContent(ContentTurnEdit t)
    {
        var label = t.Image is not null ? Strings.EditContent_EditTurnPicture : Strings.EditContent_EditTurnText;
        var outcome = await TryEdit(label, (d, pw) => t.Image is { } image
            ? ContentEditor.RotateImage(d, pw, image, t.By)
            : ContentEditor.RotateParagraph(d, pw, t.Paragraph!, t.By), veil: false);
        if (outcome == EditOutcome.Busy) Notify(Strings.EditContent_StillApplying, error: true);
        if (outcome != EditOutcome.Done) ReloadEditContent();
        UpdateContentButtons();
    }

    /// <summary>After any change to the document: what was read is stale, so the pages ask again.</summary>
    private void ReloadEditContent()
    {
        if (!IsEditingContent) return;
        _contentWanted.Clear();
        Viewer.ClearPageContent();
    }

    private void RequestContent(int page)
    {
        _contentWanted.Add(page);
        if (!_contentLoading) _ = LoadContent();
    }

    /// <summary>Reads the wanted pages' text and pictures off the UI thread (a few at a time, from the current bytes).</summary>
    private async Task LoadContent()
    {
        _contentLoading = true;
        try
        {
            while (_contentWanted.Count > 0 && IsEditingContent && !_disposed)
            {
                var data = Session.Data;
                var pw = Session.Password;
                var pages = _contentWanted.Take(8).ToList();
                IReadOnlyDictionary<int, PageContent> read;
                try
                {
                    read = await Task.Run(() => ContentEditor.Read(data, pw, pages));
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"Reading page content for Edit Text & Images failed: {ex.Message}");
                    read = pages.ToDictionary(p => p, _ => PageContent.Empty);
                }
                if (_disposed || !IsEditingContent) return;
                if (!ReferenceEquals(data, Session.Data)) continue; // changed meanwhile: read again from the new bytes
                _contentData = data;
                foreach (var p in pages)
                {
                    _contentWanted.Remove(p);
                    Viewer.SetPageContent(p, read.GetValueOrDefault(p) ?? PageContent.Empty);
                }
            }
        }
        finally
        {
            _contentLoading = false;
        }
    }

    private async Task EditRun(RunEdit e)
    {
        var check = e.Run.Check(e.Text);
        if (check.Missing.Count > 0)
        {
            // Said live under the editor too; nothing is changed.
            var list = string.Join(Strings.EditContent_ListSeparator, check.Missing.Take(8).Select(c => c == " " ? Strings.EditContent_Space : Loc.Format(Strings.EditContent_QuotedChar, c)));
            Notify(Loc.Format(Strings.EditContent_FontLacks, e.Run.FontName, list), error: true);
            return;
        }
        var outcome = await TryEdit(Strings.EditContent_EditText, (d, pw) => ContentEditor.ReplaceText(d, pw, e.Run, e.Text), veil: false);
        if (outcome == EditOutcome.Busy) Notify(Strings.EditContent_StillApplying, error: true);
        if (outcome != EditOutcome.Done) return;
        if (check.Width - check.OldWidth > 0.5)
            Notify(Loc.Format(Strings.EditContent_Wider, check.Width - check.OldWidth),
                Strings.Common_Undo, () =>
                {
                    if (!IsBusy && Session.CanUndo) Undo();
                });
    }

    /// <summary>
    /// A paragraph's new text, rewrapped in its box. Characters its font lacks: nothing changes (said live in the editor
    /// too). Text that would run into what follows below: asked first, never written silently.
    /// </summary>
    private async Task EditParagraph(ParagraphEdit e)
    {
        var check = e.Paragraph.Check(e.Text, e.Spans, e.Added);
        if (check.LookProblem is { } lp)
        {
            Notify(Loc.Format(Strings.EditContent_NotChangedBecause, lp), error: true);
            return;
        }
        if (check.Missing.Count > 0)
        {
            var list = string.Join(Strings.EditContent_ListSeparator, check.Missing.Take(8).Select(c => c == " " ? Strings.EditContent_Space : Loc.Format(Strings.EditContent_QuotedChar, c)));
            Notify(Loc.Format(Strings.EditContent_FontLacks, e.Paragraph.Lead.FontName, list), error: true);
            return;
        }
        var allow = false;
        if (check.Overlaps is not null)
        {
            var was = e.Paragraph.Lines.Count;
            if (!Prompt.Confirm(Window.GetWindow(this), Strings.EditContent_OverlapTitle,
                    Loc.Format(Strings.EditContent_OverlapBody, check.LineCount, was), Strings.EditContent_ChangeAnyway, warning: true))
            {
                Notify(Strings.EditContent_Shorten);
                return;
            }
            allow = true;
        }
        var outcome = await TryEdit(Strings.EditContent_EditParagraph, (d, pw) => ContentEditor.ReplaceParagraph(d, pw, e.Paragraph, e.Text, allow, e.Spans, e.Added), veil: false);
        if (outcome == EditOutcome.Busy) Notify(Strings.EditContent_StillApplying, error: true);
    }

    /// <summary>Insert Picture in the paragraph editor: an image file, put where the caret was.</summary>
    private async Task InsertParagraphPicture()
    {
        try
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Title = Strings.EditContent_InsertPictureTitle, Filter = FileTools.ImageFilter, InitialDirectory = AppSettings.Current.LastFolder };
            if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
            byte[] file;
            try
            {
                file = await File.ReadAllBytesAsync(dlg.FileName);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Prompt.Error(Window.GetWindow(this), Strings.EditContent_InsertPictureFailed, ex.Message);
                return;
            }
            Viewer.InsertParagraphPicture(file, Path.GetFileName(dlg.FileName));
        }
        finally
        {
            Viewer.EndParagraphPictureRequest();
        }
    }

    private async Task MoveImage(ImageMove m)
    {
        var page = m.Image.PageIndex;
        if (await TryEdit(Strings.EditContent_EditMovePicture, (d, pw) => ContentEditor.MoveImage(d, pw, m.Image, m.Box), veil: false) == EditOutcome.Done)
            Viewer.SelectImage(page, m.Box);
        else ReloadEditContent(); // back where it was
    }

    /// <summary>A picture cropped to a box by dragging its handles while cropping: one edit, then still selected (as it shows now).</summary>
    private async Task CropImage(ImageMove m)
    {
        var page = m.Image.PageIndex;
        if (await TryEdit(Strings.EditContent_EditCropPicture, (d, pw) => ContentEditor.CropImage(d, pw, m.Image, m.Box), veil: false) == EditOutcome.Done)
            Viewer.SelectImage(page, m.Box.Intersect(m.Image.Uncropped ?? m.Image.Box));
        else ReloadEditContent(); // back where it was
    }

    private async Task OnContentAction(ContentAction action)
    {
        if (Viewer.SelectedImage is not { Blocked: null } image) return;
        Viewer.FlushImageNudge();
        image = Viewer.SelectedImage ?? image;
        switch (action)
        {
            case ContentAction.Crop:
                Viewer.SetCropping(!Viewer.CroppingImage);
                if (Viewer.CroppingImage) Notify(Strings.EditContent_CropHint);
                else if (image.Turned) Notify(PdfStrings.Edit_CropTurned, error: true);
                UpdateContentButtons();
                break;
            case ContentAction.Delete:
                if (await RunEdit(Strings.EditContent_EditDeletePicture, (d, pw) => ContentEditor.DeleteImage(d, pw, image)))
                    Viewer.SelectImage(image.PageIndex, null);
                break;
            case ContentAction.Replace:
            {
                var dlg = new Microsoft.Win32.OpenFileDialog { Title = Strings.EditContent_ReplaceTitle, Filter = FileTools.ImageFilter, InitialDirectory = AppSettings.Current.LastFolder };
                if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
                byte[] file;
                try
                {
                    file = await File.ReadAllBytesAsync(dlg.FileName);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Prompt.Error(Window.GetWindow(this), Strings.EditContent_ReplaceFailed, ex.Message);
                    return;
                }
                var name = Path.GetFileName(dlg.FileName);
                await ReplaceImageWith(image, file, name);
                break;
            }
        }
        Viewer.Focus();
    }

    private async Task ReplaceImageWith(PageImage image, byte[] file, string name)
    {
        if (await RunEdit(Strings.EditContent_EditReplacePicture, (d, pw) => ContentEditor.ReplaceImage(d, pw, image, file, name)))
            Viewer.SelectImage(image.PageIndex, null);
    }

    /// <summary>Speaks a message through the bar's title (a polite live region).</summary>
    private void AnnounceContent(string message)
    {
        System.Windows.Automation.AutomationProperties.SetName(EditContentTitle, message);
        UIElementAutomationPeer.CreatePeerForElement(EditContentTitle)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    internal string DevContentState()
    {
        var page = Viewer.CurrentPage;
        var c = Viewer.DevContent(page);
        var sel = Viewer.SelectedImage;
        var para = Viewer.EditedParagraph;
        return $"editing={IsEditingContent} page={page + 1} runs={c?.Runs.Count.ToString() ?? "-"} images={c?.Images.Count.ToString() ?? "-"} " +
               $"paragraphs={c?.Paragraphs.Count.ToString() ?? "-"} " +
               $"selected={(sel is null ? "-" : $"{sel.Box.X:0},{sel.Box.Y:0} {sel.Box.Width:0}x{sel.Box.Height:0} angle {sel.Angle:0.##}")} editor='{Viewer.EditedRun?.Text}'" +
               $" turn={(Viewer.TurnSubject is { } ts ? ContentTurn.Format(ts.Angle, System.Globalization.CultureInfo.InvariantCulture) : "-")} anglebox='{EditContentAngle.Text}'" +
               (para is null ? "" : $" paragraph={para.Lines.Count} lines {para.Align} '{para.Text}'") +
               (Viewer.EditorNote is { } note ? $" note='{note.Replace('\n', ' ')}'" : "") +
               (c is null ? "" : " texts=[" + string.Join(" | ", c.Runs.Take(30).Select(r => r.Blocked is null ? r.Text : $"({r.Text})")) + "]");
    }

    /// <summary>DevScript's turnangle: typed in the bar's angle box, then Enter.</summary>
    internal void DevTurnAngle(string text)
    {
        UpdateContentButtons();
        EditContentAngle.Text = text;
        ApplyAngle();
    }

    internal Task DevReplaceImage(string path) =>
        Viewer.SelectedImage is { } image ? ReplaceImageWith(image, File.ReadAllBytes(path), Path.GetFileName(path)) : Task.CompletedTask;
}
