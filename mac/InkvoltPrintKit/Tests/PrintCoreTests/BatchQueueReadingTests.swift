import Foundation
import Testing
@testable import PrintCore

/// What a batch reads from a macOS print queue (no Windows test to port: Windows asks its spooler and its driver's ticket).
struct BatchQueueReadingTests {
    @Test(arguments: [
        (3, true, ["none"], nil),
        (3, true, ["toner-low-warning"], nil),
        (4, true, ["cups-waiting-for-job-completed"], nil),
        (3, true, ["media-jam-error"], "Paper jam."),
        (3, true, ["media-empty"], "Out of paper."),
        (3, true, ["offline-report"], "Offline."),
        (5, true, ["paused"], nil), // a paused queue takes the jobs, as Windows' does
        (3, false, ["none"], "The printer's queue isn't taking jobs: resume it in System Settings › Printers & Scanners."),
    ] as [(Int, Bool, [String], String?)])
    func A_queue_with_an_error_or_offline_stops_the_batch_and_a_warning_or_a_pause_doesnt(_ c: (state: Int, accepting: Bool, reasons: [String], problem: String?)) {
        #expect(BatchQueueReading.problem(state: c.state, accepting: c.accepting, reasons: c.reasons) == c.problem)
    }

    @Test func A_queue_that_is_gone_stops_the_batch() {
        #expect(BatchQueueReading.problem(state: nil, accepting: nil, reasons: []) != nil)
    }

    @Test func A_papers_size_comes_from_its_ipp_name_and_a_media_col() throws {
        let letter = try #require(BatchQueueReading.size("na_letter_8.5x11in"))
        #expect(abs(letter.width - 612) < 0.01 && abs(letter.height - 792) < 0.01)
        let a4 = try #require(BatchQueueReading.size("iso_a4_210x297mm.borderless"))
        #expect(abs(a4.width - 595.28) < 0.01 && abs(a4.height - 841.89) < 0.01)
        #expect(BatchQueueReading.size("Letter") == nil)
        #expect(BatchQueueReading.size("na_x_0x11in") == nil)
        let col = try #require(BatchQueueReading.mediaColSize("{media-size={x-dimension=21590 y-dimension=27940} media-top-margin=423}"))
        #expect(abs(col.width - 612) < 0.01 && abs(col.height - 792) < 0.01)
        #expect(BatchQueueReading.label("iso_a4_210x297mm", localized: nil) == "A4")
        #expect(BatchQueueReading.label("na_letter_8.5x11in", localized: "US Letter") == "US Letter")
    }

    @Test func The_demo_queues_draw_every_page_print_nothing_and_the_shared_one_that_is_off_stops_the_batch() async throws {
        let f = BatchFolder()
        let laser = try #require(DemoBatchQueue.named("Office color MFP"))
        let line = try await BatchPrintTests.line(f.file("a.pdf", "pages=3"), BatchPrintSettings(copies: 2, twoSided: true), info: try await laser.read())
        let summary = await BatchPrintRunner.run([line], laser, FakeDocuments())
        #expect(summary.sent == 1)
        #expect(summary.sheetsSent == 4)
        #expect(laser.sent.map(\.pages) == [[1, 2, 3]])

        let off = try #require(DemoBatchQueue.named("Front_desk_demo_mac"))
        #expect(try await off.problem() == "Offline.")
        #expect(try await DemoBatchQueue.named("Demo USB laser")?.read()?.canTwoSided == false)
    }
}
