using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Make Accessible: reads the pages into a tag plan (<see cref="AutoTag.Plan"/>, off the UI thread with a
/// progress window), asks for the title and language (proposed: the document's, its first heading, a language read from
/// the text), writes the tags as one undo step (<see cref="AutoTag.Write"/>; a signed file's edit is appended), then opens
/// the reading order panel to check the order and give pictures alternate text.
/// </summary>
internal static class AccessibleActions
{
    /// <summary>Language codes offered (any other can be typed).</summary>
    private static readonly string[] Languages = ["en", "en-US", "en-GB", "es", "es-PR", "es-ES", "es-MX", "fr", "de", "it", "pt", "pt-BR", "nl"];

    /// <summary>True when the tags were written.</summary>
    public static async Task<bool> MakeAccessible(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return false;
        if (await PlanAsync(host, tab) is not { } plan) return false;
        return await WriteAsync(host, tab, plan, ask: true);
    }

    /// <summary>The plan for the document as it is now, read with a progress window (null: cancelled or unreadable).</summary>
    public static async Task<TagPlan?> PlanAsync(Window owner, DocumentTab tab)
    {
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        TagPlan plan;
        using (var prompt = new ProgressPrompt(owner, "Make Accessible", "Reading the pages…"))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report($"Reading page {p.Done + 1:N0} of {p.Total:N0}…", (double)p.Done / Math.Max(1, p.Total)));
                plan = await Task.Run(() =>
                {
                    // Its own engine: the viewer's keeps rendering meanwhile.
                    using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
                    return AutoTag.Plan(engine, data, password, progress, prompt.Token);
                }, prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or MuPDFException)
            {
                Log.Write($"Make Accessible: reading failed: {ex}");
                Prompt.Error(owner, "This document can't be tagged", ex.Message);
                return null;
            }
        }
        if (tab.IsDisposed || !ReferenceEquals(data, tab.Session.Data)) return null;
        return plan;
    }

    /// <summary>Writes the plan's tags as one undo step (asking for the title and language first with <paramref name="ask"/>), then shows the panel.</summary>
    public static async Task<bool> WriteAsync(MainWindow host, DocumentTab tab, TagPlan plan, bool ask)
    {
        if (ask)
        {
            if (Ask(host, plan) is not { } confirmed) return false;
            plan = confirmed;
        }
        if (!await tab.SettleAsync()) return false;
        var options = new AccessibleOptions { Title = plan.Title, Language = plan.Language };
        var outcome = await tab.TryEdit("Make accessible", (d, pw) => AutoTag.Write(d, pw, plan, options));
        if (outcome != EditOutcome.Done) return false;
        Log.Write($"Make Accessible: {plan.Blocks.Count} pieces, {plan.FiguresWithoutAlt} pictures without alternate text");
        tab.ShowWrittenPlan(plan);
        host.ShowStatus(plan.FiguresWithoutAlt == 0
            ? "Tagged. Check the reading order, then run the Accessibility Check."
            : $"Tagged. {plan.FiguresWithoutAlt} {(plan.FiguresWithoutAlt == 1 ? "picture needs" : "pictures need")} alternate text: select each in the Reading order pane.");
        return true;
    }

    /// <summary>The title and language window; the plan with what the person confirmed, or null when cancelled.</summary>
    private static TagPlan? Ask(Window owner, TagPlan plan)
    {
        var dlg = new FormDialog(owner, "Make Accessible", "Tag the Document", 520);
        dlg.AddNote("Tags the document on this PC, from its layout: headings, paragraphs, lists, tables and pictures in reading order; " +
                    "running headers, footers and page numbers are marked as decoration. Screen readers and Reflow use the tags. " +
                    "You can undo this until you save.");
        if (plan.WasTagged) dlg.AddNote("This document already has tags. They are replaced with new ones (pictures in the same place keep their alternate text).");

        var title = dlg.Add("Title", new TextBox { Text = plan.Title ?? "" });
        AutomationName(title, "Title");
        dlg.AddNote(plan.TitleFrom switch
        {
            TitleSource.Metadata => "From the document's properties. Screen readers say it first, and the window shows it.",
            TitleSource.Heading => "From the first heading: check that it says what the document is.",
            _ => "No title was found: type one that says what the document is.",
        });

        var language = dlg.Add("Language", new ComboBox { IsEditable = true, ItemsSource = Languages, Text = plan.Language ?? "" });
        AutomationName(language, "Language code");
        dlg.AddNote(plan.Language is null ? "The language couldn't be told from the text: choose or type its code (such as en or es)."
            : plan.LanguageGuessed ? "Read from the text: check it. A code such as en, en-US or es-PR."
            : "From the document. A code such as en, en-US or es-PR.");

        var figures = plan.Blocks.Count(b => b.Kind == TagBlockKind.Figure);
        var tables = plan.Blocks.Count(b => b.Kind == TagBlockKind.Table);
        var headings = plan.Blocks.Count(b => b.Kind == TagBlockKind.Heading);
        dlg.AddNote($"Found: {Count(headings, "heading")}, {Count(tables, "table")}, {Count(figures, "picture")}" +
                    (plan.FiguresWithoutAlt > 0 ? $"; {Count(plan.FiguresWithoutAlt, "picture")} still {(plan.FiguresWithoutAlt == 1 ? "needs" : "need")} alternate text, " +
                                                  "which you add in the Reading order pane that opens next." : "."));
        dlg.Validate(() =>
        {
            if (string.IsNullOrWhiteSpace(title.Text)) return "Type a title: PDF/UA asks for one.";
            var code = language.Text.Trim();
            return AccessibilityCheck.IsLanguage(code) ? null : "Choose or type a language code, such as en, en-US or es.";
        });
        dlg.Loaded += (_, _) => title.Focus();
        if (!dlg.ShowModal()) return null;
        return plan with { Title = title.Text.Trim(), Language = language.Text.Trim(), LanguageGuessed = false, TitleFrom = TitleSource.Metadata };

        static string Count(int n, string what) => n == 1 ? $"1 {what}" : $"{n} {what}s";
    }

    private static void AutomationName(UIElement e, string name) => System.Windows.Automation.AutomationProperties.SetName(e, name);
}
