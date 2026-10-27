namespace InkvoltPdf.Core;

public enum CommandKind { Help, Batch, Watch, Fill }

/// <summary>A parsed command line (see <see cref="BatchCommandLine.Usage"/>).</summary>
/// <param name="Preset">The preset file.</param>
/// <param name="Inputs">--batch: the files and folders to run it on.</param>
/// <param name="Folder">--watch: the folder.</param>
/// <param name="Name">--fill: the file name pattern of the forms.</param>
public sealed record CommandLineRequest(CommandKind Kind, string? Preset = null, IReadOnlyList<string>? Inputs = null, string? Folder = null,
    string? Output = null, bool Recursive = false, bool Once = false, bool Quiet = false, string? Name = null, bool Flatten = false);

/// <summary>The command line is wrong; the message says how.</summary>
public sealed class CommandLineException(string message) : Exception(message);

/// <summary>
/// <c>inkvoltpdf --batch</c> and <c>--watch</c>: a preset run without a window, from a terminal, a script or a scheduled
/// task. Lines go to <c>output</c> (one per file) and problems to <c>error</c>; the exit code says how it went
/// (<see cref="Done"/>, <see cref="SomeFailed"/>, <see cref="Wrong"/>, <see cref="Stopped"/>). Nothing is asked: files that
/// need a password to open are skipped, and Protect's passwords come from <see cref="OpenPasswordVariable"/> and
/// <see cref="PermissionsPasswordVariable"/> (presets never keep them). The app's entry point attaches the console and
/// passes the recognizer (OCR); everything else is here, so tests run it in-process.
/// </summary>
public static class BatchCommandLine
{
    /// <summary>Exit codes: every file done; a file failed or was skipped; the command line, preset or folder is wrong (nothing
    /// was done); stopped (Ctrl+C) before the end.</summary>
    public const int Done = 0, SomeFailed = 1, Wrong = 2, Stopped = 3;

    public const string OpenPasswordVariable = "INKVOLTPDF_OPEN_PASSWORD";
    public const string PermissionsPasswordVariable = "INKVOLTPDF_PERMISSIONS_PASSWORD";

    public static string Usage { get; } =
        """
        Inkvolt PDF command line: run a saved Batch preset without a window.

          inkvoltpdf --batch <preset.json> <files or folders>... [--out <folder>] [--recursive] [--quiet]
              Runs the preset on PDFs and images (a folder: the PDFs and images in it), a line per file.
              --out <folder>   where the results go (default: the preset's folder)
              --recursive      the folders' subfolders too

          inkvoltpdf --watch <folder> --preset <preset.json> [--out <folder>] [--once] [--quiet]
              Runs the preset on each PDF or image that lands in the folder, once it has stopped growing.
              Originals move to "done" or "failed" below the folder; inkvolt-watch.log there has a line per file.
              Ctrl+C stops (the files being worked on finish their current action first).
              --out <folder>   where the results go (default: the preset's folder, else <folder>\results)
              --once           handle the files there now, then stop (for a scheduled task)

          inkvoltpdf --fill <form.pdf> <data.csv> [--out <folder>] [--name <pattern>] [--flatten] [--quiet]
              Fills one copy of the form for each row of the CSV (its header names the fields), a line per row.
              A row with a value the form refuses is not saved; a report CSV lists why.
              --out <folder>   where the forms go (default: "<form> forms" beside the CSV)
              --name <pattern> file names: <<name>> the form's name, <<n>> or <<n:3>> the row, <<date>>, and any
                               column as <<Column>> (default: "<<name>> <<n:3>>")
              --flatten        the values become part of the pages

          inkvoltpdf --help

        Make presets in Inkvolt PDF: File > Batch > Save Preset (or Export). They are plain JSON.
        Protect with a password takes its passwords from the environment variables INKVOLTPDF_OPEN_PASSWORD and
        INKVOLTPDF_PERMISSIONS_PASSWORD. Files that need a password to open are skipped.

        Exit codes: 0 every file done; 1 a file failed or was skipped; 2 wrong command line, preset or folder
        (nothing done); 3 stopped before the end.
        """;

    /// <summary>The arguments ask for the command line (rather than opening files in the app).</summary>
    public static bool IsCommand(IReadOnlyList<string> args) => args.Count > 0 && args[0].ToLowerInvariant() is "--batch" or "--watch" or "--fill" or "--help" or "-h" or "-?" or "/?";

