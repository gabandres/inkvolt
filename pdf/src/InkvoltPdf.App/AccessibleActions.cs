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
        if (!tab.Session.IsPdf || !ProGate.Check(host, ProFeature.AutoTagging) || !await tab.SettleAsync()) return false;
        if (await PlanAsync(host, tab) is not { } plan) return false;
        return await WriteAsync(host, tab, plan, ask: true);
    }

    /// <summary>The plan for the document as it is now, read with a progress window (null: cancelled or unreadable).</summary>
    public static async Task<TagPlan?> PlanAsync(Window owner, DocumentTab tab)
    {
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        TagPlan plan;
        using (var prompt = new ProgressPrompt(owner, Strings.Access_MakeAccessible, Strings.Access_ReadingPages))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.Access_ReadingPage, p.Done + 1, p.Total), (double)p.Done / Math.Max(1, p.Total)));
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
                Prompt.Error(owner, Strings.Access_CantTag, ex.Message);
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
        var outcome = await tab.TryEdit(Strings.Access_EditLabel, (d, pw) => AutoTag.Write(d, pw, plan, options));
        if (outcome != EditOutcome.Done) return false;
        Log.Write($"Make Accessible: {plan.Blocks.Count} pieces, {plan.FiguresWithoutAlt} pictures without alternate text");
        tab.ShowWrittenPlan(plan);
        host.ShowStatus(plan.FiguresWithoutAlt == 0
            ? Strings.Access_Tagged
            : Loc.Plural(plan.FiguresWithoutAlt, Strings.Access_TaggedAlt_One, Strings.Access_TaggedAlt_Many));
        return true;
    }

    /// <summary>The title and language window; the plan with what the person confirmed, or null when cancelled.</summary>
    private static TagPlan? Ask(Window owner, TagPlan plan)
    {
        var dlg = new FormDialog(owner, Strings.Access_MakeAccessible, Strings.Access_TagButton, 520);
        dlg.AddNote(Strings.Access_TagNote);
        if (plan.WasTagged) dlg.AddNote(Strings.Access_AlreadyTagged);

        var title = dlg.Add(Strings.Access_Title, new TextBox { Text = plan.Title ?? "" });
        AutomationName(title, Strings.Access_Title);
        dlg.AddNote(plan.TitleFrom switch
        {
            TitleSource.Metadata => Strings.Access_TitleFromProperties,
            TitleSource.Heading => Strings.Access_TitleFromHeading,
            _ => Strings.Access_NoTitle,
        });

        var language = dlg.Add(Strings.Access_Language, new ComboBox { IsEditable = true, ItemsSource = Languages, Text = plan.Language ?? "" });
        AutomationName(language, Strings.Access_LanguageCode);
        dlg.AddNote(plan.Language is null ? Strings.Access_LanguageUnknown
            : plan.LanguageGuessed ? Strings.Access_LanguageGuessed
            : Strings.Access_LanguageFromDoc);

        var figures = plan.Blocks.Count(b => b.Kind == TagBlockKind.Figure);
        var tables = plan.Blocks.Count(b => b.Kind == TagBlockKind.Table);
        var headings = plan.Blocks.Count(b => b.Kind == TagBlockKind.Heading);
        var found = (Loc.Plural(headings, Strings.Access_Headings_One, Strings.Access_Headings_Many), Loc.Plural(tables, Strings.Access_Tables_One, Strings.Access_Tables_Many),
            Loc.Plural(figures, Strings.Access_Pictures_One, Strings.Access_Pictures_Many));
        dlg.AddNote(plan.FiguresWithoutAlt > 0
            ? Loc.Plural(plan.FiguresWithoutAlt, Strings.Access_FoundAlt_One, Strings.Access_FoundAlt_Many, found.Item1, found.Item2, found.Item3)
            : Loc.Format(Strings.Access_Found, found.Item1, found.Item2, found.Item3));
        dlg.Validate(() =>
        {
            if (string.IsNullOrWhiteSpace(title.Text)) return Strings.Access_TypeTitle;
            var code = language.Text.Trim();
            return AccessibilityCheck.IsLanguage(code) ? null : Strings.Access_ChooseLanguage;
        });
        dlg.Loaded += (_, _) => title.Focus();
        if (!dlg.ShowModal()) return null;
        return plan with { Title = title.Text.Trim(), Language = language.Text.Trim(), LanguageGuessed = false, TitleFrom = TitleSource.Metadata };
    }

    private static void AutomationName(UIElement e, string name) => System.Windows.Automation.AutomationProperties.SetName(e, name);
}
