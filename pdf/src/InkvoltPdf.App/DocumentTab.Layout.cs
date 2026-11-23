using System.Globalization;
using System.Windows;
using System.Windows.Input;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Rulers, guides, a grid and snapping (roadmap 4.19): the settings (View menu) on this tab's page views, and the guides
/// kept on the session (never written into the PDF): they follow their pages when pages move, and go with a page that is
/// deleted, turned, resized or replaced (PageGuides.Keys, Remap).
/// </summary>
public partial class DocumentTab
{
    private (byte[] Data, IReadOnlyList<string> Keys)? _guideKeys; // each page's identity when the guides were last placed
    private int _guideTicket;
    private CancellationTokenSource? _guideKeying, _guideRemapping; // stop the reads an earlier one would have dropped

    /// <summary>Stops the read <paramref name="running"/> holds (a huge file reads for long) and starts another's token.</summary>
    private static CancellationToken Restart(ref CancellationTokenSource? running)
    {
        running?.Cancel();
        running = new CancellationTokenSource();
        return running.Token;
    }

    private void InitLayoutAids()
    {
        ApplyLayoutAids();
        Viewer.GuidesChanged += (_, _) =>
        {
            CommandManager.InvalidateRequerySuggested();
            _ = KeyGuidesAsync();
        };
        Session.ContentChanged += (_, e) =>
        {
            if (Session.Guides.All.Count == 0)
            {
                _guideKeys = null;
                return;
            }
            // A form value or Fill & Sign edit leaves the pages as they were.
            if (e.ContentOnly && _guideKeys is { } k) _guideKeys = (Session.Data, k.Keys);
            else _ = RemapGuidesAsync();
        };
    }

    /// <summary>Reads each page's identity (off the UI thread) once guides are placed, to follow the pages through later edits.</summary>
    private async Task KeyGuidesAsync()
    {
        if (Session.Guides.All.Count == 0 || ReferenceEquals(_guideKeys?.Data, Session.Data) || !Session.IsPdf) return;
        var (data, pw) = (Session.Data, Session.Password);
        var cancel = Restart(ref _guideKeying);
        try
        {
            var keys = await Task.Run(() => PageGuides.Keys(data, pw, cancel), cancel);
            if (ReferenceEquals(data, Session.Data)) _guideKeys = (data, keys);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            // A later read took over.
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reading the pages for their guides failed: {ex.Message}");
        }
    }

    /// <summary>
    /// The pages may have moved, turned or been replaced: each page's guides follow it (PageGuides.Remap), a page that is
    /// gone or changed takes them with it; when the pages couldn't be told apart, they all go.
    /// </summary>
    private async Task RemapGuidesAsync()
    {
        var before = _guideKeys;
        var ticket = ++_guideTicket;
        var (data, pw) = (Session.Data, Session.Password);
        _guideKeying?.Cancel(); // the version it reads is gone
        var cancel = Restart(ref _guideRemapping);
        IReadOnlyList<string>? keys = null;
        try
        {
            keys = await Task.Run(() => PageGuides.Keys(data, pw, cancel), cancel);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            return; // a later edit's read took over (its ticket is newer)
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reading the pages for their guides failed: {ex.Message}");
        }
        if (ticket != _guideTicket || _disposed) return;
        if (before is null || keys is null) Session.Guides.Clear();
        else Session.Guides.Remap(before.Value.Keys, keys);
        _guideKeys = keys is null ? null : (data, keys);
        foreach (var v in new[] { Viewer, _second }.OfType<PageViewer>()) v.Guides = Session.Guides; // drawn again
        CommandManager.InvalidateRequerySuggested();
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
