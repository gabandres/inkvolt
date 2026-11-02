namespace InkvoltPdf.App;

/// <summary>
/// The entry point. A find worker (see <see cref="Core.FindWorkers"/>) or index worker (<see cref="Core.IndexWorkers"/>) only
/// ever connects to its parent's pipe and reads text, so it goes straight there: no WPF, no settings, no log, no
/// single-instance check.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (Core.FindWorkers.IsCommand(args)) return Core.FindWorkers.Run(args);
        if (Core.IndexWorkers.IsCommand(args)) return Core.IndexWorkers.Run(args);
        if (Environment.ProcessPath is { } exe)
        {
            Core.FindWorkers.Use(exe);
            Core.IndexWorkers.Use(exe);
        }
        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
