import Foundation
import Testing
@testable import PdfCore

/// Windows' `ConvertCommandTests`, with the Mac's paths: Finder's "Convert to Word with Inkvolt PDF" (`--convert-to word
/// <files…>`): what the command line asks for, how it reaches a running copy, the names it writes and where its result
/// shows.
struct ConvertCommandTests {
    private static let folder = "/Users/me/work"

    private func parse(_ args: String...) -> ConvertCommand.Request { parse(args) }

    private func parse(_ args: [String]) -> ConvertCommand.Request {
        let (request, error) = ConvertCommand.tryParse(args, folder: Self.folder)
        #expect(error == .none, "refused: \(error)")
        return request ?? ConvertCommand.Request(.word, [])
    }

    private func refused(_ args: String...) -> ConvertCommand.ParseError {
        let (request, error) = ConvertCommand.tryParse(args, folder: Self.folder)
        #expect(request == nil)
        return error
    }

    @Test func ExplorersVerbIsAConvertCommand() {
        #expect(ConvertCommand.isCommand(["--convert-to", "word", "/a.pdf"]))
        #expect(ConvertCommand.isCommand(["--CONVERT-TO=word", "/a.pdf"]))
        #expect(!ConvertCommand.isCommand(["/a.pdf"]))
        #expect(!ConvertCommand.isCommand([]))
        #expect(!ConvertCommand.isCommand(["--batch", "--convert-to", "word"]))
        #expect(!ConvertCommand.isCommand(["--convert-tones"]))
    }

    @Test func TheFormatAndFilesAreRead() {
        let r = parse("--convert-to", "word", "/Users/me/report.pdf")
        #expect(r.format == .word)
        #expect(r.files == ["/Users/me/report.pdf"])
        #expect(r.overLimit == 0 && r.refused == 0)
    }

    @Test(arguments: [("word", ExportFormat.word), ("DOCX", .word), ("excel", .excel), ("xlsx", .excel),
                      ("powerpoint", .powerPoint), ("pptx", .powerPoint), ("text", .text), ("txt", .text), ("html", .html)])
    func EachExportFormatHasANameOnTheCommandLine(_ name: String, _ format: ExportFormat) {
        #expect(parse("--convert-to", name, "/a.pdf").format == format)
        #expect(parse("--convert-to=\(name)", "/a.pdf").format == format)
    }

    @Test func AWrongCommandSaysWhatIsWrong() {
        #expect(refused("--convert-to") == .noFormat)
        #expect(refused("--convert-to=") == .noFormat)
        #expect(refused("--convert-to", "pdf", "/a.pdf") == .unknownFormat)
        #expect(refused("--convert-to", "/a.pdf") == .unknownFormat)
        #expect(refused("--convert-to", "word") == .noFiles)
        #expect(refused("--convert-to", "word", "", "   ") == .noFiles)
        #expect(refused("/a.pdf") == .notACommand)
    }

    @Test func ManyFilesAreKeptInOrderOnceEach() {
        let r = parse("--convert-to", "word", "/b.pdf", "/a.pdf", "/B.PDF", "/c.pdf")
        #expect(r.files == ["/b.pdf", "/a.pdf", "/c.pdf"])
    }

    @Test func FilesPastTheLimitAreDroppedAndCounted() {
        let files = (0..<(ConvertCommand.maxFiles + 7)).map { "/in/\($0).pdf" }
        let r = parse(["--convert-to", "word"] + files)
        #expect(r.files.count == ConvertCommand.maxFiles)
        #expect(r.overLimit == 7 && r.refused == 0)
        #expect(r.files[0] == "/in/0.pdf")
    }

    @Test func RelativePathsBecomeFullOnes() {
        let r = parse("--convert-to", "word", "report.pdf", "../x/other.pdf")
        #expect(r.files == ["/Users/me/work/report.pdf", "/Users/me/x/other.pdf"])
    }

    @Test(arguments: ["/Volumes/share/Reports/Q3 \"final\".pdf", "/Volumes/share/Reports/Q3.pdf",
                      "/work/CON.pdf", "/work/-- not an option.pdf", "/work/:colon.pdf"])
    func HostilePathsAreTakenAsFilesNeverAsMore(_ path: String) {
        let r = parse("--convert-to", "word", path)
        #expect(r.files.count == 1)
        #expect(r.files.first?.hasSuffix((path as NSString).lastPathComponent) == true)
    }

    @Test(arguments: ["/dev/tty", "/dev/null", "/dev/fd/0", "//dev/stdin", "/dev", "/DEV/tty", "/tmp/../dev/tty"])
    func ADevicePathIsRefusedNotRead(_ path: String) {
        let r = parse("--convert-to", "word", path, "/d.pdf")
        #expect(r.files == ["/d.pdf"])
        #expect(r.refused == 1)
    }

