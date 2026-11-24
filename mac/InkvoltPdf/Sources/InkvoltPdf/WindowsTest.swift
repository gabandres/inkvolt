import AppKit
import PdfCore

/// The self-test's scenario for roadmap 4.9, two documents side by side (`--edit`, on the synthetic text document;
/// `--only-windows` runs it alone), on copies of the synthetic document: a file asked for again by another spelling, or
/// twice at once, is read once; a document opened joins the group of tabs in use; Window › Move Tab to New Window (AppKit's
/// own) makes a second window, and documents opened while it is in use join it; File › New Window gives the next one a
/// window of its own; Merge All Windows makes them one again; closing tabs takes them out. Where AppKit doesn't make a
/// window main over SSH, the test tells the hub as `windowDidBecomeMain` would. Only counts are written.
@MainActor
struct WindowsTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    /// While it runs, the documents it opens get no checks of their own.
    private(set) static var isActive = false

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var hub: WindowHub { WindowHub.shared }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[windows] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    private func documents(at url: URL) -> [PdfDocument] {
        let path = WindowHub.fullPath(url)
        return NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }.filter { $0.fileURL.map(WindowHub.fullPath) == path }
    }

    private func controller(at url: URL) -> DocumentWindowController? {
        documents(at: url).first?.windowControllers.first as? DocumentWindowController
    }

    private final class Opened { var document: NSDocument?; var done = false }

    /// Asks the document controller for `url`, as Finder and Open do, and waits for its window.
    private func open(_ url: URL) async -> DocumentWindowController? {
        let opened = Opened()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
            MainActor.assumeIsolated {
                opened.document = document
                opened.done = true
            }
        }
        _ = await wait { opened.done }
        let c = (opened.document as? PdfDocument)?.windowControllers.first as? DocumentWindowController
        _ = await wait(5) { c?.window?.isVisible == true }
        await settle()
        return c
    }

    /// The group of tabs `c` is in, as the hub has it after what AppKit did.
    private func group(_ c: DocumentWindowController?) -> Int? { c.flatMap { hub.window(of: $0) } }

    /// The window becomes the one in use, as a click on it does.
    private func use(_ c: DocumentWindowController?) async {
        guard let c else { return }
        c.window?.makeKeyAndOrderFront(nil)
        await settle()
        if NSApp.mainWindow !== c.window { hub.activated(c) }
    }

    /// AppKit's groups of document windows, by size (for the report).
    private var groupSizes: [Int] {
        var seen: Set<ObjectIdentifier> = []
        var sizes: [Int] = []
        for document in NSDocumentController.shared.documents {
            for case let c as DocumentWindowController in document.windowControllers {
                guard let w = c.window else { continue }
                let members = w.tabbedWindows ?? [w]
                if seen.insert(ObjectIdentifier(members[0])).inserted { sizes.append(members.count) }
            }
        }
        return sizes.sorted()
    }

    private var tabCount: Int { hub.rules.windows.reduce(0) { $0 + hub.rules.tabs(of: $1).count } }

    mutating func run() async {
        lines.append("== \(name): two documents side by side")
        Self.isActive = true
        defer { Self.isActive = false }
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-windows-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        guard let synthetic = Report.syntheticPath, (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil
        else {
            lines.append("SKIP two documents side by side: needs --synthetic")
            return Report.write(lines.joined(separator: "\n"))
        }
        let urls = ["One.pdf", "Two.pdf", "Three.pdf"].map { URL(fileURLWithPath: (folder as NSString).appendingPathComponent($0)) }
        for url in urls { try? FileManager.default.copyItem(at: URL(fileURLWithPath: synthetic), to: url) }
        NSApp.activate()
        await use(controller)
        hub.sync()
        let windowsBefore = hub.rules.count, tabsBefore = tabCount, documentsBefore = NSDocumentController.shared.documents.count
        check(group(controller) != nil && hub.rules.active == group(controller),
              "the synthetic document's window is known and in use (\(windowsBefore) windows, \(tabsBefore) tabs)")

        // A file open once: asked for again by another spelling of its path, its own tab comes forward.
        // The file the document shows now: earlier sections' Save As moved it from where the run made it.
        let shown = controller.pdf.fileURL?.path ?? synthetic
        let again = await open(URL(fileURLWithPath: shown.uppercased()))
        check(again === controller && NSDocumentController.shared.documents.count == documentsBefore,
              "a file asked for again (its path in capitals) brings its tab forward, not a second copy")
        if let again, again !== controller { again.pdf.close() } // a second copy, if one opened, goes

        // Asked for twice at once (a double-click repeated): read once.
        NSDocumentController.shared.openDocument(withContentsOf: urls[0], display: true) { _, _, _ in }
        NSDocumentController.shared.openDocument(withContentsOf: urls[0], display: true) { _, _, _ in }
        _ = await wait { controller(at: urls[0])?.window?.isVisible == true }
        await settle()
        let one = controller(at: urls[0])
        check(documents(at: urls[0]).count == 1, "a file asked for twice at once is read once (\(documents(at: urls[0]).count) open)")
        check(one != nil && group(one) == group(controller), "a document opened joins the group of tabs in use")

        // Window › Move Tab to New Window (AppKit's): a second window, and it's the one in use once clicked.
        one?.window?.moveTabToNewWindow(nil)
        await settle()
        await use(one)
        check(hub.rules.count == windowsBefore + 1 && group(one) != group(controller) && hub.rules.active == group(one),
              "Move Tab to New Window: \(hub.rules.count) windows, the moved tab alone in the one in use")
        let two = await open(urls[1])
        check(two != nil && group(two) == group(one), "a document opened while the second window is in use joins it")

        // Back to the first window: what opens goes there.
        await use(controller)
        var three = await open(urls[2])
        check(three != nil && group(three) == group(controller), "with the first window in use again, a document opened joins it")
        three?.pdf.close()
        await settle()

        // File › New Window: the start page, and the next document gets a window of its own.
        NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil)
        let asked = hub.wantsNewWindow && StartWindowController.shared?.isShown == true
        three = await open(urls[2])
        await settle()
        hub.sync()
        let alone = three?.window.map { ($0.tabbedWindows ?? [$0]).count } ?? 0
        check(asked && three != nil && alone == 1 && hub.rules.count == windowsBefore + 2 && group(three) != group(controller) && group(three) != group(one)
              && StartWindowController.shared?.isShown != true && !hub.wantsNewWindow,
              "File › New Window: the start page (\(asked)), then the next document in a window of its own (\(alone) tab there, "
                  + "\(hub.rules.count) windows of \(hub.rules.windows.map { hub.rules.tabs(of: $0).count }) tabs, \(windowsBefore) at first; "
                  + "AppKit's groups: \(groupSizes))")

        // Merge All Windows (AppKit's): one group again, every tab in it.
        controller.window?.mergeAllWindows(nil)
        await settle()
        let merged = group(controller).map { hub.rules.tabs(of: $0).count } ?? 0
        check(hub.rules.count == windowsBefore && merged == tabsBefore + 3 && [one, two, three].allSatisfy { group($0) == group(controller) },
              "Merge All Windows: \(hub.rules.count) window with \(merged) tabs")

        // Closing the tabs takes them out; a file closed can be opened again.
        for c in [one, two, three] { c?.pdf.close() }
        _ = await wait(5) { urls.allSatisfy { documents(at: $0).isEmpty } }
        hub.sync()
        check(tabCount == tabsBefore && hub.rules.beginOpening(WindowHub.fullPath(urls[0])), "the copies closed: \(tabCount) tabs left, and a file closed can open again")
        hub.finishOpening(WindowHub.fullPath(urls[0]))
        await use(controller)

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
