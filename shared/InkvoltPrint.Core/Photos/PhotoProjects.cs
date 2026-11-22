using System.Globalization;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Photos;

/// <summary>A line drawn on a sheet (fold and cut marks, a calendar's grid), in inches from the paper's top-left corner.</summary>
public readonly record struct SheetLine(double X1, double Y1, double X2, double Y2, bool Dashed = false);

public enum SheetTextAlign { Left, Center, Right }

/// <summary>
/// Text drawn on a sheet: wrapped within <see cref="Box"/> (inches, from the paper's top-left), <see cref="Size"/> the font's
/// size in inches, <see cref="Bold"/> for titles, <see cref="Muted"/> in grey (days of a calendar's next month left out are never drawn).
/// </summary>
public sealed record SheetText(string Text, Placement Box, double Size, SheetTextAlign Align = SheetTextAlign.Center, bool Bold = false, bool Muted = false);

/// <summary>A collage's arrangement: rows as even as can be, columns as even as can be, or the first photo large above the rest.</summary>
public enum CollageArrangement { Rows, Columns, OneLarge }

/// <summary>
/// Cards, calendars and collages (roadmap 4.16): sheets made from the photos with words and marks on them, laid out here in
/// inches (pure arithmetic and the interface language's calendar), drawn by the app exactly as photo sheets are (preview, print,
/// PDF). Photos are never turned to suit a cell here: a sideways picture in a card or a calendar would read sideways.
/// </summary>
public static class PhotoProjects
{
    /// <summary>Photos one collage holds; more make another collage sheet.</summary>
    public const int MaxCollage = 9;

    /// <summary>A card's message is cut to this many characters (it has half a page at most).</summary>
    public const int MaxMessage = 400;

    /// <summary>Spacing and border choices for collages, inches.</summary>
    public static IReadOnlyList<double> Spacings { get; } = [0, 0.08, 0.2];
    public static IReadOnlyList<double> Borders { get; } = [0, 0.25, 0.5];

    /// <summary>Space kept between a card panel's edge (its fold or the cut between two cards) and what is printed on it.</summary>
    public const double CardPad = 0.25;

    public static bool IsProject(PhotoLayoutKind kind) =>
        kind is PhotoLayoutKind.Card or PhotoLayoutKind.MonthCalendar or PhotoLayoutKind.YearCalendar or PhotoLayoutKind.Collage;

    public static IReadOnlyList<PhotoSheet> Sheets(IReadOnlyList<PhotoInput> photos, PhotoLayoutOptions options, SheetPaper paper) =>
        photos.Count == 0 || paper.Printable is { Width: <= 0 } or { Height: <= 0 } ? [] : options.Kind switch
        {
            PhotoLayoutKind.Card => Cards(photos, options, paper),
            PhotoLayoutKind.MonthCalendar => [.. photos.Select((p, i) => MonthSheet(i, p, options, paper, i))],
            PhotoLayoutKind.YearCalendar => [.. photos.Select((p, i) => YearSheet(i, p, options, paper))],
            PhotoLayoutKind.Collage => Collages(photos, options, paper),
            _ => [],
        };

    private static PhotoCell Cell(int index, PhotoInput photo, Placement cell) =>
        new(index, cell, PhotoLayout.Place(cell, photo.Width, photo.Height, PhotoFit.Fill, photo.Crop, turned: false), false);

    private static Placement Inset(Placement p, double d) =>
        new(p.X + d, p.Y + d, Math.Max(0, p.Width - 2 * d), Math.Max(0, p.Height - 2 * d));

    // ---------------------------------------------------------------- cards

