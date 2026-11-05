import Foundation
import Testing
@testable import PrintCore

/// The places the Batch Print window was given, remembered by path (Mac only: the sandbox; no Windows equivalent). The
/// bookmarks here are bytes no Mac could resolve: nothing in the list needs one resolved.
struct BatchPlaceListTests {
    static func place(_ path: String, _ mark: String = "") -> BatchPlace { BatchPlace(path, Data((mark.isEmpty ? path : mark).utf8)) }

    @Test func A_place_given_again_is_kept_once_with_its_newest_bookmark_last() {
        let before = [Self.place("/Users/a/Invoices"), Self.place("/Users/a/Scans"), Self.place("/Users/a/list.inkvoltlist")]

        let after = BatchPlaceList.remember(before, [Self.place("/users/A/invoices", "new"), Self.place("/Users/a/Photos")])

        #expect(after.map(\.path) == ["/Users/a/Scans", "/Users/a/list.inkvoltlist", "/users/A/invoices", "/Users/a/Photos"])
        #expect(after[2].bookmark == Data("new".utf8))
    }

    @Test func At_most_the_newest_two_hundred_are_kept() {
        let many = (0..<PrintState.maxBatchPlaces).map { Self.place("/Users/a/\($0).pdf") }

        let after = BatchPlaceList.remember(many, [Self.place("/Users/a/new.pdf"), Self.place("/Users/a/newer.pdf")])

        #expect(after.count == PrintState.maxBatchPlaces)
        #expect(after.first?.path == "/Users/a/2.pdf")
        #expect(after.suffix(2).map(\.path) == ["/Users/a/new.pdf", "/Users/a/newer.pdf"])
    }

    @Test func A_lists_files_are_reached_through_their_own_place_or_a_folder_they_are_in() {
        let places = [Self.place("/Users/a/Invoices"), Self.place("/Users/a/Invoices 2024"), Self.place("/Users/a/one.pdf"),
                      Self.place("/Volumes/Share/Scans/"), Self.place("/Users/b")]

        let reached = BatchPlaceList.covering(places, ["/Users/a/Invoices/March/1.pdf", "/users/a/ONE.pdf", "/Volumes/Share/Scans",
                                                       "/Users/a/Invoices 2", "/Users/bc/x.pdf"])

        #expect(reached.map(\.path) == ["/Users/a/Invoices", "/Users/a/one.pdf", "/Volumes/Share/Scans/"])
        #expect(BatchPlaceList.covering(places, []).isEmpty)
    }

    @Test func A_renewed_bookmark_replaces_the_stale_one_under_the_path_it_resolved_to() {
        let stale = Self.place("/Users/a/Invoices", "stale")
        let places = [stale, Self.place("/Users/a/Scans")]

        let after = BatchPlaceList.renewed(places, stale, to: Self.place("/Users/a/Invoices (moved)", "fresh"))

        #expect(after.map(\.path) == ["/Users/a/Invoices (moved)", "/Users/a/Scans"])
        #expect(after[0].bookmark == Data("fresh".utf8))
        // One already forgotten meanwhile isn't brought back.
        #expect(BatchPlaceList.renewed([Self.place("/Users/a/Scans")], stale, to: Self.place("/x", "fresh")).map(\.path) == ["/Users/a/Scans"])
    }

    @Test func The_state_file_keeps_each_place_by_its_path() throws {
        var state = PrintState()
        state.batchPlaces = [Self.place("/Users/a/Invoices", "mark")]
        let back = try JSONDecoder().decode(PrintState.self, from: try JSONEncoder().encode(state))
        #expect(back.batchPlaces == state.batchPlaces)
    }
}
