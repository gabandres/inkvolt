import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for the command bar (`--edit --only-command-bar`, on the synthetic text document): the
/// toolbar's groups in order, each body and arrow named for VoiceOver, each menu with its commands and lines, the
/// colours of Convert's file types and Apply Redactions; then Convert › Word in one click through the body's own
/// accessibility press (name.docx next to the PDF, the notice and its links), a double-click (one more file, not two),
/// a name already taken ("name (2).docx"), and Change options… while the document is busy. With `--snapshots <dir>`
/// it draws the toolbar and the open menus for the owner (light and dark; `--lang es` for Spanish). Files it makes are
/// deleted at the end; only counts and names are written.
@MainActor
struct CommandBarTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private var shots: UxShots

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
        shots = UxShots(controller: controller)
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[bar] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func settle(_ ms: Int = 200) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// The accessibility elements under the window's frame view, with their roles and labels.
    private func elements() -> [(role: String, label: String, element: NSAccessibilityProtocol)] {
        var out: [(String, String, NSAccessibilityProtocol)] = []
        func walk(_ any: Any, _ depth: Int) {
            guard depth < 30, let e = any as? NSAccessibilityProtocol else { return }
            if e.isAccessibilityElement() { out.append((e.accessibilityRole()?.rawValue ?? "", e.accessibilityLabel() ?? "", e)) }
            for child in e.accessibilityChildren() ?? [] { walk(child, depth + 1) }
        }
        if let root = controller.window?.contentView?.superview { walk(root, 0) }
        return out
    }

    private var language: String { CoreLanguage.table?.language ?? "en" }

    mutating func run() async {
        lines.append("== \(name): the command bar (\(language))")
        guard let window = controller.window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let wide = NSSize(width: 1500, height: 860)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wide))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true)
        await settle(600)

        // The groups, in order, each a split item with its label beside its icon.
        let ids = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let groups = ids.compactMap(ToolbarLayout.groupId)
        check(groups == CommandBar.groups.map(\.id), "the toolbar holds the groups in order: \(groups.joined(separator: ", "))")
        let menuItems = window.toolbar?.items.compactMap { $0 as? NSMenuToolbarItem } ?? []
        check(menuItems.count == 7 && menuItems.allSatisfy { $0.showsIndicator && $0.action != nil && $0.title == $0.label && !$0.title.isEmpty },
              "seven split items, each body with an action and its label shown, each arrow with its menu")
        check(window.toolbar?.items.first { $0.itemIdentifier.rawValue == ToolbarLayout.group(CommandBar.pointer) } is NSToolbarItemGroup,
              "the pointer tools: one group of three icons")

        // VoiceOver: both parts of every split item named ("Convert" and "Convert: more commands").
        let all = elements()
        for group in CommandBar.groups where group.hasMainJob {
            let body = all.contains { $0.role == "AXButton" && $0.label == group.label }
            let arrow = all.contains { $0.role == "AXMenuButton" && $0.label == loc("{0}: more commands", group.label) }
            check(body && arrow, "VoiceOver names \(group.id)'s body \"\(group.label)\" and its arrow")
        }

        // Each menu: its commands in order with their lines, the main job first; Comment ends with Draw.
        for item in menuItems {
            guard let id = ToolbarLayout.groupId(item.itemIdentifier.rawValue), let group = CommandBar.group(id) else { continue }
            let commands = item.menu.items.filter { $0.action == #selector(DocumentWindowController.barItemClicked(_:)) }
            let ok = commands.map { $0.representedObject as? String } == group.items.map(\.id) && commands.allSatisfy { !($0.subtitle ?? "").isEmpty }
            let draw = id != CommandBar.drawsIn || item.menu.items.last?.submenu?.items.isEmpty == false
            let enabled = commands.filter { controller.validateMenuItem($0) }.count
            check(ok && draw, "\(id)'s menu: \(commands.count) commands with their lines\(id == CommandBar.drawsIn ? ", then Draw" : ""); \(enabled) can run now")
        }
        // Colours: Convert's four file types and Apply Redactions, drawn in their colour (not as a template).
        let tinted = menuItems.flatMap(\.menu.items).filter { $0.image != nil && $0.image?.isTemplate == false }
            .compactMap { $0.representedObject as? String }.sorted()
        check(tinted == ["ApplyRedactions", "ExportExcel", "ExportPowerPoint", "ExportWord", "SaveAsPdfA"], "coloured icons: \(tinted.joined(separator: ", "))")

        // Every command reaches whoever runs it: this window, or along the responder chain the app delegate (Combine
        // Files…, Scan…); every tool maps to a page tool.
        var lost: [String] = []
        var app: [String] = []
        for entry in BarTable.groups.flatMap(\.items) {
            guard let action = entry.action else { continue }
            let selector = NSSelectorFromString(action)
            let target = controller.barTarget(selector) ?? NSApp.target(forAction: selector, to: nil, from: controller) as AnyObject?
            if (target as? NSObject)?.responds(to: selector) != true { lost.append(entry.id) }
            if target != nil && target !== controller { app.append(entry.id) }
        }
        check(lost.isEmpty, "every bar command finds who runs it\(lost.isEmpty ? "" : "; none for \(lost.joined(separator: ", "))") (the app's: \(app.joined(separator: ", ")))")

        // Organize Pages' grid: the pointer tools are disabled and a click on them changes nothing.
        let pointerId = ToolbarLayout.group(CommandBar.pointer)
        let toolBefore = controller.activePages.tool
        controller.toggleOrganizer(nil)
        await settle(400)
        let pointerGroup = window.toolbar?.items.first { $0.itemIdentifier.rawValue == pointerId } as? NSToolbarItemGroup
        let disabled = controller.validateBarItem(pointerId) == false
        if let pointerGroup {
            pointerGroup.selectedIndex = toolBefore == .hand ? 1 : 0
            controller.pointerClicked(pointerGroup)
        }
        let unchanged = controller.activePages.tool == toolBefore
        controller.toggleOrganizer(nil)
        await settle(400)
        check(disabled && unchanged && controller.validateBarItem(pointerId) == true,
              "with Organize Pages shown the pointer tools are disabled and a click changes no tool; enabled again after")

        if Report.snapshots != nil { await shoot(window) }
        await convertInOneClick(window)

        lines.append(contentsOf: shots.lines.dropFirst())
        lines.append("RESULT: \(failures + shots.failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures + shots.failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    // MARK: Convert › Word in one click

    private mutating func convertInOneClick(_ window: NSWindow) async {
        guard let pdfPath = controller.pdf.fileURL?.path else { return check(false, "the synthetic document has a file") }
        let folder = (pdfPath as NSString).deletingLastPathComponent
        let stem = (controller.pdf.fileURL!.lastPathComponent as NSString).deletingPathExtension
        let docx = { (n: String) in (folder as NSString).appendingPathComponent(n) }
        let made = [stem + ".docx", stem + " (2).docx", stem + " (3).docx"].map(docx)
        defer { for path in made { try? FileManager.default.removeItem(atPath: path) } }
        for path in made { try? FileManager.default.removeItem(atPath: path) }
        DocumentWindowController.atOnceRecognizer = { _, _, _ in [] } // no Vision model to load
        defer { DocumentWindowController.atOnceRecognizer = nil }

        // The body's own press, as a click (or VoiceOver) gives it.
        let convert = loc("Convert")
        guard let body = elements().first(where: { $0.role == "AXButton" && $0.label == convert }) else {
            return check(false, "Convert's body is on the toolbar")
        }
        _ = body.element.accessibilityPerformPress()
        await waitIdle()
        let first = FileManager.default.fileExists(atPath: made[0])
        let size = ((try? FileManager.default.attributesOfItem(atPath: made[0]))?[.size] as? Int) ?? 0
        let notice = controller.noticeBar.message
        let links = controller.noticeBar.linkTitles
        check(first && size > 0 && notice.hasPrefix(Shown.head(loc("Saved {0}", Shown.gap))) && notice.contains(stem + ".docx")
              && links == [loc("Show in Finder"), loc("Change options…")],
              "one click on Convert: \(stem).docx next to the PDF (\(size) bytes); the notice \"\(notice.prefix(60))\" · \(links.joined(separator: " · "))")
        if Report.snapshots != nil {
            await shootRetrying(window, "saved-notice-light" + (language == "en" ? "" : "-\(language)"))
        }

        // A double-click: the second click while the first converts makes nothing more.
        controller.runBar(CommandBar.group("Convert")!.main, option: false)
        let busy = controller.isBusy
        controller.runBar(CommandBar.group("Convert")!.main, option: false)
        // Change options… while the document is busy says so, and opens nothing.
        controller.noticeBar.clickLink(loc("Change options…"))
        let saidBusy = controller.noticeBar.message.hasPrefix(Shown.head(loc("Wait a moment: {0} is still busy.", Shown.gap)))
        check(busy && saidBusy, "Change options… on a busy document says it is busy (\(saidBusy ? "said" : "not said"))")
        await waitIdle()
        let second = FileManager.default.fileExists(atPath: made[1]), third = FileManager.default.fileExists(atPath: made[2])
        check(second && !third, "a double-click converts once: \(stem) (2).docx made, no (3); the first file kept, never written over")

        // Change options… on an idle document opens the export's options.
        controller.noticeBar.clickLink(loc("Change options…"))
        await settle(400)
        let sheet = window.attachedSheet
        check(sheet != nil, "Change options… opens the export's options")
        if let sheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        await settle(300)
    }

    private func waitIdle() async {
        for _ in 0..<600 where controller.isBusy { await settle(100) }
        await settle(200)
    }

    // MARK: Shots for the owner

    private mutating func shoot(_ window: NSWindow) async {
        let suffix = language == "en" ? "" : "-\(language)"
        let looks: [(String, NSAppearance.Name)] = language == "en" ? [("light", .aqua), ("dark", .darkAqua)] : [("light", .aqua)]
        for (look, appearance) in looks {
            NSApp.appearance = NSAppearance(named: appearance)
            await settle(700)
            await shootRetrying(window, "toolbar-\(look)\(suffix)")
            await shootMenu(window, group: "Convert", name: "convert-menu-\(look)\(suffix)")
            if language == "en" {
                await shootMenu(window, group: "Protect", name: "protect-menu-\(look)")
                await shootMenu(window, group: "Comment", name: "comment-menu-\(look)")
            }
        }
        // Narrow: the toolbar's » overflow takes Scan & OCR, Protect and Organize first.
        let wide = window.frame
        var narrow = wide
        narrow.size.width = 1000
        window.setFrame(narrow, display: true)
        await settle(700)
        let shown = window.toolbar?.visibleItems?.compactMap { ToolbarLayout.groupId($0.itemIdentifier.rawValue) } ?? []
        lines.append("at 1000 pt the toolbar shows: \(shown.joined(separator: ", "))")
        await shootRetrying(window, "toolbar-1000-light\(suffix)")
        window.setFrame(wide, display: true)
        await settle(400)
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// A shot, taken again once after a pause when the first try finds no picture (the first shot after an appearance
    /// change came out empty once: the window hadn't drawn yet).
    private mutating func shootRetrying(_ window: NSWindow, _ name: String) async {
        let failed = shots.failures
        shots.shoot(window, name)
        guard shots.failures > failed else { return }
        shots.failures = failed
        shots.lines.removeLast()
        await settle(1000)
        window.display()
        shots.shoot(window, name)
    }

    /// The window with `group`'s menu open under its arrow: the arrow pressed (its accessibility press, as VoiceOver's),
    /// the menu's window drawn while it shows, then closed; both drawn into one picture where they are on screen.
    private mutating func shootMenu(_ window: NSWindow, group id: String, name: String) async {
        guard let dir = Report.snapshots, let group = CommandBar.group(id),
              let arrow = elements().first(where: { $0.role == "AXMenuButton" && $0.label == loc("{0}: more commands", group.label) }) else {
            return check(false, "\(name): \(id)'s arrow found")
        }
        let base = window.contentView?.superview
        let capture = MenuCapture()
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                for w in NSApp.windows where w.isVisible && w !== window {
                    capture.classes.append(String(describing: type(of: w)))
                    guard String(describing: type(of: w)).contains("Menu"), let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    capture.shot = (rep, w.frame)
                }
                for item in window.toolbar?.items ?? [] { (item as? NSMenuToolbarItem)?.menu.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = arrow.element.accessibilityPerformPress()
        await settle(1500)
        timer.invalidate()
        let classes = capture.classes
        guard let (menuRep, menuFrame) = capture.shot, let base, let baseRep = base.bitmapImageRepForCachingDisplay(in: base.bounds) else {
            return check(false, "\(name): the open menu drawn (windows: \(classes.joined(separator: ", ")))")
        }
        base.cacheDisplay(in: base.bounds, to: baseRep)
        // One picture: the window, and the menu where it is on screen (it may hang below the window).
        let windowFrame = window.frame
        let union = windowFrame.union(menuFrame)
        let scale = CGFloat(baseRep.pixelsWide) / max(base.bounds.width, 1)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((union.width * scale).rounded()), pixelsHigh: Int((union.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return check(false, "\(name): no bitmap") }
        out.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: union.size).fill()
            let windowRect = NSRect(x: windowFrame.minX - union.minX, y: windowFrame.minY - union.minY, width: windowFrame.width, height: windowFrame.height)
            UxShots.opaque(baseRep, window)?.draw(in: windowRect)
            let menuRect = NSRect(x: menuFrame.minX - union.minX, y: menuFrame.minY - union.minY, width: menuFrame.width, height: menuFrame.height)
            // The menu's material is drawn by the window server, not by cacheDisplay: the capture holds only the items
            // (white text in dark) over nothing. A flat stand-in of the menu's colour goes under them, chosen from the
            // window's appearance by name: a dynamic colour resolved white here, which hid the dark menu's text.
            let shade = NSBezierPath(roundedRect: menuRect, xRadius: 10, yRadius: 10)
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1)).setFill()
            shade.fill()
            menuRep.draw(in: menuRect)
            (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.15)).setStroke()
            shade.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if ProcessInfo.processInfo.environment["INKVOLT_BAR_RAW"] != nil {
            // Diagnosis: the menu window as cacheDisplay drew it, alone.
            try? menuRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + "-raw.png")))
        }
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".png"))
        let written = (try? out.representation(using: .png, properties: [:])?.write(to: url)) != nil
        check(written, "shot \(name): \(id)'s menu open, \(Int(menuFrame.width)) x \(Int(menuFrame.height)) pt")
    }
}

/// What the menu shot's timer found while the menu was open.
@MainActor
private final class MenuCapture {
    var shot: (NSBitmapImageRep, NSRect)?
    var classes: [String] = []
}
