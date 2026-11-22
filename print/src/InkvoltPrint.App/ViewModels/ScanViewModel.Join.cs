using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Join two halves (roadmap 4.8): an original too big for the glass scanned in two, each half with some overlap, joined into one
/// page. The overlap is found (<see cref="HalvesJoin"/>); when it isn't sure, the halves start edge to edge and the second half
/// is moved by hand. The joined page takes the two pages' place, one step back with Undo.
/// </summary>
public sealed partial class ScanViewModel
{
    /// <summary>How far one nudge moves the second half: a twentieth of an inch; with Shift, half an inch.</summary>
    private const double NudgeInches = 0.05, FarNudgeInches = 0.5;

    /// <summary>Longest side of the preview of the joined page.</summary>
    private const int JoinPreviewSize = 1600;

    /// <summary>The two halves as pixels, full size and as the preview draws them, while the join view is open.</summary>
    private sealed record JoinHalves(ScanPageViewModel First, ScanPageViewModel Second, int Channels,
        byte[] A, int WidthA, int HeightA, byte[] B, int WidthB, int HeightB,
        int PreviewFactor, byte[] SmallA, int SmallWidthA, int SmallHeightA, byte[] SmallB, int SmallWidthB, int SmallHeightB);

    private JoinHalves? _join;

    /// <summary>The first of the two pages being joined; null when the join view is closed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsJoining), nameof(IsAdjustingPage), nameof(JoinTitle))]
    public partial ScanPageViewModel? JoinPage { get; set; }

    public bool IsJoining => JoinPage is not null;

    public string JoinTitle => JoinPage is { } page ? string.Format(Strings.Scan_JoinTitle, page.Number, page.Number + 1) : "";

    /// <summary>The joined page as it would be, small.</summary>
    [ObservableProperty] public partial BitmapSource? JoinImage { get; set; }

    /// <summary>Found, not found (move it by hand), or working.</summary>
    [ObservableProperty] public partial string? JoinStatus { get; set; }

    /// <summary>Where the second half lies on the first, in the full-size pixels.</summary>
    private JoinPlacement? _placement;

    /// <summary>Opens the join view on <paramref name="page"/> and the page after it, with the overlap found (or a guess to move).</summary>
    [RelayCommand]
    private async Task JoinWithNextAsync(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        var index = Pages.IndexOf(page);
        if (index < 0) return;
        if (index == Pages.Count - 1)
        {
            Message = string.Format(Strings.Scan_JoinNoNext, page.Number);
            Prompt.Announce(Message);
            return;
        }
        var next = Pages[index + 1];
        if (page.IsSeparator || next.IsSeparator || page.FindsPhotos || next.FindsPhotos)
        {
            Message = string.Format(Strings.Scan_JoinCant, page.Number);
            Prompt.Announce(Message);
            return;
        }
        if (page.Dpi != next.Dpi)
        {
            Message = Strings.Scan_JoinDpi;
            Prompt.Announce(Message);
            return;
        }
        CancelCrop();
        CancelPhotos();
        CancelClean();
        JoinPage = page;
        JoinImage = null;
        JoinStatus = Strings.Scan_JoinFinding;
        Prompt.Announce(JoinStatus);
        try
        {
            var (first, second, dpi) = (page, next, page.Dpi);
            var (edits1, edits2) = (first.Edits, second.Edits);
            var (halves, found) = await Task.Run(() =>
            {
                var color = !first.IsGrey || !second.IsGrey;
                var a = ScanImaging.Pixels(first.Original, edits1, dpi, color);
                var b = ScanImaging.Pixels(second.Original, edits2, dpi, color);
                // About 100 pixels an inch to find the overlap on.
                var analysis = Math.Max(1, (int)Math.Round(dpi / 100.0));
                var found = HalvesJoin.Find(HalvesJoin.Gray(a.Pixels, a.Width, a.Height, a.Channels, analysis),
                    HalvesJoin.Gray(b.Pixels, b.Width, b.Height, b.Channels, analysis), dpi / (double)analysis);
                var preview = Math.Max(1, (int)Math.Ceiling(2.0 * Math.Max(Math.Max(a.Width, a.Height), Math.Max(b.Width, b.Height)) / JoinPreviewSize));
                var smallA = HalvesJoin.Shrink(a.Pixels, a.Width, a.Height, a.Channels, preview);
                var smallB = HalvesJoin.Shrink(b.Pixels, b.Width, b.Height, b.Channels, preview);
                var halves = new JoinHalves(first, second, a.Channels, a.Pixels, a.Width, a.Height, b.Pixels, b.Width, b.Height,
                    preview, smallA.Pixels, smallA.Width, smallA.Height, smallB.Pixels, smallB.Width, smallB.Height);
                return (halves, found with { Placement = found.Placement.Scaled(analysis) });
            });
            if (JoinPage != page) return; // closed meanwhile
            _join = halves;
            _placement = found.Placement;
            JoinStatus = found.Sure ? Strings.Scan_JoinFound : Strings.Scan_JoinNotFound;
            Prompt.Announce(JoinStatus);
            ShowJoin();
        }
        catch (Exception ex)
        {
            Log.Write($"Join failed: {ex}");
            if (JoinPage == page) CancelJoin();
            Message = Strings.Scan_JoinFailed;
        }
    }

