using System.Globalization;
using InkvoltPrint.Core.Photos;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>Roadmap 4.16: cards, calendars and collages in the Photos tab, laid out by <see cref="PhotoProjects"/>.</summary>
public class PhotoProjectsTests
{
    private static readonly SheetPaper Letter = new(8.5, 11, 0.25, 0.25, 0.25, 0.25);
    private static readonly SheetPaper A4 = new(8.27, 11.69, 0.12, 0.12, 0.12, 0.12);
    private static readonly CultureInfo English = CultureInfo.GetCultureInfo("en");
    private static readonly CultureInfo Spanish = CultureInfo.GetCultureInfo("es");

    private static PhotoInput Landscape(int copies = 1) => new(6000, 4000, copies, PhotoCrop.None);
    private static PhotoInput Portrait(int copies = 1) => new(3000, 4000, copies, PhotoCrop.None);

    private static bool Inside(Placement outer, Placement inner) =>
        inner.X >= outer.X - 1e-9 && inner.Y >= outer.Y - 1e-9 && inner.Right <= outer.Right + 1e-9 && inner.Bottom <= outer.Bottom + 1e-9;

    private static IReadOnlyList<PhotoSheet> Sheets(PhotoLayoutKind kind, IReadOnlyList<PhotoInput> photos, SheetPaper paper, Func<PhotoLayoutOptions, PhotoLayoutOptions>? more = null)
    {
        var options = new PhotoLayoutOptions { Kind = kind, Culture = English, CalendarYear = 2026, CalendarMonth = 11 };
        return PhotoLayout.Sheets(photos, more?.Invoke(options) ?? options, paper);
    }

    // ---- Cards ----

    [Fact]
    public void TwoCardsGoOnASheetEachPhotoOnItsFrontPanel()
    {
        var sheets = Sheets(PhotoLayoutKind.Card, [Portrait(), Landscape()], Letter);
        var outside = Assert.Single(sheets); // no message: no inside sheet
        Assert.Equal(2, outside.Cells.Count);
        for (var k = 0; k < 2; k++)
        {
            var front = PhotoProjects.Panel(PhotoProjects.CardBox(Letter, k), right: true);
            Assert.Equal(k, outside.Cells[k].Photo);
            Assert.True(Inside(front, outside.Cells[k].Cell));
            Assert.True(Inside(Letter.Printable, outside.Cells[k].Cell));
            Assert.False(outside.Cells[k].Turned); // never turned: a card reads upright
        }
    }

    [Fact]
    public void ACardHasFoldMarksAtItsFoldAndCutMarksBetweenTheCards()
    {
        var sheet = Sheets(PhotoLayoutKind.Card, [Portrait(), Portrait()], A4)[0];
        var folds = sheet.Lines.Where(l => l.Dashed).ToList();
        Assert.Equal(4, folds.Count); // top and bottom of each card's fold
        Assert.All(folds, l => Assert.Equal(A4.Width / 2, l.X1, 6));
        var cuts = sheet.Lines.Where(l => !l.Dashed).ToList();
        Assert.Equal(2, cuts.Count);
        Assert.All(cuts, l => Assert.Equal(A4.Height / 2, l.Y1, 6));
        Assert.All(sheet.Lines, l => Assert.True(Inside(A4.Printable, new Placement(Math.Min(l.X1, l.X2), Math.Min(l.Y1, l.Y2), Math.Abs(l.X2 - l.X1), Math.Abs(l.Y2 - l.Y1)))));
    }

    [Fact]
    public void AMessageAddsTheInsideBehindEachOutside()
    {
        var sheets = Sheets(PhotoLayoutKind.Card, [Portrait(copies: 3)], Letter, o => o with { CardMessage = "  Happy birthday!\nLove, Ana  " });
        Assert.Equal(4, sheets.Count); // 3 cards: two outsides, each with its inside
        Assert.Equal([false, true, false, true], sheets.Select(s => s.Inside));
        Assert.Equal(2, sheets[1].Texts.Count);
        Assert.Single(sheets[3].Texts); // the second sheet has one card
        Assert.All(sheets[1].Texts, t => Assert.Equal("Happy birthday!\nLove, Ana", t.Text));
        // Long-edge flip: the inside's message lies behind the outside's back panel, so it is drawn on the same right half.
        Assert.All(sheets[1].Texts, t => Assert.True(t.Box.X >= Letter.Width / 2));
        Assert.Empty(sheets[1].Cells);
    }

