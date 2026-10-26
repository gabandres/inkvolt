import Foundation
import Testing
@testable import PrintCore

/// Unsaved scans kept on disk while Inkvolt Print runs: each printer's pages (the scanner's JPEGs as they came, and the
/// review's turns, crops, skips and file starts), in a folder of the run's own; left over only when the run didn't exit
/// cleanly. Ported from ScanRecoveryTests.cs.
final class ScanRecoveryTests {
    private static let laser = "12345678-1234-4abc-8def-123456789abc", inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    private let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvoltprint-scans-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private static func scan(_ printer: String, _ pages: KeptPage...) -> KeptScan {
        KeptScan(printerId: printer, printerName: printer == laser ? "Office laser" : "Inkjet", savedUtc: Date(timeIntervalSince1970: 1_792_956_600),
                 pages: pages)
    }

    private func folders() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] }

    private func bytes(_ path: String) -> [UInt8] { Array(FileManager.default.contents(atPath: path) ?? Data()) }

    @Test func aRunningCopysScansAreNotLeftOver() throws {
        let store = try ScanRecoveryStore.start(root)
        defer { store.close() }
        try store.keep(Self.scan(Self.laser, KeptPage(try store.keepPage([1, 2]), dpi: 300, ocr: true)))
        #expect(ScanRecoveryStore.findLeftOver(root).isEmpty)
    }

    @Test func aCleanExitLeavesNothing() throws {
        let store = try ScanRecoveryStore.start(root)
        try store.keep(Self.scan(Self.laser, KeptPage(try store.keepPage([1, 2]), dpi: 300, ocr: true)))
        store.close()
        #expect(ScanRecoveryStore.findLeftOver(root).isEmpty)
        #expect(folders().isEmpty)
    }

    @Test func aRunThatEndedWithoutACleanExitLeavesEachPrintersPagesInOrderWithTheirEdits() throws {
        let store = try ScanRecoveryStore.start(root)
        let a = try store.keepPage([1, 1])
        let b = try store.keepPage([2, 2])
        let crop = CropBox(0.1, 0.2, 0.5, 0.6)
        try store.keep(Self.scan(Self.laser, KeptPage(b, dpi: 300, ocr: true, quarterTurns: 1, deskew: 1.5, crop: crop, skipped: true),
                                 KeptPage(a, dpi: 200, ocr: false, startsFile: true)))
        try store.keep(Self.scan(Self.inkjet, KeptPage(try store.keepPage([3]), dpi: 600, ocr: false)))
        store.keepForNextStart()

        let left = ScanRecoveryStore.findLeftOver(root).sorted { $0.scan.printerName < $1.scan.printerName }
        #expect(left.map(\.scan.printerName) == ["Inkjet", "Office laser"])
        let laser = left[1]
        #expect(laser.scan.printerId == Self.laser)
        #expect(laser.scan.pages.map { bytes(laser.pagePath($0)) } == [[2, 2], [1, 1]])
        #expect(laser.scan.pages[0].edits == PageEdits(quarterTurns: 1, deskew: 1.5, crop: crop))
        #expect(laser.scan.pages[0].skipped)
        #expect(laser.scan.pages[1].dpi == 200 && !laser.scan.pages[1].ocr && laser.scan.pages[1].startsFile)
    }

    @Test func pagesNoLongerInAScanAreDeletedAndASavedScanIsForgotten() throws {
        let store = try ScanRecoveryStore.start(root)
        let a = try store.keepPage([1])
        let b = try store.keepPage([2])
        try store.keep(Self.scan(Self.laser, KeptPage(a, dpi: 300, ocr: true), KeptPage(b, dpi: 300, ocr: true)))
        try store.keep(Self.scan(Self.laser, KeptPage(b, dpi: 300, ocr: true))) // page a deleted in the review
        try store.keep(Self.scan(Self.inkjet, KeptPage(try store.keepPage([3]), dpi: 300, ocr: true)))
        store.forget(Self.inkjet) // saved
        store.keepForNextStart()

        let left = ScanRecoveryStore.findLeftOver(root)
        try #require(left.count == 1)
        #expect(left[0].scan.pages.map(\.file) == [b])
        let jpegs = (try FileManager.default.contentsOfDirectory(atPath: left[0].folder)).filter { $0.hasSuffix(".jpg") }
        #expect(jpegs == [b])
    }

    @Test func pagesOfAForgottenScanAreWrittenAgainWhenAListNamesThemAgain() throws {
        let store = try ScanRecoveryStore.start(root)
        let a = ScanRecoveryStore.newPageName()
        let b = ScanRecoveryStore.newPageName()
        var written: [String] = []
        let jpeg = { (name: String) -> [UInt8] in
            written.append(name)
            return name == a ? [1, 1] : [2, 2]
        }
        try store.keep(Self.scan(Self.laser, KeptPage(a, dpi: 300, ocr: true)), jpeg: jpeg)
        try store.keep(Self.scan(Self.laser, KeptPage(a, dpi: 300, ocr: true), KeptPage(b, dpi: 300, ocr: true)), jpeg: jpeg) // a is on disk
        #expect(written == [a, b])
        store.forget(Self.laser) // saved: its list and pages go
        try store.keep(Self.scan(Self.laser, KeptPage(a, dpi: 300, ocr: true), KeptPage(b, dpi: 300, ocr: true)), jpeg: jpeg) // then changed
        store.keepForNextStart()

        let left = ScanRecoveryStore.findLeftOver(root)
        try #require(left.count == 1)
        #expect(left[0].scan.pages.map { bytes(left[0].pagePath($0)) } == [[1, 1], [2, 2]])
    }

    @Test func aScanWhosePagesAreMissingOrWhoseListIsDamagedIsSkipped() throws {
        let store = try ScanRecoveryStore.start(root)
        try store.keep(Self.scan(Self.laser, KeptPage(try store.keepPage([1]), dpi: 300, ocr: true)))
        try store.keep(Self.scan(Self.inkjet, KeptPage(try store.keepPage([2]), dpi: 300, ocr: true)))
        store.keepForNextStart()
        let inkjet = try #require(ScanRecoveryStore.findLeftOver(root).first { $0.scan.printerId == Self.inkjet })
        try FileManager.default.removeItem(atPath: inkjet.pagePath(inkjet.scan.pages[0]))
        try Data("not json".utf8).write(to: URL(fileURLWithPath: (inkjet.folder as NSString).appendingPathComponent("scan-damaged.json")))
        #expect(ScanRecoveryStore.findLeftOver(root).map(\.scan.printerId) == [Self.laser])
    }

    @Test func restoredOrDiscardedScansAreDeletedWithTheirFolder() throws {
        let store = try ScanRecoveryStore.start(root)
        try store.keep(Self.scan(Self.laser, KeptPage(try store.keepPage([1]), dpi: 300, ocr: true)))
        try store.keep(Self.scan(Self.inkjet, KeptPage(try store.keepPage([2]), dpi: 300, ocr: true)))
        store.keepForNextStart()
        let left = ScanRecoveryStore.findLeftOver(root)
        ScanRecoveryStore.remove(left[0])
        #expect(ScanRecoveryStore.findLeftOver(root).count == 1)
        ScanRecoveryStore.remove(left[1])
        #expect(folders().isEmpty)
    }

    @Test func aRunFolderIsLeftOverOnlyOnceItsRunHasEnded() throws {
        let running = try RunFolder.start(root)
        defer { running.close() }
        let crashed = try RunFolder.start(root)
        crashed.abandon()
        #expect(RunFolder.leftOver(root) == [crashed.path])
        RunFolder.delete(running.path) // never a running one's
        #expect(RunFolder.isDirectory(running.path))
        RunFolder.delete(crashed.path)
        #expect(RunFolder.leftOver(root).isEmpty)
    }
}
