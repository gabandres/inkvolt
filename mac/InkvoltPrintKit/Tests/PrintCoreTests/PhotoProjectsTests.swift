import Foundation
import Testing
@testable import PrintCore

/// Ported from PhotoProjectsTests.cs: roadmap 4.16, cards, calendars and collages in Print Photos, laid out by
/// `PhotoProjects`. Adapted: a culture is a `Locale` (Foundation's calendar gives the first weekday), a week day is .NET's
/// `DayOfWeek` number (0 Sunday).
struct PhotoProjectsTests {
    private static let letter = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
    private static let a4 = SheetPaper(8.27, 11.69, 0.12, 0.12, 0.12, 0.12)
    private static let english = Locale(identifier: "en")
    private static let spanish = Locale(identifier: "es")

    private static func landscape(_ copies: Int = 1) -> PhotoInput { PhotoInput(6000, 4000, copies, .none) }
    private static func portrait(_ copies: Int = 1) -> PhotoInput { PhotoInput(3000, 4000, copies, .none) }

    private static func inside(_ outer: Placement, _ inner: Placement) -> Bool {
        inner.x >= outer.x - 1e-9 && inner.y >= outer.y - 1e-9 && inner.right <= outer.right + 1e-9 && inner.bottom <= outer.bottom + 1e-9
    }

    private static func sheets(_ kind: PhotoLayoutKind, _ photos: [PhotoInput], _ paper: SheetPaper,
                               _ more: ((inout PhotoLayoutOptions) -> Void)? = nil) -> [PhotoSheet] {
        var options = PhotoLayoutOptions(kind: kind)
        options.locale = english
        options.calendarYear = 2026
        options.calendarMonth = 11
        more?(&options)
        return PhotoLayout.sheets(photos, options, paper)
    }

    // MARK: Cards

    @Test func twoCardsGoOnASheetEachPhotoOnItsFrontPanel() throws {
        let sheets = Self.sheets(.card, [Self.portrait(), Self.landscape()], Self.letter)
        #expect(sheets.count == 1) // no message: no inside sheet
        let outside = try #require(sheets.first)
        #expect(outside.cells.count == 2)
        for k in 0..<2 {
            let front = PhotoProjects.panel(PhotoProjects.cardBox(Self.letter, k), right: true)
            #expect(outside.cells[k].photo == k)
            #expect(Self.inside(front, outside.cells[k].cell))
            #expect(Self.inside(Self.letter.printable, outside.cells[k].cell))
            #expect(!outside.cells[k].turned) // never turned: a card reads upright
        }
    }

