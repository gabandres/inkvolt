import Foundation
import Testing
@testable import PdfCore

/// The Mac UX review's words, round 2 (a Mac addition, no Windows counterpart): errors without debug dumps, Go to
/// Page's problem, the window's subtitle and the plain-words notes.
struct UxWordsTests {
    @Test func An_errors_sentence_is_kept_with_its_reason() {
        let text = ErrorWords.plain(description: "You don't have permission to save the file “a.pdf” in the folder “x”.",
                                    suggestion: "To view or change permissions, select the item in the Finder and choose File > Get Info.")
        #expect(text.hasPrefix("You don't have permission"))
        #expect(text.hasSuffix("Get Info."))
    }

    @Test func A_reason_already_said_is_not_repeated() {
        let text = ErrorWords.plain(description: "The file couldn’t be saved because you don’t have permission.", reason: "You don’t have permission.")
        #expect(text == "The file couldn’t be saved because you don’t have permission.")
    }

    @Test func A_debug_description_becomes_the_fallback() {
        #expect(ErrorWords.plain(description: "The operation couldn’t be completed. (PdfCore.SigningError error 1.)") == ErrorWords.fallback)
        #expect(ErrorWords.plain(description: "Error Domain=NSCocoaErrorDomain Code=513 \"x\" UserInfo={}") == ErrorWords.fallback)
        #expect(ErrorWords.plain(description: "SigningError(message: \"x\")") == ErrorWords.fallback)
        #expect(ErrorWords.plain(description: "  ") == ErrorWords.fallback)
    }

    @Test func A_dump_keeps_a_plain_reason_when_there_is_one() {
        #expect(ErrorWords.plain(description: "The operation couldn’t be completed. (Foo error 2.)", reason: "The disk is full.") == "The disk is full.")
    }

    @Test func Go_to_page_says_what_was_typed_and_the_range() {
        #expect(GoToPageWords.problem(typed: " 99 ", pageCount: 3) == "There's no page “99”. Type a page from 1 to 3.")
        #expect(GoToPageWords.problem(typed: "", pageCount: 3) == "Type a page from 1 to 3.")
        #expect(GoToPageWords.problem(typed: "5", pageCount: 1) == "There's no page “5”. This document has 1 page.")
    }

    @Test func The_subtitle_shows_the_zoom_only_when_it_is_not_100_percent() {
        #expect(WindowStatus.subtitle(page: 2, pageCount: 14, zoom: 1) == "Page 2 of 14")
        #expect(WindowStatus.subtitle(page: 2, pageCount: 14, zoom: 1.25) == "Page 2 of 14 · 125%")
        #expect(WindowStatus.subtitle(page: 1, pageCount: 3, zoom: 0.5, fit: "Fit Width") == "Page 1 of 3 · Fit Width")
        #expect(WindowStatus.subtitle(page: 9, pageCount: 3, zoom: 0.333) == "Page 3 of 3 · 33%")
        #expect(WindowStatus.subtitle(page: 1, pageCount: 0, zoom: 1) == "No pages")
    }

    @Test func Every_plain_note_avoids_the_jargon_it_explains() {
        #expect(PlainWords.entries.count == 6)
        for e in PlainWords.entries {
            for word in PlainWords.jargon {
                #expect(!e.note.localizedCaseInsensitiveContains(word), "\(e.name): \(word)")
            }
            #expect(e.note.hasSuffix("."))
            #expect(e.proposed != e.name)
        }
        #expect(PlainWords.note(for: "Flatten…") != nil)
        #expect(PlainWords.note(for: "Open…") == nil)
    }

    @Test func The_sidebar_text_grows_with_the_sidebar_size() {
        #expect(SidebarText.points(sizeMode: 2) == (11, 11)) // medium: as before
        #expect(SidebarText.points(sizeMode: 1).title < SidebarText.points(sizeMode: 2).title)
        #expect(SidebarText.points(sizeMode: 3).title > SidebarText.points(sizeMode: 2).title)
        #expect(SidebarText.points(sizeMode: 0) == SidebarText.points(sizeMode: 1))
        #expect(SidebarText.points(sizeMode: 9) == SidebarText.points(sizeMode: 3))
    }

    @Test func A_document_propertys_value_is_shown_short_and_on_one_line() {
        // A hostile file's Producer of 2 MB made Document Properties' sheet 685,000 points tall (review of 1.6.0).
        let huge = String(repeating: "Producer word ", count: 150_000)
        let shown = PropertyText.shown(huge)
        #expect(shown.count <= PropertyText.maxLength + 1)
        #expect(shown.hasSuffix("…"))
        #expect(PropertyText.shown("Line one\nline two\r\n\tend\u{7}") == "Line one line two end")
        #expect(PropertyText.shown("Acrobat 9") == "Acrobat 9")
    }
}
