using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using InkvoltPrint.App.Tray;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.App.Views;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPrint.App;

/// <summary>What's New (WHATS-NEW.md, embedded) and the details Report a problem copies (Core.Suite.Diagnostics).</summary>
public static class AppHelp
{
    private static Version CurrentVersion => ReleaseNotes.Normalize(AboutDialog.AppVersion) ?? new Version(0, 0, 0);

    /// <summary>Every versioned entry of this build's notes, newest first (none if the resource is missing).</summary>
    public static IReadOnlyList<ReleaseNote> Notes()
    {
        try
        {
            var info = Application.GetResourceStream(new Uri("pack://application:,,,/WHATS-NEW.md"));
            if (info is null) return [];
            using var reader = new StreamReader(info.Stream);
            return ReleaseNotes.Parse(reader.ReadToEnd());
        }
        catch (IOException ex)
        {
            Log.Write($"Release notes not read: {ex.Message}");
            return [];
        }
    }

    /// <summary>After an update, once: what came since the version last run (nothing on a new install). Records this version.</summary>
    public static void ShowWhatsNewOnce(Window owner, AppState state)
    {
        var current = CurrentVersion.ToString();
        if (state.LastVersionSeen == current) return;
        var news = ReleaseNotes.Since(Notes(), state.LastVersionSeen, CurrentVersion, state.IsNewInstall);
        state.LastVersionSeen = current;
        state.Save();
        if (news.Count == 0) return;
        Log.Write($"What's New shown for {string.Join(", ", news.Select(n => n.Version))}");
        WhatsNewDialog.Open(owner, news);
    }

    public static string IssueUrl() =>
        Diagnostics.IssueUrl(AboutDialog.SourceUrl, "Inkvolt Print", AboutDialog.AppVersion, RuntimeInformation.OSDescription);

    public static string Report(MainViewModel vm)
    {
        var s = vm.State;
        var tray = s.Tray;
        string OnOff(bool on) => on ? "on" : "off";
        var models = s.Printers.Select(p => p.Model ?? "unknown model").ToList();
        var settings = new List<(string, string)>
        {
            ("Theme", WindowFrame.Theme),
            ("Printers remembered", models.Count == 0 ? "none" : $"{models.Count}: {string.Join(", ", models)}"),
            ("Printers listed now", vm.Printers.Count.ToString()),
            ("Scan", $"{s.ScanResolution} dpi, {(s.ScanColor ? "color" : "gray")}, OCR {OnOff(s.ScanOcr)}, skip blank {OnOff(s.ScanSkipBlank)}, straighten {OnOff(s.ScanStraighten)}"),
            ("Scan presets", vm.Presets.Items.Count.ToString()),
            ("Inkvolt PDF", InkvoltApps.Find(InkvoltApps.InkvoltPdf) is null ? "not installed" : $"installed, open scans {OnOff(s.OpenScansInInkvoltPdf)}"),
            ("Notification area", tray is { Enabled: true } ? $"on, alerts {OnOff(tray.Alerts)}" : "off"),
            ("Start with Windows", OnOff(StartWithWindows.IsOn)),
            ("Inkvolt Pro", Core.Pro.Licence is not null ? "licensed" : Core.Pro.Problem is not null ? "key not accepted" : "none"),
        };
        return Diagnostics.Report("Inkvolt Print", AboutDialog.AppVersion, RuntimeInformation.OSDescription,
            RuntimeInformation.ProcessArchitecture.ToString(), AppPackage.IsPackaged, settings, Diagnostics.Tail(Log.FilePath),
            Diagnostics.Identity.Current);
    }
}