    /// <exception cref="CommandLineException">The arguments are wrong.</exception>
    public static CommandLineRequest Parse(IReadOnlyList<string> args)
    {
        if (args.Count == 0) throw new CommandLineException("Say what to do: --batch, --watch, --fill or --help.");
        var kind = args[0].ToLowerInvariant() switch
        {
            "--batch" => CommandKind.Batch,
            "--watch" => CommandKind.Watch,
            "--fill" => CommandKind.Fill,
            "--help" or "-h" or "-?" or "/?" => CommandKind.Help,
            _ => throw new CommandLineException($"\"{args[0]}\" isn't a command: use --batch, --watch, --fill or --help."),
        };
        if (kind == CommandKind.Help) return new CommandLineRequest(kind);

        string? first = null, preset = null, output = null, name = null;
        bool recursive = false, once = false, quiet = false, flatten = false;
        var inputs = new List<string>();
        string Value(ref int i, string name) =>
            i + 1 < args.Count && !args[i + 1].StartsWith("--", StringComparison.Ordinal) ? args[++i] : throw new CommandLineException($"{name} needs a value after it.");

        for (var i = 1; i < args.Count; i++)
        {
            var a = args[i];
            switch (a.ToLowerInvariant())
            {
                case "--out": output = Value(ref i, "--out"); break;
                case "--preset": preset = Value(ref i, "--preset"); break;
                case "--recursive": recursive = true; break;
                case "--once": once = true; break;
                case "--quiet": quiet = true; break;
                case "--name" when kind == CommandKind.Fill: name = Value(ref i, "--name"); break;
                case "--flatten" when kind == CommandKind.Fill: flatten = true; break;
                default:
                    if (a.StartsWith("--", StringComparison.Ordinal)) throw new CommandLineException($"\"{a}\" isn't an option Inkvolt PDF knows (--help lists them).");
                    if (first is null) first = a;
                    else inputs.Add(a);
                    break;
            }
        }
        if (kind == CommandKind.Fill)
        {
            if (first is null || inputs.Count != 1) throw new CommandLineException("--fill needs the form (a PDF), then the CSV of values.");
            if (preset is not null || recursive || once) throw new CommandLineException("--fill takes --out, --name, --flatten and --quiet.");
            return new CommandLineRequest(kind, null, [first, inputs[0]], null, output, Quiet: quiet, Name: name, Flatten: flatten);
        }
        if (kind == CommandKind.Batch)
        {
            if (first is null) throw new CommandLineException("--batch needs a preset file, then the files or folders to run it on.");
            if (preset is not null) throw new CommandLineException("--batch takes the preset right after it, not with --preset.");
            if (once) throw new CommandLineException("--once goes with --watch.");
            if (inputs.Count == 0) throw new CommandLineException("--batch needs the files or folders to run the preset on, after the preset.");
            return new CommandLineRequest(kind, first, inputs, null, output, recursive, Quiet: quiet);
        }
        if (first is null) throw new CommandLineException("--watch needs the folder to watch.");
        if (inputs.Count > 0) throw new CommandLineException($"--watch takes one folder (\"{inputs[0]}\" is one too many).");
        if (preset is null) throw new CommandLineException("--watch needs a preset: --preset <preset.json>.");
        if (recursive) throw new CommandLineException("--recursive goes with --batch (a watched folder takes the files at its top).");
        return new CommandLineRequest(kind, preset, null, first, output, Once: once, Quiet: quiet);
    }

    /// <summary>Runs the command line; returns the exit code.</summary>
    /// <param name="host">The recognizer (OCR) when there is one; its password prompt is never used.</param>
    /// <param name="environment">Reads an environment variable (tests give their own).</param>
    public static async Task<int> RunAsync(IReadOnlyList<string> args, TextWriter output, TextWriter error, BatchHost host, CancellationToken cancel,
        Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        CommandLineRequest request;
        try
        {
            request = Parse(args);
        }
        catch (CommandLineException ex)
        {
            error.WriteLine(ex.Message);
            error.WriteLine("inkvoltpdf --help shows how to use it.");
            return Wrong;
        }
        if (request.Kind == CommandKind.Help)
        {
            output.WriteLine(Usage);
            return Done;
        }
        if (request.Kind == CommandKind.Fill) return Fill(request, output, error, environment(OpenPasswordVariable), cancel); // free (roadmap 1.4)
        if (!Pro.Allows(ProFeature.CommandLine))
        {
            error.WriteLine(Pro.Locked(ProFeature.CommandLine));
            return Wrong;
        }

        BatchPreset preset;
        try
        {
            preset = BatchPresets.Load(Path.GetFullPath(request.Preset!));
        }
        catch (Exception ex) when (ex is BatchPresetException or ArgumentException or NotSupportedException or PathTooLongException)
        {
            error.WriteLine(ex.Message);
            return Wrong;
        }
        var steps = BatchPresets.WithPasswords(preset.Steps, environment(OpenPasswordVariable), environment(PermissionsPasswordVariable));
        if (steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords))
        {
            error.WriteLine($"The preset protects files with a password: set {OpenPasswordVariable} and/or {PermissionsPasswordVariable} (presets never keep passwords).");
            return Wrong;
        }
        host = new BatchHost { Recognize = host.Recognize };
        var gate = new Lock();
        void Line(TextWriter to, string text)
        {
            lock (gate) to.WriteLine(text);
        }

