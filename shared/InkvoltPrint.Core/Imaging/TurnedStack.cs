namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// Two-sided scanning on a one-sided feeder: the fronts of a stack, then the stack turned over and its backs, put together
/// in page order. Turned over, the stack's last sheet comes first, so the backs arrive last sheet first
/// (<see cref="BacksReversed"/>); on a scanner whose output tray reverses the stack itself they arrive first sheet first,
/// which the review can switch to. When the counts differ (a sheet fed twice, one left behind) the backs are matched from
/// the end they began at, the sheets past it keep one side, and the review says so.
/// </summary>
public static class TurnedStack
{
    public const bool BacksReversed = true;

    /// <summary>
    /// The pages in order, as indexes into the fronts (0 to <paramref name="fronts"/> − 1) followed by the backs
    /// (<paramref name="fronts"/> on), each front followed by its back. Backs with no front left over go at the end, as scanned.
    /// </summary>
    /// <param name="reversed">The backs came last sheet first (the usual way: <see cref="BacksReversed"/>).</param>
    public static IReadOnlyList<int> Order(int fronts, int backs, bool reversed = BacksReversed)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(fronts);
        ArgumentOutOfRangeException.ThrowIfNegative(backs);
        // backOf[f]: the back scanned for front f, or -1. Reversed, the first back is the last front's.
        var backOf = new int[fronts];
        Array.Fill(backOf, -1);
        var paired = Math.Min(fronts, backs);
        for (var j = 0; j < paired; j++)
            backOf[reversed ? fronts - 1 - j : j] = j;
        var order = new List<int>(fronts + backs);
        for (var f = 0; f < fronts; f++)
        {
            order.Add(f);
            if (backOf[f] >= 0) order.Add(fronts + backOf[f]);
        }
        for (var j = paired; j < backs; j++) order.Add(fronts + j);
        return order;
    }

    /// <summary>
    /// <paramref name="pages"/> (all its fronts, then all its backs, as scanned) put in order: <see cref="Order"/> applied.
    /// </summary>
    public static List<T> Arrange<T>(IReadOnlyList<T> fronts, IReadOnlyList<T> backs, bool reversed = BacksReversed) =>
        [.. Order(fronts.Count, backs.Count, reversed).Select(i => i < fronts.Count ? fronts[i] : backs[i - fronts.Count])];

    /// <summary>
    /// The same pages in the other back order, wherever they are now: the stack's pages still in <paramref name="current"/>
    /// (others the review deleted stay deleted, pages from other scans stay where they are) go into the places they hold
    /// now, in <see cref="Arrange"/>'s order with <paramref name="reversed"/>.
    /// </summary>
    public static List<T> Rearrange<T>(IReadOnlyList<T> current, IReadOnlyList<T> fronts, IReadOnlyList<T> backs, bool reversed) where T : class =>
        InPlaces(current, Arrange(fronts, backs, reversed));

    /// <summary>
    /// <paramref name="current"/> with the pages of <paramref name="order"/> it holds put in that order, in the places they
    /// hold now; every other page stays where it is. (Undo puts a stack back as scanned with its fronts, then its backs.)
    /// </summary>
    public static List<T> InPlaces<T>(IReadOnlyList<T> current, IEnumerable<T> order) where T : class
    {
        var here = new HashSet<T>(current, ReferenceEqualityComparer.Instance);
        var wanted = order.Where(here.Contains).Distinct(ReferenceEqualityComparer.Instance).Cast<T>().ToList();
        var mine = new HashSet<T>(wanted, ReferenceEqualityComparer.Instance);
        var result = new List<T>(current.Count);
        var next = 0;
        foreach (var page in current)
            result.Add(mine.Contains(page) ? wanted[next++] : page);
        return result;
    }
}
