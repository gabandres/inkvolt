using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.App.Views;

namespace InkvoltPrint.App;

public partial class App : Application
{
    private MainViewModel? _vm;
    private SingleInstance? _instance;

    protected override void OnStartup(StartupEventArgs e)
    {
        // --demo: one made-up printer, no network (Demo.cs). Like the dev aids, it runs beside a normal copy.
        // --try: the same, labelled as a demo (the "Try a demo printer" link on the no-printers screen).
        var tryDemo = e.Args.Contains("--try");
        var demo = tryDemo || e.Args.Contains("--demo");
        var devRun = demo || e.Args.Any(a => a is "--snapshot" or "--autoprint");
        if (!devRun)
        {
            _instance = SingleInstance.TryAcquire(e.Args);
            if (_instance is null)
            {
                Shutdown(); // the running copy got our arguments
                return;
            }
        }

        // This UI is static; GPU rendering only costs memory (~200 MB on some ARM64 graphics drivers).
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;

        DispatcherUnhandledException += OnUiException;
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Write($"Unobserved task exception: {args.Exception}");
            args.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write($"FATAL: {args.ExceptionObject}");

        if (Array.IndexOf(e.Args, "--theme") is var t and >= 0 && t + 1 < e.Args.Length)
            ThemeMode = new ThemeMode(e.Args[t + 1]);

        base.OnStartup(e);
        Log.Write($"Inkvolt Print started ({Environment.ProcessPath})");
        if (AppState.MovedLegacyData) Log.Write("Data folder carried over from its pre-rename location");

        SettingsViewModel.AskPassword = (printer, rejected, fingerprint) => PasswordDialog.AskAdmin(MainWindow, printer, rejected, fingerprint);
        PrintViewModel.AskPdfPassword = (file, wrong) => PasswordDialog.AskPdf(MainWindow, file, wrong);
        Prompt.Confirm = (message, confirm) => ConfirmDialog.Ask(MainWindow, message, confirm);
        Prompt.Inform = message => ConfirmDialog.Tell(MainWindow, message);

        _vm = demo ? new MainViewModel(Demo.CreateState(), Demo.CreateTransport) : new MainViewModel(AppState.Load());
        MainWindow = new MainWindow { DataContext = _vm };
        if (tryDemo)
        {
            MainWindow.Title = "Inkvolt Print (demo printer)";
            ((MainWindow)MainWindow).AppName.Text = "Inkvolt Print · Demo";
        }
        if (DevSnapshot.Size(e.Args) is var (width, height))
        {
            MainWindow.Width = width;
            MainWindow.Height = height;
        }
        MainWindow.Show();

        _instance?.Listen(args => Dispatcher.InvokeAsync(() => HandleForwarded(args)));
        if (!devRun) _ = Task.Run(ShellIntegration.RegisterOpenWith);

        // "Open with Inkvolt Print" / InkvoltPrint.exe file.pdf → straight to Print for the last-used printer.
        if (FirstPdf(e.Args) is { } pdf) _ = _vm.OpenPdfAsync(pdf);
        if (Array.IndexOf(e.Args, "--autoprint") is var ap and >= 0 && ap + 1 < e.Args.Length)
            _ = DevAutoPrint.RunAsync(_vm, e.Args[ap + 1],
                copies: int.TryParse(e.Args.SkipWhile(x => x != "--copies").Skip(1).FirstOrDefault(), out var c) ? c : 1,
                twoSided: e.Args.Contains("--two-sided"));
        if (Array.IndexOf(e.Args, "--snapshot") is var i and >= 0 && i + 1 < e.Args.Length)
            _ = DevSnapshot.RunAsync((MainWindow)MainWindow, e.Args[i + 1], e.Args.SkipWhile(a => a != "--tab").Skip(1).FirstOrDefault(),
                scan: e.Args.Contains("--scan"), scrollToEnd: e.Args.Contains("--scroll-end"),
                copy: e.Args.SkipWhile(a => a != "--copy").Skip(1).FirstOrDefault());
    }

    private static string? FirstPdf(IEnumerable<string> args) =>
        args.FirstOrDefault(a => a.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(a));

    /// <summary>Another launch handed us its arguments: bring the window forward and open its PDF, if any.</summary>
    private void HandleForwarded(string[] args)
    {
        if (MainWindow is not { } w) return;
        // Owned WPF dialogs, and Win32 Open/Save dialogs (which register as thread-modal), must close first.
        static bool DialogOpen(Window w) => w.OwnedWindows.Count > 0 || System.Windows.Interop.ComponentDispatcher.IsThreadModal;
        if (DialogOpen(w))
        {
            // A dialog (password, confirmation) is open: opening a PDF now would stack dialogs. Try again shortly.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            timer.Tick += (_, _) =>
            {
                if (DialogOpen(w)) return;
                timer.Stop();
                HandleForwarded(args);
            };
            timer.Start();
            return;
        }
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Show();
        w.Activate();
        w.Topmost = true; // Windows won't let a background process steal focus; flash to the top instead
        w.Topmost = false;
        if (FirstPdf(args) is { } pdf && _vm is not null) _ = _vm.OpenPdfAsync(pdf);
    }

    /// <summary>Last line of defence: log it, tell the user, keep running (and keep their scanned pages).</summary>
    private void OnUiException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Write($"Unhandled UI exception: {e.Exception}");
        e.Handled = true;
        if (MainWindow is not { IsLoaded: true, IsVisible: true } owner)
        {
            // Failed before the window was up: a windowless process would keep the single-instance lock and
            // silently swallow every later launch. Say so and exit instead.
            MessageBox.Show($"Inkvolt Print couldn't start.\n\n{e.Exception.Message}\n\nDetails were saved to {Log.FilePath}",
                "Inkvolt Print", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        MessageBox.Show(owner,
            $"Something went wrong, but Inkvolt Print is still running and nothing you were working on was lost.\n\n{e.Exception.Message}\n\nDetails were saved to {Log.FilePath}",
            "Inkvolt Print", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _vm?.Dispose();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
