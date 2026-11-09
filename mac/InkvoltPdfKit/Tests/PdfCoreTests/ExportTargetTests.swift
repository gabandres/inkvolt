import Foundation
import Testing
@testable import PdfCore

/// Windows' `ExportTargetTests`, with the Mac's paths: where a one-click conversion writes.
struct ExportTargetTests {
    private static let documents = "/Users/someone/Documents"

    /// As `SplitFiles.uniquePath`: the name, else "name (2)", "name (3)"… for names already taken.
    private static func unique(_ taken: @escaping () -> Set<String>) -> (String, String) -> String {
        { folder, name in
            var path = (folder as NSString).appendingPathComponent(name)
            var n = 2
            let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
            while taken().contains(path) {
                path = (folder as NSString).appendingPathComponent("\(stem) (\(n)).\(ext)")
                n += 1
            }
            return path
        }
    }

    @Test func AConversionIsReservedNextToThePdf() {
        var created: [String] = []
        let r = ExportTarget.reserve(pdfPath: "/work/report.pdf", fileName: "report.docx", documents: Self.documents,
                                     uniquePath: Self.unique { [] }) { created.append($0); return .created }
        #expect(r == ExportTarget.Reserved(path: "/work/report.docx", inDocuments: false))
        #expect(created == ["/work/report.docx"])
    }

    @Test func ANameTakenMeanwhileMovesOnToTheNextOne() {
        // A second conversion (a double-click) reserved report.docx between choosing the name and creating it.
        var taken = Set<String>()
        let r = ExportTarget.reserve(pdfPath: "/work/report.pdf", fileName: "report.docx", documents: Self.documents,
                                     uniquePath: Self.unique { taken }) { path in
            let first = taken.insert(path).inserted
            return first && path.hasSuffix("report.docx") ? .exists : .created
        }
        #expect(r?.path == "/work/report (2).docx")
    }

