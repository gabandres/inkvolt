namespace InkvoltPdf.App;

/// <summary>
/// The taskbar jump list's New Window task (roadmap 4.9): it starts Inkvolt PDF with <c>--new-window</c>, which a running
/// copy takes as a new window (<see cref="App"/>'s forwarded launches) and a first launch as an empty window. Recent files
/// there are Windows' own (files opened through the file association) and open in the window used last. Packaged installs
/// go through WinRT's jump list (the item's arguments reach the app's command line); others through the shell's, as WPF
/// writes it. Best effort: a jump list that can't be written is logged.
/// </summary>
internal static class JumpListTasks
{
    public static void Set()
    {
        try
        {
            if (AppEnvironment.IsPackaged) _ = SetPackagedAsync();
            else SetShell();
        }
        catch (Exception ex)
        {
            Log.Write($"Jump list not set: {ex.Message}");
        }
    }

    private static void SetShell()
    {
        if (Environment.ProcessPath is not { } exe) return;
        var list = new System.Windows.Shell.JumpList { ShowRecentCategory = false, ShowFrequentCategory = false };
        list.JumpItems.Add(new System.Windows.Shell.JumpTask
        {
            Title = Strings.Jump_NewWindow,
            Description = Strings.Jump_NewWindowTip,
            ApplicationPath = exe,
            IconResourcePath = exe,
            Arguments = Core.WindowLaunch.NewWindowSwitch,
        });
        list.JumpItemsRejected += (_, e) => Log.Write($"Jump list: {e.RejectedItems.Count} item(s) rejected");
        System.Windows.Shell.JumpList.SetJumpList(System.Windows.Application.Current, list);
        list.Apply();
    }

    private static async Task SetPackagedAsync()
    {
        try
        {
            if (!global::Windows.UI.StartScreen.JumpList.IsSupported()) return;
            var list = await global::Windows.UI.StartScreen.JumpList.LoadCurrentAsync();
            list.Items.Clear();
            var item = global::Windows.UI.StartScreen.JumpListItem.CreateWithArguments(Core.WindowLaunch.NewWindowSwitch, Strings.Jump_NewWindow);
            item.Description = Strings.Jump_NewWindowTip;
            list.Items.Add(item);
            list.SystemGroupKind = global::Windows.UI.StartScreen.JumpListSystemGroupKind.Recent;
            await list.SaveAsync();
        }
        catch (Exception ex)
        {
            Log.Write($"Jump list not set: {ex.Message}");
        }
    }
}
