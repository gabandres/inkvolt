using System.Collections.Specialized;

namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Motion in the scan review: which page moves when the page list changes, and how. A page put back (Undo) rises into its
/// place; after a delete the page that takes its place fades in; a moved page (Alt+Shift+arrows, the menu) slides in from the
/// side it came from. Nothing moves while a scan or a save shows its progress (the progress bar is the one thing moving then,
/// and pages arriving from the scanner simply appear), while a page is dragged (it follows the pointer already), or when several
/// pages change at once (a restored scan, a cleared list). Fluent's fast duration; the app turns it off with Windows' animation
/// effects (<c>Motion.Enabled</c>).
/// </summary>
public static class ReviewMotion
{
    public enum Kind { None, Arrive, Fade, FromBefore, FromAfter }

    /// <summary>What moves: <see cref="Kind"/> on the page at <see cref="Index"/> of the list as it is now.</summary>
    public readonly record struct Step(Kind Kind, int Index);

    public static readonly Step None = new(Kind.None, -1);

    /// <summary>The app's fast motion (Fluent 2: 167 ms, decelerating).</summary>
    public static readonly TimeSpan Duration = TimeSpan.FromMilliseconds(167);

    /// <param name="newIndex">Where the page is now (Add, Move).</param>
    /// <param name="oldIndex">Where it was (Remove, Move).</param>
    /// <param name="count">The pages now.</param>
    /// <param name="changed">How many pages the change was about.</param>
    /// <param name="busy">A scan or a save is running (its progress bar shows).</param>
    /// <param name="dragging">A page is being dragged.</param>
    public static Step For(NotifyCollectionChangedAction action, int newIndex, int oldIndex, int count, int changed, bool busy, bool dragging)
    {
        if (busy || dragging || changed != 1) return None;
        return action switch
        {
            NotifyCollectionChangedAction.Add when newIndex >= 0 && newIndex < count => new(Kind.Arrive, newIndex),
            NotifyCollectionChangedAction.Remove when oldIndex >= 0 && oldIndex < count => new(Kind.Fade, oldIndex),
            NotifyCollectionChangedAction.Move when newIndex >= 0 && newIndex < count && oldIndex != newIndex =>
                new(newIndex > oldIndex ? Kind.FromBefore : Kind.FromAfter, newIndex),
            _ => None,
        };
    }

    /// <summary>How far (DIPs) the page rises into place.</summary>
    public static double Rise(Kind kind) => kind == Kind.Arrive ? 8 : 0;

    /// <summary>How far (DIPs) the page slides in sideways: from the left when it came from before, from the right when from after.</summary>
    public static double Slide(Kind kind) => kind switch { Kind.FromBefore => -12, Kind.FromAfter => 12, _ => 0 };
}
