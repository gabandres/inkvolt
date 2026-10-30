using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace InkvoltPrint.App;

/// <summary>
/// The app's motion, as Inkvolt PDF's: what changes in place arrives instead of blinking on, in Fluent's "fast" duration
/// with its decelerate curve. A section's page when its tab is chosen, the printer's page when another printer is,
/// a status line when its words change (<c>local:Motion.OnChange</c> with <c>NotifyOnTargetUpdated</c> on the
/// binding), the folded sidebar sliding in, the command palette dropping in. None at all when Windows' "Animation
/// effects" is off (Settings › Accessibility › Visual effects; WCAG 2.3.3).
/// </summary>
public static class Motion
{
    /// <summary>Fluent 2's fast duration (167 ms).</summary>
    public static readonly Duration Fast = new(TimeSpan.FromMilliseconds(167));

    /// <summary>False when Windows' Animation effects is off.</summary>
    public static bool Enabled => SystemParameters.ClientAreaAnimation;

    /// <summary>Fades the element in while it moves <paramref name="rise"/> up (or <paramref name="slide"/> right) into place.</summary>
    public static void Enter(UIElement element, double rise = 8, double slide = 0)
    {
        if (!Enabled) return;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        element.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, Fast) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        var move = new TranslateTransform();
        element.RenderTransform = move;
        if (rise != 0) move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(rise, 0, Fast) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        if (slide != 0) move.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(slide, 0, Fast) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }

    // ── A status line whose words change ──

    public static readonly DependencyProperty OnChangeProperty = DependencyProperty.RegisterAttached(
        "OnChange", typeof(bool), typeof(Motion), new PropertyMetadata(false, OnOnChangeChanged));

    public static bool GetOnChange(DependencyObject d) => (bool)d.GetValue(OnChangeProperty);
    public static void SetOnChange(DependencyObject d, bool value) => d.SetValue(OnChangeProperty, value);

    private static void OnOnChangeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement fe) return;
        if (e.NewValue is true) fe.AddHandler(Binding.TargetUpdatedEvent, (EventHandler<DataTransferEventArgs>)OnTargetUpdated);
        else fe.RemoveHandler(Binding.TargetUpdatedEvent, (EventHandler<DataTransferEventArgs>)OnTargetUpdated);
    }

    private static void OnTargetUpdated(object? sender, DataTransferEventArgs e)
    {
        // A line of text rises less than a surface: 4 px.
        if (e.Property == TextBlock.TextProperty && sender is TextBlock { IsLoaded: true, Text.Length: > 0 } text) Enter(text, rise: 4);
    }

    // ── A section's page when its tab is chosen ──

    public static readonly DependencyProperty OnTabChangeProperty = DependencyProperty.RegisterAttached(
        "OnTabChange", typeof(bool), typeof(Motion), new PropertyMetadata(false, OnOnTabChangeChanged));

    public static bool GetOnTabChange(DependencyObject d) => (bool)d.GetValue(OnTabChangeProperty);
    public static void SetOnTabChange(DependencyObject d, bool value) => d.SetValue(OnTabChangeProperty, value);

    private static void OnOnTabChangeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is TabControl tabs && e.NewValue is true) tabs.SelectionChanged += OnTabSelectionChanged;
    }

    private static void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Lists and boxes inside a section raise SelectionChanged through the tab control too: only its own tabs count.
        if (e.OriginalSource != sender || sender is not TabControl { IsLoaded: true } tabs || e.RemovedItems.Count == 0) return;
        if (tabs.Template?.FindName("PART_SelectedContentHost", tabs) is UIElement page) Enter(page);
    }
}
