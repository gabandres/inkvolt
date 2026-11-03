using System.Collections.Specialized;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Motion in the scan review (UX-REVIEW Print "Still short"): which page moves when one is put back, deleted or moved, and
/// none while a scan or a save shows its progress, while a page is dragged, or for a list filled at once.
/// </summary>
public class ReviewMotionTests
{
    private static ReviewMotion.Step For(NotifyCollectionChangedAction action, int newIndex = -1, int oldIndex = -1, int count = 5,
        int changed = 1, bool busy = false, bool dragging = false) =>
        ReviewMotion.For(action, newIndex, oldIndex, count, changed, busy, dragging);

    [Fact]
    public void A_page_put_back_rises_into_its_place()
    {
        Assert.Equal(new ReviewMotion.Step(ReviewMotion.Kind.Arrive, 2), For(NotifyCollectionChangedAction.Add, newIndex: 2));
        Assert.Equal(8, ReviewMotion.Rise(ReviewMotion.Kind.Arrive));
        Assert.Equal(0, ReviewMotion.Slide(ReviewMotion.Kind.Arrive));
    }

    [Fact]
    public void After_a_delete_the_page_taking_its_place_fades_in()
    {
        Assert.Equal(new ReviewMotion.Step(ReviewMotion.Kind.Fade, 1), For(NotifyCollectionChangedAction.Remove, oldIndex: 1, count: 4));
        // The last page deleted: nothing takes its place.
        Assert.Equal(ReviewMotion.None, For(NotifyCollectionChangedAction.Remove, oldIndex: 4, count: 4));
        Assert.Equal((0, 0), (ReviewMotion.Rise(ReviewMotion.Kind.Fade), ReviewMotion.Slide(ReviewMotion.Kind.Fade)));
    }

    [Fact]
    public void A_moved_page_slides_in_from_the_side_it_came_from()
    {
        var later = For(NotifyCollectionChangedAction.Move, newIndex: 3, oldIndex: 2);
        Assert.Equal(new ReviewMotion.Step(ReviewMotion.Kind.FromBefore, 3), later);
        Assert.True(ReviewMotion.Slide(later.Kind) < 0); // it came from the left (earlier in the grid)
        var earlier = For(NotifyCollectionChangedAction.Move, newIndex: 0, oldIndex: 2);
        Assert.Equal(new ReviewMotion.Step(ReviewMotion.Kind.FromAfter, 0), earlier);
        Assert.True(ReviewMotion.Slide(earlier.Kind) > 0);
        Assert.Equal(0, ReviewMotion.Rise(later.Kind));
    }

    [Theory]
    [InlineData(NotifyCollectionChangedAction.Add)]
    [InlineData(NotifyCollectionChangedAction.Remove)]
    [InlineData(NotifyCollectionChangedAction.Move)]
    public void Nothing_moves_while_a_scan_or_save_shows_its_progress(NotifyCollectionChangedAction action) =>
        Assert.Equal(ReviewMotion.None, For(action, newIndex: 1, oldIndex: 2, busy: true));

    [Fact]
    public void Nothing_moves_while_a_page_is_dragged_since_it_follows_the_pointer() =>
        Assert.Equal(ReviewMotion.None, For(NotifyCollectionChangedAction.Move, newIndex: 1, oldIndex: 2, dragging: true));

    [Theory]
    [InlineData(NotifyCollectionChangedAction.Reset)]
    [InlineData(NotifyCollectionChangedAction.Replace)]
    public void A_list_cleared_or_replaced_doesnt_move(NotifyCollectionChangedAction action) =>
        Assert.Equal(ReviewMotion.None, For(action, newIndex: 0, oldIndex: 0));

    [Fact]
    public void Several_pages_at_once_dont_move()
    {
        Assert.Equal(ReviewMotion.None, For(NotifyCollectionChangedAction.Add, newIndex: 0, changed: 3));
        Assert.Equal(ReviewMotion.None, For(NotifyCollectionChangedAction.Add, newIndex: -1));
    }

    [Fact]
    public void The_motion_is_the_apps_fast_one() => Assert.Equal(TimeSpan.FromMilliseconds(167), ReviewMotion.Duration);
}
