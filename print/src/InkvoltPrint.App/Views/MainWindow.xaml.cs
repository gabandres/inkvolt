using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Root.SizeChanged += (_, _) => FoldSidebar();
        // Choosing a printer in the folded sidebar closes it, as Windows Settings' pane does.
        PrinterList.SelectionChanged += (_, _) =>
        {
            if (_sidebarOpen) Dispatcher.BeginInvoke(() => ShowSidebar(open: false));
            // Moving through the list by keyboard leaves the Fleet page; the list changing by itself (a queue added, a printer gone) doesn't.
            if (PrinterList.IsKeyboardFocusWithin && Vm is { } vm) vm.IsFleetShown = false;
        };
        // The printer already selected is chosen again: the selection doesn't change, the Fleet page still goes.
        PrinterList.PreviewMouseLeftButtonUp += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement(PrinterList, d) is ListBoxItem && Vm is { } vm) vm.IsFleetShown = false;
        };
        PrinterList.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Vm is { } vm) vm.IsFleetShown = false;
        };
        PreviewKeyDown += OnPreviewKey;
        CommandBindings.Add(new CommandBinding(PaletteCommand, (_, _) => OpenPalette()));
        PaletteBox.TextChanged += (_, _) => FilterPalette();
        PaletteBox.PreviewKeyDown += OnPaletteKey;
        PaletteList.MouseUp += (_, e) =>
        {
            for (var d = e.OriginalSource as DependencyObject; d is not null && d != PaletteList; d = System.Windows.Media.VisualTreeHelper.GetParent(d))
                if (d is ListBoxItem) { RunPaletteSelection(); return; }
        };
        PaletteBox.LostKeyboardFocus += (_, e) =>
        {
            if (Palette.Visibility == Visibility.Visible && e.NewFocus is DependencyObject d && !Palette.IsAncestorOf(d)) ClosePalette(focus: false);
        };
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is MainViewModel old) old.PropertyChanged -= OnVmChanged;
            if (e.NewValue is MainViewModel vm) vm.PropertyChanged += OnVmChanged;
        };
    }

    /// <summary>Another printer's page arrives (Motion), rather than replacing the last one at once.</summary>
    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.Selected) && IsLoaded) Motion.Enter(PrinterPane);
        if (e.PropertyName == nameof(MainViewModel.IsFleetShown) && IsLoaded && Vm is { IsFleetShown: false })
        {
            Motion.Enter(PrinterPane);
            // The Fleet page took the keyboard's place with it: back to the printer, on the list.
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
            {
                if (Keyboard.FocusedElement is UIElement { IsVisible: true }) return;
                (PrinterList.ItemContainerGenerator.ContainerFromItem(PrinterList.SelectedItem) as ListBoxItem)?.Focus();
            });
        }
    }

    // ───────────── The sidebar, folded on a narrow window or at a large Text size ─────────────

    private bool _folded, _sidebarOpen;

    /// <summary>Folds the sidebar into the Printers button when the window has no room for it (<see cref="NavPane"/>), and back.</summary>
    private void FoldSidebar()
    {
        var fold = NavPane.Folds(Root.ActualWidth);
        if (fold == _folded) return;
        _folded = fold;
        SidebarColumn.Width = new GridLength(fold ? 0 : NavPane.Width);
        Grid.SetColumnSpan(Sidebar, fold ? 2 : 1);
        Sidebar.Width = fold ? NavPane.Width : double.NaN;
        Sidebar.HorizontalAlignment = fold ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        if (fold) Sidebar.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        else Sidebar.ClearValue(Border.BackgroundProperty);
        Sidebar.Effect = fold ? new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 28, ShadowDepth = 4, Opacity = 0.28 } : null;
        NavButton.Visibility = fold ? Visibility.Visible : Visibility.Collapsed;
        ShowSidebar(open: false, focus: false);
    }

    /// <summary>Opens the folded sidebar over the page (sliding in), or closes it; unfolded, it always shows.</summary>
    public void ShowSidebar(bool open, bool focus = true)
    {
        var was = _sidebarOpen;
        _sidebarOpen = open && _folded;
        Sidebar.Visibility = !_folded || _sidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        Scrim.Visibility = _sidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        if (_sidebarOpen && !was)
        {
            Motion.Enter(Sidebar, rise: 0, slide: -16);
            if (focus) Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
            {
                if ((PrinterList.ItemContainerGenerator.ContainerFromItem(PrinterList.SelectedItem) as ListBoxItem ?? PrinterList.ItemContainerGenerator.ContainerFromIndex(0) as ListBoxItem) is { } item) item.Focus();
                else PrinterList.Focus();
            });
        }
        else if (was && !_sidebarOpen && focus) NavButton.Focus();
    }

    private void NavButton_Click(object sender, RoutedEventArgs e) => ShowSidebar(open: !_sidebarOpen);

    private void Scrim_MouseDown(object sender, MouseButtonEventArgs e) => ShowSidebar(open: false);

    private void OnPreviewKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        if (Palette.Visibility == Visibility.Visible) ClosePalette();
        else if (_sidebarOpen) ShowSidebar(open: false);
        else return;
        e.Handled = true;
    }

    // ───────────── Command palette (Ctrl+K), as Inkvolt PDF's ─────────────

    /// <summary>Ctrl+K: the command palette.</summary>
    public static readonly RoutedCommand PaletteCommand = new(nameof(PaletteCommand), typeof(MainWindow));

    private List<PrintPalette.Entry> _paletteAll = [];

    public void OpenPalette()
    {
        if (Vm is not { } vm) return;
        ShowSidebar(open: false, focus: false);
        var p = vm.Selected;
        _paletteAll = PrintPalette.Build(
            p is null ? null : new PrintPalette.Printer(p.Name, p.CanPrint, p.Scan is not null, p.ShowCopy, p.Settings is not null, p.NeedsSetup, p.CanFix, p.IsNetworkPrinter),
            p is null ? -1 : vm.Printers.IndexOf(p), [.. vm.Printers.Select(x => x.Name)], [.. vm.Presets.Items.Select(x => x.Name)]);
        Palette.Visibility = Visibility.Visible;
        Motion.Enter(PaletteCard, rise: -8); // drops in from the top
        PaletteBox.Text = "";
        FilterPalette();
        PaletteBox.Focus();
    }

    private void ClosePalette(bool focus = true)
    {
        Palette.Visibility = Visibility.Collapsed;
        if (focus) (PrinterPane as UIElement).MoveFocus(new TraversalRequest(FocusNavigationDirection.First));
    }

    private void Palette_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource == Palette) ClosePalette();
    }

    private void FilterPalette()
    {
        var result = PaletteSearch.Filter(_paletteAll, PaletteBox.Text, i => i.Name, i => i.Category);
        PaletteList.ItemsSource = result;
        PaletteList.SelectedIndex = result.Count > 0 ? 0 : -1;
        var q = PaletteBox.Text.Trim();
        PaletteEmpty.Visibility = result.Count == 0 && q.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (result.Count == 0 && q.Length > 0) PaletteEmpty.Text = PrintPalette.NoMatch(q);
    }

    private void OnPaletteKey(object sender, KeyEventArgs e)
    {
        var count = PaletteList.Items.Count;
        switch (e.Key)
        {
            case Key.Down when count > 0:
                PaletteList.SelectedIndex = (PaletteList.SelectedIndex + 1) % count;
                PaletteList.ScrollIntoView(PaletteList.SelectedItem);
                break;
            case Key.Up when count > 0:
                PaletteList.SelectedIndex = (PaletteList.SelectedIndex - 1 + count) % count;
                PaletteList.ScrollIntoView(PaletteList.SelectedItem);
                break;
            case Key.Enter:
                RunPaletteSelection();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    public void RunPaletteSelection()
    {
        if (PaletteList.SelectedItem is not PrintPalette.Entry entry) return;
        ClosePalette();
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () => RunPaletteEntry(entry.Id));
    }

    /// <summary>Runs a palette entry by its id (<see cref="PrintPalette.Entry.Id"/>): what its button or menu item does.</summary>
    public void RunPaletteEntry(string id)
    {
        if (Vm is not { } vm) return;
        var p = vm.Selected;
        var (kind, arg) = id.IndexOf(':') is var colon and > 0 ? (id[..colon], id[(colon + 1)..]) : (id, "");
        static void Run(ICommand? command, object? parameter = null)
        {
            if (command?.CanExecute(parameter) == true) command.Execute(parameter);
        }
        if (kind is "section" or "show" or "preset" or "printer") vm.IsFleetShown = false; // what they do is on the printer's page
        switch (kind, arg)
        {
            case ("app", "fleet"): ShowFleet(); break;
            case ("section", _) when p is not null && int.TryParse(arg, out var section): p.SelectedSection = section; break;
            case ("show", _) when int.TryParse(arg, out var n) && n < vm.Printers.Count: vm.Selected = vm.Printers[n]; break;
            case ("preset", _) when int.TryParse(arg, out var preset) && p?.Scan is not null && preset < vm.Presets.Items.Count:
                _ = p.RunPresetCommand.ExecuteAsync(vm.Presets.Items[preset]);
                break;
            case ("printer", "print"): Run(p?.GoToPrintCommand); break;
            case ("printer", "scan"): Run(p?.GoToScanCommand); break;
            case ("printer", "setup"): Run(p?.SetUpCommand); break;
            case ("printer", "reconnect"): Run(p?.ReconnectCommand); break;
            case ("printer", "photos"): Run(p?.GoToPhotosCommand); break;
            case ("printer", "fix"): Run(p?.OpenFixerCommand); break;
            case ("printer", "maintenance"): Run(p?.ShowMaintenanceCommand); break;
            case ("printer", "remove"): Run(vm.ForgetCommand, p); break;
            case ("app", "add"): AddPrinterWindow.Open(this, vm); break;
            case ("app", "search"): Run(vm.SearchAgainCommand); break;
            case ("app", "settings"): SettingsWindow.Open(this, vm, (Application.Current as App)?.Tray); break;
            case ("app", "help"): ShowHelp(); break;
            case ("app", "whatsnew"): WhatsNewDialog.Open(this, AppHelp.Notes()); break;
            case ("app", "report"): ReportProblemDialog.Open(this, AppHelp.Report(vm)); break;
            case ("app", "about"): AboutDialog.Open(this); break;
        }
    }

    /// <summary>The palette's entries as listed now (dev snapshots: <c>--palette</c>).</summary>
    public IReadOnlyList<PrintPalette.Entry> PaletteShown => PaletteList.ItemsSource as IReadOnlyList<PrintPalette.Entry> ?? [];

    /// <summary>Types into the palette (dev snapshots: <c>--palette words</c>).</summary>
    public void TypeInPalette(string text) => PaletteBox.Text = text;

    private MainViewModel? Vm => DataContext as MainViewModel;

    /// <summary>Normal runs keep the window's place and size for next time (never dev snapshots or demos).</summary>
    public bool RemembersPlacement { get; set; }

    private void About_Click(object sender, RoutedEventArgs e) => AboutDialog.Open(this);

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (Vm is { } vm) SettingsWindow.Open(this, vm, (Application.Current as App)?.Tray);
    }

    private void Help_Click(object sender, RoutedEventArgs e) => ShowHelp();

    private void Fleet_Click(object sender, RoutedEventArgs e) => ShowFleet();

    /// <summary>The Fleet page, with the keyboard on its first row.</summary>
    public void ShowFleet()
    {
        if (Vm is not { } vm) return;
        ShowSidebar(open: false, focus: false);
        vm.IsFleetShown = true;
        Motion.Enter(FleetPage);
        Dispatcher.BeginInvoke(DispatcherPriority.Input, FleetPage.FocusList);
    }

    private void AddPrinter_Click(object sender, RoutedEventArgs e)
    {
        if (Vm is { } vm) AddPrinterWindow.Open(this, vm);
    }

    private void Help_Executed(object sender, System.Windows.Input.ExecutedRoutedEventArgs e) => ShowHelp();

    private void ShowHelp()
    {
        if (Vm is { } vm) HelpDialog.Open(this, vm);
    }

    /// <summary>
    /// With the notification-area icon on, closing goes to the tray (scanned pages stay in memory). Otherwise scanned pages
    /// live only in memory until saved: don't let a stray click on X throw them away.
    /// </summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (RemembersPlacement && Vm?.State is { } state && WindowFrame.Placement(this) is { } placement && placement != state.Window)
        {
            state.Window = placement;
            state.Save();
        }
        if (Application.Current is App { Quitting: false, Tray.KeepsRunning: true } app)
        {
            e.Cancel = true;
            app.Tray!.HideWindow();
            base.OnClosing(e);
            return;
        }
        // Signing out: the scans are on disk and come back next start, so Windows isn't held up by a question.
        if (Application.Current is not App { SigningOut: true, KeepsScans: true } && Vm?.PrintersWithUnsavedScans is { Count: > 0 } printers)
        {
            var pages = printers.Sum(p => p.Scan!.Pages.Count);
            if (!ConfirmDialog.Ask(this, $"You have {pages} scanned page{(pages == 1 ? "" : "s")} that you haven't saved. Close Inkvolt Print anyway?",
                    "Close without saving"))
            {
                e.Cancel = true;
                if (Vm.Selected is { Scan: not null } sel && sel.Scan.HasUnsavedPages) sel.SelectedSection = PrinterViewModel.ScanSection;
                else Vm.ShowPrinter(printers[0]);
            }
        }
        base.OnClosing(e);
    }

    /// <summary>
    /// The printer menu is one shared instance; point it at the item it was opened on, so "Remove" can never act on
    /// a different printer than the one right-clicked (or focused, for Shift+F10).
    /// </summary>
    private void Printers_ContextMenuOpening(object sender, System.Windows.Controls.ContextMenuEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source
            && System.Windows.Controls.ItemsControl.ContainerFromElement((System.Windows.Controls.ItemsControl)sender, source)
                is System.Windows.Controls.ListBoxItem { ContextMenu: { } menu } item)
        {
            menu.DataContext = item.DataContext;
            menu.PlacementTarget = item;
        }
    }

    /// <summary>"Printer maintenance…" (printer menu): scroll the Maintenance card into view and focus its first action.</summary>
    private void MaintenanceCard_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: null } card) return;
        // The template is reused across printers: the card checks its own view model each time.
        Action<PrinterViewModel> show = _ => FocusMaintenance(card);
        PrinterViewModel.MaintenanceRequested += show;
        card.Tag = show;
        FocusMaintenance(card);
    }

    private void FocusMaintenance(FrameworkElement card)
    {
        if (card.DataContext is not MaintenanceViewModel { FocusRequested: true } maintenance) return;
        maintenance.FocusRequested = false;
        // Focus first (which scrolls just far enough for the button), then the whole card once layout has settled.
        Dispatcher.BeginInvoke(() => card.MoveFocus(new System.Windows.Input.TraversalRequest(System.Windows.Input.FocusNavigationDirection.First)),
            System.Windows.Threading.DispatcherPriority.Loaded);
        Dispatcher.BeginInvoke(() => card.BringIntoView(), System.Windows.Threading.DispatcherPriority.ContextIdle);
    }

    private void MaintenanceCard_Unloaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Action<PrinterViewModel> show } card)
        {
            PrinterViewModel.MaintenanceRequested -= show;
            card.Tag = null;
        }
    }

    private static string[] Dropped(DragEventArgs e) => e.Data.GetData(DataFormats.FileDrop) as string[] ?? [];

    private static string? DroppedPdf(string[] files) =>
        files is [var first, ..] && first.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? first : null;

    /// <summary>Pictures to print, including HEIC / WebP without a codec (the Photos tab then says what's missing).</summary>
    private static List<string> DroppedPictures(string[] files) =>
        files.Where(f => Printing.PhotoFiles.IsPicture(f) || Printing.PhotoFiles.MissingCodec(f) is not null).ToList();

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        var files = Dropped(e);
        e.Effects = (DroppedPdf(files) is not null || DroppedPictures(files).Count > 0) && Vm?.Selected is not null ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>Drop a PDF anywhere on the window: it opens in the selected printer's Print section. Pictures go to Photos.</summary>
    private async void Window_Drop(object sender, DragEventArgs e)
    {
        try
        {
            var files = Dropped(e);
            if (Vm?.Selected is not { } printer) return;
            if (DroppedPdf(files) is { } path && File.Exists(path)) await printer.OpenPdfAsync(path);
            else if (DroppedPictures(files).Where(File.Exists).ToList() is { Count: > 0 } pictures) await printer.OpenPhotosAsync(pictures);
        }
        catch (Exception ex)
        {
            Log.Write($"Drop failed: {ex}"); // async void: never let it escape
        }
    }
}
