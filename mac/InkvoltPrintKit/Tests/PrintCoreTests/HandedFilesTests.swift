import Foundation
import Testing
@testable import PrintCore

/// Files and presets handed to the app from outside (Finder, a drop, the command line, the Dock and menu bar's Scan
/// With). No Windows test to port: the rules are App.xaml.cs's FirstPdf, Pictures, QueueArg, PresetArg and
/// ScanPresetLibrary.Find, and MainViewModel.Printer's choice.
struct HandedFilesTests {
    private static let there: Set<String> = ["/a/report.pdf", "/a/later.PDF", "/a/beach.jpg", "/a/kid.HEIC", "/a/notes.txt"]
    private static func exists(_ p: String) -> Bool { there.contains(p) }

    @Test func theFirstPdfWinsOverPictures() {
        #expect(HandedFiles.choose(["/a/beach.jpg", "/a/report.pdf", "/a/later.PDF"], exists: Self.exists) == .pdf("/a/report.pdf"))
        #expect(HandedFiles.choose(["/a/gone.pdf", "/a/later.PDF"], exists: Self.exists) == .pdf("/a/later.PDF")) // a missing one is skipped
    }

    @Test func picturesGoTogetherAndOtherFilesAreLeftOut() {
        #expect(HandedFiles.choose(["/a/beach.jpg", "/a/notes.txt", "/a/kid.HEIC", "/a/gone.png"], exists: Self.exists)
            == .pictures(["/a/beach.jpg", "/a/kid.HEIC"]))
        #expect(HandedFiles.choose(["/a/notes.txt"], exists: Self.exists) == .nothing)
        #expect(HandedFiles.choose([], exists: Self.exists) == .nothing)
    }

    @Test func theCommandLinesFilesComeBeforeItsOptions() {
        #expect(HandedFiles.files(in: ["/a/report.pdf", "--queue", "Office_Laser"]) == ["/a/report.pdf"])
        #expect(HandedFiles.files(in: ["--report", "shot.png", "--demo"]).isEmpty) // an option's value is no file
        #expect(HandedFiles.files(in: ["-NSDocumentRevisionsDebugMode", "YES"]).isEmpty) // AppKit's own option and its value
        #expect(HandedFiles.files(in: ["", "/a/beach.jpg", "/a/kid.HEIC"]) == ["/a/beach.jpg", "/a/kid.HEIC"])
    }

    @Test func anOptionsValueIsTheNextArgumentUnlessItIsAnotherOption() {
        #expect(HandedFiles.value("--queue", in: ["/a/report.pdf", "--queue", "Office_Laser"]) == "Office_Laser")
        #expect(HandedFiles.value("--preset", in: ["--preset", " doc ", "--demo"]) == "doc")
        #expect(HandedFiles.value("--preset", in: ["--preset", "--demo"]) == nil)
        #expect(HandedFiles.value("--preset", in: ["--preset"]) == nil)
        #expect(HandedFiles.value("--preset", in: ["--preset", "  "]) == nil)
        #expect(HandedFiles.value("--queue", in: []) == nil)
    }

    @Test func aPresetIsFoundByItsIdThenByItsNameInAnyCase() {
        var doc = ScanPreset()
        doc.id = "doc"
        doc.name = "Document to PDF"
        var photo = ScanPreset()
        photo.id = "photo"
        photo.name = "doc" // a name that is another's id: the id wins
        #expect(HandedFiles.preset("doc", in: [doc, photo])?.id == "doc")
        #expect(HandedFiles.preset("document to pdf", in: [doc, photo])?.id == "doc")
        #expect(HandedFiles.preset("PHOTO", in: [doc, photo]) == nil) // ids are matched exactly
        #expect(HandedFiles.preset("gone", in: [doc, photo]) == nil)
    }

    @Test func theMeantPrinterThenTheSelectedThenTheFirstThatPrints() {
        let printers = ["scanner", "laser", "inkjet"]
        let prints: (String) -> Bool = { $0 != "scanner" }
        #expect(HandedFiles.target(printers, selected: "inkjet", meant: "laser", prints: prints) == "laser")
        #expect(HandedFiles.target(printers, selected: "inkjet", meant: nil, prints: prints) == "inkjet")
        #expect(HandedFiles.target(printers, selected: "scanner", prints: prints) == "laser") // a scanner on its own: the first printer
        #expect(HandedFiles.target(printers, selected: nil, meant: "scanner", prints: prints) == "laser")
        #expect(HandedFiles.target(["scanner"], selected: "scanner", prints: prints) == nil)
    }
}