    [Fact]
    public void AMessageIsCleanedAndCut()
    {
        Assert.Equal("", PhotoProjects.Message(" \t "));
        Assert.Equal("a\nb", PhotoProjects.Message("a\r\n\u0007b"));
        Assert.Equal(PhotoProjects.MaxMessage, PhotoProjects.Message(new string('x', 5000)).Length);
    }

    // ---- Calendars ----

    [Fact]
    public void TheWeekStartsOnTheInterfaceLanguagesFirstDay()
    {
        Assert.Equal(DayOfWeek.Sunday, PhotoProjects.FirstDay(English));
        Assert.Equal(DayOfWeek.Monday, PhotoProjects.FirstDay(Spanish));
        Assert.Equal(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], PhotoProjects.DayNames(English));
        Assert.Equal("Lun", PhotoProjects.DayNames(Spanish)[0]);
        Assert.Equal("Dom", PhotoProjects.DayNames(Spanish)[6]);
        Assert.Equal("Noviembre", PhotoProjects.MonthName(11, Spanish));
        Assert.Equal("November", PhotoProjects.MonthName(11, English));
    }

    [Fact]
    public void AMonthsWeeksPutEachDayUnderItsName()
    {
        // November 2026 begins on a Sunday: the first row in English, the seventh column in Spanish.
        var en = PhotoProjects.Weeks(2026, 11, DayOfWeek.Sunday);
        Assert.Equal([1, 2, 3, 4, 5, 6, 7], en[0]);
        Assert.Equal(5, en.Count);
        var es = PhotoProjects.Weeks(2026, 11, DayOfWeek.Monday);
        Assert.Equal([0, 0, 0, 0, 0, 0, 1], es[0]);
        Assert.Equal(6, es.Count);
        Assert.Equal(30, es.SelectMany(w => w).Max());
        // February 2026 starts on a Sunday and has 28 days: four weeks exactly.
        Assert.Equal(4, PhotoProjects.Weeks(2026, 2, DayOfWeek.Sunday).Count);
        Assert.Equal(29, PhotoProjects.Weeks(2028, 2, DayOfWeek.Monday).SelectMany(w => w).Max()); // a leap year
    }

    [Fact]
    public void AMonthCalendarGoesOnMonthAfterMonth()
    {
        var sheets = Sheets(PhotoLayoutKind.MonthCalendar, [Landscape(), Portrait(), Landscape()], Letter);
        Assert.Equal(3, sheets.Count);
        Assert.Equal(["November 2026", "December 2026", "January 2027"], sheets.Select(s => s.Texts[0].Text));
        var first = sheets[0];
        var photo = Assert.Single(first.Cells);
        Assert.True(Inside(Letter.Printable, photo.Cell));
        Assert.All(first.Texts, t => Assert.True(Inside(Letter.Printable, t.Box)));
        Assert.True(first.Texts.Skip(1).Take(7).All(t => t.Box.Y > photo.Cell.Bottom)); // the day names under the photo
        Assert.Equal(30 + 1 + 7, first.Texts.Count); // the title, the day names and 30 days
        Assert.Equal((5 + 1) + (7 + 1), first.Lines.Count); // a ruled grid of 5 weeks
    }

    [Fact]
    public void AMonthCalendarInSpanishStartsOnMonday()
    {
        var sheet = Sheets(PhotoLayoutKind.MonthCalendar, [Landscape()], A4, o => o with { Culture = Spanish })[0];
        Assert.Equal("Noviembre 2026", sheet.Texts[0].Text);
        Assert.Equal("Lun", sheet.Texts[1].Text);
        var one = sheet.Texts.First(t => t.Text == "1");
        var sunday = sheet.Texts[7]; // the seventh day name
        Assert.Equal("Dom", sunday.Text);
        Assert.True(one.Box.X >= sunday.Box.X && one.Box.X < sunday.Box.Right); // the 1st is a Sunday
    }

    [Fact]
    public void AYearCalendarHasTwelveMonths()
    {
        var sheet = Sheets(PhotoLayoutKind.YearCalendar, [Landscape()], Letter, o => o with { CalendarYear = 2027 })[0];
        Assert.Equal("2027", sheet.Texts[0].Text);
        var months = sheet.Texts.Where(t => t.Bold).Skip(1).Select(t => t.Text).ToList();
        Assert.Equal(Enumerable.Range(1, 12).Select(m => PhotoProjects.MonthName(m, English)), months);
        Assert.Equal(365, sheet.Texts.Count(t => int.TryParse(t.Text, out _) && t.Text != "2027"));
        Assert.All(sheet.Texts, t => Assert.True(Inside(Letter.Printable, t.Box)));
    }

    [Fact]
    public void MonthsCountOnAcrossYearsAndStayInRange()
    {
        Assert.Equal((2027, 1), PhotoProjects.MonthAt(2026, 12, 1));
        Assert.Equal((2026, 1), PhotoProjects.MonthAt(2026, 0, 0)); // a month out of range is clamped
        Assert.Equal((9998, 12), PhotoProjects.MonthAt(99999, 12, 0));
    }

    // ---- Collages ----

    [Theory]
    [InlineData(2), InlineData(3), InlineData(5), InlineData(7), InlineData(9)]
    public void ACollagesCellsFillTheAreaWithoutOverlapping(int count)
    {
        var area = new Placement(0.5, 0.5, 7.5, 10);
        foreach (var arrangement in PhotoProjects.Arrangements(count))
        {
            var cells = PhotoProjects.CollageCells(count, arrangement, area, 0.1);
            Assert.Equal(count, cells.Count);
            Assert.All(cells, c => Assert.True(Inside(area, c) && c.Width > 0 && c.Height > 0, $"{arrangement} {c}"));
            for (var i = 0; i < count; i++)
                for (var j = i + 1; j < count; j++)
                    Assert.True(cells[i].Intersect(cells[j]).IsEmpty, $"{arrangement}: {i} and {j} overlap");
            // Without spacing they cover the whole area.
            var covered = PhotoProjects.CollageCells(count, arrangement, area, 0).Sum(c => c.Width * c.Height);
            Assert.Equal(area.Width * area.Height, covered, 6);
        }
    }

    [Fact]
    public void RowsAreAsEvenAsCanBe()
    {
        Assert.Equal([2], PhotoProjects.Lines(2));
        Assert.Equal([1, 2], PhotoProjects.Lines(3));
        Assert.Equal([2, 3], PhotoProjects.Lines(5));
        Assert.Equal([3, 3], PhotoProjects.Lines(6));
        Assert.Equal([3, 3, 3], PhotoProjects.Lines(9));
        Assert.Equal(7, PhotoProjects.Lines(7).Sum());
    }

    [Fact]
    public void OneLargeNeedsThreePhotosAndPutsTheFirstOnTop()
    {
        Assert.DoesNotContain(CollageArrangement.OneLarge, PhotoProjects.Arrangements(2));
        var cells = PhotoProjects.CollageCells(4, CollageArrangement.OneLarge, new Placement(0, 0, 8, 10), 0);
        Assert.Equal(8, cells[0].Width);
        Assert.True(cells.Skip(1).All(c => c.Y >= cells[0].Bottom && c.Width < cells[0].Width));
    }

    [Fact]
    public void TenPhotosMakeTwoCollagesInsideTheirBorder()
    {
        var photos = Enumerable.Range(0, 10).Select(i => i % 2 == 0 ? Landscape(copies: 3) : Portrait()).ToList();
        var sheets = Sheets(PhotoLayoutKind.Collage, photos, Letter, o => o with { CollageBorder = 0.5, Collage = CollageArrangement.OneLarge });
        Assert.Equal(2, sheets.Count);
        Assert.Equal(9, sheets[0].Cells.Count); // copies don't apply: each photo once
        Assert.Equal(9, sheets[1].Cells.Single().Photo);
        var inner = new Placement(Letter.Left + 0.5, Letter.Top + 0.5, Letter.Printable.Width - 1, Letter.Printable.Height - 1);
        Assert.All(sheets.SelectMany(s => s.Cells), c => Assert.True(Inside(inner, c.Cell)));
        Assert.All(sheets.SelectMany(s => s.Cells), c => Assert.False(c.Turned));
    }

    [Fact]
    public void DraggingOnePhotoOntoAnotherSwapsThem()
    {
        Assert.Equal([0, 3, 2, 1], PhotoProjects.Swap(4, 1, 3));
        Assert.Equal([0, 1, 2], PhotoProjects.Swap(3, 0, 7)); // out of range: as it was
    }

    [Fact]
    public void NoPhotosNoSheets()
    {
        foreach (var kind in new[] { PhotoLayoutKind.Card, PhotoLayoutKind.MonthCalendar, PhotoLayoutKind.YearCalendar, PhotoLayoutKind.Collage })
            Assert.Empty(Sheets(kind, [], Letter));
    }
}
