import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import Synchronization
import Testing
@testable import PrintMac

/// Batch print through this Mac's real engines (PDFKit, Image I/O) and `print`, to demo mode's made-up queue: nothing prints.
/// Ported from BatchPrintEndToEndTests.cs with the same names where the Mac does the same (Windows runs the built app's
/// command line; here `BatchPrintCommandLine` runs in-process with the engines the app passes it). Its Windows-only tests
/// (the Print to PDF queue, Windows' AES lock, Control-C with piped output, the scripts' names in a console) aren't ported.
@Suite(.serialized)
struct BatchEnginesTests {
    static let password = "s3cret"
    static let printer = "Office color MFP"

    struct Host: BatchPrintHost {
        var documents: any BatchDocuments { MacBatchDocuments() }

        func findPrinter(_ name: String) async throws -> any BatchQueue {
            guard let queue = DemoBatchQueue.named(name) else { throw BatchCommandError("There is no printer \"\(name)\".") }
            return queue
        }
    }

    final class Said: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var text: String { lines.withLock { $0.joined(separator: "\n") } }
    }

    static func run(_ password: String?, _ args: String...) async -> (code: Int32, out: String, err: String) {
        let out = Said(), err = Said()
        let code = await BatchPrintCommandLine.run(args, Host(), environment: { $0 == BatchPrintCommandLine.passwordVariable ? password : nil },
                                                   output: { out.add($0) }, error: { err.add($0) })
        return (code, out.text, err.text)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-batch-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fiftyRealFilesPrintToTheDemoQueueInOrderWithTheEstimatedSheetCount() async throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        var entries: [BatchListEntry] = []
        var expected: [(name: String, sheets: Int)] = []
        for i in 0..<50 {
            let copies = 1 + i % 3, twoSided = i % 4 == 0
            let paper: String? = i % 5 == 0 ? "iso_a4_210x297mm" : nil
            var range: String?
            var pages: Int
            let name: String, bytes: [UInt8]
            let n = String(format: "%02d", i)
            if i == 25 {
                (name, bytes, pages) = ("locked.pdf", BatchPrintSamples.pdf(3, "Locked", password: Self.password), 3)
            } else {
                switch i % 4 {
                case 0:
                    pages = 1 + i % 7
                    (name, bytes) = ("\(n) document.pdf", BatchPrintSamples.pdf(pages, "Document \(i)"))
                    if pages > 2 {
                        range = "2-3"
                        pages = 2
                    }
                case 1: (name, bytes, pages) = ("\(n) photo.jpg", BatchPrintSamples.jpeg(160, 200), 1)
                case 2: (name, bytes, pages) = ("\(n) drawing.png", BatchPrintSamples.png(120, 80), 1)
                default: (name, bytes, pages) = ("\(n) scan.tif", BatchPrintSamples.tiff(2, 50, 50), 2)
                }
            }
            let path = f.appendingPathComponent(name).path
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            entries.append(BatchListEntry(path, BatchPrintSettings(copies: copies, range: range, twoSided: twoSided, paper: paper)))
            expected.append((name, BatchPrintSettings.sheets(pages, copies, twoSided)))
        }
        let list = f.appendingPathComponent("fifty" + BatchPrintList.fileExtension).path
        try BatchPrintList.save(list, entries)
        let report = f.appendingPathComponent("results.csv").path

        let (code, out, err) = await Self.run(Self.password, "print", "--list", list, "--printer", Self.printer, "--report", report)

        #expect(code == BatchPrintSummary.done, "\(out)\n\(err)")
        let rows = try String(contentsOfFile: report, encoding: .utf8).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }.map { $0.components(separatedBy: ",") }
        let names: [String] = rows.map { row in row[1] }
        let estimated: [Int] = rows.map { row in Int(row[row.count - 3]) ?? -1 }
        let sentSheets: [Int] = rows.map { row in Int(row[row.count - 2]) ?? -1 }
        let wantedNames: [String] = expected.map { e in e.name }
        let wantedSheets: [Int] = expected.map { e in e.sheets }
        #expect(names == wantedNames)
        #expect(rows.allSatisfy { row in row[3] == "Sent" })
        #expect(sentSheets == wantedSheets)
        #expect(estimated == wantedSheets)
        // Sent one by one in the list's order, not just listed in it.
        let sent = out.components(separatedBy: "\n").filter { $0.contains("] sent ") }
        #expect(sent.count == 50)
        for (i, line) in sent.enumerated() { #expect(line.contains("[\(i + 1)/50] sent     \(expected[i].name):")) }
        #expect(out.contains("50 sent (\(expected.reduce(0) { $0 + $1.sheets }) sheets)."))
    }

    @Test func withoutItsPasswordTheLockedPdfIsSkippedAndExit1WithAWrongOneToo() async throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        let locked = f.appendingPathComponent("locked.pdf").path, open = f.appendingPathComponent("open.pdf").path
        try Data(BatchPrintSamples.pdf(3, "Locked", password: Self.password)).write(to: URL(fileURLWithPath: locked))
        try Data(BatchPrintSamples.pdf(2, "Open")).write(to: URL(fileURLWithPath: open))

        let none = await Self.run(nil, "print", locked, open, "--printer", Self.printer)
        #expect(none.code == BatchPrintSummary.someFailed, "\(none.out)\n\(none.err)")
        #expect(none.err.contains("needs a password"))
        #expect(none.out.contains("1 sent (2 sheets), 1 skipped."))

        let wrong = await Self.run("wrong", "print", locked, open, "--printer", Self.printer)
        #expect(wrong.code == BatchPrintSummary.someFailed)
        #expect(wrong.err.contains("doesn't open"))
        #expect(!wrong.out.contains("wrong"))

        let right = await Self.run(Self.password, "print", locked, open, "--printer", Self.printer)
        #expect(right.code == BatchPrintSummary.done, "\(right.out)\n\(right.err)")
        #expect(right.out.contains("2 sent (5 sheets)."))
        #expect(!(right.out + right.err).contains(Self.password))
    }

    @Test func damagedAndDisguisedFilesAndAPictureClaimingAHugeSizeAreLeftOutWithoutEndingTheBatch() async throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        func write(_ name: String, _ bytes: [UInt8]) throws { try Data(bytes).write(to: f.appendingPathComponent(name)) }
        try write("1 not a pdf.pdf", Array("this is no PDF at all".utf8))
        try write("2 not a picture.jpg", Array("this is no JPEG at all".utf8))
        try write("3 truncated.pdf", Array(BatchPrintSamples.pdf(2, "Cut").prefix(40)))
        // A file of a few bytes whose header, with a right checksum, claims 40,000 × 40,000 pixels.
        var huge = BatchPrintSamples.png(1, 1)
        for (at, value) in [(16, UInt32(40_000)), (20, UInt32(40_000))] {
            for k in 0..<4 { huge[at + k] = UInt8(value >> (24 - 8 * UInt32(k)) & 0xFF) }
        }
        let crc = Crc32.of(Array(huge[12..<29]))
        for k in 0..<4 { huge[29 + k] = UInt8(crc >> (24 - 8 * UInt32(k)) & 0xFF) }
        try write("4 huge.png", huge)
        try write("5 good.pdf", BatchPrintSamples.pdf(1, "Good"))
        try write("6 really a pdf.jpg", BatchPrintSamples.pdf(2, "Disguised")) // what it is decides, not its name
        // A whole JPEG of 20,000 × 20,000 pixels (1.6 MB, every block the same grey). Mac difference: Image I/O gives no size
        // for the PNG above whose header alone claims one, so it reads as damaged; this one has a size to refuse.
        try write("7 huge.jpg", BatchPrintSamples.jpeg(20_000, 20_000))

        let (code, out, err) = await Self.run(nil, "print", f.path, "--printer", Self.printer)

        #expect(code == BatchPrintSummary.someFailed, "\(out)\n\(err)")
        #expect(out.contains("2 sent (3 sheets), 5 skipped."), "\(out)\n\(err)")
        for name in ["1 not a pdf.pdf", "2 not a picture.jpg", "3 truncated.pdf", "4 huge.png", "7 huge.jpg"] { #expect(err.contains("left out \(name)"), "\(name)") }
        #expect(err.contains("too large"), "\(err)") // refused by its header's size, before any pixel
    }

    @Test func aPictureIsDrawnUprightAtMostItsLongestEdgeAndAPdfPageAtItsSize() async throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        let photo = f.appendingPathComponent("photo.jpg"), pdf = f.appendingPathComponent("letter.pdf"), tiff = f.appendingPathComponent("scan.tif")
        try Data(BatchPrintSamples.jpeg(6000, 3000)).write(to: photo)
        try Data(BatchPrintSamples.pdf(2, "Letter")).write(to: pdf)
        try Data(BatchPrintSamples.tiff(3, 30, 40)).write(to: tiff)
        let documents = MacBatchDocuments()

        let picture = try await documents.open(photo.path, nil, BatchStop())
        let drawn = try await picture.render(1, BatchStop())
        #expect(picture.sizing == .fitToPaper)
        #expect(abs(drawn.widthInches - 14) < 0.01 && abs(drawn.heightInches - 7) < 0.01) // 4,200 × 2,100 pixels at 300 dpi

        let document = try await documents.open(pdf.path, nil, BatchStop())
        #expect(document.pageCount == 2 && document.sizing == .actualSize)
        let page = try await document.render(2, BatchStop())
        #expect(abs(page.widthInches - 8.5) < 0.01 && abs(page.heightInches - 11) < 0.01)
        #expect(page.jpeg.starts(with: [0xFF, 0xD8]))

        #expect(try await documents.open(tiff.path, nil, BatchStop()).pageCount == 3)
    }

    /// A page whose CropBox is inside its MediaBox (a trimmed scan, a page cut from a poster) prints as Preview shows it and as
    /// Windows' batch does (Windows.Data.Pdf's `PdfPage.Size` and rendering go by the CropBox): at the CropBox's size, with what
    /// is inside it, not the whole MediaBox with the trimmed parts around it. Here a black CropBox of 4 × 5 in on a white
    /// letter page, turned a quarter as /Rotate 90 says.
    @Test func aPdfPageIsDrawnAtItsCropBoxAsPreviewAndWindowsShowIt() async throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(at: f) }
        let pdf = f.appendingPathComponent("cropped.pdf")
        try Data(Self.croppedPdf(rotate: 0)).write(to: pdf)
        let turned = f.appendingPathComponent("turned.pdf")
        try Data(Self.croppedPdf(rotate: 90)).write(to: turned)
        let documents = MacBatchDocuments()

        let page = try await documents.open(pdf.path, nil, BatchStop()).render(1, BatchStop())
        #expect(abs(page.widthInches - 4) < 0.01 && abs(page.heightInches - 5) < 0.01, "\(page.widthInches) × \(page.heightInches) in")
        let image = try #require(CGImageSourceCreateWithData(Data(page.jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        for (x, y) in [(0.03, 0.03), (0.97, 0.03), (0.5, 0.5), (0.03, 0.97), (0.97, 0.97)] {
            #expect(try Self.gray(image, x, y) < 40, "white at \(x), \(y): the MediaBox around the CropBox was drawn")
        }

        let side = try await documents.open(turned.path, nil, BatchStop()).render(1, BatchStop())
        #expect(abs(side.widthInches - 5) < 0.01 && abs(side.heightInches - 4) < 0.01, "\(side.widthInches) × \(side.heightInches) in")
        let sideImage = try #require(CGImageSourceCreateWithData(Data(side.jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        for (x, y) in [(0.03, 0.03), (0.97, 0.97)] { #expect(try Self.gray(sideImage, x, y) < 40, "white at \(x), \(y) when turned") }
    }

    /// A letter page, white, with a black square filling its CropBox [100 200 388 560] (4 × 5 in).
    static func croppedPdf(rotate: Int) -> [UInt8] {
        let content = "0 g 100 200 288 360 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [100 200 388 560] /Rotate \(rotate) /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    /// The brightness (0 to 255) at a point given as a fraction of the picture's width and height from its top left.
    static func gray(_ image: CGImage, _ x: Double, _ y: Double) throws -> Int {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }
}
