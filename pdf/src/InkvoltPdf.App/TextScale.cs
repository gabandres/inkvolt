using System.Windows;
using System.Windows.Media;
using InkvoltPrint.Core.Suite;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// Follows Windows' Settings › Accessibility › Text size (WPF follows only the display scale). Every window's content is
/// scaled by it and dialogs widen to match, unless a window sets <c>WholeWindow="False"</c> and scales chosen parts with
/// <c>app:TextScale.Scales="True"</c> instead (the main window: its page view renders pages for the screen's own pixels,
/// so it zooms rather than scaling). <c>INKVOLT_TEXTSCALE=1.5</c> (or the dev step <c>textscale</c>) overrides the
/// setting for checks and screenshots. The same as Inkvolt Print's; the factor's rules are <see cref="TextSize"/>.
/// </summary>
public static class TextScale
{
    public static double Factor { get; private set; } = 1;

    /// <summary>Raised on the UI thread when the factor changes (Windows' setting, or the override).</summary>
    public static event EventHandler? Changed;

    private static global::Windows.UI.ViewManagement.UISettings? _settings;
    private static double? _override;

    public static void Start(Application app)
    {
        _override = TextSize.Parse(Environment.GetEnvironmentVariable("INKVOLT_TEXTSCALE"));
        Factor = Read();
        try
        {
            _settings = new global::Windows.UI.ViewManagement.UISettings();
            _settings.TextScaleFactorChanged += (_, _) => app.Dispatcher.BeginInvoke(Refresh);
        }
        catch (Exception) { } // older Windows: the factor read at start stays
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler(OnWindowLoaded));
    }

    /// <summary>Overrides Windows' setting (null: follow it again).</summary>
    public static void Override(double? factor)
    {
        _override = factor is { } f ? TextSize.Factor(f) : null;
        Refresh();
    }

    private static void Refresh()
    {
        var factor = Read();
        if (factor == Factor) return;
        Factor = factor;
        Changed?.Invoke(null, EventArgs.Empty);
    }

    private static double Read()
    {
        if (_override is { } o) return o;
        try
        {
            if (_settings is not null) return TextSize.Factor(_settings.TextScaleFactor);
            if (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Accessibility", "TextScaleFactor", null) is int percent)
                return TextSize.Factor(percent / 100.0);
        }
        catch (Exception) { }
        return 1;
    }

    // ── Parts of a window ──

    public static readonly DependencyProperty ScalesProperty = DependencyProperty.RegisterAttached(
        "Scales", typeof(bool), typeof(TextScale), new PropertyMetadata(false, OnScalesChanged));

    public static bool GetScales(DependencyObject d) => (bool)d.GetValue(ScalesProperty);
    public static void SetScales(DependencyObject d, bool value) => d.SetValue(ScalesProperty, value);

    /// <summary>False on a window that scales only its marked parts (<see cref="ScalesProperty"/>).</summary>
    public static readonly DependencyProperty WholeWindowProperty = DependencyProperty.RegisterAttached(
        "WholeWindow", typeof(bool), typeof(TextScale), new PropertyMetadata(true));

    public static bool GetWholeWindow(DependencyObject d) => (bool)d.GetValue(WholeWindowProperty);
    public static void SetWholeWindow(DependencyObject d, bool value) => d.SetValue(WholeWindowProperty, value);

    private static void OnScalesChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement fe || e.NewValue is not true) return;
        Apply(fe);
        // Static event, so unhook when the element leaves (a closed tab), or it would be kept alive.
        EventHandler handler = (_, _) => Apply(fe);
        if (fe.IsLoaded) Changed += handler;
        fe.Loaded += (_, _) => { Changed -= handler; Changed += handler; Apply(fe); };
        fe.Unloaded += (_, _) => Changed -= handler;
    }

    private static void Apply(FrameworkElement fe) =>
        fe.LayoutTransform = Factor == 1 ? Transform.Identity : new ScaleTransform(Factor, Factor);

    // ── Whole windows ──

    private static void OnWindowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Window window || !GetWholeWindow(window) || window.Content is not FrameworkElement content) return;
        if (content.ReadLocalValue(ScalesProperty) != DependencyProperty.UnsetValue) return; // already done (Loaded again)
        SetScales(content, true);
        // A main window keeps the size the person gave it; a dialog widens with its text, so it wraps as designed.
        if (Factor == 1 || window.Owner is null && window == Application.Current.MainWindow) return;
        var designed = (window.Width, window.MinWidth, window.Height);
        // After Show is done with the window: a size set while it is still showing is put back to the designed one.
        window.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
        {
            var room = SystemParameters.WorkArea;
            window.MinWidth = TextSize.Widen(designed.MinWidth, Factor, room.Width * 0.95);
            window.Width = TextSize.Widen(designed.Width, Factor, room.Width * 0.95);
            if (!window.SizeToContent.HasFlag(SizeToContent.Height))
                window.Height = TextSize.Widen(designed.Height, Factor, room.Height * 0.95);
            window.UpdateLayout();
            // Grown after Windows placed it: center it again where it was meant to be.
            if (window.WindowStartupLocation == WindowStartupLocation.CenterOwner && window.Owner is { WindowState: WindowState.Normal } owner)
            {
                window.Left = owner.Left + (owner.ActualWidth - window.ActualWidth) / 2;
                window.Top = owner.Top + (owner.ActualHeight - window.ActualHeight) / 2;
            }
            else if (window.WindowStartupLocation == WindowStartupLocation.CenterScreen
                     || window.WindowStartupLocation == WindowStartupLocation.CenterOwner && window.Owner is { WindowState: WindowState.Maximized })
            {
                window.Left = room.Left + (room.Width - window.ActualWidth) / 2;
                window.Top = Math.Max(room.Top, room.Top + (room.Height - window.ActualHeight) / 2);
            }
        });
    }
}
