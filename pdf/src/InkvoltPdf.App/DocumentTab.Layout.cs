using System.Globalization;
using System.Windows;
using System.Windows.Input;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Rulers, guides, a grid and snapping (roadmap 4.19): the settings (View menu) on this tab's page views, and the guides
/// kept on the session (never written into the PDF; they go when the page count changes, as they were for those pages).
/// </summary>
public partial class DocumentTab
{
    private int _guidePages = -1;

    private void InitLayoutAids()
    {
        ApplyLayoutAids();
        Viewer.GuidesChanged += (_, _) => CommandManager.InvalidateRequerySuggested();
        Session.ContentChanged += (_, _) =>
        {
            if (_guidePages >= 0 && Viewer.PageCount > 0 && Viewer.PageCount != _guidePages) Session.Guides.PagesChanged();
            _guidePages = Viewer.PageCount;
        };
    }

    /// <summary>The settings on this tab's views (both panes of a split), and its guides.</summary>
    internal void ApplyLayoutAids()
    {
        var s = AppSettings.Current;
        foreach (var v in new[] { Viewer, _second }.OfType<PageViewer>())
        {
            if (!ReferenceEquals(v.Guides, Session.Guides)) v.Guides = Session.Guides;
            if (v.ShowRulers != s.ShowRulers) v.ShowRulers = s.ShowRulers;
            if (v.ShowGrid != s.ShowGrid) v.ShowGrid = s.ShowGrid;
            v.SnapToGuides = s.SnapToGuides;
            v.SnapToGrid = s.SnapToGrid;
            v.SnapToObjects = s.SnapToObjects;
            v.GridStep = s.GridStep >= 1 ? s.GridStep : 18;
            v.RulerUnitSetting = RulerUnit.Choices.Contains(s.RulerUnit) ? s.RulerUnit : "auto";
        }
        if (_guidePages < 0 && Viewer.PageCount > 0) _guidePages = Viewer.PageCount;
    }

    public bool HasGuides => Session.Guides.All.Count > 0;

    /// <summary>View › Clear Guides: every page's.</summary>
    internal void ClearGuides()
    {
        var n = Session.Guides.Clear();
        foreach (var v in new[] { Viewer, _second }.OfType<PageViewer>()) v.Guides = Session.Guides; // drawn again
        Notify(Loc.Plural(n, Strings.Layout_GuidesCleared_One, Strings.Layout_GuidesCleared_Many));
    }

    /// <summary>After Ruler Units: which unit the rulers count in now.</summary>
    internal void SayRulerUnit() =>
        Notify(Loc.Format(Strings.Layout_RulerUnit, AppSettings.Current.RulerUnit == "auto" ? Loc.Format(Strings.Layout_UnitAuto, ActiveView.RulerUnitOn(ActiveView.CurrentPage).Name) : AppSettings.Current.RulerUnit));

    /// <summary>View › Grid Spacing…: the grid's step from a short list, in the rulers' unit where it is one of its own.</summary>
    internal static double? AskGridStep(Window owner)
    {
        var steps = LayoutAids.GridSteps;
        string Label(double pt) => pt switch
        {
            18 => Strings.Layout_GridQuarterInch,
            36 => Strings.Layout_GridHalfInch,
            72 => Strings.Layout_GridInch,
            10 => Strings.Layout_Grid10Points,
            _ when Math.Abs(pt - 72 / 2.54) < 0.01 => Strings.Layout_Grid1Cm,
            _ => Strings.Layout_Grid5Mm,
        };
        var dlg = new FormDialog(owner, Strings.Layout_GridTitle);
        var current = steps.ToList().FindIndex(x => Math.Abs(x - AppSettings.Current.GridStep) < 0.01);
        var box = dlg.AddChoice(Strings.Layout_GridEvery, steps.Select(Label), Math.Max(0, current));
        dlg.AddNote(Strings.Layout_GridNote);
        return dlg.ShowModal() && box.SelectedIndex >= 0 ? steps[box.SelectedIndex] : null;
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    internal string DevLayoutState()
    {
        var v = ActiveView;
        var page = v.CurrentPage;
        return $"layout: rulers={v.ShowRulers} grid={v.ShowGrid} step={v.GridStep.ToString("0.##", CultureInfo.InvariantCulture)} snap guides={v.SnapToGuides} grid={v.SnapToGrid} objects={v.SnapToObjects} " +
               $"unit={v.RulerUnitOn(page).Name} guides=[{string.Join(" ", Session.Guides.All.Select(g => $"p{g.Page + 1}:{g.Axis}={g.At.ToString("0.##", CultureInfo.InvariantCulture)}"))}]";
    }
}
