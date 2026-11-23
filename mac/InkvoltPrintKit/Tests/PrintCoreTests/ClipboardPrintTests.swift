import Foundation
import Testing
@testable import PrintCore

/// Ported from ClipboardPrintTests.cs: print the clipboard (roadmap 4.13), what's on it decides where it goes
/// (`ClipboardPrint.choose`), and text is laid out on pages (`ClipboardPrint.pages`), bounded as input from another app.
/// Adapted: files are the Mac's paths (copied in Finder), a picture's size a `PixelSize`; a Swift string holds no lone
/// surrogate, so that line of the control-character test has no Mac counterpart.
struct ClipboardPrintTests {
    private static func choose(_ text: String? = nil, _ picture: PixelSize? = nil, files: [String] = []) -> ClipboardPlan {
        ClipboardPrint.choose(ClipboardContent(text: text, picture: picture, files: files))
    }

    @Test func filesFromFileExplorerGoAsTheyAre() {
        let one = Self.choose(files: ["/Users/me/a.pdf"])
        #expect(one.what == .pdf)
        #expect(one.files == ["/Users/me/a.pdf"])
        #expect(Self.choose(files: ["/Users/me/a.JPG", "/Users/me/b.png"]).what == .pictures)
        let batch = Self.choose(files: ["/Users/me/a.pdf", "/Users/me/b.png", "/Users/me/notes.docx"])
        #expect(batch.what == .batch)
        #expect(batch.files == ["/Users/me/a.pdf", "/Users/me/b.png"]) // the rest left out
        #expect(Self.choose("some text", files: ["/Users/me/notes.docx"]).what == .notPrintable) // files win over text
        #expect(Self.choose(files: (0..<101).map { "/Users/me/\($0).pdf" }).what == .tooBig)
    }

    @Test func textBesideAPictureWinsUnlessItIsOnlyAnAddress() {
        #expect(Self.choose("Quarterly totals\t1200\t1300", PixelSize(800, 200)).what == .text) // Excel puts a picture too
        #expect(Self.choose("https://example.com/cat.jpg", PixelSize(800, 600)).what == .picture) // a browser's copied picture
        #expect(Self.choose(nil, PixelSize(800, 600)).what == .picture)
        #expect(Self.choose("   ", PixelSize(800, 600)).what == .picture)
        #expect(Self.choose("hello").what == .text)
        #expect(Self.choose(" \r\n ").what == .nothing)
        #expect(Self.choose(nil, PixelSize(0, 10)).what == .nothing)
    }

    @Test func tooMuchIsSaidNotPrinted() {
        #expect(Self.choose(nil, PixelSize(20_000, 20_000)).what == .tooBig)
        #expect(Self.choose(String(repeating: "x", count: ClipboardPrint.maxChars + 1)).what == .tooBig)
    }

    // Mac only: the clipboard's text is measured in bytes before it's read; only what can't fit in maxChars is refused there.
    @Test func textTooManyBytesToFitIsRefusedBeforeItIsRead() {
        #expect(!ClipboardPrint.textTooBig(utf8Bytes: 0))
        #expect(!ClipboardPrint.textTooBig(utf8Bytes: ClipboardPrint.maxChars * 4))
        #expect(ClipboardPrint.textTooBig(utf8Bytes: ClipboardPrint.maxChars * 4 + 1))
        let emoji = String(repeating: "😀", count: ClipboardPrint.maxChars)
        #expect(!ClipboardPrint.textTooBig(utf8Bytes: emoji.utf8.count))
        #expect(Self.choose(emoji).what == .text)
    }

    @Test func letterAndA4HoldAboutNinetyColumnsAndFiftySevenLines() {
        let letter = ClipboardPrint.layout(8.5, 11)
        #expect(letter.columns == 91 && letter.lines == 57)
        let a4 = ClipboardPrint.layout(8.27, 11.69)
        #expect(a4.columns == 88)
        #expect(a4.lines == 61)
        // Narrow paper still holds 40 characters a line (smaller type); a size that isn't one falls back to Letter.
        #expect(ClipboardPrint.layout(4, 6).columns >= 40)
        #expect(ClipboardPrint.layout(.nan, 11) == letter)
        #expect(ClipboardPrint.layout(1e9, 11) == letter)
    }

    @Test func linesWrapAtASpaceAndLongWordsAreCut() {
        #expect(ClipboardPrint.wrap("the quick brown fox", 10) == ["the quick", "brown fox"])
        #expect(ClipboardPrint.wrap("abcdefghijklm", 10) == ["abcdefghij", "klm"])
        #expect(ClipboardPrint.wrap("", 10) == [""])
        // A wide character takes two columns.
        #expect(ClipboardPrint.wrap("日本語日本語", 10) == ["日本語日本", "語"])
    }

    @Test func tabsLineEndsAndControlCharacters() {
        #expect(ClipboardPrint.expand("a\tb") == "a       b")
        #expect(ClipboardPrint.expand("abcdefgh\tc") == "abcdefgh        c")
        #expect(ClipboardPrint.expand("a\u{0007}b\u{0000}") == "ab")
        #expect(ClipboardPrint.expand("a😀") == "a😀")
        var cut = false
        let pages = ClipboardPrint.pages("one\r\ntwo\rthree\nfour", 20, 10, cut: &cut)
        #expect(pages == [["one", "two", "three", "four"]])
        #expect(!cut)
    }

    @Test func pagesFillThenBreakAndAFormFeedStartsANewOne() {
        var cut = false
        let text = (1...25).map { "line \($0)" }.joined(separator: "\n")
        let pages = ClipboardPrint.pages(text, 40, 10, cut: &cut)
        #expect(pages.map(\.count) == [10, 10, 5])
        #expect(pages[1][0] == "line 11")
        #expect(ClipboardPrint.pages("first\u{0C}second", 40, 10, cut: &cut).count == 2)
        // Nothing blank at the end.
        #expect(ClipboardPrint.pages("only\n\n\n\u{0C}\n\n", 40, 2, cut: &cut).count == 1)
        #expect(ClipboardPrint.pages("\n\n\n", 40, 2, cut: &cut).isEmpty)
    }

    @Test func blankLinesPastThePageLimitLoseNothingAndTextPastTheCharacterLimitIsStillLaidOut() {
        var cut = false
        let full = Array(repeating: "x", count: ClipboardPrint.maxPages * 3).joined(separator: "\n") + "\n\n\n\n\n"
        #expect(ClipboardPrint.pages(full, 40, 3, cut: &cut).count == ClipboardPrint.maxPages)
        #expect(!cut)
        let longText = "a b c\n" + String(repeating: "z", count: ClipboardPrint.maxChars)
        let pages = ClipboardPrint.pages(longText, 5000, 5000, cut: &cut)
        #expect(!pages.isEmpty)
        #expect(pages.first?.first == "a b c")
        #expect(cut)
    }

    @Test func pastThePageLimitTheRestIsLeftOutAndSaid() {
        var cut = false
        let text = Array(repeating: "x", count: (ClipboardPrint.maxPages + 5) * 3).joined(separator: "\n")
        #expect(ClipboardPrint.pages(text, 40, 3, cut: &cut).count == ClipboardPrint.maxPages)
        #expect(cut)
        // One very long line alone can't pass it either.
        #expect(ClipboardPrint.pages(String(repeating: "y", count: 1_000_000), 10, 10, cut: &cut).count == ClipboardPrint.maxPages)
        #expect(cut)
    }

    @Test func theNameHasTheDateAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 1, minute: 30)))
        #expect(ClipboardPrint.name(date, "Clipboard") == "Clipboard 2026-11-22 0130")
    }
}
