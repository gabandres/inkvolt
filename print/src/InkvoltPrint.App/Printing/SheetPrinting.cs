using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Sheets;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// Print a PDF's layouts (roadmap 4.18): pages per sheet, a booklet and a poster, laid out by the shared core's
/// <see cref="PrintLayout"/> (Inkvolt PDF's) through <see cref="SheetPrint"/>, sent where the printer's other prints go: its
/// Windows queue, straight to the printer, or two-sided by hand.
/// </summary>
public static class SheetPrinting
{
    /// <summary>
    /// Draws the chosen pages and prints them laid out by <paramref name="setup"/>; two-sided as <see cref="SheetPrint.TwoSided"/>
    /// says, by hand (<paramref name="byHand"/>) when the printer can't. Returns how far it got.
    /// </summary>
    public static async Task<HandDuplexOutcome> PrintAsync(PrintTarget target, PdfSource pdf, PrintOptions options, PrintSetup setup,
        HandDuplexPrinter? byHand, IProgress<string> progress, CancellationToken ct, Action? onSpooling = null, Action? onSent = null)
    {
        var pages = await PrintTargets.RenderAsync(pdf, options.Pages, progress, ct, SheetPrint.RenderDpi(setup));
        var twoSided = SheetPrint.TwoSided(setup, options.TwoSided);
        if (twoSided && byHand is not null)
        {
            // A booklet's or pages per sheet's sides don't depend on the paper: count them on any.
            var (w, h) = SheetPrint.GuessPaper(false);
            var sides = SheetPrint.Plan(Sizes(pages), w, h, setup).SheetCount;
            var plan = HandDuplexPlan.For([.. Enumerable.Range(0, sides)], options.Copies);
            return await HandDuplexPrinting.PrintAsync(target, plan,
                order => (paper, images) => new SheetsPaginator(pages, setup, order, twoSided: true, copies: 1, paper, images),
                options.JobName, byHand, progress, ct, onSpooling, onSent);
        }
        DocumentPaginator Paginator(Size paper, PrintImages images) => new SheetsPaginator(pages, setup, null, twoSided, options.Copies, paper, images);
        switch (target)
        {
            case PrintTarget.Queue q:
                ct.ThrowIfCancellationRequested();
                onSpooling?.Invoke();
                progress.Report(Strings.Print_SendingSheets);
                await QueuePrinter.PrintPassAsync(q.Name, twoSided, options.JobName, Paginator);
                onSent?.Invoke();
                return HandDuplexOutcome.Both;
            case PrintTarget.Direct d:
                await DirectPrinter.PrintAsync(d, options.JobName, new DirectPrintRequest(1, twoSided), Paginator, progress, ct, onSpooling, onSent);
                return HandDuplexOutcome.Both;
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }

    /// <summary>Pages' sizes as the layout reads them (DIPs).</summary>
    public static IReadOnlyList<(double W, double H)> Sizes(IReadOnlyList<RenderedPage> pages) =>
        [.. pages.Select(p => (p.WidthInches * 96, p.HeightInches * 96))];

    /// <summary>
    /// Drawn pages laid out on sheets (<see cref="SheetPrint.Plan"/> for the paper the job prints on): each placed page clipped to
    /// what it shows (a poster's part) and turned as placed, cut marks as thin lines, a turned sheet's backs upside down when
    /// printed on both sides (<see cref="SheetPrint.HalfTurned"/>). <paramref name="order"/>: the sides to print (−1 blank), else
    /// every side and copy (<see cref="SheetPrint.Order"/>). The pictures stay JPEGs in the job.
    /// </summary>
    internal sealed class SheetsPaginator : DocumentPaginator
    {
        private readonly IReadOnlyList<RenderedPage> _pages;
        private readonly PrintPlan _plan;
        private readonly IReadOnlyList<int> _order;
        private readonly bool _twoSided;
        private readonly Size _paper;
        private readonly PrintImages _images;
        private readonly Dictionary<int, System.Windows.Media.Imaging.BitmapFrame> _frames = [];

        public SheetsPaginator(IReadOnlyList<RenderedPage> pages, PrintSetup setup, IReadOnlyList<int>? order, bool twoSided, int copies, Size paper, PrintImages images)
        {
            _pages = pages;
            _plan = SheetPrint.Plan(Sizes(pages), paper.Width, paper.Height, setup);
            // The printer's paper can hold fewer tiles than the paper the job was counted on: still never more than the limit.
            if (_plan.SheetCount * (long)Math.Max(1, copies) > SheetPrint.MaxSides * 2L)
                throw new InvalidOperationException(string.Format(Strings.PrintLayout_TooMany, SheetPrint.MaxSides));
            _order = order ?? SheetPrint.Order(_plan.SheetCount, copies, twoSided);
            _twoSided = twoSided;
            _paper = paper;
            _images = images;
        }

        public override bool IsPageCountValid => true;
        public override int PageCount => _order.Count;
        public override Size PageSize { get => _paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var page = new Canvas { Width = _paper.Width, Height = _paper.Height, Background = Brushes.White };
            if (_order[pageNumber] is var side and >= 0 && side < _plan.SheetCount)
            {
                var sheet = _plan.Sheet(side);
                var content = new Canvas { Width = _paper.Width, Height = _paper.Height };
                if (SheetPrint.HalfTurned(sheet, side, _twoSided)) content.RenderTransform = new RotateTransform(180, _paper.Width / 2, _paper.Height / 2);
                foreach (var placed in sheet.Pages) content.Children.Add(Placed(placed));
                foreach (var m in sheet.Marks)
                    content.Children.Add(new Line { X1 = m.X1, Y1 = m.Y1, X2 = m.X2, Y2 = m.Y2, Stroke = Brushes.Black, StrokeThickness = 0.75 });
                page.Children.Add(content);
            }
            page.Measure(_paper);
            page.Arrange(new Rect(_paper));
            page.UpdateLayout();
            return new DocumentPage(page, _paper, new Rect(_paper), new Rect(_paper));
        }

        /// <summary>One placed page: a box the size of the part shown (before its turn), clipping the whole page drawn to scale in it.</summary>
        private Canvas Placed(PlacedPage placed)
        {
            var drawn = _pages[placed.Page];
            var (pageW, pageH) = (drawn.WidthInches * 96, drawn.HeightInches * 96);
            var shown = placed.Source ?? new Placement(0, 0, pageW, pageH);
            var turned = placed.Turns == 1;
            var (w, h) = turned ? (placed.Box.Height, placed.Box.Width) : (placed.Box.Width, placed.Box.Height);
            var scale = shown.Width > 0 ? w / shown.Width : 1;
            var box = new Canvas { Width = w, Height = h, ClipToBounds = true, LayoutTransform = turned ? new RotateTransform(90) : Transform.Identity };
            if (!_frames.TryGetValue(placed.Page, out var frame)) _frames[placed.Page] = frame = _images.Jpeg(drawn.Image);
            var image = new Image { Source = frame, Stretch = Stretch.Fill, Width = pageW * scale, Height = pageH * scale };
            Canvas.SetLeft(image, -shown.X * scale);
            Canvas.SetTop(image, -shown.Y * scale);
            box.Children.Add(image);
            Canvas.SetLeft(box, placed.Box.X);
            Canvas.SetTop(box, placed.Box.Y);
            return box;
        }
    }
}