    /// <summary>
    /// Folded greeting cards, two to a sheet (the top half and the bottom half, each folded down its middle): on the outside the
    /// photo is the front (the right panel), the left panel the back; with a message, the next sheet is the inside, printed on
    /// the back of the outside (both sides, flipping on the long edge: the message lands behind the back panel, on the inside's
    /// right). Fold marks at each card's fold and cut marks between the two cards, short ticks inside the printable area.
    /// A photo's copies make more cards.
    /// </summary>
    public static IReadOnlyList<PhotoSheet> Cards(IReadOnlyList<PhotoInput> photos, PhotoLayoutOptions options, SheetPaper paper)
    {
        var cards = new List<int>();
        for (var i = 0; i < photos.Count; i++) cards.AddRange(Enumerable.Repeat(i, Math.Clamp(photos[i].Copies, 0, 999)));
        var message = Message(options.CardMessage);
        var area = paper.Printable;
        var sheets = new List<PhotoSheet>();
        for (var start = 0; start < cards.Count; start += 2)
        {
            var cells = new List<PhotoCell>();
            var lines = new List<SheetLine>();

            for (var k = 0; k < 2 && start + k < cards.Count; k++)
            {
                var card = CardBox(paper, k);
                var front = Inset(Panel(card, right: true).Intersect(area), CardPad);
                cells.Add(Cell(cards[start + k], photos[cards[start + k]], front));
                // The fold: a short tick at its top and its bottom, inside what the printer prints.
                var x = card.CenterX;
                var tick = Math.Min(0.25, card.Height / 8);
                var top = Math.Max(card.Y, area.Y);
                var bottom = Math.Min(card.Bottom, area.Bottom);
                lines.Add(new SheetLine(x, top, x, top + tick, Dashed: true));
                lines.Add(new SheetLine(x, bottom - tick, x, bottom, Dashed: true));
            }
            // Between the two cards: where to cut, a tick at each side.
            var cutY = paper.Height / 2;
            var cutTick = Math.Min(0.25, paper.Width / 8);
            lines.Add(new SheetLine(area.X, cutY, area.X + cutTick, cutY));
            lines.Add(new SheetLine(area.Right - cutTick, cutY, area.Right, cutY));
            sheets.Add(new PhotoSheet(cells) { Lines = lines });
            if (message.Length == 0) continue;
            var inside = new List<SheetText>();
            for (var k = 0; k < 2 && start + k < cards.Count; k++)
            {
                var panel = Inset(Panel(CardBox(paper, k), right: true).Intersect(area), CardPad * 2);
                inside.Add(new SheetText(message, panel, MessageSize(panel)));
            }
            sheets.Add(new PhotoSheet([]) { Texts = inside, Inside = true });
        }
        return sheets;
    }

    /// <summary>The <paramref name="k"/>th card (0 the top, 1 the bottom) on the paper: half of it, whole width.</summary>
    public static Placement CardBox(SheetPaper paper, int k) => new(0, k * paper.Height / 2, paper.Width, paper.Height / 2);

    /// <summary>A card's left or right panel: half of it, either side of the fold.</summary>
    public static Placement Panel(Placement card, bool right) =>
        new(right ? card.CenterX : card.X, card.Y, card.Width / 2, card.Height);

    /// <summary>A card's message as written: trimmed, without control characters but line breaks, at most <see cref="MaxMessage"/> characters.</summary>
    public static string Message(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        var clean = new string([.. text.Replace("\r\n", "\n").Where(c => c == '\n' || !char.IsControl(c))]).Trim();
        return clean.Length > MaxMessage ? clean[..MaxMessage] : clean;
    }

    /// <summary>The message's size: about a tenth of the panel's width, a large hand's writing (inches).</summary>
    private static double MessageSize(Placement panel) => Math.Clamp(panel.Width / 12, 0.08, 0.3);

    // ---------------------------------------------------------------- calendars

    /// <summary>The first day of the week in <paramref name="culture"/> (Sunday in English, Monday in Spanish).</summary>
    public static DayOfWeek FirstDay(CultureInfo culture) => culture.DateTimeFormat.FirstDayOfWeek;

