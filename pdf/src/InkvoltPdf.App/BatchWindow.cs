using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using InkvoltPdf.Core;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// File › Batch: one list of actions run on many files (PDFs, and images made into PDFs), the results saved in a folder
/// with names from a template; the originals stay as they are. The work is <see cref="BatchRunner"/>'s (worker threads, a
/// few files at a time within a memory budget); this window lists the files with each one's result, asks for passwords
/// as they come up (or skips those files), and can stop the batch. The actions and choices can be saved as a named preset
/// (<see cref="PresetLibrary"/>, plain JSON through <see cref="BatchPresets"/>), exported and imported, and run by a watched
/// folder (<see cref="WatchWindow"/>) or the command line.
/// </summary>
internal sealed class BatchWindow : Window
{
    /// <summary>A file in the list, with its result.</summary>
    private sealed class FileRow(BatchFile file) : INotifyPropertyChanged
    {
        public BatchFile File { get; } = file;
        public string Name => Path.GetFileName(File.Path);
        public string Folder => Path.GetDirectoryName(File.Path) ?? "";
        public BatchItemResult? Result { get; private set; }

        private string _status = "";
        public string Status
        {
            get => _status;
            private set
            {
                _status = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
            }
        }

        public void Show(string status, BatchItemResult? result = null)
        {
            Result = result;
            Status = status;
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        public override string ToString() => $"{Name}{(Status.Length > 0 ? $": {Status}" : "")}"; // what a screen reader says
    }

    private static BatchWindow? _open;

    private readonly MainWindow _host;
    private readonly ObservableCollection<FileRow> _files = [];
    private readonly List<BatchStep> _steps = [];
    private readonly HashSet<string> _listed = new(StringComparer.OrdinalIgnoreCase);

