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
    private readonly CheckBox _recursive = new() { Content = Strings.Batch_IncludeSubfolders, Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBox _folder = new();
    private readonly TextBox _template = new();
    private readonly CheckBox _neverOverwrite = new() { Content = Strings.Batch_NeverOverwrite, Margin = new Thickness(0, 8, 16, 0) };
    private readonly CheckBox _keepSubfolders = new() { Content = Strings.Batch_KeepSubfolders, Margin = new Thickness(0, 8, 0, 0) };
    private readonly ComboBox _signed = new() { ItemsSource = new[] { Strings.Batch_SignedLeave, Strings.Batch_SignedChange } };
    private readonly ComboBox _passwords = new() { ItemsSource = new[] { Strings.Batch_PasswordsAsk, Strings.Batch_PasswordsSkip } };
    private readonly ComboBox _imageSize = new() { ItemsSource = new[] { Strings.Batch_ImageSizeImage, Strings.Convert_PaperLetter, Strings.Convert_PaperA4 } };
    private readonly ProgressBar _progress = new() { Height = 4, Maximum = 1, Margin = new Thickness(0, 0, 0, 6) };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _start = new() { Content = Strings.Batch_Start, MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
    private readonly Button _stop = new() { Content = Strings.Common_Stop, MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), Visibility = Visibility.Collapsed };
    private readonly Button _openFolder = new() { Content = Strings.FormData_OpenFolder, MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsEnabled = false };
    private readonly Button _report = new() { Content = Strings.Batch_RedactionReport, MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), Visibility = Visibility.Collapsed };
    private readonly Button _close = new() { Content = Strings.Common_Close, MinWidth = 104, IsCancel = true };
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
        Title = Strings.Batch_Title;
        Width = 900;
        Height = 840;
        MinWidth = 720;
        MinHeight = 690;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var s = AppSettings.Current;

        // ── Files ──
        var view = new GridView();
        view.Columns.Add(new GridViewColumn { Header = Strings.File_PropFile, Width = 200, DisplayMemberBinding = new Binding(nameof(FileRow.Name)) });
        view.Columns.Add(new GridViewColumn { Header = Strings.Batch_ColResult, Width = 300, DisplayMemberBinding = new Binding(nameof(FileRow.Status)) });
        view.Columns.Add(new GridViewColumn { Header = Strings.Batch_ColFolder, Width = 220, DisplayMemberBinding = new Binding(nameof(FileRow.Folder)) });
        _fileList.View = view;
        _fileList.ItemsSource = _files;
        AutomationProperties.SetName(_fileList, Strings.Batch_Files);
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
        fileButtons.Children.Add(Small(Strings.Dialog_AddFiles, AddFilesDialog));
        fileButtons.Children.Add(Small(Strings.Batch_AddFolder, AddFolderDialog));
        fileButtons.Children.Add(Small(Strings.Common_Remove, RemoveSelectedFiles));
        fileButtons.Children.Add(Small(Strings.Common_Clear, () =>
        {
            _files.Clear();
            _listed.Clear();
            UpdateCounts();
        }));
        var filesHeader = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        filesHeader.Children.Add(new TextBlock { Text = Strings.Batch_Files, FontWeight = FontWeights.SemiBold });
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
        AutomationProperties.SetName(_stepList, Strings.Batch_ActionsInOrder);
        ScrollViewer.SetHorizontalScrollBarVisibility(_stepList, ScrollBarVisibility.Disabled); // so the empty list's hint wraps
        _stepList.MouseDoubleClick += (_, _) => ChangeSelectedStep();
        _stepList.KeyDown += (_, e) =>
        {
            if (!IsIdle) return;
            if (e.Key == Key.Delete) RemoveSelectedStep();
            else if (e.Key == Key.Enter) ChangeSelectedStep();
        };
        var add = Small(Strings.Batch_AddActionMenu, () => { });
        add.ContextMenu = ActionMenu();
        add.Click += (_, _) =>
        {
            add.ContextMenu.PlacementTarget = add;
            add.ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            add.ContextMenu.IsOpen = true;
        };
        AutomationProperties.SetName(add, Strings.Batch_AddAction);
        var stepButtons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        stepButtons.Children.Add(add);
        stepButtons.Children.Add(Small(Strings.Common_Change, ChangeSelectedStep));
        stepButtons.Children.Add(Small(Strings.Common_Remove, RemoveSelectedStep));
        stepButtons.Children.Add(Glyph("", Strings.Batch_MoveUp, () => MoveSelectedStep(-1)));
        stepButtons.Children.Add(Glyph("", Strings.Batch_MoveDown, () => MoveSelectedStep(1)));
        var stepsHeader = new TextBlock { Text = Strings.Batch_ActionsInOrder, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) };
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
        AutomationProperties.SetName(_folder, Strings.Batch_SaveResultsTo);
        AutomationProperties.SetName(_template, Strings.FormData_FileNames);
        AutomationProperties.SetName(_signed, Strings.Batch_SignedPdfs);
        AutomationProperties.SetName(_passwords, Strings.Batch_PasswordPdfs);
        AutomationProperties.SetName(_imageSize, Strings.Batch_ImagesBecome);
        var browse = Small(Strings.Common_Browse, () =>
        {
            if (PdfFiles.PickFolder(this, Strings.Batch_SaveTheResultsTo, Directory.Exists(_folder.Text) ? _folder.Text : null) is { } f) _folder.Text = f;
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
        left.Children.Add(Label(Strings.Batch_SaveResultsTo));
        left.Children.Add(folderRow);
        left.Children.Add(Label(Strings.FormData_FileNames));
        left.Children.Add(_template);
        left.Children.Add(new TextBlock { Text = Strings.Batch_NamePattern, Style = Caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        var checks = new WrapPanel();
        checks.Children.Add(_neverOverwrite);
        checks.Children.Add(_keepSubfolders);
        left.Children.Add(checks);
        var right = new StackPanel();
        right.Children.Add(Label(Strings.Batch_SignedPdfs));
        right.Children.Add(_signed);
        right.Children.Add(Label(Strings.Batch_PasswordPdfs));
        right.Children.Add(_passwords);
        right.Children.Add(Label(Strings.Batch_ImagesBecome));
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
        heading.Children.Add(new TextBlock { Text = Strings.Batch_Title, FontSize = 20, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock
        {
            Text = Strings.Batch_Intro,
            Style = Caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        var presetRow = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        presetRow.Children.Add(new TextBlock { Text = Strings.Batch_Preset, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 6) });
        AutomationProperties.SetName(_preset, Strings.Batch_Preset);
        _preset.Margin = new Thickness(0, 0, 8, 6);
        _preset.SelectionChanged += (_, _) => LoadSelectedPreset();
        presetRow.Children.Add(_preset);
        presetRow.Children.Add(Small(Strings.Batch_SavePreset, SavePreset));
        presetRow.Children.Add(Small(Strings.Batch_Import, ImportPreset));
        presetRow.Children.Add(Small(Strings.Export_ExportButton, ExportPreset));
        presetRow.Children.Add(Small(Strings.Common_Delete, DeletePreset));
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
        _report.Click += (_, _) => ShowRedactionReport();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 16, 24, 16) };
        buttons.Children.Add(_start);
        buttons.Children.Add(_stop);
        buttons.Children.Add(_report);
        buttons.Children.Add(_openFolder);
        buttons.Children.Add(_close);
        var watched = new Button { Content = Strings.Batch_WatchedFoldersButton, MinWidth = 104, Margin = new Thickness(24, 16, 0, 16), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
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
        if (ignored > 0) Status(Loc.Plural(ignored, Strings.Batch_Ignored_One, Strings.Batch_Ignored_Many));
        if (_folder.Text.Length == 0 && found.Count > 0)
            _folder.Text = Path.Combine(Path.GetDirectoryName(found[0].Path) ?? AppSettings.Current.LastFolder, Strings.Batch_ResultsFolder);
    }

    private void AddFilesDialog()
    {
        var dlg = new OpenFileDialog
        {
            Title = Strings.Batch_AddFilesTitle,
            Filter = $"{Strings.Batch_FilterPdfImages}|*.pdf;*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp;*.gif|{Strings.Compare_FilterPdf}|*.pdf|{Strings.Batch_FilterImages}|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp;*.gif",
            Multiselect = true,
            InitialDirectory = AppSettings.Current.LastFolder,
        };
        if (dlg.ShowDialog(this) == true) AddPaths(dlg.FileNames);
    }

    private void AddFolderDialog()
    {
        if (PdfFiles.PickFolder(this, Strings.Batch_AddFolderTitle) is { } folder) AddPaths([folder]);
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
        _fileCount.Text = _files.Count == 0 ? Strings.Batch_FilesEmpty
            : images > 0 ? Loc.Format(Strings.Batch_FilesWithImages, Loc.Plural(_files.Count, Strings.Folder_Files_One, Strings.Folder_Files_Many), Loc.Plural(images, Strings.Batch_Images_One, Strings.Batch_Images_Many)) : Loc.Plural(_files.Count, Strings.Folder_Files_One, Strings.Folder_Files_Many);
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
                if (make() is not { } step || step.Feature is { } pro && !ProGate.Check(this, pro)) return;
                _steps.Add(step);
                RefreshSteps(_steps.Count - 1);
            };
            menu.Items.Add(item);
        }
        Item(Strings.Batch_ItemReduce, () => AskOptimize(null));
        Item(Strings.Batch_ItemProtect, () => AskProtect());
        Item(Strings.Batch_ItemUnprotect, () => new UnprotectStep());
        Item(Strings.Inventory_Sanitize, () => AskSanitize(null));
        Item(Strings.Batch_ItemRedactPatterns, () => AskRedactPatterns(null));
        Item(Strings.Batch_ItemCheckRedaction, () => new CheckRedactionStep());
        Item(Strings.Batch_ItemCheckAccess, () => new CheckAccessibilityStep());
        Item(Strings.Batch_ItemReportContents, () => new ReportContentsStep());
        Item(Strings.Batch_ItemWatermark, () => PageMarkActions.AskWatermark(this, null) is { } w ? new WatermarkStep(w.Options) : null);
        Item(Strings.Batch_ItemHeaderFooter, () => PageMarkActions.AskHeaderFooter(this, null) is { } h ? new HeaderFooterStep(h.Options, h.ContinueBates) : null);
        Item(Strings.Batch_ItemRotate, () => AskRotate(null));
        Item(Strings.Batch_ItemFlatten, () => AskFlatten(null));
        var ocr = PageOcr.Engine is not null;
        Item(Strings.Batch_ItemOcr, () => new OcrStep(), ocr, ocr ? null : PageOcr.Unavailable);
        Item(Strings.Batch_ItemMakeAccessible, () => new MakeAccessibleStep());
        Item(Strings.Batch_ItemPdfA2b, () => new SaveAsPdfAStep());
        Item(Strings.Batch_ItemPdfA2a, () => new SaveAsPdfAStep { Conformance = PdfAConformance.A });
        Item(Strings.Batch_LongTermMenu, () => AskLongTerm(null));
        menu.Items.Add(new Separator());
        Item(Strings.Batch_ItemWord, () => new ExportStep(BatchExportFormat.Word));
        Item(Strings.Batch_ItemExcel, () => new ExportStep(BatchExportFormat.Excel));
        Item(Strings.Batch_ItemText, () => new ExportStep(BatchExportFormat.Text));
        Item(Strings.Batch_ItemPowerPoint, () => new ExportStep(BatchExportFormat.PowerPoint));
        Item(Strings.Batch_ItemHtml, () => new ExportStep(BatchExportFormat.Html));
        Item(Strings.Batch_ItemImages, () => AskImages(null));
        menu.Items.Add(new Separator());
        Item(Strings.Batch_ItemComments, () => AskReview(null, comments: true));
        Item(Strings.Comments_SummarizeTitle, () => new ExportStep(BatchExportFormat.CommentSummary));
        Item(Strings.Batch_ItemFormData, () => AskReview(null, comments: false));
        return menu;
    }

    private void RefreshSteps(int select = -1)
    {
        _stepList.Items.Clear();
        for (var i = 0; i < _steps.Count; i++)
        {
            var step = _steps[i];
            var panel = new StackPanel { Margin = new Thickness(0, 3, 0, 3) };
            panel.Children.Add(new TextBlock { Text = $"{i + 1}. {step.Title}", FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis }); // in every language: only names and values, no words
            var detail = Describe(step);
            if (detail.Length > 0) panel.Children.Add(new TextBlock { Text = detail, Style = Caption, TextWrapping = TextWrapping.Wrap });
            var item = new ListBoxItem { Content = panel, Tag = step };
            AutomationProperties.SetName(item, detail.Length > 0 ? Loc.Format(Strings.Batch_StepNameDetail, i + 1, step.Title, detail) : Loc.Format(Strings.Batch_StepName, i + 1, step.Title));
            _stepList.Items.Add(item);
        }
        if (_steps.Count == 0)
            _stepList.Items.Add(new ListBoxItem
            {
                Content = new TextBlock { Text = Strings.Batch_StepsEmpty, Style = Caption, TextWrapping = TextWrapping.Wrap },
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
            AddLongTermStep l => AskLongTerm(l),
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
        var dlg = new FormDialog(this, Strings.File_ReduceTitle, Strings.Common_OK, 480);
        dlg.AddNote(Strings.Batch_ReduceNote);
        var qualities = FileTools.Qualities;
        var quality = dlg.AddChoice(Strings.File_ImageQuality, qualities.Select(q => q.Name), Math.Max(0, Array.FindIndex(qualities, q => q.Dpi == o.MaxImageDpi)));
        dlg.Add(Strings.File_Also, new StackPanel());
        var thumbs = dlg.AddCheck(Strings.File_RemoveThumbs, o.RemoveThumbnails);
        var pieces = dlg.AddCheck(Strings.File_RemovePieces, o.RemovePieceInfo);
        var dedupe = dlg.AddCheck(Strings.File_Dedupe, o.DeduplicateStreams);
        var metadata = dlg.AddCheck(Strings.File_RemoveMetadata, o.RemoveMetadata);
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
        SecurityActions.AskProtection(this, Strings.Security_ProtectTitle, Strings.Common_OK, null,
                Strings.Batch_ProtectNote)
            is { } c
            ? new ProtectStep(c.UserPassword, c.OwnerPassword, c.Permissions, c.Method)
            : null;

    private SanitizeStep? AskSanitize(SanitizeStep? current)
    {
        var dlg = new FormDialog(this, Strings.Sanitize_Sanitize, Strings.Common_OK, 540);
        dlg.AddNote(Strings.Batch_SanitizeNote);
        var checks = new List<(SanitizeItem Item, CheckBox Box)>();
        foreach (var (item, label, group) in SanitizeActions.Kinds)
        {
            var on = current?.Items.Contains(item) ?? item != SanitizeItem.Signatures;
            var box = new CheckBox { Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap }, IsChecked = on };
            AutomationProperties.SetName(box, label);
            dlg.Add(group, box, top: 14);
            checks.Add((item, box));
        }
        dlg.AddNote(Strings.Batch_SanitizeSignedNote);
        dlg.Validate(() => checks.Any(c => c.Box.IsChecked == true) ? null : Strings.Batch_ChooseRemove);
        if (!dlg.ShowModal()) return null;
        return new SanitizeStep(checks.Where(c => c.Box.IsChecked == true).Select(c => c.Item).ToHashSet());
    }

    private RedactPatternsStep? AskRedactPatterns(RedactPatternsStep? current) =>
        RedactPatternActions.Ask(this, current?.Options ?? new RedactionPatternOptions(), null) is { } o ? new RedactPatternsStep(o) : null;

    private RotateStep? AskRotate(RotateStep? current)
    {
        int[] degrees = [90, -90, 180];
        var dlg = new FormDialog(this, Strings.Batch_RotateTitle, Strings.Common_OK);
        var dir = dlg.AddChoice(Strings.Batch_EveryPage, [Strings.Batch_Clockwise, Strings.Batch_Counterclockwise, "180°"], Math.Max(0, Array.IndexOf(degrees, current?.Degrees ?? 90)));
        return dlg.ShowModal() ? new RotateStep(degrees[Math.Max(0, dir.SelectedIndex)]) : null;
    }

    private FlattenStep? AskFlatten(FlattenStep? current)
    {
        var o = current?.Options ?? new FlattenOptions();
        var dlg = new FormDialog(this, Strings.File_Flatten, Strings.Common_OK, 460);
        dlg.AddNote(Strings.Batch_FlattenNote);
        var comments = dlg.AddCheck(Strings.File_FlattenComments, o.Annotations);
        var fields = dlg.AddCheck(Strings.File_FlattenFields, o.FormFields);
        var printable = dlg.AddCheck(Strings.File_FlattenPrintable, o.PrintableOnly);
        dlg.Validate(() => comments.IsChecked != true && fields.IsChecked != true ? Strings.File_FlattenChoose : null);
        if (!dlg.ShowModal()) return null;
        return new FlattenStep(o with { Annotations = comments.IsChecked == true, FormFields = fields.IsChecked == true, PrintableOnly = printable.IsChecked == true });
    }

    /// <summary>Add long-term validation data: with a document timestamp or not. What it will contact is shown when the batch starts.</summary>
    private AddLongTermStep? AskLongTerm(AddLongTermStep? current)
    {
        var dlg = new FormDialog(this, Strings.Batch_LongTermTitle, "OK", 560);
        dlg.AddNote(Strings.Batch_LongTermNote);
        var stamp = dlg.AddCheck(Strings.Batch_LongTermTimestamp, current?.TimestampUrl is not null);
        var url = dlg.AddText(Strings.Batch_LongTermServer, current?.TimestampUrl ?? SignDialog.ChosenTimestampUrl(AppSettings.Current));
        url.IsEnabled = stamp.IsChecked == true;
        dlg.AddNote(Strings.Batch_LongTermServerNote);
        stamp.Click += (_, _) => url.IsEnabled = stamp.IsChecked == true;
        dlg.Validate(() =>
        {
            if (stamp.IsChecked != true) return null;
            if (url.Text.Trim().Length == 0) return Strings.Batch_LongTermNeedServer;
            return LtvClient.WhyRefused(url.Text.Trim(), LtvAddressKind.Timestamp) is { } why ? Loc.Format(Strings.Batch_LongTermBadServer, why) : null;
        });
        if (!dlg.ShowModal()) return null;
        return new AddLongTermStep(stamp.IsChecked == true ? url.Text.Trim() : null);
    }

    private ExportStep? AskImages(ExportStep? current)
    {
        int[] dpis = [72, 96, 150, 200, 300, 600];
        var dlg = new FormDialog(this, Strings.File_ExportImagesTitle, Strings.Common_OK);
        dlg.AddNote(Strings.Batch_ImagesNote);
        var format = dlg.AddChoice(Strings.File_Format, [Strings.File_FormatPng, Strings.File_FormatJpeg], current?.Format == BatchExportFormat.Jpeg ? 1 : 0);
        var dpi = dlg.AddChoice(Strings.File_Resolution, dpis.Select(d => Loc.Format(Strings.File_Dpi, d)), Math.Max(0, Array.IndexOf(dpis, current?.Dpi ?? 150)));
        if (!dlg.ShowModal()) return null;
        return new ExportStep(format.SelectedIndex == 1 ? BatchExportFormat.Jpeg : BatchExportFormat.Png, dpis[Math.Max(0, dpi.SelectedIndex)]);
    }

    private ExportStep? AskReview(ExportStep? current, bool comments)
    {
        BatchExportFormat[] formats = comments
            ? [BatchExportFormat.CommentsXfdf, BatchExportFormat.CommentsFdf, BatchExportFormat.CommentsCsv]
            : [BatchExportFormat.FormDataXfdf, BatchExportFormat.FormDataFdf, BatchExportFormat.FormDataCsv, BatchExportFormat.FormDataJson];
        string[] labels = comments
            ? [Strings.Batch_FormatXfdf, Strings.Batch_FormatFdfLooks, Strings.Batch_FormatCsvComments]
            : [Strings.Batch_FormatXfdf, "FDF", Strings.Batch_FormatCsvValues, "JSON"];
        var dlg = new FormDialog(this, comments ? Strings.Comments_ExportTitle : Strings.FormData_ExportTitle, Strings.Common_OK);
        dlg.AddNote(comments
            ? Strings.Batch_CommentsNote
            : Strings.Batch_FormDataNote);
        var format = dlg.AddChoice(Strings.File_Format, labels, Math.Max(0, Array.IndexOf(formats, current?.Format ?? formats[0])));
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
                return o.Options.RemoveMetadata ? Loc.Format(Strings.Batch_DescMetadata, q) : q;
            case ProtectStep { NeedsPasswords: true }:
                return Strings.Batch_DescNoPasswords;
            case ProtectStep p:
                var parts = new List<string>();
                if (!string.IsNullOrEmpty(p.UserPassword)) parts.Add(Strings.Security_NeedsOpen);
                if (!p.Permissions.IsUnrestricted) parts.Add(Strings.Batch_DescRestricted);
                parts.Add(p.Method == EncryptionMethod.Aes128 ? "AES-128" : "AES-256");
                return string.Join(" · ", parts);
            case UnprotectStep:
                return Strings.Batch_DescUnprotect;
            case SanitizeStep s:
                return s.Items.Count == SanitizeActions.Kinds.Length ? Strings.Batch_DescEverything
                    : s.Items.Count == SanitizeActions.Kinds.Length - 1 && !s.Items.Contains(SanitizeItem.Signatures) ? Strings.Batch_DescButSignatures
                    : Loc.Format(Strings.Batch_DescKinds, s.Items.Count, SanitizeActions.Kinds.Length);
            case RedactPatternsStep r:
                return RedactPatternActions.Describe(r.Options);
            case CheckRedactionStep:
                return Strings.Batch_DescCheckRedaction;
            case CheckAccessibilityStep:
                return Strings.Batch_DescCheckAccess;
            case ReportContentsStep:
                return Strings.Batch_DescReportContents;
            case WatermarkStep w:
                var what = w.Options.Image is not null ? Strings.Batch_DescPicture : $"\"{w.Options.Text}\"";
                var tiled = w.Options.Layout == WatermarkLayout.Tiled;
                return Loc.Format(w.Options.Behind ? (tiled ? Strings.Batch_DescWmTiledBehind : Strings.Batch_DescWmCenteredBehind) : (tiled ? Strings.Batch_DescWmTiled : Strings.Batch_DescWmCentered), what, w.Options.Opacity);
            case HeaderFooterStep h:
                var texts = Enum.GetValues<HeaderFooterSlot>().Select(h.Options.Text).Where(t => !string.IsNullOrWhiteSpace(t)).ToList();
                var line = string.Join(" · ", texts);
                if (line.Length > 80) line = line[..80] + "…";
                if (h.Options.Bates is { } b) line += Loc.Format(h.ContinueBates ? Strings.Batch_DescBatesContinued : Strings.Batch_DescBatesEach, b.Format(0));
                return line;
            case RotateStep r:
                return r.Degrees switch { 90 => Strings.Batch_Clockwise, -90 or 270 => Strings.Batch_Counterclockwise, _ => "180°" };
            case FlattenStep f:
                var flat = f.Options.Annotations && f.Options.FormFields ? Strings.Batch_DescFlatBoth : f.Options.Annotations ? Strings.Batch_DescFlatComments : f.Options.FormFields ? Strings.Batch_DescFlatFields : "";
                return flat.Length > 0 && f.Options.PrintableOnly ? Loc.Format(Strings.Batch_DescPrintsOnly, flat) : flat;
            case SaveAsPdfAStep { Conformance: PdfAConformance.A }:
                return Strings.Batch_DescPdfA2a;
            case SaveAsPdfAStep:
                return Strings.Batch_DescPdfA2b;
            case MakeAccessibleStep:
                return Strings.Batch_DescMakeAccessible;
            case AddLongTermStep { TimestampUrl: { } stampUrl }:
                return Loc.Format(Strings.Batch_LongTermDescribeStamp, stampUrl);
            case AddLongTermStep:
                return Strings.Batch_LongTermDescribe;
            case OcrStep:
                return PageOcr.Engine is { } e ? Loc.Format(Strings.Batch_DescOcr, e.LanguageName) : PageOcr.Unavailable;
            case ExportStep x:
                return x.Format switch
                {
                    BatchExportFormat.Word => Strings.Batch_DescWord,
                    BatchExportFormat.Excel => Strings.Batch_DescExcel,
                    BatchExportFormat.Text => Strings.Batch_DescText,
                    BatchExportFormat.PowerPoint => Strings.Batch_DescPptx,
                    BatchExportFormat.Html => Strings.Batch_DescHtml,
                    BatchExportFormat.CommentsXfdf => Strings.Batch_DescXfdf,
                    BatchExportFormat.CommentsFdf => Strings.Batch_DescFdf,
                    BatchExportFormat.CommentsCsv => Strings.Batch_DescCsv,
                    BatchExportFormat.CommentSummary => Strings.Batch_DescSummary,
                    BatchExportFormat.FormDataXfdf => Strings.Batch_DescFormXfdf,
                    BatchExportFormat.FormDataFdf => Strings.Batch_DescFormFdf,
                    BatchExportFormat.FormDataCsv => Strings.Batch_DescFormCsv,
                    BatchExportFormat.FormDataJson => Strings.Batch_DescFormJson,
                    _ => Loc.Format(Strings.Batch_DescImages, x.Format == BatchExportFormat.Png ? "PNG" : "JPEG", x.Dpi),
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
        Status(Loc.Plural(preset.Steps.Count, Strings.Batch_PresetActions_One, Strings.Batch_PresetActions_Many, preset.Name) +
               (preset.Steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords) ? " " + Strings.Batch_PresetNeedsPasswords : ""));
    }

    private void SavePreset()
    {
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        if (_steps.Count == 0)
        {
            Status(Strings.Batch_AddActionsFirst, error: true);
            return;
        }
        var dlg = new FormDialog(this, Strings.Batch_SavePresetTitle, Strings.Common_Save, 480);
        var name = dlg.AddText(Strings.Sign_Name, SelectedPreset?.Name ?? "");
        var keepFolder = dlg.AddCheck(Strings.Batch_KeepFolder, _folder.Text.Trim().Length > 0);
        dlg.AddNote(Strings.Batch_SavePresetNote);
        dlg.Validate(() => string.IsNullOrWhiteSpace(name.Text) ? Strings.Batch_NamePreset : null);
        if (!dlg.ShowModal()) return;
        var path = PresetLibrary.PathFor(name.Text.Trim());
        if (File.Exists(path) && !string.Equals(path, SelectedPreset?.Path, StringComparison.OrdinalIgnoreCase)
                              && !Prompt.Confirm(this, Strings.Batch_ReplacePreset, Loc.Format(Strings.Batch_PresetExists, name.Text.Trim()), Strings.Common_Replace))
            return;
        try
        {
            RefreshPresets(PresetLibrary.Save(BatchPreset.From(name.Text.Trim(), Plan(), keepFolder.IsChecked == true)));
            Status(Loc.Format(Strings.Batch_PresetSaved, name.Text.Trim()));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status(Loc.Format(Strings.Batch_PresetNotSaved, ex.Message), error: true);
        }
    }

    private void ImportPreset()
    {
        if (!ProGate.Check(this, ProFeature.BatchPresets)) return;
        var dlg = new OpenFileDialog { Title = Strings.Batch_ImportTitle, Filter = Strings.Batch_PresetFilter, InitialDirectory = AppSettings.Current.LastFolder };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            var preset = BatchPresets.Load(dlg.FileName);
            var path = PresetLibrary.PathFor(preset.Name);
            if (File.Exists(path) && !Prompt.Confirm(this, Strings.Batch_ReplacePreset, Loc.Format(Strings.Batch_PresetExists, preset.Name), Strings.Common_Replace)) return;
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
            Status(Strings.Batch_AddActionsFirstExport, error: true);
            return;
        }
        var name = SelectedPreset?.Name ?? Strings.Batch_DefaultPresetName;
        var dlg = new SaveFileDialog { Title = Strings.Batch_ExportTitle, Filter = Strings.Batch_PresetFilter, FileName = BatchPresets.FileName(name) };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            BatchPresets.Save(BatchPreset.From(name, Plan(), keepFolder: true), dlg.FileName);
            Status(Loc.Format(Strings.Batch_ExportedRun, dlg.FileName));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status(Loc.Format(Strings.Batch_PresetNotExported, ex.Message), error: true);
        }
    }

    private void DeletePreset()
    {
        if (SelectedPreset is not { } chosen
            || !Prompt.Confirm(this, Strings.Batch_DeletePresetTitle, Loc.Format(Strings.Batch_DeletePresetBody, chosen.Name), Strings.Common_Delete))
            return;
        try
        {
            File.Delete(chosen.Path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Status(Loc.Format(Strings.Batch_PresetNotDeleted, ex.Message), error: true);
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
            Status(Strings.Batch_AddFilesFirst, error: true);
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
            Status(Loc.Format(Strings.Batch_CantSaveThere, ex.Message), error: true);
            return;
        }
        // Long-term data goes online: the window lists every address the batch would ask before anything is sent.
        Func<LtvClient>? longTermClient = null;
        if (plan.Steps.OfType<AddLongTermStep>().FirstOrDefault() is { } longTerm)
        {
            if (await ConfirmLongTermAsync(longTerm) is not { } client) return;
            longTermClient = () => client;
        }
        var s = AppSettings.Current;
        s.BatchFolder = plan.OutputFolder;
        s.BatchTemplate = plan.NameTemplate;
        s.BatchNeverOverwrite = plan.NeverOverwrite;
        s.BatchKeepSubfolders = plan.KeepSubfolders;
        s.BatchRecursive = _recursive.IsChecked == true;
        s.Save();

        var rows = _files.ToList();
        foreach (var r in rows) r.Show(Strings.Batch_Waiting);
        var fractions = new double[rows.Count];
        var finished = 0;
        _skipPasswords = false;
        _cts = new CancellationTokenSource();
        SetRunning(true);
        using var taskbar = new TaskbarProgress(this);
        Status(Loc.Plural(rows.Count, Strings.Batch_WorkingOnFiles_One, Strings.Batch_WorkingOnFiles_Many));
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
            Recognizer = ocr is null ? null : new SerialRecognizer(ocr, ocrGate),
            LongTermClient = longTermClient,
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
            if (_cts is { IsCancellationRequested: false }) _status.Text = Loc.Plural(rows.Count, Strings.Batch_WorkingOf_One, Strings.Batch_WorkingOf_Many, finished);
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
            Status(Loc.Format(Strings.Batch_Stopped2, ex.Message), error: true);
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
        Status(Loc.Plural(written, Strings.Batch_SavedIn_One, Strings.Batch_SavedIn_Many, summary.Text, plan.OutputFolder) +
               (summary.Failed + summary.Skipped > 0 ? " " + Strings.Batch_ListSaysWhy : "") +
               (written > 0 ? " " + Strings.Batch_DoubleClick : ""), error: summary.Failed > 0);
        _openFolder.IsEnabled = written > 0;
        _report.Visibility = summary.RedactionReport is null ? Visibility.Collapsed : Visibility.Visible;
        _start.Content = Strings.Batch_RunAgain;
        Log.Write($"Batch: {summary.Text}");
        if (_closeWhenDone) Close();
    }

    /// <summary>
    /// The addresses every signed file in the list would have asked (read offline), in one window. The client the run
    /// goes online through, which judged them; null when nothing is to be done or the person said no.
    /// </summary>
    private async Task<LtvClient?> ConfirmLongTermAsync(AddLongTermStep step)
    {
        var client = _host.NewLtvClient();
        var paths = _files.Select(r => r.File).Where(f => !f.IsImage).Select(f => f.Path).ToList();
        Status(Strings.Batch_LongTermReading);
        var (plan, signed) = await Task.Run(() => BatchLongTermPlan(paths, client, step.TimestampUrl));
        Status("");
        if (signed == 0)
        {
            client.Dispose();
            Status(Strings.Batch_LongTermNoneSigned, error: true);
            return null;
        }
        if (_host.DevLtvClient is not null || LtvDialogs.ConfirmBatch(this, plan, signed)) return client; // the dev script answers for itself
        client.Dispose();
        return null;
    }

    /// <summary>What adding long-term data to these files would contact, all together, and how many have a signature to add it for.</summary>
    private static (LtvPlan Plan, int Signed) BatchLongTermPlan(IReadOnlyList<string> paths, LtvClient client, string? timestampUrl)
    {
        var addresses = new List<LtvAddress>();
        var notes = new List<string>();
        var complete = true;
        var signed = 0;
        if (timestampUrl is not null) addresses.Add(new LtvAddress(LtvAddressKind.Timestamp, timestampUrl, Strings.Batch_LongTermEachFile, client.Why(timestampUrl, LtvAddressKind.Timestamp)));
        foreach (var path in paths)
        {
            try
            {
                var data = File.ReadAllBytes(path);
                if (data.AsSpan().IndexOf("/Encrypt"u8) >= 0 || !Signatures.Inspect(data, null).Any(f => f.Intact && f.Info.Certificate is not null)) continue;
                signed++;
                var plan = Ltv.Plan(data, null, client);
                complete &= plan.Complete;
                foreach (var a in plan.Addresses)
                    if (!addresses.Any(x => x.Url == a.Url)) addresses.Add(a);
                foreach (var n in plan.Notes)
                    if (!notes.Contains(n)) notes.Add(n);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // Unreadable here, it fails as the batch runs, before anything is asked.
            }
        }
        return (new LtvPlan(addresses, notes, complete && timestampUrl is null), signed);
    }

    /// <summary>The last run's removal report as a page.</summary>
    internal void ShowRedactionReport()
    {
        if (LastSummary?.RedactionReport is { } report) RedactionReportDialog.Show(this, report, Strings.Batch_Title);
    }

    private static string RowText(BatchItemResult r)
    {
        var text = r.State switch
        {
            BatchItemState.Done => r.Outputs.Count switch
            {
                0 => Strings.Batch_DoneNothing,
                1 => Loc.Format(Strings.Batch_DoneFile, Path.GetFileName(r.Outputs[0])),
                _ => Loc.Format(Strings.Batch_DoneFiles, r.Outputs.Count),
            },
            BatchItemState.Skipped => Loc.Format(Strings.Batch_SkippedMsg, r.Message),
            BatchItemState.Failed => Loc.Format(Strings.Batch_FailedMsg, r.Message),
            BatchItemState.Cancelled => Strings.Batch_Cancelled,
            _ => r.Message,
        };
        return r.Notes.Count > 0 ? $"{text} ({string.Join("; ", r.Notes)})" : text;
    }

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
        Status(Strings.Batch_Stopping);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (IsIdle) return;
        e.Cancel = true;
        if (!Prompt.Confirm(this, Strings.Batch_StopTitle, Strings.Batch_StopBody, Strings.Common_Stop)) return;
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
                BatchPasswordKind.Open => (Strings.Dialog_PasswordRequired, Loc.Format(Strings.Batch_PwOpen, name), Strings.Common_Continue),
                BatchPasswordKind.Permissions => (Strings.PdfA_PasswordTitle, Loc.Format(Strings.Batch_PwPerms, name), Strings.Common_Continue),
                _ => (Strings.Batch_OpenPwTitle, Loc.Format(Strings.Batch_PwKeep, name), Strings.Common_Continue),
            };
            var dlg = new FormDialog(this, title, ok);
            if (request.Wrong) dlg.AddNote(Strings.PdfA_PasswordWrong);
            dlg.AddNote(text);
            var box = dlg.Add(Strings.PdfA_Password, new PasswordBox());
            AutomationProperties.SetName(box, Strings.PdfA_Password);
            var skipRest = dlg.AddCheck(Strings.Batch_SkipOthers);
            dlg.AddNote(Strings.Batch_CancelSkips);
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
            "redactpatterns" when rest.StartsWith("set:", StringComparison.Ordinal) => new RedactPatternsStep(RedactionPatternSets.Load(Path.Combine(RedactPatternActions.SetsFolder, RedactionPatternSets.FileName(rest[4..]))).Options),
            "redactpatterns" => new RedactPatternsStep(new RedactionPatternOptions { Phrases = rest.Length > 0 ? [rest] : [] }),
            "checkredaction" => new CheckRedactionStep(),
            "checkaccessibility" => new CheckAccessibilityStep(),
            "reportcontents" => new ReportContentsStep(),
            "watermark" => new WatermarkStep(new WatermarkOptions { Text = rest.Length > 0 ? rest : "DRAFT" }),
            "footer" => new HeaderFooterStep(new HeaderFooterOptions { FooterCenter = rest.Length > 0 ? rest : "Page <<page>> of <<pages>>" }),
            "bates" => new HeaderFooterStep(new HeaderFooterOptions { FooterRight = "<<bates>>", Bates = new BatesFormat(rest.Split(' ')[0], 1, 6) }, rest.Contains("continue")),
            "rotate" => new RotateStep(int.TryParse(rest, out var d) ? d : 90),
            "flatten" => new FlattenStep(new FlattenOptions()),
            "ocr" => new OcrStep(),
            "pdfa" => new SaveAsPdfAStep(),
            "pdfa2a" => new SaveAsPdfAStep { Conformance = PdfAConformance.A },
            "longterm" => new AddLongTermStep(rest.Length > 0 ? rest : null),
            "makeaccessible" or "tag" => new MakeAccessibleStep { Language = rest.Length > 0 ? rest : null },
            "export" => new ExportStep(rest.ToLowerInvariant() switch
            {
                "word" => BatchExportFormat.Word,
                "excel" => BatchExportFormat.Excel,
                "powerpoint" or "pptx" => BatchExportFormat.PowerPoint,
                "html" => BatchExportFormat.Html,
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
