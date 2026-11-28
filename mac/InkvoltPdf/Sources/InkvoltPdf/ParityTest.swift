import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for the Windows features the Mac lacked (`--edit`, on the synthetic text document;
/// `--only-parity` runs it alone): File › Export To › Pages as Images… (two pages as PNG and one as JPEG into a folder
/// of the test's own, read back, a taken name not replaced). Only counts and states are written.
@MainActor
struct ParityTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }

    mutating func run() async {
        lines.append("== \(name): Windows parity (\(controller.engine.pageCount) pages)")
        await exportImages()
        Report.write(lines.joined(separator: "\n"))
        Report.write("parity: \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
    }

    // MARK: Export Pages as Images

    private mutating func exportImages() async {
        let count = controller.engine.pageCount
        guard count >= 2 else { return check(false, "export images: the document has \(count) page") }
        let item = menuItem(loc("Pages as Images…"))
        check(item.map { controller.validateMenuItem($0) } == true, "export images: File › Export To › Pages as Images… is in the menu and enabled")
        check(CommandBar.group("Convert")?.items.contains { $0.action == "exportImages:" } == true, "export images: Convert › Images… sends it")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-parity-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stem = ((controller.pdf.session?.displayName ?? "") as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: dir + "/" + PageImageExport.fileName(stem, page: 0, jpeg: false), contents: Data([0]))
        await controller.runExportImages([0, 1], folder: dir, dpi: 72, jpeg: false)
        await controller.runExportImages([1], folder: dir, dpi: 96, jpeg: true)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        func head(_ file: String) -> [UInt8] { [UInt8]((FileManager.default.contents(atPath: dir + "/" + file) ?? Data()).prefix(3)) }
        let pngs = files.filter { $0.hasSuffix(".png") && head($0) == [0x89, 0x50, 0x4E] }
        let jpegs = files.filter { $0.hasSuffix(".jpg") && head($0) == [0xFF, 0xD8, 0xFF] }
        check(files.count == 4 && pngs.count == 2 && jpegs.count == 1, "export images: 2 PNG and 1 JPEG written beside a taken name (\(files.count) files)")
        check(files.contains { $0.hasSuffix("page 1 (2).png") }, "export images: the taken name kept, the new one numbered")
        if let png = pngs.first(where: { $0.contains("page 2") }), let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: dir + "/" + png) ?? Data()) {
            let g = controller.engine.page(1)
            check(abs(rep.pixelsWide - Int((g.width).rounded())) <= 1, "export images: 72 dpi is the page's size in points (\(rep.pixelsWide) px)")
        } else {
            check(false, "export images: page 2's PNG read back")
        }
        await settle()
    }
}
