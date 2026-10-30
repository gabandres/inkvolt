using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace InkvoltPdf.App;

/// <summary>
/// The app's only motion: a transient surface (a toast, the command palette) fades in while rising a few pixels, in
/// Fluent's "fast" duration with its decelerate curve, so it reads as arriving rather than blinking on. None at all when
/// Windows' "Animation effects" is off (Settings › Accessibility › Visual effects; WCAG 2.3.3).
/// </summary>
public static class Motion
{
    /// <summary>Fluent 2's fast duration (167 ms).</summary>
    public static readonly Duration Fast = new(TimeSpan.FromMilliseconds(167));

    /// <summary>False when Windows' Animation effects is off.</summary>
    public static bool Enabled => SystemParameters.ClientAreaAnimation;

    public static void Enter(UIElement element, double rise = 8)
    {
        if (!Enabled) return;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        element.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, Fast) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        var move = new TranslateTransform();
        element.RenderTransform = move;
        move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(rise, 0, Fast) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }
}
