namespace InkvoltPdf.Core;

/// <summary>How several fields line up with the first one picked: by an edge, or by their centers (in a column) or
/// middles (in a row), as the page is shown.</summary>
public enum DesignAlign { Left, Right, Top, Bottom, Center, Middle }

/// <summary>Which side several fields take from the first one picked.</summary>
public enum DesignSameSize { Width, Height, Both }

/// <summary>Spacing several fields evenly: left to right, or top to bottom, as the page is shown.</summary>
public enum DesignSpread { Across, Down }

/// <summary>Several fields selected together (Prepare Form): aligned, sized alike and spaced evenly.</summary>
public static partial class FormDesignRules
{
    /// <summary>
    /// <paramref name="selected"/> (the first is the anchor, as Acrobat's: it stays where it is) lined up by
    /// <paramref name="how"/> on the page as shown (<paramref name="page"/>: its size and the view's turn). Only the fields
    /// on the anchor's page that aren't signed move; each stays on the page. Returns the fields that moved.
    /// </summary>
    public static IReadOnlyList<DesignField> Aligned(IReadOnlyList<DesignField> selected, DesignAlign how, DesignPage page) =>
        Arranged(selected, page, (anchor, r) => how switch
        {
            DesignAlign.Left => r with { X = anchor.X },
            DesignAlign.Right => r with { X = anchor.Right - r.Width },
            DesignAlign.Top => r with { Y = anchor.Y },
            DesignAlign.Bottom => r with { Y = anchor.Bottom - r.Height },
            DesignAlign.Center => r with { X = anchor.CenterX - r.Width / 2 },
            _ => r with { Y = anchor.CenterY - r.Height / 2 },
        });

    /// <summary>
    /// <paramref name="selected"/> given the first one's width, height or both (as the page is shown), each keeping its
    /// top-left corner. A check box or radio button stays square, its side the one asked for.
    /// </summary>
    public static IReadOnlyList<DesignField> SizedAlike(IReadOnlyList<DesignField> selected, DesignSameSize side, DesignPage page) =>
        Arranged(selected, page, (anchor, r) => side switch
        {
            DesignSameSize.Width => r with { Width = anchor.Width },
            DesignSameSize.Height => r with { Height = anchor.Height },
            _ => r with { Width = anchor.Width, Height = anchor.Height },
        }, square: side);

    /// <summary>
    /// <paramref name="selected"/> spaced evenly <paramref name="way"/>: the first and last (left to right, or top to
    /// bottom, as shown) stay, the ones between get equal gaps. Refused for fewer than three.
    /// </summary>
    public static IReadOnlyList<DesignField> Spread(IReadOnlyList<DesignField> selected, DesignSpread way, DesignPage page)
    {
        var movable = Movable(selected);
        if (movable.Count < 3) throw new DesignRefusal(PdfStrings.Form_SpreadNeedsThree);
        var across = way == DesignSpread.Across;
        var shown = movable.Select(f => (Field: f, Rect: ToView(f.Rect, page)))
            .OrderBy(x => across ? x.Rect.X : x.Rect.Y).ThenBy(x => across ? x.Rect.Y : x.Rect.X).ToList();
        var first = shown[0].Rect;
        var last = shown[^1].Rect;
        var span = across ? last.Right - first.X : last.Bottom - first.Y;
        var gap = (span - shown.Sum(x => across ? x.Rect.Width : x.Rect.Height)) / (shown.Count - 1);
        var at = across ? first.Right + gap : first.Bottom + gap;
        var moved = new List<DesignField>();
        for (var i = 1; i < shown.Count - 1; i++)
        {
            var r = shown[i].Rect;
            var to = across ? r with { X = at } : r with { Y = at };
            at += (across ? r.Width : r.Height) + gap;
            if (Placed(shown[i].Field, to, page) is { } f) moved.Add(f);
        }
        return moved;
    }

    /// <summary>The selected fields an arrangement may move: on the anchor's page, not signed.</summary>
    private static List<DesignField> Movable(IReadOnlyList<DesignField> selected) =>
        selected.Count == 0 ? [] : [.. selected.Where(f => f.PageIndex == selected[0].PageIndex && !f.Signed).DistinctBy(f => f.Id)];

    private static IReadOnlyList<DesignField> Arranged(IReadOnlyList<DesignField> selected, DesignPage page, Func<RectD, RectD, RectD> arrange, DesignSameSize? square = null)
    {
        if (selected.Count < 2) throw new DesignRefusal(PdfStrings.Form_ArrangeNeedsTwo);
        var anchor = ToView(selected[0].Rect, page);
        var moved = new List<DesignField>();
        foreach (var f in Movable(selected).Where(f => f.Id != selected[0].Id))
        {
            var r = arrange(anchor, ToView(f.Rect, page));
            if (square is { } side && f.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio)
            {
                var s = side == DesignSameSize.Height ? r.Height : r.Width;
                r = r with { Width = s, Height = s };
            }
            if (Placed(f, r, page) is { } done) moved.Add(done);
        }
        return moved;
    }

    /// <summary>The field at <paramref name="view"/> (as shown), kept on the page and no smaller than the designer
    /// allows; null when that doesn't change it.</summary>
    private static DesignField? Placed(DesignField f, RectD view, DesignPage page)
    {
        var (vw, vh) = RotatedView.Size(page.Width, page.Height, page.Rotation);
        var w = Math.Clamp(view.Width, FormDesigner.MinSize, Math.Max(FormDesigner.MinSize, vw));
        var h = Math.Clamp(view.Height, FormDesigner.MinSize, Math.Max(FormDesigner.MinSize, vh));
        var kept = new RectD(Math.Clamp(view.X, 0, Math.Max(0, vw - w)), Math.Clamp(view.Y, 0, Math.Max(0, vh - h)), w, h);
        var rect = RotatedView.FromView(kept, page.Width, page.Height, page.Rotation);
        return Near(rect, f.Rect) ? null : f with { Rect = rect };
    }

    private static bool Near(RectD a, RectD b) =>
        Math.Abs(a.X - b.X) < 0.01 && Math.Abs(a.Y - b.Y) < 0.01 && Math.Abs(a.Width - b.Width) < 0.01 && Math.Abs(a.Height - b.Height) < 0.01;

    private static RectD ToView(RectD r, DesignPage page) => RotatedView.ToView(r, page.Width, page.Height, page.Rotation);
}