    /// <summary>The week day names, short, from the culture's first day: "Sun".."Sat"; "lun".."dom" (the trailing period gone).</summary>
    public static IReadOnlyList<string> DayNames(CultureInfo culture)
    {
        var names = culture.DateTimeFormat.AbbreviatedDayNames;
        var first = (int)FirstDay(culture);
        return [.. Enumerable.Range(0, 7).Select(i => Capital(names[(first + i) % 7].TrimEnd('.'), culture))];
    }

    /// <summary>A month's name in <paramref name="culture"/>, its first letter capital (Spanish writes them small).</summary>
    public static string MonthName(int month, CultureInfo culture) => Capital(culture.DateTimeFormat.GetMonthName(month), culture);

    private static string Capital(string s, CultureInfo culture) => s.Length == 0 ? s : char.ToUpper(s[0], culture) + s[1..];

    /// <summary>
    /// A month as weeks from the culture's first day: each row seven day numbers, 0 where the day belongs to another month.
    /// Four to six rows.
    /// </summary>
    public static IReadOnlyList<int[]> Weeks(int year, int month, DayOfWeek firstDay)
    {
        var days = DateTime.DaysInMonth(year, month);
        var offset = ((int)new DateTime(year, month, 1).DayOfWeek - (int)firstDay + 7) % 7;
        var rows = (offset + days + 6) / 7;
        var weeks = new List<int[]>(rows);
        for (var r = 0; r < rows; r++)
        {
            var week = new int[7];
            for (var c = 0; c < 7; c++)
                if (r * 7 + c - offset + 1 is var d && d >= 1 && d <= days) week[c] = d;
            weeks.Add(week);
        }
        return weeks;
    }

    /// <summary>The <paramref name="index"/>th month from the options' first month (photo 2 of a month calendar is the month after photo 1's).</summary>
    public static (int Year, int Month) MonthAt(int year, int month, int index)
    {
        var start = new DateTime(Math.Clamp(year, 1, 9998), Math.Clamp(month, 1, 12), 1).AddMonths(Math.Clamp(index, 0, 1200));
        return (start.Year, start.Month);
    }

    /// <summary>A month's sheet: the photo over the top half, the month's name and year, and its days in a grid of weeks.</summary>
    public static PhotoSheet MonthSheet(int photo, PhotoInput input, PhotoLayoutOptions options, SheetPaper paper, int index)
    {
        var culture = options.Culture ?? CultureInfo.InvariantCulture;
        var (year, month) = MonthAt(options.CalendarYear, options.CalendarMonth, index);
        var area = Inset(paper.Printable, 0.1);
        var photoBox = new Placement(area.X, area.Y, area.Width, area.Height * 0.52);
        var titleH = area.Height * 0.07;
        var title = new SheetText($"{MonthName(month, culture)} {year.ToString(culture)}", new Placement(area.X, photoBox.Bottom + area.Height * 0.02, area.Width, titleH),
            titleH * 0.6, Bold: true);
        var grid = new Placement(area.X, title.Box.Bottom + area.Height * 0.01, area.Width, area.Bottom - title.Box.Bottom - area.Height * 0.01);
        var (lines, texts) = MonthGrid(year, month, culture, grid, lines: true);
        texts.Insert(0, title);
        return new PhotoSheet([Cell(photo, input, photoBox)]) { Lines = lines, Texts = texts };
    }

