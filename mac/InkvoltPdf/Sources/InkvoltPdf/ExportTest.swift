import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for E15 (`--edit`, on the synthetic text document; `--only-export` runs it alone): File ›
/// Export To's PowerPoint Presentation… and HTML Web Page… chosen through the menu's own items (each opens its export
/// sheet, cancelled), then both exports run as the sheet runs them, the files read back: a presentation with a slide per
/// page, a web page with the document's words, its Content-Security-Policy and no script. Only counts are written.
@MainActor
struct ExportTest {
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

    private func menuItem(_ title: String) -> NSMenuItem? {
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

    /// The words a sheet shows, all of them.
    private func words(_ view: NSView?) -> [String] {
        guard let view else { return [] }
        return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(words)
    }

    mutating func run() async {
        lines.append("== \(name): export to PowerPoint and HTML (\(controller.engine.pageCount) pages)")
        let window = controller.window
        for (title, heading) in [("PowerPoint Presentation…", "Export to PowerPoint"), ("HTML Web Page…", "Export to HTML")] {
            guard let item = menuItem(loc(title)), let action = item.action else {
                check(false, "File › Export To › \(title) is in the menu")
                continue
            }
            let enabled = controller.validateMenuItem(item)
            if enabled { NSApp.sendAction(action, to: controller, from: item) } // the window may not be key over SSH
            await settle(300)
            let sheet = window?.attachedSheet
            check(enabled && sheet != nil && words(sheet?.contentView).contains(loc(heading)),
                  "File › Export To › \(title) opens the \(heading) sheet")
            if let sheet { window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            await settle(200)
        }

        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-export-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let all = Array(0..<controller.engine.pageCount)
        let firstWords = ((try? controller.engine.text(0).text) ?? "").split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")

        let deck = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("\(name).pptx"))
        let pptx = await controller.runExport(.powerPoint, to: deck, pages: all, recognize: false)
        let deckBytes = (try? Data(contentsOf: deck)).map { [UInt8]($0) } ?? []
        // A ZIP keeps its entries' names as they are: count the slides by their part names.
        let names = String(decoding: deckBytes.map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
        let slides = Set((try? NSRegularExpression(pattern: #"ppt/slides/slide(\d+)\.xml"#))?.matches(in: names, range: NSRange(names.startIndex..., in: names))
            .compactMap { Range($0.range(at: 1), in: names).map { String(names[$0]) } } ?? [])
        check(pptx?.saved == true && deckBytes.starts(with: [0x50, 0x4B]) && slides.count == all.count && !controller.noticeBar.isHidden,
              "Export to PowerPoint: \(deckBytes.count) bytes, \(slides.count) slides for \(all.count) pages, the notice shown")

        let page = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("\(name).html"))
        let html = await controller.runExport(.html, to: page, pages: all, recognize: false)
        let text = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
        // The page's words without its markup: a heading and the paragraph after it run on, as the PDF's text does.
        let flat = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hasWords = firstWords.isEmpty || flat.contains(firstWords)
        check(html?.saved == true && text.hasPrefix("<!DOCTYPE html>") && text.contains("Content-Security-Policy") && !text.lowercased().contains("<script")
              && hasWords,
              "Export to HTML: \(text.utf8.count) bytes, one page with the document's first words (\(hasWords ? "found" : "not found: \(firstWords)")), its policy and no script")

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