    private readonly ListView _fileList = new() { SelectionMode = SelectionMode.Extended, AllowDrop = true };
    private readonly TextBlock _fileCount = new() { Style = Caption, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 0, 1) };
    private readonly ListBox _stepList = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly CheckBox _recursive = new() { Content = "Include subfolders", Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBox _folder = new();
    private readonly TextBox _template = new();
    private readonly CheckBox _neverOverwrite = new() { Content = "Never overwrite (add a number to a taken name)", Margin = new Thickness(0, 8, 16, 0) };
    private readonly CheckBox _keepSubfolders = new() { Content = "Keep subfolders", Margin = new Thickness(0, 8, 0, 0) };
    private readonly ComboBox _signed = new() { ItemsSource = new[] { "Leave them as they are", "Change them too (signatures may stop verifying)" } };
    private readonly ComboBox _passwords = new() { ItemsSource = new[] { "Ask for each one", "Skip them" } };
    private readonly ComboBox _imageSize = new() { ItemsSource = new[] { "The size of the image", "Letter", "A4" } };
    private readonly ProgressBar _progress = new() { Height = 4, Maximum = 1, Margin = new Thickness(0, 0, 0, 6) };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _start = new() { Content = "Start", MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
    private readonly Button _stop = new() { Content = "Stop", MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), Visibility = Visibility.Collapsed };
    private readonly Button _openFolder = new() { Content = "Open Folder", MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsEnabled = false };
    private readonly Button _close = new() { Content = "Close", MinWidth = 104, IsCancel = true };
    private readonly List<UIElement> _editors = [];
    private readonly ComboBox _preset = new() { MinWidth = 220 };
    private List<(string Name, string Path)> _presets = [];
    private bool _showingPresets;

    private CancellationTokenSource? _cts;
    private Task<BatchSummary>? _run;
    private bool _skipPasswords;
    private bool _closeWhenDone;

    /// <summary>The last finished batch (for the dev script).</summary>
    internal BatchSummary? LastSummary { get; private set; }

    private static Style Caption => (Style)Application.Current.FindResource("Caption");

    /// <summary>Opens the Batch window (one at a time), with <paramref name="paths"/> listed.</summary>
    /// <param name="modal">False for the dev script, which drives the window while it is open.</param>
    public static BatchWindow Open(MainWindow host, IEnumerable<string>? paths = null, bool modal = true)
    {
        if (_open is { } existing)
        {
            if (paths is not null) existing.AddPaths(paths);
            existing.Activate();
            return existing;
        }
        var w = new BatchWindow(host);
        if (paths is not null) w.AddPaths(paths);
        _open = w;
        w.Closed += (_, _) => _open = null;
        if (modal) w.ShowDialog();
        else w.Show();
        return w;
    }

    private BatchWindow(MainWindow host)
    {
        _host = host;
        Owner = host;
        Title = "Batch";
        Width = 900;
        Height = 840;
        MinWidth = 720;
        MinHeight = 690;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var s = AppSettings.Current;

        // ── Files ──
        var view = new GridView();
        view.Columns.Add(new GridViewColumn { Header = "File", Width = 200, DisplayMemberBinding = new Binding(nameof(FileRow.Name)) });
        view.Columns.Add(new GridViewColumn { Header = "Result", Width = 300, DisplayMemberBinding = new Binding(nameof(FileRow.Status)) });
        view.Columns.Add(new GridViewColumn { Header = "Folder", Width = 220, DisplayMemberBinding = new Binding(nameof(FileRow.Folder)) });
        _fileList.View = view;
        _fileList.ItemsSource = _files;
        AutomationProperties.SetName(_fileList, "Files");
        _fileList.Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped) AddPaths(dropped);
        };
        _fileList.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Delete && IsIdle) RemoveSelectedFiles();
        };
        _fileList.MouseDoubleClick += (_, _) => OpenResult(_fileList.SelectedItem as FileRow);
        _recursive.IsChecked = s.BatchRecursive;

        var fileButtons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        fileButtons.Children.Add(Small("Add Files…", AddFilesDialog));
        fileButtons.Children.Add(Small("Add Folder…", AddFolderDialog));
        fileButtons.Children.Add(Small("Remove", RemoveSelectedFiles));
        fileButtons.Children.Add(Small("Clear", () =>
        {
            _files.Clear();
            _listed.Clear();
            UpdateCounts();
        }));
        var filesHeader = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        filesHeader.Children.Add(new TextBlock { Text = "Files", FontWeight = FontWeights.SemiBold });
        filesHeader.Children.Add(_fileCount);
        var filesPanel = new DockPanel();
        DockPanel.SetDock(filesHeader, Dock.Top);
        filesPanel.Children.Add(filesHeader);
        _recursive.Margin = new Thickness(6, 4, 0, 6);
        _recursive.VerticalAlignment = VerticalAlignment.Center;
        fileButtons.Children.Add(_recursive);
        DockPanel.SetDock(fileButtons, Dock.Bottom);
        filesPanel.Children.Add(fileButtons);
        filesPanel.Children.Add(_fileList);
        _editors.Add(fileButtons);

        // ── Actions ──
        AutomationProperties.SetName(_stepList, "Actions, in order");
        _stepList.MouseDoubleClick += (_, _) => ChangeSelectedStep();
        _stepList.KeyDown += (_, e) =>
        {
            if (!IsIdle) return;
            if (e.Key == Key.Delete) RemoveSelectedStep();
            else if (e.Key == Key.Enter) ChangeSelectedStep();
        };
        var add = Small("Add Action ▾", () => { });
        add.ContextMenu = ActionMenu();
        add.Click += (_, _) =>
        {
            add.ContextMenu.PlacementTarget = add;
            add.ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            add.ContextMenu.IsOpen = true;
        };
        AutomationProperties.SetName(add, "Add action");
        var stepButtons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        stepButtons.Children.Add(add);
        stepButtons.Children.Add(Small("Change…", ChangeSelectedStep));
        stepButtons.Children.Add(Small("Remove", RemoveSelectedStep));
        stepButtons.Children.Add(Glyph("", "Move up", () => MoveSelectedStep(-1)));
        stepButtons.Children.Add(Glyph("", "Move down", () => MoveSelectedStep(1)));
        var stepsHeader = new TextBlock { Text = "Actions, in order", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) };
        var stepsPanel = new DockPanel { Margin = new Thickness(16, 0, 0, 0) };
        DockPanel.SetDock(stepsHeader, Dock.Top);
        stepsPanel.Children.Add(stepsHeader);
        DockPanel.SetDock(stepButtons, Dock.Bottom);
        stepsPanel.Children.Add(stepButtons);
        stepsPanel.Children.Add(_stepList);
        _editors.Add(stepButtons);

        var lists = new Grid { MinHeight = 220 };
        lists.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star) });
        lists.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        Grid.SetColumn(stepsPanel, 1);
        lists.Children.Add(filesPanel);
        lists.Children.Add(stepsPanel);

        // ── Output ──
        _folder.Text = s.BatchFolder;
        _template.Text = string.IsNullOrWhiteSpace(s.BatchTemplate) ? BatchNames.DefaultTemplate : s.BatchTemplate;
        _neverOverwrite.IsChecked = s.BatchNeverOverwrite;
        _keepSubfolders.IsChecked = s.BatchKeepSubfolders;
        _signed.SelectedIndex = 0;
        _passwords.SelectedIndex = 0;
        _imageSize.SelectedIndex = 0;
        AutomationProperties.SetName(_folder, "Save results to");
        AutomationProperties.SetName(_template, "File names");
        AutomationProperties.SetName(_signed, "Signed PDFs");
        AutomationProperties.SetName(_passwords, "PDFs with a password");
        AutomationProperties.SetName(_imageSize, "Images become pages of");
        var browse = Small("Browse…", () =>
        {
            if (PdfFiles.PickFolder(this, "Save the results to", Directory.Exists(_folder.Text) ? _folder.Text : null) is { } f) _folder.Text = f;
        });
        browse.Margin = new Thickness(6, 0, 0, 0);

        var output = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        output.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        output.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        output.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var folderRow = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        folderRow.Children.Add(browse);
        folderRow.Children.Add(_folder);
        var left = new StackPanel();
        left.Children.Add(Label("Save results to"));
        left.Children.Add(folderRow);
        left.Children.Add(Label("File names"));
        left.Children.Add(_template);
        left.Children.Add(new TextBlock { Text = "<<name>> the file's name · <<n>> its number (<<n:3>>: 001) · <<date>> · <<folder>>", Style = Caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        var checks = new WrapPanel();
        checks.Children.Add(_neverOverwrite);
        checks.Children.Add(_keepSubfolders);
        left.Children.Add(checks);
        var right = new StackPanel();
        right.Children.Add(Label("Signed PDFs"));
        right.Children.Add(_signed);
        right.Children.Add(Label("PDFs with a password"));
        right.Children.Add(_passwords);
        right.Children.Add(Label("Images become pages of"));
        right.Children.Add(_imageSize);
        Grid.SetColumn(right, 2);
        output.Children.Add(left);
        output.Children.Add(right);
        _editors.Add(output);

        var progressPanel = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        progressPanel.Children.Add(_progress);
        progressPanel.Children.Add(_status);
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);

        // ── Layout ──
        var body = new Grid { Margin = new Thickness(24, 20, 24, 16) };
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        heading.Children.Add(new TextBlock { Text = "Batch", FontSize = 20, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock
        {
            Text = "The same actions for many files, in the order listed. The originals stay as they are; the results go to the folder below (exports and page images without password protection).",
            Style = Caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        var presetRow = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        presetRow.Children.Add(new TextBlock { Text = "Preset", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 6) });
        AutomationProperties.SetName(_preset, "Preset");
        _preset.Margin = new Thickness(0, 0, 8, 6);
        _preset.SelectionChanged += (_, _) => LoadSelectedPreset();
        presetRow.Children.Add(_preset);
        presetRow.Children.Add(Small("Save Preset…", SavePreset));
        presetRow.Children.Add(Small("Import…", ImportPreset));
        presetRow.Children.Add(Small("Export…", ExportPreset));
        presetRow.Children.Add(Small("Delete", DeletePreset));
        heading.Children.Add(presetRow);
        _editors.Add(presetRow);
        body.Children.Add(heading);
        Grid.SetRow(lists, 1);
        body.Children.Add(lists);
        Grid.SetRow(output, 2);
        body.Children.Add(output);
        Grid.SetRow(progressPanel, 3);
        body.Children.Add(progressPanel);

        _start.SetResourceReference(StyleProperty, "AccentButtonStyle");
        _start.Click += (_, _) => _ = StartAsync();
        _stop.Click += (_, _) => Stop();
        _openFolder.Click += (_, _) =>
        {
            if (Directory.Exists(_folder.Text)) Shell.Open(_folder.Text);
        };
        _close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 16, 24, 16) };
        buttons.Children.Add(_start);
        buttons.Children.Add(_stop);
        buttons.Children.Add(_openFolder);
        buttons.Children.Add(_close);
        var watched = new Button { Content = "Watched Folders…", MinWidth = 104, Margin = new Thickness(24, 16, 0, 16), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
        watched.Click += (_, _) => WatchWindow.Open(_host);
        var bar = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Right);
        bar.Children.Add(buttons);
        bar.Children.Add(watched);
        var footer = new Border { Child = bar, BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(Border.BackgroundProperty, "LayerFillColorDefaultBrush");
        footer.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(body);
        Content = root;

        UpdateCounts();
        RefreshSteps();
        RefreshPresets();
        Closing += OnClosing;
    }

    private bool IsIdle => _run is null;

    private static Button Small(string text, Action onClick)
    {
        var b = new Button { Content = text, Margin = new Thickness(0, 0, 6, 6), Padding = new Thickness(10, 4, 10, 4) };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>An icon button (Segoe Fluent Icons) with its name for screen readers and as a tooltip.</summary>
    private static Button Glyph(string glyph, string name, Action onClick)
    {
        var b = Small(glyph, onClick);
        b.FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("Icons");
        b.ToolTip = name;
        AutomationProperties.SetName(b, name);
        return b;
    }

    private static TextBlock Label(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 4) };

    // ───────────────────────────── files ─────────────────────────────

    public void AddPaths(IEnumerable<string> paths)
    {
        var output = _folder.Text.Trim();
        var found = BatchFiles.Expand(paths, _recursive.IsChecked == true, Directory.Exists(output) ? output : null);
        foreach (var f in found)
            if (_listed.Add(f.Path)) _files.Add(new FileRow(f));
        var ignored = paths.Count(p => File.Exists(p) && !BatchFiles.IsSupported(p));
        UpdateCounts();
        if (ignored > 0) Status($"{(ignored == 1 ? "1 file isn't" : $"{ignored} files aren't")} a PDF or an image, so {(ignored == 1 ? "it was" : "they were")} left out.");
        if (_folder.Text.Length == 0 && found.Count > 0)
            _folder.Text = Path.Combine(Path.GetDirectoryName(found[0].Path) ?? AppSettings.Current.LastFolder, "Batch results");
    }

    private void AddFilesDialog()
    {
        var dlg = new OpenFileDialog
        {
            Title = "Add files",
            Filter = "PDFs and images|*.pdf;*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp;*.gif|PDF files (*.pdf)|*.pdf|Images|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp;*.gif",
            Multiselect = true,
            InitialDirectory = AppSettings.Current.LastFolder,
        };
        if (dlg.ShowDialog(this) == true) AddPaths(dlg.FileNames);
    }

    private void AddFolderDialog()
    {
        if (PdfFiles.PickFolder(this, "Add the PDFs and images in a folder") is { } folder) AddPaths([folder]);
    }

    private void RemoveSelectedFiles()
    {
        foreach (var row in _fileList.SelectedItems.Cast<FileRow>().ToList())
        {
            _files.Remove(row);
            _listed.Remove(row.File.Path);
        }
        UpdateCounts();
    }

    private void UpdateCounts()
    {
        var images = _files.Count(f => f.File.IsImage);
        _fileCount.Text = _files.Count == 0 ? "add PDFs or images, or drag them here"
            : $"{_files.Count:N0} file{(_files.Count == 1 ? "" : "s")}{(images > 0 ? $" ({images:N0} image{(images == 1 ? "" : "s")}, made into PDFs)" : "")}";
    }

    /// <summary>A finished file: open its PDF result in a tab, else show its first result in its folder.</summary>
    private void OpenResult(FileRow? row)
    {
        if (row?.Result is not { Outputs.Count: > 0 } r) return;
        if (r.Outputs.FirstOrDefault(o => o.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) is { } pdf && File.Exists(pdf)) _host.OpenFile(pdf);
        else if (File.Exists(r.Outputs[0])) Shell.ShowInFolder(r.Outputs[0]);
    }

    // ───────────────────────────── actions ─────────────────────────────

    private ContextMenu ActionMenu()
    {
        var menu = new ContextMenu();
        void Item(string header, Func<BatchStep?> make, bool enabled = true, string? tip = null)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            if (tip is not null)
            {
                item.ToolTip = tip;
                ToolTipService.SetShowOnDisabled(item, true);
            }
            item.Click += (_, _) =>
            {
                if (make() is not { } step) return;
                _steps.Add(step);
                RefreshSteps(_steps.Count - 1);
            };
            menu.Items.Add(item);
        }
        Item("Reduce File Size…", () => AskOptimize(null));
        Item("Protect with Password…", () => AskProtect());
        Item("Remove Password Protection", () => new UnprotectStep());
        Item("Sanitize…", () => AskSanitize(null));
        Item("Redact Patterns…", () => AskRedactPatterns(null));
        Item("Check Redaction", () => new CheckRedactionStep());
        Item("Check Accessibility (PDF/UA)", () => new CheckAccessibilityStep());
        Item("Add Watermark…", () => PageMarkActions.AskWatermark(this, null) is { } w ? new WatermarkStep(w.Options) : null);
        Item("Add Header, Footer & Bates Numbers…", () => PageMarkActions.AskHeaderFooter(this, null) is { } h ? new HeaderFooterStep(h.Options, h.ContinueBates) : null);
        Item("Rotate Pages…", () => AskRotate(null));
        Item("Flatten…", () => AskFlatten(null));
        var ocr = PageOcr.Engine is not null;
        Item("Recognize Text (OCR)", () => new OcrStep(), ocr, ocr ? null : PageOcr.Unavailable);
        Item("Save as PDF/A-2b", () => new SaveAsPdfAStep());
        menu.Items.Add(new Separator());
        Item("Export to Word (.docx)", () => new ExportStep(BatchExportFormat.Word));
        Item("Export Tables to Excel (.xlsx)", () => new ExportStep(BatchExportFormat.Excel));
        Item("Export as Plain Text (.txt)", () => new ExportStep(BatchExportFormat.Text));
        Item("Export Pages as Images…", () => AskImages(null));
        menu.Items.Add(new Separator());
        Item("Export Comments…", () => AskReview(null, comments: true));
        Item("Summarize Comments", () => new ExportStep(BatchExportFormat.CommentSummary));
        Item("Export Form Data…", () => AskReview(null, comments: false));
        return menu;
    }

    private void RefreshSteps(int select = -1)
    {
        _stepList.Items.Clear();
        for (var i = 0; i < _steps.Count; i++)
        {
            var step = _steps[i];
            var panel = new StackPanel { Margin = new Thickness(0, 3, 0, 3) };
            panel.Children.Add(new TextBlock { Text = $"{i + 1}. {step.Title}", FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            var detail = Describe(step);
            if (detail.Length > 0) panel.Children.Add(new TextBlock { Text = detail, Style = Caption, TextWrapping = TextWrapping.Wrap });
            var item = new ListBoxItem { Content = panel, Tag = step };
            AutomationProperties.SetName(item, $"{i + 1}. {step.Title}{(detail.Length > 0 ? $": {detail}" : "")}");
            _stepList.Items.Add(item);
        }
        if (_steps.Count == 0)
            _stepList.Items.Add(new ListBoxItem
            {
                Content = new TextBlock { Text = "Add Action adds what to do with each file: reduce size, protect, sanitize, redact patterns, check redaction, watermark, header and footer, rotate, flatten, OCR, PDF/A, export. Or choose a saved preset above.", Style = Caption, TextWrapping = TextWrapping.Wrap },
                Focusable = false,
                IsHitTestVisible = false,
            });
        if (select >= 0 && select < _steps.Count) _stepList.SelectedIndex = select;
    }

    private int SelectedStep => _steps.Count > 0 ? _stepList.SelectedIndex : -1;

    private void RemoveSelectedStep()
    {
        if (SelectedStep is not (>= 0 and var i)) return;
        _steps.RemoveAt(i);
        RefreshSteps(Math.Min(i, _steps.Count - 1));
    }

    private void MoveSelectedStep(int delta)
    {
        if (SelectedStep is not (>= 0 and var i) || i + delta < 0 || i + delta >= _steps.Count) return;
        (_steps[i], _steps[i + delta]) = (_steps[i + delta], _steps[i]);
        RefreshSteps(i + delta);
    }

    private void ChangeSelectedStep()
    {
        if (!IsIdle || SelectedStep is not (>= 0 and var i)) return;
        BatchStep? changed = _steps[i] switch
        {
            OptimizeStep o => AskOptimize(o),
            ProtectStep => AskProtect(),
            SanitizeStep s => AskSanitize(s),
            RedactPatternsStep r => AskRedactPatterns(r),
            WatermarkStep w => PageMarkActions.AskWatermark(this, null, w.Options) is { } x ? new WatermarkStep(x.Options) : null,
            HeaderFooterStep h => PageMarkActions.AskHeaderFooter(this, null, h.Options, h.ContinueBates) is { } y ? new HeaderFooterStep(y.Options, y.ContinueBates) : null,
            RotateStep r => AskRotate(r),
            FlattenStep f => AskFlatten(f),
            ExportStep { IsImages: true } e => AskImages(e),
            ExportStep { IsReview: true, Format: not BatchExportFormat.CommentSummary } e =>
                AskReview(e, comments: e.Format is BatchExportFormat.CommentsXfdf or BatchExportFormat.CommentsFdf or BatchExportFormat.CommentsCsv),
            _ => null, // nothing to set
        };
        if (changed is null) return;
        _steps[i] = changed;
        RefreshSteps(i);
    }

    private OptimizeStep? AskOptimize(OptimizeStep? current)
    {
        var o = current?.Options ?? new OptimizeOptions();
        var dlg = new FormDialog(this, "Reduce File Size", "OK", 480);
        dlg.AddNote("Each file is rewritten in a compact form. A file that would shrink by less than 1% is left as it was.");
        var qualities = FileTools.Qualities;
        var quality = dlg.AddChoice("Image quality", qualities.Select(q => q.Name), Math.Max(0, Array.FindIndex(qualities, q => q.Dpi == o.MaxImageDpi)));
        dlg.Add("Also", new StackPanel());
        var thumbs = dlg.AddCheck("Remove embedded page thumbnails", o.RemoveThumbnails);
        var pieces = dlg.AddCheck("Remove other apps' private editing data", o.RemovePieceInfo);
        var dedupe = dlg.AddCheck("Store identical images and fonts once", o.DeduplicateStreams);
        var metadata = dlg.AddCheck("Remove XMP metadata (title, author and subject stay)", o.RemoveMetadata);
        if (!dlg.ShowModal()) return null;
        var q = qualities[Math.Max(0, quality.SelectedIndex)];
        return new OptimizeStep(o with
        {
            MaxImageDpi = q.Dpi,
            JpegQuality = q.Quality,
            RemoveThumbnails = thumbs.IsChecked == true,
            RemovePieceInfo = pieces.IsChecked == true,
            DeduplicateStreams = dedupe.IsChecked == true,
            RemoveMetadata = metadata.IsChecked == true,
        });
    }

    private ProtectStep? AskProtect() =>
        SecurityActions.AskProtection(this, "Protect with Password", "OK", null,
                "Each file is encrypted with these passwords. Keep them somewhere safe: a forgotten open password can't be recovered. Files that are already protected need their permissions password (asked for each file).")
            is { } c
            ? new ProtectStep(c.UserPassword, c.OwnerPassword, c.Permissions, c.Method)
            : null;

    private SanitizeStep? AskSanitize(SanitizeStep? current)
    {
        var dlg = new FormDialog(this, "Sanitize", "OK", 540);
        dlg.AddNote("Removes what each file carries besides its pages, and rewrites it as a single version (earlier versions and unused objects go too).");
        var checks = new List<(SanitizeItem Item, CheckBox Box)>();
        foreach (var (item, label, group) in SanitizeActions.Kinds)
        {
            var on = current?.Items.Contains(item) ?? item != SanitizeItem.Signatures;
            var box = new CheckBox { Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap }, IsChecked = on };
            AutomationProperties.SetName(box, label);
            dlg.Add(group, box, top: 14);
            checks.Add((item, box));
        }
        dlg.AddNote("Removing digital signatures takes the signers' names and certificates out. Signed files are only changed when \"Signed PDFs\" says so: sanitizing rewrites them, so their signatures stop verifying either way.");
        dlg.Validate(() => checks.Any(c => c.Box.IsChecked == true) ? null : "Choose what to remove.");
        if (!dlg.ShowModal()) return null;
        return new SanitizeStep(checks.Where(c => c.Box.IsChecked == true).Select(c => c.Item).ToHashSet());
    }

    private RedactPatternsStep? AskRedactPatterns(RedactPatternsStep? current) =>
        RedactPatternActions.Ask(this, current?.Options ?? new RedactionPatternOptions(), null) is { } o ? new RedactPatternsStep(o) : null;

    private RotateStep? AskRotate(RotateStep? current)
    {
        int[] degrees = [90, -90, 180];
        var dlg = new FormDialog(this, "Rotate Pages", "OK");
        var dir = dlg.AddChoice("Every page of each file", ["90° clockwise", "90° counterclockwise", "180°"], Math.Max(0, Array.IndexOf(degrees, current?.Degrees ?? 90)));
        return dlg.ShowModal() ? new RotateStep(degrees[Math.Max(0, dir.SelectedIndex)]) : null;
    }

    private FlattenStep? AskFlatten(FlattenStep? current)
    {
        var o = current?.Options ?? new FlattenOptions();
        var dlg = new FormDialog(this, "Flatten", "OK", 460);
        dlg.AddNote("Draws comments and filled-in fields into the pages as they look. They can't be edited, replied to or filled in afterwards.");
        var comments = dlg.AddCheck("Comments, markup and stamps", o.Annotations);
        var fields = dlg.AddCheck("Form fields (signature fields stay)", o.FormFields);
        var printable = dlg.AddCheck("Only what prints (drop the rest)", o.PrintableOnly);
        dlg.Validate(() => comments.IsChecked != true && fields.IsChecked != true ? "Choose what to flatten." : null);
        if (!dlg.ShowModal()) return null;
        return new FlattenStep(o with { Annotations = comments.IsChecked == true, FormFields = fields.IsChecked == true, PrintableOnly = printable.IsChecked == true });
    }

    private ExportStep? AskImages(ExportStep? current)
    {
        int[] dpis = [72, 96, 150, 200, 300, 600];
        var dlg = new FormDialog(this, "Export Pages as Images", "OK");
        dlg.AddNote("One image per page, named \"<file> - page 1\" and so on. Very large pages are made at a lower resolution.");
        var format = dlg.AddChoice("Format", ["PNG (lossless)", "JPEG (smaller)"], current?.Format == BatchExportFormat.Jpeg ? 1 : 0);
        var dpi = dlg.AddChoice("Resolution", dpis.Select(d => $"{d} dpi"), Math.Max(0, Array.IndexOf(dpis, current?.Dpi ?? 150)));
        if (!dlg.ShowModal()) return null;
        return new ExportStep(format.SelectedIndex == 1 ? BatchExportFormat.Jpeg : BatchExportFormat.Png, dpis[Math.Max(0, dpi.SelectedIndex)]);
    }

    private ExportStep? AskReview(ExportStep? current, bool comments)
    {
        BatchExportFormat[] formats = comments
            ? [BatchExportFormat.CommentsXfdf, BatchExportFormat.CommentsFdf, BatchExportFormat.CommentsCsv]
            : [BatchExportFormat.FormDataXfdf, BatchExportFormat.FormDataFdf, BatchExportFormat.FormDataCsv, BatchExportFormat.FormDataJson];
        string[] labels = comments
            ? ["XFDF (Acrobat and other PDF apps)", "FDF (keeps every appearance)", "CSV (a row per comment, for spreadsheets)"]
            : ["XFDF (Acrobat and other PDF apps)", "FDF", "CSV (a header and a row of values)", "JSON"];
        var dlg = new FormDialog(this, comments ? "Export Comments" : "Export Form Data", "OK");
        dlg.AddNote(comments
            ? "A file beside each result with its comments; a PDF without comments gets none."
            : "A file beside each result with its form's values; a PDF without a form gets none.");
        var format = dlg.AddChoice("Format", labels, Math.Max(0, Array.IndexOf(formats, current?.Format ?? formats[0])));
        if (!dlg.ShowModal()) return null;
        return new ExportStep(formats[Math.Max(0, format.SelectedIndex)]);
    }

    /// <summary>The line under an action's name.</summary>
    internal static string Describe(BatchStep step)
    {
        switch (step)
        {
            case OptimizeStep o:
                var q = FileTools.Qualities.FirstOrDefault(x => x.Dpi == o.Options.MaxImageDpi).Name ?? "";
                return q + (o.Options.RemoveMetadata ? "; XMP metadata removed" : "");
            case ProtectStep { NeedsPasswords: true }:
                return "Its passwords aren't in the preset: Change… to type them";
            case ProtectStep p:
                var parts = new List<string>();
                if (!string.IsNullOrEmpty(p.UserPassword)) parts.Add("needs a password to open");
                if (!p.Permissions.IsUnrestricted) parts.Add("restricted");
                parts.Add(p.Method == EncryptionMethod.Aes128 ? "AES-128" : "AES-256");
                return string.Join(" · ", parts);
            case UnprotectStep:
                return "Each file's permissions password is asked for";
            case SanitizeStep s:
                return s.Items.Count == SanitizeActions.Kinds.Length ? "Everything, signatures too"
                    : s.Items.Count == SanitizeActions.Kinds.Length - 1 && !s.Items.Contains(SanitizeItem.Signatures) ? "Everything but signatures"
                    : $"{s.Items.Count} of {SanitizeActions.Kinds.Length} kinds of hidden data";
            case RedactPatternsStep r:
                return RedactPatternActions.Describe(r.Options);
            case CheckRedactionStep:
                return "A file with anything recoverable left (text under boxes, leftovers of what was redacted) fails and isn't saved";
            case CheckAccessibilityStep:
                return "PDF/UA-1 machine checks (Matterhorn Protocol); a report (.html) beside each file; a file that fails any isn't saved";
            case WatermarkStep w:
                var what = w.Options.Image is not null ? "A picture" : $"\"{w.Options.Text}\"";
                return $"{what}, {w.Options.Opacity:P0} opaque, {(w.Options.Layout == WatermarkLayout.Tiled ? "tiled" : "centered")}{(w.Options.Behind ? ", behind the content" : "")}";
            case HeaderFooterStep h:
                var texts = Enum.GetValues<HeaderFooterSlot>().Select(h.Options.Text).Where(t => !string.IsNullOrWhiteSpace(t)).ToList();
                var line = string.Join(" · ", texts);
                if (line.Length > 80) line = line[..80] + "…";
                if (h.Options.Bates is { } b) line += $"; Bates from {b.Format(0)}{(h.ContinueBates ? ", continued across files" : ", in each file")}";
                return line;
            case RotateStep r:
                return r.Degrees switch { 90 => "90° clockwise", -90 or 270 => "90° counterclockwise", _ => "180°" };
            case FlattenStep f:
                var kinds = new List<string>();
                if (f.Options.Annotations) kinds.Add("comments");
                if (f.Options.FormFields) kinds.Add("form fields");
                return string.Join(" and ", kinds) is { Length: > 0 } k ? char.ToUpperInvariant(k[0]) + k[1..] + (f.Options.PrintableOnly ? ", only what prints" : "") : "";
            case SaveAsPdfAStep:
                return "An archival copy (ISO 19005-2, level B); a file that can't be made one fails, saying why";
            case OcrStep:
                return PageOcr.Engine is { } e ? $"Pages without text, with Windows' {e.RecognizerLanguage.DisplayName} recognizer" : PageOcr.Unavailable;
            case ExportStep x:
                return x.Format switch
                {
                    BatchExportFormat.Word => "A .docx beside each result",
                    BatchExportFormat.Excel => "The tables found, as an .xlsx (none found: no file)",
                    BatchExportFormat.Text => "A .txt beside each result",
                    BatchExportFormat.CommentsXfdf => "An .xfdf beside each result (none without comments)",
                    BatchExportFormat.CommentsFdf => "An .fdf beside each result (none without comments)",
                    BatchExportFormat.CommentsCsv => "A comments .csv beside each result (none without comments)",
                    BatchExportFormat.CommentSummary => "A PDF of each page beside its comments, numbered and connected",
                    BatchExportFormat.FormDataXfdf => "An .xfdf of the form's values beside each result",
                    BatchExportFormat.FormDataFdf => "An .fdf of the form's values beside each result",
                    BatchExportFormat.FormDataCsv => "A data .csv of the form's values beside each result",
                    BatchExportFormat.FormDataJson => "A .json of the form's values beside each result",
                    _ => $"{(x.Format == BatchExportFormat.Png ? "PNG" : "JPEG")}, {x.Dpi} dpi, one file per page",
                };
            default:
                return "";
        }
    }

    // ───────────────────────────── presets ─────────────────────────────

    private void RefreshPresets(string? select = null)
    {
        _showingPresets = true;
        _presets = PresetLibrary.List();
        _preset.ItemsSource = _presets.Select(p => p.Name).ToList();
        _preset.SelectedIndex = select is null ? -1 : _presets.FindIndex(p => string.Equals(p.Path, select, StringComparison.OrdinalIgnoreCase));
        _showingPresets = false;
    }

    private (string Name, string Path)? SelectedPreset => _preset.SelectedIndex >= 0 && _preset.SelectedIndex < _presets.Count ? _presets[_preset.SelectedIndex] : null;

    private void LoadSelectedPreset()
    {
        if (_showingPresets || SelectedPreset is not { } chosen) return;
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        try
        {
            ShowPreset(BatchPresets.Load(chosen.Path));
        }
        catch (BatchPresetException ex)
        {
            Status(ex.Message, error: true);
        }
    }

    /// <summary>The window takes a preset's actions and choices (and its results folder, when it has one).</summary>
    private void ShowPreset(BatchPreset preset)
    {
        _steps.Clear();
        _steps.AddRange(preset.Steps);
        RefreshSteps(0);
        if (preset.OutputFolder is { } folder) _folder.Text = folder;
        _template.Text = preset.NameTemplate;
        _neverOverwrite.IsChecked = preset.NeverOverwrite;
        _keepSubfolders.IsChecked = preset.KeepSubfolders;
        _signed.SelectedIndex = preset.SignedFiles == SignedFilePolicy.Edit ? 1 : 0;
        _passwords.SelectedIndex = preset.Passwords == PasswordPolicy.Skip ? 1 : 0;
        _imageSize.SelectedIndex = preset.ImagePageSize switch { PageSizeOption.Letter => 1, PageSizeOption.A4 => 2, _ => 0 };
        Status($"\"{preset.Name}\": {preset.Steps.Count} action{(preset.Steps.Count == 1 ? "" : "s")}." +
               (preset.Steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords) ? " Protect with a password needs its passwords (presets don't keep them): choose it, then Change…" : ""));
    }

    private void SavePreset()
    {
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        if (_steps.Count == 0)
        {
            Status("Add the actions first, then save them as a preset.", error: true);
            return;
        }
        var dlg = new FormDialog(this, "Save Preset", "Save", 480);
        var name = dlg.AddText("Name", SelectedPreset?.Name ?? "");
        var keepFolder = dlg.AddCheck("Keep the results folder in the preset", _folder.Text.Trim().Length > 0);
        dlg.AddNote("The actions in order with their settings, the file names and the choices below. Passwords are never saved: they are asked for when the preset runs.");
        dlg.Validate(() => string.IsNullOrWhiteSpace(name.Text) ? "Name the preset." : null);
        if (!dlg.ShowModal()) return;
        var path = PresetLibrary.PathFor(name.Text.Trim());
        if (File.Exists(path) && !string.Equals(path, SelectedPreset?.Path, StringComparison.OrdinalIgnoreCase)
                              && !Prompt.Confirm(this, "Replace the preset?", $"There is a preset named \"{name.Text.Trim()}\" already.", "Replace"))
            return;
        try
        {
            RefreshPresets(PresetLibrary.Save(BatchPreset.From(name.Text.Trim(), Plan(), keepFolder.IsChecked == true)));
            Status($"Preset \"{name.Text.Trim()}\" saved. Watched Folders can run it; Export… writes a copy for the command line or another PC.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status($"The preset couldn't be saved: {ex.Message}", error: true);
        }
    }

    private void ImportPreset()
    {
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        var dlg = new OpenFileDialog { Title = "Import a batch preset", Filter = "Batch presets (*.json)|*.json", InitialDirectory = AppSettings.Current.LastFolder };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            var preset = BatchPresets.Load(dlg.FileName);
            var path = PresetLibrary.PathFor(preset.Name);
            if (File.Exists(path) && !Prompt.Confirm(this, "Replace the preset?", $"There is a preset named \"{preset.Name}\" already.", "Replace")) return;
            RefreshPresets(PresetLibrary.Save(preset));
            ShowPreset(preset);
        }
        catch (Exception ex) when (ex is BatchPresetException or IOException or UnauthorizedAccessException)
        {
            Status(ex.Message, error: true);
        }
    }

    /// <summary>The window's actions and choices (results folder included) as a preset file anywhere: to share, or for the command line.</summary>
    private void ExportPreset()
    {
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        if (_steps.Count == 0)
        {
            Status("Add the actions first (or choose a preset), then export them.", error: true);
            return;
        }
        var name = SelectedPreset?.Name ?? "Batch preset";
        var dlg = new SaveFileDialog { Title = "Export the batch preset", Filter = "Batch presets (*.json)|*.json", FileName = BatchPresets.FileName(name) };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            BatchPresets.Save(BatchPreset.From(name, Plan(), keepFolder: true), dlg.FileName);
            Status($"Exported to {dlg.FileName}. Run it with: inkvoltpdf --batch \"{dlg.FileName}\" <files or folders>");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status($"The preset couldn't be exported: {ex.Message}", error: true);
        }
    }

    private void DeletePreset()
    {
        if (SelectedPreset is not { } chosen
            || !Prompt.Confirm(this, "Delete the preset?", $"\"{chosen.Name}\" is removed from this PC. A watched folder using it stops at its next start.", "Delete"))
            return;
        try
        {
            File.Delete(chosen.Path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status($"The preset couldn't be deleted: {ex.Message}", error: true);
        }
        RefreshPresets();
    }

    // ───────────────────────────── running ─────────────────────────────

    /// <summary>The plan from the window's settings (not yet checked).</summary>
    private BatchPlan Plan() => new()
    {
        Steps = [.. _steps],
        OutputFolder = _folder.Text.Trim().Trim('"'),
        NameTemplate = _template.Text,
        NeverOverwrite = _neverOverwrite.IsChecked == true,
        KeepSubfolders = _keepSubfolders.IsChecked == true,
        SignedFiles = _signed.SelectedIndex == 1 ? SignedFilePolicy.Edit : SignedFilePolicy.Skip,
        Passwords = _passwords.SelectedIndex == 1 ? PasswordPolicy.Skip : PasswordPolicy.Ask,
        ImagePageSize = _imageSize.SelectedIndex switch { 1 => PageSizeOption.Letter, 2 => PageSizeOption.A4, _ => PageSizeOption.FitImage },
        Date = DateTime.Now,
    };

    private void Status(string text, bool error = false)
    {
        _status.Text = text;
        if (error) _status.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
        else _status.ClearValue(TextBlock.ForegroundProperty);
        AiActions.Announce(_status, text);
    }

    public async Task StartAsync()
    {
        if (!IsIdle) return;
        if (_files.Count == 0)
        {
            Status("Add the files first (Add Files, Add Folder, or drag them into the list).", error: true);
            return;
        }
        var plan = Plan();
        var ocr = PageOcr.Engine;
        if (plan.Validate(ocr is not null) is { } error)
        {
            Status(error, error: true);
            return;
        }
        try
        {
            Directory.CreateDirectory(plan.OutputFolder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            Status($"The results can't be saved there: {ex.Message}", error: true);
            return;
        }
        var s = AppSettings.Current;
        s.BatchFolder = plan.OutputFolder;
        s.BatchTemplate = plan.NameTemplate;
        s.BatchNeverOverwrite = plan.NeverOverwrite;
        s.BatchKeepSubfolders = plan.KeepSubfolders;
        s.BatchRecursive = _recursive.IsChecked == true;
        s.Save();

        var rows = _files.ToList();
        foreach (var r in rows) r.Show("Waiting");
        var fractions = new double[rows.Count];
        var finished = 0;
        _skipPasswords = false;
        _cts = new CancellationTokenSource();
        SetRunning(true);
        using var taskbar = new TaskbarProgress(this);
        Status($"Working on {Files(rows.Count)}…");
        Log.Write($"Batch: {rows.Count} file(s); {string.Join(", ", plan.Steps.Select(x => x.Title))}; to {Log.Name(plan.OutputFolder)}");

        var ocrGate = new Lock();
        var host = new BatchHost
        {
            AskPassword = AskPasswordAsync,
            // Windows' recognizer, one page at a time (the engine is shared by the files running together).
            Recognize = ocr is null ? null : (engine, page, cancel) =>
            {
                lock (ocrGate) return PageOcr.Recognize(ocr, engine, page, cancel);
            },
        };
        var progress = new Progress<BatchProgress>(p =>
        {
            if (p.Index < 0 || p.Index >= rows.Count) return;
            var row = rows[p.Index];
            if (p.Result is { } result)
            {
                row.Show(RowText(result), result);
                if (result.State != BatchItemState.Done) Log.Write($"Batch: {Log.Name(result.File.Path)}: {result.State}: {result.Message}");
                fractions[p.Index] = 1;
                finished++;
            }
            else
            {
                row.Show(p.Message);
                fractions[p.Index] = Math.Clamp(p.Fraction, 0, 0.99);
            }
            var overall = fractions.Sum() / rows.Count;
            _progress.Value = overall;
            taskbar.Report(overall);
            if (_cts is { IsCancellationRequested: false }) _status.Text = $"Working: {finished:N0} of {Files(rows.Count)} finished…";
        });

        BatchSummary? summary = null;
        try
        {
            _run = BatchRunner.RunAsync([.. rows.Select(r => r.File)], plan, host, progress, _cts.Token);
            summary = await _run;
        }
        catch (Exception ex)
        {
            Log.Write($"Batch failed: {ex}");
            Status($"The batch stopped: {ex.Message}", error: true);
        }
        finally
        {
            _run = null;
            _cts.Dispose();
            _cts = null;
            SetRunning(false);
        }
        if (summary is null) return;
        await Task.Yield(); // let the last progress reports land
        LastSummary = summary;
        foreach (var (row, result) in rows.Zip(summary.Items))
            if (row.Result is null) row.Show(RowText(result), result);
        _progress.Value = 1;
        var written = summary.Items.Sum(i => i.Outputs.Count);
        Status($"{summary.Text} {(written == 1 ? "1 file" : $"{written:N0} files")} saved in {plan.OutputFolder}." +
               (summary.Failed + summary.Skipped > 0 ? " The list says why for each file not done." : "") +
               (written > 0 ? " Double-click a file to open its result." : ""), error: summary.Failed > 0);
        _openFolder.IsEnabled = written > 0;
        _start.Content = "Run Again";
        Log.Write($"Batch: {summary.Text}");
        if (_closeWhenDone) Close();
    }

    private static string RowText(BatchItemResult r)
    {
        var text = r.State switch
        {
            BatchItemState.Done => r.Outputs.Count switch
            {
                0 => "Done: nothing to save",
                1 => $"Done: {Path.GetFileName(r.Outputs[0])}",
                _ => $"Done: {r.Outputs.Count} files",
            },
            BatchItemState.Skipped => $"Skipped: {r.Message}",
            BatchItemState.Failed => $"Failed: {r.Message}",
            BatchItemState.Cancelled => "Cancelled",
            _ => r.Message,
        };
        return r.Notes.Count > 0 ? $"{text} ({string.Join("; ", r.Notes)})" : text;
    }

    private static string Files(int n) => n == 1 ? "1 file" : $"{n:N0} files";

    private void SetRunning(bool running)
    {
        foreach (var e in _editors) e.IsEnabled = !running;
        _fileList.AllowDrop = !running;
        _stepList.IsEnabled = !running;
        _start.Visibility = running ? Visibility.Collapsed : Visibility.Visible;
        _stop.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        _stop.IsEnabled = running;
        if (running)
        {
            _openFolder.IsEnabled = false;
            _progress.Value = 0;
        }
    }

    private void Stop()
    {
        if (_cts is not { IsCancellationRequested: false } cts) return;
        cts.Cancel();
        _stop.IsEnabled = false;
        Status("Stopping: the files being worked on finish their current action…");
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (IsIdle) return;
        e.Cancel = true;
        if (!Prompt.Confirm(this, "Stop the batch?", "Files not finished yet are left out. Results already saved stay.", "Stop")) return;
        _closeWhenDone = true;
        Stop();
    }

    /// <summary>A file's password, asked on the UI thread (the runner asks one at a time). Null skips the file.</summary>
    private async Task<string?> AskPasswordAsync(BatchPasswordRequest request, CancellationToken cancel)
    {
        if (DevScript.TakeBatchPassword(out var scripted)) return scripted;
        return await Dispatcher.InvokeAsync(() =>
        {
            if (_skipPasswords || cancel.IsCancellationRequested) return null;
            var name = Path.GetFileName(request.File.Path);
            var (title, text, ok) = request.Kind switch
            {
                BatchPasswordKind.Open => ("Password required", $"\"{name}\" is protected. Enter its password to work on it.", "Continue"),
                BatchPasswordKind.Permissions => ("Permissions password required", $"\"{name}\" is restricted: its author's permissions password is needed to change it.", "Continue"),
                _ => ("Open password required", $"\"{name}\" needs its open password too, so the result can keep it.", "Continue"),
            };
            var dlg = new FormDialog(this, title, ok);
            if (request.Wrong) dlg.AddNote("That password is incorrect. Try again.");
            dlg.AddNote(text);
            var box = dlg.Add("Password", new PasswordBox());
            AutomationProperties.SetName(box, "Password");
            var skipRest = dlg.AddCheck("Skip the other files that need a password");
            dlg.AddNote("Cancel skips this file; the batch goes on.");
            dlg.Loaded += (_, _) => box.Focus();
            var given = dlg.ShowModal() ? box.Password : null;
            if (skipRest.IsChecked == true) _skipPasswords = true;
            return given is { Length: > 0 } ? given : null;
        }).Task;
    }

    // ───────────────────────────── dev script ─────────────────────────────

    /// <summary><c>batchstep</c>: an action from words (no dialog).</summary>
    internal void DevAddStep(string spec)
    {
        var a = spec.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        var rest = a.Length > 1 ? a[1] : "";
        BatchStep step = a[0].ToLowerInvariant() switch
        {
            "optimize" => new OptimizeStep(new OptimizeOptions()),
            "protect" => new ProtectStep(rest.Split(' ')[0], rest.Split(' ').ElementAtOrDefault(1), PdfPermissions.All),
            "unprotect" => new UnprotectStep(),
            "sanitize" => new SanitizeStep(SanitizeActions.Kinds.Select(k => k.Item).Where(i => i != SanitizeItem.Signatures).ToHashSet()),
            "redactpatterns" => new RedactPatternsStep(new RedactionPatternOptions { Phrases = rest.Length > 0 ? [rest] : [] }),
            "checkredaction" => new CheckRedactionStep(),
            "checkaccessibility" => new CheckAccessibilityStep(),
            "watermark" => new WatermarkStep(new WatermarkOptions { Text = rest.Length > 0 ? rest : "DRAFT" }),
            "footer" => new HeaderFooterStep(new HeaderFooterOptions { FooterCenter = rest.Length > 0 ? rest : "Page <<page>> of <<pages>>" }),
            "bates" => new HeaderFooterStep(new HeaderFooterOptions { FooterRight = "<<bates>>", Bates = new BatesFormat(rest.Split(' ')[0], 1, 6) }, rest.Contains("continue")),
            "rotate" => new RotateStep(int.TryParse(rest, out var d) ? d : 90),
            "flatten" => new FlattenStep(new FlattenOptions()),
            "ocr" => new OcrStep(),
            "pdfa" => new SaveAsPdfAStep(),
            "export" => new ExportStep(rest.ToLowerInvariant() switch
            {
                "word" => BatchExportFormat.Word,
                "excel" => BatchExportFormat.Excel,
                "png" => BatchExportFormat.Png,
                "jpeg" or "jpg" => BatchExportFormat.Jpeg,
                "xfdf" => BatchExportFormat.CommentsXfdf,
                "summary" => BatchExportFormat.CommentSummary,
                "formcsv" => BatchExportFormat.FormDataCsv,
                _ => BatchExportFormat.Text,
            }, 72),
            _ => throw new ArgumentException($"unknown batch step {a[0]}"),
        };
        _steps.Add(step);
        RefreshSteps(_steps.Count - 1);
    }

    /// <summary><c>batchask</c>: opens an action's settings dialog (the script snapshots and closes it).</summary>
    internal void DevAsk(string kind)
    {
        BatchStep? step = kind switch
        {
            "optimize" => AskOptimize(null),
            "protect" => AskProtect(),
            "sanitize" => AskSanitize(null),
            "redactpatterns" => AskRedactPatterns(null),
            "watermark" => PageMarkActions.AskWatermark(this, null) is { } w ? new WatermarkStep(w.Options) : null,
            "headerfooter" => PageMarkActions.AskHeaderFooter(this, null) is { } h ? new HeaderFooterStep(h.Options, h.ContinueBates) : null,
            "rotate" => AskRotate(null),
            "flatten" => AskFlatten(null),
            "images" => AskImages(null),
            _ => null,
        };
        if (step is null) return;
        _steps.Add(step);
        RefreshSteps(_steps.Count - 1);
    }

    /// <summary><c>batchout folder [template]</c> and <c>batchoption signed=edit passwords=skip overwrite=on|off subfolders=on|off</c>.</summary>
    internal void DevOutput(string folder, string? template)
    {
        _folder.Text = folder;
        if (template is not null) _template.Text = template;
    }

    internal void DevOption(string name, string value)
    {
        switch (name)
        {
            case "signed": _signed.SelectedIndex = value == "edit" ? 1 : 0; break;
            case "passwords": _passwords.SelectedIndex = value == "skip" ? 1 : 0; break;
            case "overwrite": _neverOverwrite.IsChecked = value != "on"; break;
            case "subfolders": _keepSubfolders.IsChecked = value == "on"; break;
            case "recursive": _recursive.IsChecked = value == "on"; break;
            case "images": _imageSize.SelectedIndex = value switch { "letter" => 1, "a4" => 2, _ => 0 }; break;
        }
    }

    /// <summary><c>presetsave name</c> and <c>presetload name</c>: a preset saved or chosen without the dialogs.</summary>
    internal void DevSavePreset(string name) => RefreshPresets(PresetLibrary.Save(BatchPreset.From(name, Plan(), keepFolder: true)));

    internal void DevLoadPreset(string name)
    {
        RefreshPresets();
        _preset.SelectedIndex = _presets.FindIndex(p => p.Name == name);
    }

    internal string DevState() =>
        $"batch: {_files.Count} file(s) [{string.Join(" | ", _files.Select(f => f.ToString()))}]; steps [{string.Join(" | ", _steps.Select(s => $"{s.Title}: {Describe(s)}"))}]; " +
        $"running={!IsIdle} status='{_status.Text}' summary={LastSummary?.Text ?? "-"}";
}