        return request.Kind == CommandKind.Batch
            ? await BatchAsync(request, preset with { Steps = steps }, host, output, error, Line, cancel).ConfigureAwait(false)
            : await WatchAsync(request, preset with { Steps = steps }, host, output, error, Line, cancel).ConfigureAwait(false);
    }

    private static async Task<int> BatchAsync(CommandLineRequest request, BatchPreset preset, BatchHost host, TextWriter output, TextWriter error,
        Action<TextWriter, string> line, CancellationToken cancel)
    {
        var outFolder = request.Output ?? preset.OutputFolder;
        if (string.IsNullOrWhiteSpace(outFolder))
        {
            error.WriteLine("Say where the results go: --out <folder> (the preset has no folder of its own).");
            return Wrong;
        }
        outFolder = Path.GetFullPath(outFolder);
        var plan = preset.ToPlan(outFolder) with { Passwords = PasswordPolicy.Skip };
        if (plan.Validate(host.Recognize is not null) is { } planError)
        {
            error.WriteLine($"The preset can't run: {planError}");
            return Wrong;
        }
        var inputs = request.Inputs!.Select(Path.GetFullPath).ToList();
        if (inputs.FirstOrDefault(p => !File.Exists(p) && !Directory.Exists(p)) is { } missing)
        {
            error.WriteLine($"There is no file or folder {missing}.");
            return Wrong;
        }
        var files = BatchFiles.Expand(inputs, request.Recursive, outFolder);
        if (files.Count == 0)
        {
            error.WriteLine("No PDFs or images to work on there.");
            return Wrong;
        }
        try
        {
            Directory.CreateDirectory(outFolder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            error.WriteLine($"The results can't be saved in {outFolder}: {ex.Message}");
            return Wrong;
        }

        if (!request.Quiet) line(output, $"\"{preset.Name}\" ({string.Join(", ", plan.Steps.Select(s => s.Title))}) on {Count(files.Count, "file")}, results in {outFolder}");
        var finished = 0;
        var progress = new Direct<BatchProgress>(p =>
        {
            if (p.Result is not { } r) return;
            var n = Interlocked.Increment(ref finished);
            var name = Path.GetFileName(r.File.Path);
            var notes = r.Notes.Count > 0 ? $" ({string.Join("; ", r.Notes)})" : "";
            var text = r.State switch
            {
                BatchItemState.Done => $"done     {name}{(r.Outputs.Count > 0 ? " -> " + string.Join(", ", r.Outputs) : ": nothing to save")}{notes}",
                BatchItemState.Skipped => $"skipped  {name}: {r.Message}{notes}",
                BatchItemState.Failed => $"failed   {name}: {r.Message}{notes}",
                _ => $"stopped  {name}",
            };
            if (r.State == BatchItemState.Done && request.Quiet) return;
            line(r.State is BatchItemState.Failed or BatchItemState.Skipped ? error : output, $"[{n}/{files.Count}] {text}");
        });

        BatchSummary summary;
        try
        {
            summary = await BatchRunner.RunAsync(files, plan, host, progress, cancel).ConfigureAwait(false);
        }
        catch (ArgumentException ex)
        {
            error.WriteLine($"The preset can't run: {ex.Message}");
            return Wrong;
        }
        line(output, summary.Text);
        if (summary.Cancelled > 0 || cancel.IsCancellationRequested) return Stopped;
        return summary.Failed + summary.Skipped > 0 ? SomeFailed : Done;
    }

    private static async Task<int> WatchAsync(CommandLineRequest request, BatchPreset preset, BatchHost host, TextWriter output, TextWriter error,
        Action<TextWriter, string> line, CancellationToken cancel)
    {
        var folder = Path.GetFullPath(request.Folder!);
        var outFolder = Path.GetFullPath(request.Output ?? preset.OutputFolder ?? WatchedFolder.DefaultOutput(folder));
        if (!Pro.Allows(ProFeature.WatchedFolders))
        {
            error.WriteLine(Pro.Locked(ProFeature.WatchedFolders));
            return Wrong;
        }
        if (WatchedFolder.Validate(folder, outFolder) is { } folderError)
        {
            error.WriteLine(folderError);
            return Wrong;
        }
        if (!request.Quiet)
            line(output, $"Watching {folder} with \"{preset.Name}\", results in {outFolder}. {(request.Once ? "Handling the files there now." : "Ctrl+C stops.")}");
        var progress = new Direct<WatchProgress>(p =>
        {
            if (p.Finished is not { } e) return;
            if (e.State == BatchItemState.Done && request.Quiet) return;
            var text = $"{e.Time:HH:mm:ss} {e.State.ToString().ToLowerInvariant(),-8} {e.FileName}: {e.Message}{(e.Outputs.Count > 0 ? " -> " + string.Join(", ", e.Outputs) : "")}";
            line(e.State is BatchItemState.Failed or BatchItemState.Skipped ? error : output, text);
        });
        try
        {
            var plan = preset.ToPlan(outFolder);
            var summary = await WatchedFolder.RunAsync(folder, plan, host, new WatchOptions { Once = request.Once }, progress, cancel).ConfigureAwait(false);
            line(output, $"{Count(summary.Done, "file")} done, {summary.Failed} failed.");
            return summary.Failed > 0 ? SomeFailed : Done;
        }
        catch (Exception ex) when (ex is ArgumentException or FolderWatchedException or UnauthorizedAccessException or IOException)
        {
            error.WriteLine(ex.Message);
            return Wrong;
        }
    }

    /// <summary>--fill: a form merge (<see cref="FormMerge"/>), a line per row; a report CSV beside the forms when a row failed.</summary>
    private static int Fill(CommandLineRequest request, TextWriter output, TextWriter error, string? password, CancellationToken cancel)
    {
        var form = Path.GetFullPath(request.Inputs![0]);
        var csv = Path.GetFullPath(request.Inputs[1]);
        if (new[] { form, csv }.FirstOrDefault(p => !File.Exists(p)) is { } missing)
        {
            error.WriteLine($"There is no file {missing}.");
            return Wrong;
        }
        var outFolder = Path.GetFullPath(request.Output ?? Path.Combine(Path.GetDirectoryName(csv)!, Path.GetFileNameWithoutExtension(form) + " forms"));
        var options = new FormMergeOptions { OutputFolder = outFolder, NameTemplate = request.Name ?? FormMergeOptions.DefaultTemplate, Flatten = request.Flatten };
        FormMergeReport report;
        try
        {
            report = FormMerge.Run(File.ReadAllBytes(form), password, File.ReadAllBytes(csv), form, options, null, cancel);
        }
        catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            error.WriteLine(ex.Message);
            return Wrong;
        }
        foreach (var c in report.UnknownColumns) error.WriteLine($"column   \"{c}\" isn't a field of the form: left out");
        foreach (var r in report.Made.Concat(report.Failed).OrderBy(r => r.Row))
        {
            if (r.File is { } file)
            {
                if (!request.Quiet) output.WriteLine($"made     row {r.Row} -> {file}");
            }
            else error.WriteLine($"failed   row {r.Row}: {string.Join("; ", r.Problems)}");
        }
        if (report.Failed.Count > 0)
        {
            var path = Path.Combine(outFolder, Path.GetFileNameWithoutExtension(form) + " merge report.csv");
            try
            {
                Directory.CreateDirectory(outFolder);
                File.WriteAllBytes(path, report.Csv());
                output.WriteLine($"Report: {path}");
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                error.WriteLine($"The report can't be saved: {ex.Message}");
            }
        }
        output.WriteLine(report.Text);
        if (report.Stopped) return Stopped;
        return report.Failed.Count > 0 ? SomeFailed : Done;
    }

    private static string Count(int n, string word) => n == 1 ? $"1 {word}" : $"{n} {word}s";

    /// <summary>Reports on the reporting thread (Progress&lt;T&gt; would post them later, after the summary line).</summary>
    private sealed class Direct<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
