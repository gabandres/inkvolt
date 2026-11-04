using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPrint.Core.Suite;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Help › What's New (WHATS-NEW.md, embedded; shown once after an update) and Help › Report a Problem: the details a report
/// needs, scrubbed (InkvoltPrint.Core.Suite.Diagnostics), shown first, then copied for the user to paste into a GitHub issue.
/// Nothing is sent from the app.
/// </summary>
internal static class AppHelp
{
    private const string Repository = "https://github.com/gabandres/inkvolt";

    private static string Version => typeof(AppHelp).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    /// <summary>Every versioned entry of this build's notes, newest first (none if the resource is missing).</summary>
    public static IReadOnlyList<ReleaseNote> Notes()
    {
        try
        {
            using var reader = new StreamReader(Application.GetResourceStream(new Uri("pack://application:,,,/WHATS-NEW.md")).Stream);
            return ReleaseNotes.Parse(reader.ReadToEnd());
        }
        catch (IOException ex)
        {
            Log.Write($"Release notes not read: {ex.Message}");
            return [];
        }
    }

    /// <summary>After an update, once: what came since the version last run (nothing on a new install, nor in dev runs).</summary>
    public static void ShowWhatsNewOnce(Window owner)
    {
        var s = AppSettings.Current;
        if (AppSettings.ReadOnly || s.LastVersionSeen == Version) return;
        var news = ReleaseNotes.Since(Notes(), s.LastVersionSeen, ReleaseNotes.Normalize(Version)!, s.IsNewInstall);
        s.LastVersionSeen = Version;
        s.Save();
        if (news.Count == 0) return;
        Log.Write($"What's New shown for {string.Join(", ", news.Select(n => n.Version))}");
        ShowWhatsNew(owner, news);
    }

    public static void ShowWhatsNew(Window owner, IReadOnlyList<ReleaseNote> notes)
    {
        var dlg = new FormDialog(owner, Strings.Help_WhatsNewTitle, Strings.Common_Close, 540);
        dlg.HideCancel();
        var list = new StackPanel();
        if (notes.Count == 0) list.Children.Add(new TextBlock { Text = Strings.Help_NoNotes, TextWrapping = TextWrapping.Wrap });
        foreach (var note in notes)
        {
            list.Children.Add(new TextBlock
            {
                Text = Loc.Format(Strings.Help_Version, note.Version), FontWeight = FontWeights.SemiBold, FontSize = 15,
                Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 16, 0, 6),
            });
            foreach (var item in note.Items)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
                var bullet = new TextBlock { Text = "•", Margin = new Thickness(0, 0, 8, 0) };
                DockPanel.SetDock(bullet, Dock.Left);
                row.Children.Add(bullet);
                row.Children.Add(new TextBlock { Text = item, TextWrapping = TextWrapping.Wrap });
                list.Children.Add(row);
            }
        }
        dlg.Add(null, new ScrollViewer
        {
            Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false,
            MaxHeight = SystemParameters.WorkArea.Height * 0.6,
            Padding = new Thickness(0, 0, 14, 0), // room for the scrollbar, so it never covers the words
        });
        dlg.ShowModal();
    }

    public static void ShowReport(Window owner, int openDocuments)
    {
        var dlg = new FormDialog(owner, Strings.Help_ReportTitle, Strings.Common_Close, 700);
        dlg.HideCancel();
        dlg.AddNote(Strings.Help_ReportNote);
        var details = dlg.Add(null, new TextBox
        {
            Text = Report(openDocuments), IsReadOnly = true, TextWrapping = TextWrapping.NoWrap, Height = 320, Margin = new Thickness(0, 12, 0, 0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        });
        System.Windows.Automation.AutomationProperties.SetName(details, Strings.Help_DetailsToReport);
        var status = dlg.AddNote("");
        status.Visibility = Visibility.Collapsed;
        bool Copy()
        {
            try
            {
                Clipboard.SetText(details.Text);
                status.Text = Strings.Help_CopiedShort;
                return true;
            }
            catch (COMException ex) // another app holds the clipboard
            {
                Log.Write($"Diagnostics not copied: {ex.Message}");
                status.Text = Strings.Help_ClipboardBusy;
                return false;
            }
            finally
            {
                status.Visibility = Visibility.Visible;
            }
        }
        var issue = dlg.AddFooterButton(Strings.Help_CopyOpenIssue);
        issue.ToolTip = Strings.Help_CopyOpenIssueTip;
        issue.Click += (_, _) =>
        {
            if (!Copy()) return;
            Shell.Open(Diagnostics.IssueUrl(Repository, "Inkvolt PDF", Version, RuntimeInformation.OSDescription));
            status.Text = Strings.Help_Copied;
        };
        dlg.AddFooterButton(Strings.Common_Copy).Click += (_, _) => Copy();
        dlg.ShowModal();
    }

    public static string Report(int openDocuments)
    {
        var s = AppSettings.Current;
        string OnOff(bool on) => on ? "on" : "off";
        var settings = new List<(string, string)>
        {
            ("Theme", s.Theme),
            ("Reopen at last page", OnOff(s.RestorePosition)),
            ("Reopen last files", OnOff(s.ReopenTabs)),
            ("Recovery copies", OnOff(s.KeepRecoveryCopies)),
            ("Dark pages", OnOff(s.DarkPages)),
            ("Update check at start", OnOff(s.CheckForUpdates)),
            ("AI assistant", s.AiEnabled ? $"on ({s.AiPreset})" : "off"),
            ("Inkvolt Pro", Core.Pro.Licence is not null ? "licensed" : Core.Pro.Problem is not null ? "key not accepted" : "none"),
            ("Open documents", openDocuments.ToString()),
            ("Inkvolt Print", Inkvolt.InkvoltPrintPath is null ? "not installed" : "installed"),
        };
        return Diagnostics.Report("Inkvolt PDF", Version, RuntimeInformation.OSDescription, RuntimeInformation.ProcessArchitecture.ToString(),
            AppEnvironment.IsPackaged, settings, Diagnostics.Tail(Log.FilePath), Diagnostics.Identity.Current);
    }
}
