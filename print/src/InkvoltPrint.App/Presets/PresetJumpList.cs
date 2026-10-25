using System.Windows;
using System.Windows.Shell;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Windows;

namespace InkvoltPrint.App.Presets;

/// <summary>
/// The first five presets as tasks in Inkvolt Print's jump list (right-click it on the taskbar or in Start):
/// <c>InkvoltPrint.exe --preset &lt;id&gt;</c>, which a running copy receives through its single-instance pipe. Only in
/// installed, unpackaged copies: the Microsoft Store package and dev builds (run from bin\) leave the jump list alone.
/// </summary>
public static class PresetJumpList
{
    public const int Count = 5;

    /// <summary>What the jump list shows now: a counter going up after each save doesn't rewrite it.</summary>
    private static string? _shown;

    private static bool? _mayRegister;

    public static bool Supported =>
        !AppPackage.IsPackaged && Environment.ProcessPath is { } exe && !exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase);

    public static void Update(Application app, IEnumerable<ScanPreset> presets)
    {
        // A second copy (another folder) leaves the installed copy's jump list alone, as it does its "Open with" entries.
        if (!Supported || Environment.ProcessPath is not { } exe || !(_mayRegister ??= ShellIntegration.MayRegister(exe))) return;
        var top = presets.Take(Count).ToList();
        var shown = string.Join("\n", top.Select(p => $"{p.Id}\t{p.Name}\t{ScanPresetText.Summary(p)}"));
        if (shown == _shown) return;
        _shown = shown;
        try
        {
            var list = new JumpList { ShowFrequentCategory = false, ShowRecentCategory = false };
            foreach (var p in top)
                list.JumpItems.Add(new JumpTask
                {
                    Title = $"Scan: {p.Name}",
                    Description = ScanPresetText.Summary(p),
                    ApplicationPath = exe,
                    IconResourcePath = exe,
                    Arguments = $"--preset {p.Id}",
                });
            JumpList.SetJumpList(app, list);
            list.Apply();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            Log.Write($"Jump list not updated: {ex.Message}");
        }
    }
}