    @Test func aCardHasFoldMarksAtItsFoldAndCutMarksBetweenTheCards() {
        let sheet = Self.sheets(.card, [Self.portrait(), Self.portrait()], Self.a4)[0]
        let folds = sheet.lines.filter(\.dashed)
        #expect(folds.count == 4) // top and bottom of each card's fold
        #expect(folds.allSatisfy { abs($0.x1 - Self.a4.width / 2) < 1e-6 })
        let cuts = sheet.lines.filter { !$0.dashed }
        #expect(cuts.count == 2)
        #expect(cuts.allSatisfy { abs($0.y1 - Self.a4.height / 2) < 1e-6 })
        #expect(sheet.lines.allSatisfy { l in
            Self.inside(Self.a4.printable, Placement(min(l.x1, l.x2), min(l.y1, l.y2), abs(l.x2 - l.x1), abs(l.y2 - l.y1)))
        })
    }

    @Test func aMessageAddsTheInsideBehindEachOutside() {
        let sheets = Self.sheets(.card, [Self.portrait(3)], Self.letter) { $0.cardMessage = "  Happy birthday!\nLove, Ana  " }
        #expect(sheets.count == 4) // 3 cards: two outsides, each with its inside
        #expect(sheets.map(\.inside) == [false, true, false, true])
        #expect(sheets[1].texts.count == 2)
        #expect(sheets[3].texts.count == 1) // the second sheet has one card
        #expect(sheets[1].texts.allSatisfy { $0.text == "Happy birthday!\nLove, Ana" })
        // Long-edge flip: the inside's message lies behind the outside's back panel, so it is drawn on the same right half.
        #expect(sheets[1].texts.allSatisfy { $0.box.x >= Self.letter.width / 2 })
        #expect(sheets[1].cells.isEmpty)
    }

    @Test func aMessageIsCleanedAndCut() {
        #expect(PhotoProjects.message(" \t ") == "")
        #expect(PhotoProjects.message("a\r\n\u{0007}b") == "a\nb")
        #expect(PhotoProjects.message(String(repeating: "x", count: 5000)).count == PhotoProjects.maxMessage)
    }

    // MARK: Calendars

    @Test func theWeekStartsOnTheInterfaceLanguagesFirstDay() {
        #expect(PhotoProjects.firstDay(Self.english) == 0) // Sunday
        #expect(PhotoProjects.firstDay(Self.spanish) == 1) // Monday
        #expect(PhotoProjects.dayNames(Self.english) == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
        #expect(PhotoProjects.dayNames(Self.spanish)[0] == "Lun")
        #expect(PhotoProjects.dayNames(Self.spanish)[6] == "Dom")
        #expect(PhotoProjects.monthName(11, Self.spanish) == "Noviembre")
        #expect(PhotoProjects.monthName(11, Self.english) == "November")
    }

    @Test func aMonthsWeeksPutEachDayUnderItsName() {
        // November 2026 begins on a Sunday: the first row in English, the seventh column in Spanish.
        let en = PhotoProjects.weeks(2026, 11, 0)
        #expect(en[0] == [1, 2, 3, 4, 5, 6, 7])
        #expect(en.count == 5)
        let es = PhotoProjects.weeks(2026, 11, 1)
        #expect(es[0] == [0, 0, 0, 0, 0, 0, 1])
        #expect(es.count == 6)
        #expect(es.flatMap { $0 }.max() == 30)
        // February 2026 starts on a Sunday and has 28 days: four weeks exactly.
        #expect(PhotoProjects.weeks(2026, 2, 0).count == 4)
        #expect(PhotoProjects.weeks(2028, 2, 1).flatMap { $0 }.max() == 29) // a leap year
    }

    @Test func aMonthCalendarGoesOnMonthAfterMonth() throws {
        let sheets = Self.sheets(.monthCalendar, [Self.landscape(), Self.portrait(), Self.landscape()], Self.letter)
        #expect(sheets.count == 3)
        #expect(sheets.map { $0.texts[0].text } == ["November 2026", "December 2026", "January 2027"])
        let first = sheets[0]
        #expect(first.cells.count == 1)
        let photo = try #require(first.cells.first)
        #expect(Self.inside(Self.letter.printable, photo.cell))
        #expect(first.texts.allSatisfy { Self.inside(Self.letter.printable, $0.box) })
        #expect(first.texts.dropFirst().prefix(7).allSatisfy { $0.box.y > photo.cell.bottom }) // the day names under the photo
        #expect(first.texts.count == 30 + 1 + 7) // the title, the day names and 30 days
        #expect(first.lines.count == (5 + 1) + (7 + 1)) // a ruled grid of 5 weeks
    }

    @Test func aMonthCalendarInSpanishStartsOnMonday() throws {
        let sheet = Self.sheets(.monthCalendar, [Self.landscape()], Self.a4) { $0.locale = Self.spanish }[0]
        #expect(sheet.texts[0].text == "Noviembre 2026")
        #expect(sheet.texts[1].text == "Lun")
        let one = try #require(sheet.texts.first { $0.text == "1" })
        let sunday = sheet.texts[7] // the seventh day name
        #expect(sunday.text == "Dom")
        #expect(one.box.x >= sunday.box.x && one.box.x < sunday.box.right) // the 1st is a Sunday
    }

    @Test func aYearCalendarHasTwelveMonths() {
        let sheet = Self.sheets(.yearCalendar, [Self.landscape()], Self.letter) { $0.calendarYear = 2027 }[0]
        #expect(sheet.texts[0].text == "2027")
        let months = sheet.texts.filter(\.bold).dropFirst().map(\.text)
        #expect(months == (1...12).map { PhotoProjects.monthName($0, Self.english) })
        #expect(sheet.texts.filter { Int($0.text) != nil && $0.text != "2027" }.count == 365)
        #expect(sheet.texts.allSatisfy { Self.inside(Self.letter.printable, $0.box) })
    }

    @Test func monthsCountOnAcrossYearsAndStayInRange() {
        #expect(PhotoProjects.monthAt(2026, 12, 1) == (2027, 1))
        #expect(PhotoProjects.monthAt(2026, 0, 0) == (2026, 1)) // a month out of range is clamped
        #expect(PhotoProjects.monthAt(99999, 12, 0) == (9999, 12))
        #expect(PhotoProjects.monthAt(9999, 12, 5) == (9999, 12)) // no month past the last a date can hold
        #expect(PhotoProjects.monthAt(9999, 11, Int.max) == (9999, 12))
    }

    @Test func aCalendarInTheLastYearAnyDateHoldsDoesntCrash() {
        let sheets = Self.sheets(.monthCalendar, [Self.landscape(), Self.landscape(), Self.landscape()], Self.letter) {
            $0.calendarYear = 9999
            $0.calendarMonth = 12
        }
        #expect(sheets.allSatisfy { $0.texts[0].text == "December 9999" })
        #expect(Self.sheets(.yearCalendar, [Self.landscape()], Self.letter) { $0.calendarYear = 9999 }.count == 1)
    }

    @Test func onlyACardWithAMessageNeedsBothSides() {
        #expect(!PhotoProjects.needsTwoSided(Self.sheets(.card, [Self.portrait()], Self.letter)))
        #expect(PhotoProjects.needsTwoSided(Self.sheets(.card, [Self.portrait()], Self.letter) { $0.cardMessage = "Hi" }))
        #expect(!PhotoProjects.needsTwoSided(Self.sheets(.collage, [Self.portrait(), Self.portrait()], Self.letter)))
    }

    // MARK: Collages

    @Test(arguments: [2, 3, 5, 7, 9])
    func aCollagesCellsFillTheAreaWithoutOverlapping(_ count: Int) {
        let area = Placement(0.5, 0.5, 7.5, 10)
        for arrangement in PhotoProjects.arrangements(count) {
            let cells = PhotoProjects.collageCells(count, arrangement, area, 0.1)
            #expect(cells.count == count)
            #expect(cells.allSatisfy { Self.inside(area, $0) && $0.width > 0 && $0.height > 0 }, "\(arrangement)")
            for i in 0..<count {
                for j in (i + 1)..<count { #expect(cells[i].intersect(cells[j]).isEmpty, "\(arrangement): \(i) and \(j) overlap") }
            }
            // Without spacing they cover the whole area.
            let covered = PhotoProjects.collageCells(count, arrangement, area, 0).reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(covered - area.width * area.height) < 1e-6)
        }
    }

    @Test func rowsAreAsEvenAsCanBe() {
        #expect(PhotoProjects.lines(2) == [2])
        #expect(PhotoProjects.lines(3) == [1, 2])
        #expect(PhotoProjects.lines(5) == [2, 3])
        #expect(PhotoProjects.lines(6) == [3, 3])
        #expect(PhotoProjects.lines(9) == [3, 3, 3])
        #expect(PhotoProjects.lines(7).reduce(0, +) == 7)
    }

    @Test func oneLargeNeedsThreePhotosAndPutsTheFirstOnTop() {
        #expect(!PhotoProjects.arrangements(2).contains(.oneLarge))
        let cells = PhotoProjects.collageCells(4, .oneLarge, Placement(0, 0, 8, 10), 0)
        #expect(cells[0].width == 8)
        #expect(cells.dropFirst().allSatisfy { $0.y >= cells[0].bottom && $0.width < cells[0].width })
    }

    @Test func tenPhotosMakeTwoCollagesInsideTheirBorder() {
        let photos = (0..<10).map { $0 % 2 == 0 ? Self.landscape(3) : Self.portrait() }
        let sheets = Self.sheets(.collage, photos, Self.letter) {
            $0.collageBorder = 0.5
            $0.collage = .oneLarge
        }
        #expect(sheets.count == 2)
        #expect(sheets[0].cells.count == 9) // copies don't apply: each photo once
        #expect(sheets[1].cells.map(\.photo) == [9])
        let inner = Placement(Self.letter.left + 0.5, Self.letter.top + 0.5, Self.letter.printable.width - 1, Self.letter.printable.height - 1)
        #expect(sheets.flatMap(\.cells).allSatisfy { Self.inside(inner, $0.cell) })
        #expect(sheets.flatMap(\.cells).allSatisfy { !$0.turned })
    }

    @Test func draggingOnePhotoOntoAnotherSwapsThem() {
        #expect(PhotoProjects.swap(4, 1, 3) == [0, 3, 2, 1])
        #expect(PhotoProjects.swap(3, 0, 7) == [0, 1, 2]) // out of range: as it was
    }

    @Test func noPhotosNoSheets() {
        for kind in [PhotoLayoutKind.card, .monthCalendar, .yearCalendar, .collage] { #expect(Self.sheets(kind, [], Self.letter).isEmpty) }
    }
}