    @Test func LeftOutCountsStopAtTheirLimitInsteadOfOverflowing() {
        let most = "--convert-to=word:\(ConvertCommand.maxLeftOut):\(ConvertCommand.maxLeftOut)"
        let flood = (0..<5000).map { _ in parse(most, "/a.pdf") }
        let merged = ConvertCommand.merge(flood)
        #expect(merged.count == 1)
        #expect(merged.first?.overLimit == ConvertCommand.maxLeftOut && merged.first?.refused == ConvertCommand.maxLeftOut)
        #expect(ConvertCommand.addLeftOut(Int.max, Int.max) == ConvertCommand.maxLeftOut)
        #expect(refused("--convert-to=word:\(ConvertCommand.maxLeftOut + 1):0", "/a.pdf") == .unknownFormat)
    }

    @Test func ALongPathIsKept() {
        let deep = "/" + Array(repeating: String(repeating: "d", count: 120), count: 10).joined(separator: "/") + "/report.pdf"
        #expect(deep.count > 1024) // past PATH_MAX: kept, it then isn't found
        #expect(parse("--convert-to", "word", deep).files.first == deep)
    }

    @Test func AnArgumentWithAControlCharacterIsDropped() {
        let r = parse("--convert-to", "word", "/a.pdf\n/b.pdf", "/c\u{0}.pdf", "/d.pdf")
        #expect(r.files == ["/d.pdf"])
        #expect(r.overLimit == 0 && r.refused == 2) // refused, not over the limit: said apart
        #expect(refused("--convert-to", "word", "/a.pdf\r") == .noFiles)
    }

    @Test func ForwardedArgumentsReadBackTheSameRequest() {
        // The running copy gets the arguments as a list: the format is one argument with the switch, so it is never
        // taken for a relative path.
        let first = parse("--convert-to", "word", "/a.pdf", "/Volumes/share/b.pdf")
        let forwarded = ConvertCommand.toArguments(first)
        #expect(forwarded[0] == "--convert-to=word")
        #expect(forwarded.dropFirst().allSatisfy { $0.hasPrefix("/") })
        let again = ConvertCommand.tryParse(forwarded, folder: "/elsewhere").request
        #expect(again?.format == first.format)
        #expect(again?.files == first.files)
    }

    @Test(arguments: [("/work/report.pdf", ExportFormat.word, "report.docx"),
                      ("/work/Q3.final.PDF", .word, "Q3.final.docx"),
                      ("/work/report.pdf", .excel, "report.xlsx"),
                      ("/work/CON.pdf", .word, "_CON.docx"), // a device name on Windows is never made, so it moves to a PC
                      ("/work/nul.pdf", .text, "_nul.txt"),
                      ("/work/.pdf", .word, "Untitled.docx"),
                      ("/work/ends with dots...pdf", .word, "ends with dots.docx")])
    func TheOutputIsNamedAfterThePdf(_ pdf: String, _ format: ExportFormat, _ expected: String) {
        #expect(ConvertCommand.outputName(pdf, format) == expected)
    }

    @Test func TheOutputIsReservedNextToThePdfNeverOverAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-convert-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let pdf = (folder as NSString).appendingPathComponent("report.pdf")
        try Data("%PDF-1.7".utf8).write(to: URL(fileURLWithPath: pdf))
        let theirs = (folder as NSString).appendingPathComponent("report.docx")
        try Data("the user's own file".utf8).write(to: URL(fileURLWithPath: theirs))
        let first = ExportTarget.reserve(pdfPath: pdf, fileName: ConvertCommand.outputName(pdf, .word), documents: nil)
        let second = ExportTarget.reserve(pdfPath: pdf, fileName: ConvertCommand.outputName(pdf, .word), documents: nil)
        #expect(first?.path == (folder as NSString).appendingPathComponent("report (2).docx"))
        #expect(second?.path == (folder as NSString).appendingPathComponent("report (3).docx"))
        #expect(try String(contentsOfFile: theirs, encoding: .utf8) == "the user's own file")
    }

    @Test func ADeviceNamedPdfGetsAFileOfItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-convert-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let pdf = (folder as NSString).appendingPathComponent("CON.pdf")
        let r = ExportTarget.reserve(pdfPath: pdf, fileName: ConvertCommand.outputName(pdf, .word), documents: nil)
        #expect(r?.path == (folder as NSString).appendingPathComponent("_CON.docx"))
        #expect(r.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test(arguments: [
        // The in-app one-click's notice when the window is up and this is the only conversion; the small window otherwise.
        (true, false, false, 1, true),
        (true, false, false, 2, false), // several files: a list says what became of each
        (true, true, false, 1, false), // the list is open: it gets this one too
        (true, false, true, 1, false), // one runs already
        (false, false, false, 1, false), // the app isn't open: the small window
    ])
    func TheResultShowsAsANoticeOnlyInTheOpenWindowForOneFile(_ c: (Bool, Bool, Bool, Int, Bool)) {
        #expect(ConvertCommand.showsNotice(windowReady: c.0, listOpen: c.1, busy: c.2, files: c.3) == c.4)
    }
}