    /// <summary>A year's sheet: the photo over the top, the year, and its twelve months small, three across and four down.</summary>
    public static PhotoSheet YearSheet(int photo, PhotoInput input, PhotoLayoutOptions options, SheetPaper paper)
    {
        var culture = options.Culture ?? CultureInfo.InvariantCulture;
        var year = Math.Clamp(options.CalendarYear, 1, 9999);
        var area = Inset(paper.Printable, 0.1);
        var landscape = area.Width > area.Height;
        var photoBox = new Placement(area.X, area.Y, area.Width, area.Height * 0.36);
        var titleH = area.Height * 0.06;
        var texts = new List<SheetText>
        {
            new(year.ToString(culture), new Placement(area.X, photoBox.Bottom + area.Height * 0.01, area.Width, titleH), titleH * 0.65, Bold: true),
        };
        var lines = new List<SheetLine>();
        var monthsTop = photoBox.Bottom + area.Height * 0.01 + titleH;
        var (cols, rows) = landscape ? (4, 3) : (3, 4);
        var gap = Math.Min(area.Width, area.Height) * 0.02;
        var w = (area.Width - (cols - 1) * gap) / cols;
        var h = (area.Bottom - monthsTop - (rows - 1) * gap) / rows;
        for (var m = 1; m <= 12; m++)
        {
            var (c, r) = ((m - 1) % cols, (m - 1) / cols);
            var box = new Placement(area.X + c * (w + gap), monthsTop + r * (h + gap), w, h);
            var nameH = h / 8;
            texts.Add(new SheetText(MonthName(m, culture), new Placement(box.X, box.Y, box.Width, nameH), nameH * 0.75, Bold: true));
            var (_, days) = MonthGrid(year, m, culture, new Placement(box.X, box.Y + nameH, box.Width, box.Height - nameH), lines: false);
            texts.AddRange(days);
        }
        return new PhotoSheet([Cell(photo, input, photoBox)]) { Lines = lines, Texts = texts };
    }

    /// <summary>
    /// A month's week day names and day numbers in <paramref name="box"/>: the names in a row on top, then a row a week; with
    /// <paramref name="lines"/> a ruled grid with each number in its box's top left corner, else the numbers centered.
    /// </summary>
    public static (List<SheetLine> Lines, List<SheetText> Texts) MonthGrid(int year, int month, CultureInfo culture, Placement box, bool lines)
    {
        var weeks = Weeks(year, month, FirstDay(culture));
        var names = DayNames(culture);
        var cw = box.Width / 7;
        var headH = Math.Min(box.Height / 8, lines ? box.Height / 10 : box.Height / 7);
        var rowH = (box.Height - headH) / Math.Max(weeks.Count, lines ? weeks.Count : 6);
        var texts = new List<SheetText>();
        var rules = new List<SheetLine>();
        for (var c = 0; c < 7; c++)
            texts.Add(new SheetText(names[c], new Placement(box.X + c * cw, box.Y, cw, headH), headH * 0.55, Muted: true));
        var top = box.Y + headH;
        for (var r = 0; r < weeks.Count; r++)
            for (var c = 0; c < 7; c++)
            {
                if (weeks[r][c] == 0) continue;
                var cell = new Placement(box.X + c * cw, top + r * rowH, cw, rowH);
                var day = weeks[r][c].ToString(culture);
                texts.Add(lines
                    ? new SheetText(day, Inset(cell, Math.Min(cw, rowH) * 0.08) with { Height = rowH * 0.4 }, Math.Min(rowH * 0.28, cw * 0.3), SheetTextAlign.Left)
                    : new SheetText(day, cell, Math.Min(rowH, cw) * 0.55));
            }
        if (lines)
        {
            var bottom = top + weeks.Count * rowH;
            for (var r = 0; r <= weeks.Count; r++) rules.Add(new SheetLine(box.X, top + r * rowH, box.Right, top + r * rowH));
            for (var c = 0; c <= 7; c++) rules.Add(new SheetLine(box.X + c * cw, top, box.X + c * cw, bottom));
        }
        return (rules, texts);
    }

    // ---------------------------------------------------------------- collages

    /// <summary>The arrangements offered for <paramref name="count"/> photos (one large needs at least three).</summary>
    public static IReadOnlyList<CollageArrangement> Arrangements(int count) =>
        count >= 3 ? [CollageArrangement.Rows, CollageArrangement.Columns, CollageArrangement.OneLarge] : [CollageArrangement.Rows, CollageArrangement.Columns];

