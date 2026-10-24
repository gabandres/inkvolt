namespace InkvoltPdf.App;

/// <summary>Commands for new-from-images, comparing files, password protection, reducing size, flattening, sanitizing, headers and footers, watermarks, bookmarks and Read Aloud.</summary>
public partial class MainWindow
{
    private void BindToolCommands()
    {
        BindAlways(Cmd.NewFromImages, () => _ = FileTools.NewFromImages(this));
        BindAlways(Cmd.NewFromClipboard, () => _ = FileTools.NewFromClipboard(this));
        BindAlways(Cmd.Compare, () => _ = Comparing.Start(this));
        BindEdit(Cmd.ProtectPassword, t => SecurityActions.Protect(this, t));
        BindEdit(Cmd.RemoveProtection, t => SecurityActions.RemoveProtection(this, t), t => t.Session.Engine.IsEncrypted);
        BindEdit(Cmd.ReduceSize, t => FileTools.ReduceSize(this, t));
        BindEdit(Cmd.Flatten, t => FileTools.Flatten(this, t));
        BindEdit(Cmd.Sanitize, t => SanitizeActions.Sanitize(this, t));
        BindEdit(Cmd.AddHeaderFooter, t => PageMarkActions.AddHeaderFooter(this, t));
        BindEdit(Cmd.RemoveHeaderFooter, PageMarkActions.RemoveHeaderFooter);
        BindEdit(Cmd.AddWatermark, t => PageMarkActions.AddWatermark(this, t));
        BindEdit(Cmd.RemoveWatermark, PageMarkActions.RemoveWatermark);
        Bind(Cmd.AddBookmark, t => t.AddBookmarkForView(), t => t.Session.IsPdf && t.PageView.PageCount > 0);
        BindTab(Cmd.ReadAloud, t => _ = t.ToggleReadAloud(), t => t.PageView.PageCount > 0);
        // AI assistant: while it is off these open its settings (with a word on why) instead.
        Bind(Cmd.AiSummarize, t =>
        {
            if (!AiReady()) return;
            if (AiActions.AskSummaryPages(this, t) is { } pages) _ = t.AiSummarize(pages);
        }, t => t.PageView.PageCount > 0 && !t.IsAiBusy);
        Bind(Cmd.AiAsk, t =>
        {
            if (AiReady()) t.ShowAiPane();
        }, t => t.PageView.PageCount > 0);
        Bind(Cmd.AiExplain, t => _ = t.AiExplainSelection(), t => t.PageView.HasSelection && !t.IsAiBusy);
        BindAlways(Cmd.AiSettings, () =>
        {
            if (!AiActions.ShowSettings(this)) return;
            foreach (var t in Tabs) t.RefreshAiPane();
            ShowStatus(AiActions.Describe());
        });
    }

    /// <summary>True when the AI assistant is set up; else offers its settings (saying why) and tells whether it is now.</summary>
    private bool AiReady()
    {
        if (AiService.Current(out var problem) is not null) return true;
        if (!AiActions.ShowSettings(this, problem + " Set it up here, or Cancel.")) return false;
        foreach (var t in Tabs) t.RefreshAiPane();
        return AiService.Current(out _) is not null;
    }
}
