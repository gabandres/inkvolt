using System.ComponentModel;
using System.IO;
using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private MainViewModel? Vm => DataContext as MainViewModel;

    /// <summary>Normal runs keep the window's place and size for next time (never dev snapshots or demos).</summary>
    public bool RemembersPlacement { get; set; }

    private void About_Click(object sender, RoutedEventArgs e) => AboutDialog.Open(this);

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (Vm is { } vm) SettingsWindow.Open(this, vm, (Application.Current as App)?.Tray);
    }

    private void Help_Click(object sender, RoutedEventArgs e) => ShowHelp();

    // Add a printer by address: type at once when it opens; back on its button when it closes from inside (Esc, Cancel).
    private void AddPrinterCard_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (AddPrinterCard.IsVisible)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () =>
            {
                AddressBox.Focus();
                AddressBox.SelectAll();
            });
        else if (AddPrinterCard.IsKeyboardFocusWithin || System.Windows.Input.Keyboard.FocusedElement is null)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () => AddPrinterButton.Focus());
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
                else Vm.Selected = printers[0];
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
