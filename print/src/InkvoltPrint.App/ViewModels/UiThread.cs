using System.Windows;

namespace InkvoltPrint.App.ViewModels;

/// <summary>Runs view-model work on the dispatcher: at once when already on it, else queued. Nothing when the app has no dispatcher (closing).</summary>
internal static class UiThread
{
    public static void Run(Action action)
    {
        if (Application.Current?.Dispatcher is not { } ui) return;
        if (ui.CheckAccess()) action();
        else ui.InvokeAsync(action);
    }
}
