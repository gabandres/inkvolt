using System.Windows;
using PrintDesk.App.ViewModels;
using PrintDesk.App.Views;

namespace PrintDesk.App;

public partial class App : Application
{
    private MainViewModel? _vm;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        SettingsViewModel.AskPassword = (printer, rejected) => PasswordDialog.Ask(MainWindow, printer, rejected);
        _vm = new MainViewModel(AppState.Load());
        MainWindow = new MainWindow { DataContext = _vm };
        MainWindow.Show();
        if (Array.IndexOf(e.Args, "--snapshot") is var i and >= 0 && i + 1 < e.Args.Length)
            _ = DevSnapshot.RunAsync((MainWindow)MainWindow, e.Args[i + 1], e.Args.SkipWhile(a => a != "--tab").Skip(1).FirstOrDefault());
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _vm?.Dispose();
        base.OnExit(e);
    }
}