    /// <summary>The preview drawn again with the second half where it is now.</summary>
    private void ShowJoin()
    {
        if (_join is not { } j || _placement is not { } at) return;
        var small = HalvesJoin.Join(j.SmallA, j.SmallWidthA, j.SmallHeightA, j.SmallB, j.SmallWidthB, j.SmallHeightB, j.Channels, at.Scaled(1.0 / j.PreviewFactor));
        JoinImage = small is { } s ? ScanImaging.Bitmap(s.Pixels, s.Width, s.Height, j.Channels) : null;
    }

    /// <summary>Moves the second half: "left", "right", "up" or "down", a twentieth of an inch; "far-…" half an inch.</summary>
    [RelayCommand]
    private void NudgeJoin(string? direction)
    {
        if (_join is not { } j || _placement is not { } at || direction is null) return;
        var far = direction.StartsWith("far-", StringComparison.Ordinal);
        var step = Math.Max(1, (int)Math.Round(j.First.Dpi * (far ? FarNudgeInches : NudgeInches)));
        var (dx, dy) = (far ? direction[4..] : direction) switch
        {
            "left" => (-step, 0),
            "right" => (step, 0),
            "up" => (0, -step),
            "down" => (0, step),
            _ => (0, 0),
        };
        _placement = at.Nudged(dx, dy);
        ShowJoin();
    }

    /// <summary>The second half turned half a turn (an original turned round on the glass for its other half), where it lies.</summary>
    [RelayCommand]
    private void TurnSecondHalf()
    {
        if (_placement is not { } at) return;
        _placement = at with { Turned = !at.Turned };
        ShowJoin();
    }

    /// <summary>The second half on the next side of the first (right, below, left, above), edge to edge, to move from there.</summary>
    [RelayCommand]
    private void JoinOtherSide()
    {
        if (_join is not { } j || _placement is not { } at) return;
        var side = (JoinSide)(((int)at.Side + 1) % 4);
        _placement = HalvesJoin.EdgeToEdge(side, at.Turned, j.WidthA, j.HeightA, j.WidthB, j.HeightB);
        ShowJoin();
    }

    /// <summary>Join: the joined page takes the two pages' place; Undo puts them back.</summary>
    [RelayCommand]
    private async Task ApplyJoinAsync()
    {
        if (_join is not { } j || _placement is not { } at || IsBusy) return;
        var index = Pages.IndexOf(j.First);
        if (index < 0 || index + 1 >= Pages.Count || Pages[index + 1] != j.Second)
        {
            CancelJoin(); // the pages moved or went meanwhile
            return;
        }
        IsBusy = true;
        JoinStatus = Strings.Scan_Working;
        try
        {
            var jpeg = await Task.Run(() =>
            {
                var joined = HalvesJoin.Join(j.A, j.WidthA, j.HeightA, j.B, j.WidthB, j.HeightB, j.Channels, at);
                return joined is { } p ? ScanImaging.Jpeg(ScanImaging.Bitmap(p.Pixels, p.Width, p.Height, j.Channels, j.First.Dpi)) : null;
            });
            if (jpeg is null)
            {
                JoinStatus = Strings.Scan_JoinTooLarge;
                Prompt.Announce(JoinStatus);
                return;
            }
            var (first, second) = (j.First, j.Second);
            var page = new ScanPageViewModel(jpeg, first.Dpi, first.Ocr || second.Ocr, first.OcrLanguage) { OneBit = first.OneBit && second.OneBit };
            var (a, b) = (first.Number, second.Number);
            History.Record(string.Format(Strings.Scan_UndoJoin, a, b), () =>
            {
                var at = Pages.IndexOf(page);
                if (at < 0) return;
                page.PropertyChanged -= PageChanged;
                Pages.RemoveAt(at);
                first.PropertyChanged += PageChanged;
                second.PropertyChanged += PageChanged;
                Pages.Insert(at, second);
                Pages.Insert(at, first);
            });
            first.PropertyChanged -= PageChanged;
            second.PropertyChanged -= PageChanged;
            Pages.RemoveAt(index + 1);
            Pages.RemoveAt(index);
            page.PropertyChanged += PageChanged;
            Pages.Insert(index, page);
            _ = page.AnalyseAsync(skipBlank: false, straighten: false); // done at once; the text is read in the background
            CancelJoin();
            Message = string.Format(Strings.Scan_Joined, a, b);
            Prompt.Announce(Message);
        }
        catch (Exception ex)
        {
            Log.Write($"Join failed: {ex}");
            JoinStatus = Strings.Scan_JoinFailed;
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private void CancelJoin()
    {
        JoinPage = null;
        JoinImage = null;
        JoinStatus = null;
        _join = null;
        _placement = null;
    }
}