    @Test func AnUnsavedPdfOrARefusedFolderGoesToDocuments() {
        #expect(ExportTarget.reserve(pdfPath: nil, fileName: "Untitled.docx", documents: Self.documents, uniquePath: Self.unique { [] }) { _ in .created }
                == ExportTarget.Reserved(path: Self.documents + "/Untitled.docx", inDocuments: true))
        var asked: [String] = []
        let r = ExportTarget.reserve(pdfPath: "/Volumes/CD/report.pdf", fileName: "report.docx", documents: Self.documents,
                                     uniquePath: Self.unique { [] }) { path in
            asked.append(path)
            return path.hasPrefix("/Volumes/") ? .refused : .created
        }
        #expect(r == ExportTarget.Reserved(path: Self.documents + "/report.docx", inDocuments: true))
        #expect(asked == ["/Volumes/CD/report.docx", Self.documents + "/report.docx"])
    }

    @Test func NoDocumentsFolderAndARefusedOneGiveNothing() {
        // No Documents folder (a sandbox or profile without it): the caller then asks where (the save panel).
        #expect(ExportTarget.reserve(pdfPath: "/Volumes/CD/report.pdf", fileName: "report.docx", documents: "",
                                     uniquePath: Self.unique { [] }) { _ in .refused } == nil)
        #expect(ExportTarget.reserve(pdfPath: nil, fileName: "report.docx", documents: nil, uniquePath: Self.unique { [] }) { _ in .created } == nil)
        // A folder whose name can't make a path is skipped, not thrown.
        struct TooLong: Error {}
        #expect(ExportTarget.reserve(pdfPath: "/Volumes/CD/report.pdf", fileName: "report.docx", documents: nil,
                                     uniquePath: { _, _ in throw TooLong() }) { _ in .created } == nil)
    }

    @Test func TryCreateReservesTheFileAndReportsRealRefusals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-target-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("report.docx")
        #expect(ExportTarget.tryCreate(path) == .created)
        #expect(FileManager.default.fileExists(atPath: path)) // the empty file holds the name until the export replaces it
        #expect(ExportTarget.tryCreate(path) == .exists)
        // A folder that isn't there, and a "folder" that is a file: the errors a refused folder gives.
        #expect(ExportTarget.tryCreate((dir as NSString).appendingPathComponent("missing/report.docx")) == .refused)
        #expect(ExportTarget.tryCreate((path as NSString).appendingPathComponent("report.docx")) == .refused)
        // A symbolic link is never followed to a file elsewhere.
        let link = (dir as NSString).appendingPathComponent("link.docx")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: (dir as NSString).appendingPathComponent("elsewhere.docx"))
        #expect(ExportTarget.tryCreate(link) != .created)
        #expect(!FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("elsewhere.docx")))
        // End to end: a refused PDF folder, so Documents; the real unique names.
        let docs = (dir as NSString).appendingPathComponent("Documents")
        try FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        let r = ExportTarget.reserve(pdfPath: (dir as NSString).appendingPathComponent("missing/report.pdf"), fileName: "report.docx", documents: docs)
        #expect(r == ExportTarget.Reserved(path: (docs as NSString).appendingPathComponent("report.docx"), inDocuments: true))
        let second = ExportTarget.reserve(pdfPath: nil, fileName: "report.docx", documents: docs)
        #expect(second?.path == (docs as NSString).appendingPathComponent("report (2).docx"))
        // What a cancelled conversion leaves: the empty file goes, a written one stays.
        #expect(ExportTarget.deleteIfEmpty(second!.path))
        try Data([1]).write(to: URL(fileURLWithPath: r!.path))
        #expect(!ExportTarget.deleteIfEmpty(r!.path))
        #expect(FileManager.default.fileExists(atPath: r!.path))
    }

    @Test func WhyNothingWasReservedIsSaid() {
        // The app says the right reason: a device name, both folders refusing, or no Documents folder to fall back on.
        #expect(ExportTarget.reservation(pdfPath: "/work/CON.pdf", fileName: "CON.docx", documents: Self.documents,
                                         uniquePath: Self.unique { [] }) { _ in .created } == .deviceName)
        #expect(ExportTarget.reservation(pdfPath: "/Volumes/CD/report.pdf", fileName: "report.docx", documents: Self.documents,
                                         uniquePath: Self.unique { [] }) { _ in .refused } == .refused(documentsTried: true))
        #expect(ExportTarget.reservation(pdfPath: "/Volumes/CD/report.pdf", fileName: "report.docx", documents: nil,
                                         uniquePath: Self.unique { [] }) { _ in .refused } == .refused(documentsTried: false))
        #expect(ExportTarget.reservation(pdfPath: nil, fileName: "report.docx", documents: Self.documents,
                                         uniquePath: Self.unique { [] }) { _ in .created }
                == .reserved(ExportTarget.Reserved(path: Self.documents + "/report.docx", inDocuments: true)))
    }

    @Test func ADeviceNameIsOfferedWithAnUnderscore() {
        // The save panel a device name falls back to never suggests the device: Inkvolt Print's rule, "CON_".
        #expect(ExportTarget.allowedName("CON.docx") == "CON_.docx")
        #expect(ExportTarget.allowedName("nul.tar.gz") == "nul_.tar.gz")
        #expect(ExportTarget.allowedName("COM¹") == "COM¹_")
        #expect(ExportTarget.allowedName("report.docx") == "report.docx")
    }

    @Test func ADanglingLinkCountsAsTakenSoTheNextNameIsUsed() throws {
        // A symbolic link pointing nowhere is a name in the folder: the next name is chosen there, not Documents.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-link-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createSymbolicLink(atPath: (dir as NSString).appendingPathComponent("report.docx"),
                                                   withDestinationPath: (dir as NSString).appendingPathComponent("gone.docx"))
        let r = ExportTarget.reserve(pdfPath: (dir as NSString).appendingPathComponent("report.pdf"), fileName: "report.docx",
                                     documents: Self.documents + "-missing")
        #expect(r == ExportTarget.Reserved(path: (dir as NSString).appendingPathComponent("report (2).docx"), inDocuments: false))
    }

    @Test func ADeviceIsNeverAReservedFile() {
        // Windows opens a device for "COM¹.docx" or "nul.docx": a file made with such a name on a Mac can't reach a PC
        // (a synced or copied folder). Refused, so the conversion asks where and under what name.
        for name in ["COM¹.docx", "nul.docx", "CONIN$.xlsx"] {
            #expect(ExportTarget.reserve(pdfPath: "/work/x.pdf", fileName: name, documents: Self.documents,
                                         uniquePath: Self.unique { [] }) { _ in .created } == nil, "\(name)")
        }
        // And a device node is never a reserved file: it exists, nothing is created over it.
        #expect(ExportTarget.tryCreate("/dev/null") == .exists)
    }

    @Test func ANameThatShortensToADeviceGetsAnUnderscore() {
        // A PDF named "CON", 200 spaces and "x": the name is cut to fit (SplitFiles.uniquePath) and its spaces trimmed,
        // which would leave "CON.docx". It is reserved as "CON_.docx", still in one click.
        let name = "CON" + String(repeating: " ", count: 200) + "x.docx"
        var created: [String] = []
        let r = ExportTarget.reservation(pdfPath: "/work/x.pdf", fileName: name, documents: Self.documents,
                                         create: { created.append($0); return .created })
        #expect(r == .reserved(ExportTarget.Reserved(path: "/work/CON_.docx", inDocuments: false)))
        #expect(created == ["/work/CON_.docx"])
    }

    @Test func TheExportIsSwappedInOnlyForItsOwnEmptyFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("inkvolt-swap-\(UUID().uuidString.prefix(8))").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let path = dir + "/report.docx", made = dir + "/made.tmp"
        func make() throws { try Data("the export".utf8).write(to: URL(fileURLWithPath: made)) }

        #expect(ExportTarget.tryCreate(path) == .created)
        try make()
        try ExportTarget.moveIntoReserved(made, path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "the export")
        #expect(!fm.fileExists(atPath: made)) // the empty file that came out is gone

        // Another app's content there now: swapped back, theirs untouched, the export left at `made` for the caller.
        try Data("someone else's".utf8).write(to: URL(fileURLWithPath: path))
        try make()
        #expect(throws: PdfEditError.self) { try ExportTarget.moveIntoReserved(made, path) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else's")
        #expect(try String(contentsOfFile: made, encoding: .utf8) == "the export")

        // Removed meanwhile: moved there while the name is free.
        try fm.removeItem(atPath: path)
        try ExportTarget.moveIntoReserved(made, path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "the export")
        #expect(ExportTarget.isStillReserved(path) == false)
    }
}
