using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// The removal report as a page in the app, after Redact by Pattern or a batch: whether reading the result back found
/// anything (free: it is the safety check), the pages to look at by hand (free, for the same reason), and per file the page,
/// pattern and masked value of each removal, with Save CSV (Pro). It only ever holds masked values.
/// </summary>
internal static class RedactionReportDialog
{
    /// <summary>A line of the list.</summary>
    internal sealed record Row(string File, string Page, string What, string Masked, string Outcome)
    {
        public string Spoken => Loc.Format(Strings.Redact_ReportSpoken, File, Page, What, Masked, Outcome);

        public string PageText => Loc.Format(Strings.Redact_ReportPage, Page);
    }

    /// <summary>The report on the screen, for the developer script.</summary>
    internal static FormDialog? Open { get; private set; }

    public static void Show(Window owner, RedactionReport report, string suggestedName)
    {
        var dlg = new FormDialog(owner, Strings.Redact_ReportTitle, Strings.Common_Close, 860);
        dlg.HideCancel();
        var failed = report.Files.Where(f => f.Failure is not null).ToList();
        var many = report.Files.Count > 1;

        var head = dlg.AddNote(failed.Count > 0
            ? Loc.Format(many ? Strings.Redact_ReportFailedMany : Strings.Redact_ReportFailed, string.Join(" ", failed.Take(5).Select(f => (many ? f.File + ": " : "") + f.Failure)), failed.Count, report.Files.Count)
            : report.Headline);
        if (failed.Count > 0) head.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
        AutomationProperties.SetLiveSetting(head, AutomationLiveSetting.Polite);

        if (report.HasLooks)
        {
            var pages = report.Files.Where(f => f.Looks.Count > 0).Select(f => (many ? f.File + ": " : "") + RedactionReport.Pages(f.Looks.Select(l => l.Page)));
            var look = dlg.AddNote(Loc.Format(Strings.Redact_ReportLook, string.Join("; ", pages.Take(8)), RedactionLook.Why(report.Files.SelectMany(f => f.Looks))));
            look.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        }

        if (Pro.Allows(ProFeature.PatternRedaction))
        {
            var rows = report.Files.SelectMany(f =>
                f.Removals.Select(r => new Row(f.File, (r.Page + 1).ToString(), r.PatternName, r.Masked, r.OutcomeText))
                    .Concat(f.Looks.Select(l => new Row(f.File, (l.Page + 1).ToString(), l.Text, "", Strings.Redact_LookByHand)))).ToList();
            var list = new ListBox { Height = 360, ItemsSource = rows };
            list.ItemTemplate = (DataTemplate)XamlReader.Parse(
                "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
                "<TextBlock TextWrapping='Wrap' Margin='0,2,0,2'>" +
                (many ? "<Run Text='{Binding File, Mode=OneTime}' FontWeight='SemiBold' /><Run Text=' · ' />" : "") +
                "<Run Text='{Binding PageText, Mode=OneTime}' /><Run Text=' · ' /><Run Text='{Binding What, Mode=OneTime}' /><Run Text='  ' />" +
                "<Run Text='{Binding Masked, Mode=OneTime}' FontFamily='Cascadia Mono, Consolas' /><Run Text='  ' />" +
                "<Run Text='{Binding Outcome, Mode=OneTime}' Foreground='{DynamicResource TextFillColorSecondaryBrush}' /></TextBlock></DataTemplate>");
            ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
            VirtualizingPanel.SetIsVirtualizing(list, true);
            AutomationProperties.SetName(list, Strings.Redact_EachRemoval);
            list.ItemContainerStyle = new Style(typeof(ListBoxItem)) { BasedOn = (Style?)Application.Current.TryFindResource(typeof(ListBoxItem)) };
            list.ItemContainerStyle.Setters.Add(new Setter(AutomationProperties.NameProperty, new System.Windows.Data.Binding(nameof(Row.Spoken))));
            dlg.Add(Strings.Redact_EachRemovalMasked, list, top: 14);
            dlg.AddNote(Strings.Redact_MaskedNote);
        }
        else dlg.AddNote(Pro.Locked(ProFeature.PatternRedaction));

        dlg.AddFooterButton(Strings.Redact_SaveCsv).Click += (_, _) =>
        {
            if (!ProGate.Check(dlg, ProFeature.PatternRedaction)) return;
            if (CommentFileActions.PickSave(dlg, Strings.Redact_SaveReport, Strings.Redact_CsvFilter, Loc.Format(Strings.Redact_ReportFileName, suggestedName), null) is not { } path) return;
            try
            {
                File.WriteAllBytes(path, report.ToCsv());
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Prompt.Error(dlg, Strings.Redact_ReportNotSaved, ex.Message);
            }
        };
        Open = dlg;
        try
        {
            dlg.ShowModal();
        }
        finally
        {
            Open = null;
        }
    }
}
