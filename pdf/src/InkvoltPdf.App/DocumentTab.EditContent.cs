using System.IO;
using System.Windows;
using System.Windows.Automation.Peers;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Edit Text &amp; Images: the bar and the page reading around the page view's <see cref="ViewerTool.EditContent"/> mode.
/// Each change (text replaced in its own font, a picture moved, resized, replaced or deleted) is one edit through
/// <see cref="DocumentTab.TryEdit"/> (undo, signed files appended to with a warning, protected files kept protected).
/// </summary>
public partial class DocumentTab
{
    private byte[]? _contentData;                 // the bytes the shown text and pictures were read from
    private readonly HashSet<int> _contentWanted = [];
    private bool _contentLoading;

    private void InitEditContent()
    {
        EditContentReplace.Click += (_, _) => _ = OnContentAction(ContentAction.Replace);
        EditContentDelete.Click += (_, _) => _ = OnContentAction(ContentAction.Delete);
        EditContentDone.Click += (_, _) => SetEditContent(false);
        Viewer.ToolChanged += (_, _) => UpdateEditContentUi();
        Viewer.ContentNeeded += (_, page) => RequestContent(page);
        Viewer.RunEdited += (_, e) => _ = EditRun(e);
        Viewer.ImageMoved += (_, m) => _ = MoveImage(m);
        Viewer.ContentActionRequested += (_, a) => _ = OnContentAction(a);
        Viewer.ContentRefused += (_, message) =>
        {
            Notify(message);
            AnnounceContent(message);
        };
        Viewer.ContentAnnounce += (_, message) => AnnounceContent(message);
        Viewer.ContentSelectionChanged += (_, _) => UpdateContentButtons();
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
            Notify("Text and pictures can be edited in PDF files only.");
            return;
        }
        if (IsOrganizing) SetOrganizing(false);
        Viewer.Tool = ViewerTool.EditContent;
        Viewer.Focus();
        Notify("Click text to change it, or a picture to move, resize, replace or delete it. Tab goes through them.");
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
            var list = string.Join(", ", check.Missing.Take(8).Select(c => c == " " ? "space" : $"“{c}”"));
            Notify($"Not changed: the font “{e.Run.FontName}” has no {list} in this PDF.", error: true);
            return;
        }
        var outcome = await TryEdit("Edit text", (d, pw) => ContentEditor.ReplaceText(d, pw, e.Run, e.Text), veil: false);
        if (outcome == EditOutcome.Busy) Notify("Not changed: the last change is still being applied. Try again in a moment.", error: true);
        if (outcome != EditOutcome.Done) return;
        if (check.Width - check.OldWidth > 0.5)
            Notify($"Text changed. It is {check.Width - check.OldWidth:0} pt wider than before and doesn't reflow, so it may overlap what follows.",
                "Undo", () =>
                {
                    if (!IsBusy && Session.CanUndo) Undo();
                });
    }

    private async Task MoveImage(ImageMove m)
    {
        var page = m.Image.PageIndex;
        if (await TryEdit("Move picture", (d, pw) => ContentEditor.MoveImage(d, pw, m.Image, m.Box), veil: false) == EditOutcome.Done)
            Viewer.SelectImage(page, m.Box);
        else ReloadEditContent(); // back where it was
    }

    private async Task OnContentAction(ContentAction action)
    {
        if (Viewer.SelectedImage is not { Blocked: null } image) return;
        Viewer.FlushImageNudge();
        image = Viewer.SelectedImage ?? image;
        switch (action)
        {
            case ContentAction.Delete:
                if (await RunEdit("Delete picture", (d, pw) => ContentEditor.DeleteImage(d, pw, image)))
                    Viewer.SelectImage(image.PageIndex, null);
                break;
            case ContentAction.Replace:
            {
                var dlg = new Microsoft.Win32.OpenFileDialog { Title = "Replace Picture", Filter = FileTools.ImageFilter, InitialDirectory = AppSettings.Current.LastFolder };
                if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
                byte[] file;
                try
                {
                    file = await File.ReadAllBytesAsync(dlg.FileName);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Prompt.Error(Window.GetWindow(this), "Replace Picture didn't work", ex.Message);
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
        if (await RunEdit("Replace picture", (d, pw) => ContentEditor.ReplaceImage(d, pw, image, file, name)))
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
        return $"editing={IsEditingContent} page={page + 1} runs={c?.Runs.Count.ToString() ?? "-"} images={c?.Images.Count.ToString() ?? "-"} " +
               $"selected={(sel is null ? "-" : $"{sel.Box.X:0},{sel.Box.Y:0} {sel.Box.Width:0}x{sel.Box.Height:0}")} editor='{Viewer.EditedRun?.Text}'" +
               (c is null ? "" : " texts=[" + string.Join(" | ", c.Runs.Take(30).Select(r => r.Blocked is null ? r.Text : $"({r.Text})")) + "]");
    }

    internal Task DevReplaceImage(string path) =>
        Viewer.SelectedImage is { } image ? ReplaceImageWith(image, File.ReadAllBytes(path), Path.GetFileName(path)) : Task.CompletedTask;
}