    /// <summary>How many photos go in each row (or column) for <paramref name="count"/>: as even as can be, the fuller lines last (5: 2, 3).</summary>
    public static IReadOnlyList<int> Lines(int count)
    {
        if (count <= 0) return [];
        var lines = Math.Max(1, (int)Math.Round(Math.Sqrt(count)));
        return [.. Enumerable.Range(0, lines).Select(i => count / lines + (i >= lines - count % lines ? 1 : 0))];
    }

    /// <summary>
    /// The cells of one collage of <paramref name="count"/> photos (1 to <see cref="MaxCollage"/>) in <paramref name="area"/>,
    /// <paramref name="spacing"/> apart (inches), in the photos' order.
    /// </summary>
    public static IReadOnlyList<Placement> CollageCells(int count, CollageArrangement arrangement, Placement area, double spacing)
    {
        count = Math.Clamp(count, 1, MaxCollage);
        spacing = Math.Clamp(spacing, 0, Math.Min(area.Width, area.Height) / 10);
        if (arrangement == CollageArrangement.OneLarge && count >= 3)
        {
            var bigH = (area.Height - spacing) * 0.6;
            var rest = Rows(count - 1, new Placement(area.X, area.Y + bigH + spacing, area.Width, area.Height - bigH - spacing), spacing, [count - 1]);
            return [new Placement(area.X, area.Y, area.Width, bigH), .. rest];
        }
        if (arrangement == CollageArrangement.Columns)
        {
            // The rows' arrangement on the area turned a quarter: columns as even as rows would be.
            var turned = Rows(count, new Placement(area.Y, area.X, area.Height, area.Width), spacing, Lines(count));
            return [.. turned.Select(p => new Placement(p.Y, p.X, p.Height, p.Width))];
        }
        return Rows(count, area, spacing, Lines(count));
    }

    private static List<Placement> Rows(int count, Placement area, double spacing, IReadOnlyList<int> perRow)
    {
        var cells = new List<Placement>(count);
        var rows = perRow.Count;
        var rh = (area.Height - (rows - 1) * spacing) / rows;
        for (var r = 0; r < rows; r++)
        {
            var n = perRow[r];
            var cw = (area.Width - (n - 1) * spacing) / n;
            for (var c = 0; c < n; c++) cells.Add(new Placement(area.X + c * (cw + spacing), area.Y + r * (rh + spacing), Math.Max(0, cw), Math.Max(0, rh)));
        }
        return cells;
    }

    /// <summary>
    /// Collages of the photos in order, at most <see cref="MaxCollage"/> to a sheet, inside a border of <see cref="PhotoLayoutOptions.CollageBorder"/>
    /// around the printable area. Each photo once (copies don't apply); an arrangement a sheet's count doesn't offer becomes rows.
    /// </summary>
    public static IReadOnlyList<PhotoSheet> Collages(IReadOnlyList<PhotoInput> photos, PhotoLayoutOptions options, SheetPaper paper)
    {
        var area = paper.Printable;
        var border = Math.Clamp(options.CollageBorder, 0, Math.Min(area.Width, area.Height) / 4);
        area = Inset(area, border);
        var sheets = new List<PhotoSheet>();
        for (var start = 0; start < photos.Count; start += MaxCollage)
        {
            var n = Math.Min(MaxCollage, photos.Count - start);
            var arrangement = Arrangements(n).Contains(options.Collage) ? options.Collage : CollageArrangement.Rows;
            var cells = CollageCells(n, arrangement, area, options.CollageSpacing);
            sheets.Add(new PhotoSheet([.. cells.Select((cell, k) => Cell(start + k, photos[start + k], cell))]));
        }
        return sheets;
    }

    /// <summary>The photos' order with <paramref name="a"/> and <paramref name="b"/> swapped (dragging one collage photo onto another).</summary>
    public static IReadOnlyList<int> Swap(int count, int a, int b)
    {
        var order = Enumerable.Range(0, count).ToArray();
        if (a >= 0 && b >= 0 && a < count && b < count) (order[a], order[b]) = (order[b], order[a]);
        return order;
    }
}
