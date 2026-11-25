import AppKit
import PdfCore
import PrintCore
import PrintMac

/// The UX review's dev step (`mac/docs/UX-REVIEW.md`): with `--self-test <report> --ux-shots <dir> --synthetic --quit`,
/// the app's own windows drawn to PNG files without a person at the screen (AppKit's cacheDisplay, the title bar and
/// toolbar included), in light, dark and Increase Contrast, at the default size and narrow; the menu bar listed; and
/// every control of each window audited for a name VoiceOver can say (`AxAudit`). Only the synthetic documents are
/// shown, never a real file. The report gets one line per shot and per audit finding.
@MainActor
struct UxShots {
    let controller: DocumentWindowController
    var lines: [String] = ["== UX shots"]
    var failures = 0
    var shots = 0
    var findings = 0
    /// Windows, sheets and alerts audited.
    var audited = 0

    init(controller: DocumentWindowController) { self.controller = controller }

    static let looks: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua), ("contrast", .accessibilityHighContrastAqua),
    ]

    func settle(_ ms: Int = 600) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// The whole window (title bar and toolbar too, where AppKit draws them in the frame view) as a PNG.
    mutating func shoot(_ window: NSWindow?, _ name: String) {
        // `--ax-audit` without `--snapshots`: the audit only, nothing drawn.
        if Report.axAudit && Report.snapshots == nil { return }
        guard let dir = Report.snapshots, let window, let view = window.contentView?.superview ?? window.contentView else {
            lines.append("FAIL \(name): no window"); failures += 1; return
        }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            lines.append("FAIL \(name): no bitmap"); failures += 1; return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".png"))
        if (try? Self.opaque(rep, window)?.representation(using: .png, properties: [:])?.write(to: url)) != nil {
            shots += 1
            lines.append("PASS shot \(name): \(Int(view.bounds.width)) x \(Int(view.bounds.height)) pt (\(type(of: view)), window \(Int(window.frame.width)), content \(Int(window.contentView?.bounds.width ?? 0)))")
        } else {
            lines.append("FAIL \(name): not written"); failures += 1
        }
    }

    /// The shot over the window's background color: an alert's material is drawn by the window server, not by
    /// cacheDisplay, so a dark alert came out as white text on nothing (round 2's first dark shots).
    static func opaque(_ rep: NSBitmapImageRep, _ window: NSWindow) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The accessibility audit of `window` (PrintMac's `AxWalk`, shared with Inkvolt Print): names, pictures, values,
    /// raw keys and English in Spanish, controls VoiceOver can't reach, the title and the Tab order. Its lines go into
    /// the report; each finding counts.
    mutating func audit(_ window: NSWindow?, _ name: String) {
        // DialogNames names a dialog's controls as it becomes key; a sheet the walk reaches first is named now, as it
        // will be by the time a person hears it.
        DialogNames.fill(window?.contentView)
        var walk = AxWalk(spanish: CoreLanguage.language != "en" ? CoreLanguage.table?.sentences ?? [:] : [:])
        walk.audit(window, name)
        lines += walk.lines
        findings += walk.findings
        audited += 1
    }

    /// The menu bar as a person sees it: each menu's items (submenus indented), with their shortcuts.
    private mutating func listMenus() {
        guard let main = NSApp.mainMenu else { return }
        var total = 0
        func list(_ menu: NSMenu, _ indent: String) {
            for item in menu.items where !item.isHidden {
                if item.isSeparatorItem { lines.append("\(indent)—"); continue }
                total += 1
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                        + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                }
                lines.append("\(indent)\(item.title)\(key.isEmpty ? "" : "  \(key)")")
                if let sub = item.submenu, !sub.items.isEmpty { list(sub, indent + "    ") }
            }
        }
        for top in main.items.dropFirst() {
            guard let sub = top.submenu else { continue }
            // AppKit fills some menus (Window, Help's search) as they open; ask them to update first.
            sub.update()
            lines.append("MENU \(top.title) (\(sub.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count) items)")
            list(sub, "    ")
        }
        lines.append("MENUS: \(total) items in all")
    }

    mutating func run() async {
        guard let window = controller.window else { return }
        NSApp.activate()
        // The form opened as a second tab: this document's tab in front, or its views are never laid out at a new size.
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        listMenus()
        let defaultSize = NSSize(width: 1100, height: 820)
        func size(_ s: NSSize) {
            var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: s))
            f.origin = window.frame.origin
            window.setFrame(f, display: true, animate: false)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            lines.append("window frame: \(Int(window.frame.width)) x \(Int(window.frame.height)) (asked \(Int(s.width)) x \(Int(s.height)), tabs: \(window.tabbedWindows?.count ?? 0), full screen: \(window.styleMask.contains(.fullScreen)))")
        }
        // The audit reads the tree, which doesn't change with the look: once, in light.
        for (look, appearance) in Self.looks where !Report.axAudit || look == "light" {
            NSApp.appearance = NSAppearance(named: appearance)
            size(defaultSize)
            await settle(900)
            shoot(window, "doc-\(look)")
            if look == "light" { audit(window, "document window") }
            if look != "contrast" {
                size(NSSize(width: 640, height: 600))
                await settle(900)
                shoot(window, "doc-narrow-\(look)")
                if look == "light" {
                    for v in controller.contentStack?.arrangedSubviews ?? [] {
                        lines.append("  narrow: \(type(of: v))\(v.isHidden ? " (hidden)" : "") fits in \(Int(v.fittingSize.width)) pt")
                    }
                    lines.append("  narrow: the sidebar fits in \(Int(controller.sidebar.view.fittingSize.width)) pt")
                    lines.append("  narrow: content stack \(Int(controller.contentStack?.fittingSize.width ?? -1)), window min \(Int(window.minSize.width)), content min \(Int(window.contentMinSize.width)), frame view fits \(Int(window.contentView?.fittingSize.width ?? -1))")
                    for item in controller.split.splitViewItems {
                        lines.append("  narrow: split item \(type(of: item.viewController)) collapsed \(item.isCollapsed) min \(Int(item.minimumThickness)) fits \(Int(item.viewController.view.fittingSize.width)) hidden \(item.viewController.view.isHidden)")
                    }
                }
                size(defaultSize)
            }

            if look == "light" {
                let was = AppSettings.markupShown
                controller.showMarkup(true)
                await settle()
                shoot(window, "doc-markup-\(look)")
                audit(window, "document window with the markup toolbar")
                controller.showMarkup(was)
            }
            controller.showFind(nil)
            await settle()
            if look == "light" { shoot(window, "doc-find-\(look)") }
            controller.hideFind()

            StartWindowController.testRecent = Report.syntheticPath.map { [URL(fileURLWithPath: $0)] } ?? []
            StartWindowController.show()
            await settle(1000)
            StartWindowController.shared?.showMoreTools(false)
            await settle(200)
            shoot(StartWindowController.shared?.window, "start-\(look)")
            if look == "light" {
                StartWindowController.shared?.showMoreTools(true)
                await settle(200)
                shoot(StartWindowController.shared?.window, "start-more-\(look)")
                StartWindowController.shared?.showMoreTools(false)
            }
            if look == "light" { audit(StartWindowController.shared?.window, "start page") }
            StartWindowController.shared?.window?.orderOut(nil)

            SettingsWindowController.show(updates: nil)
            await settle()
            shoot(SettingsWindowController.shared?.window, "settings-\(look)")
            if look == "light" { audit(SettingsWindowController.shared?.window, "Settings") }
            SettingsWindowController.shared?.window?.orderOut(nil)

            if look != "contrast" {
                window.makeKeyAndOrderFront(nil)
                CommandPalette.show(over: window)
                await settle()
                shoot(CommandPalette.shared?.window, "palette-\(look)")
                if look == "light" { audit(CommandPalette.shared?.window, "command palette") }
                CommandPalette.shared?.window?.orderOut(nil)
            }
            window.makeKeyAndOrderFront(nil)
            if look != "contrast" && !Report.uxMainOnly {
                await dialogs(look)
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.appearance = nil
        StartWindowController.testRecent = nil
        lines.append("AX RESULT: \(audited) windows, \(findings) findings (\(CoreLanguage.language))")
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(shots) shots, \(findings) audit findings, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}

/// For a self-test check that reads a shown sentence whose values it can't know (a count, a file name): the same `loc`
/// call the app makes, with `Shown.gap` for each unknown value, split at them into its fixed words, so the check reads
/// Spanish under `--lang es` and English otherwise.
enum Shown {
    static let gap = "\u{1}"

    /// The sentence's fixed words, between its unknown values.
    static func parts(_ sentence: String) -> [String] { sentence.components(separatedBy: gap) }

    /// The words before the first unknown value.
    static func head(_ sentence: String) -> String { parts(sentence).first ?? sentence }

    /// The words after the last unknown value.
    static func tail(_ sentence: String) -> String { parts(sentence).last ?? sentence }

    /// Edit › Undo's title for an action named `action` (a `loc` call), as AppKit words it in the menu.
    @MainActor static func undo(_ action: String) -> String { UndoManager().undoMenuTitle(forUndoActionName: action) }

    /// Edit › Redo's title for an action named `action`.
    @MainActor static func redo(_ action: String) -> String { UndoManager().redoMenuTitle(forUndoActionName: action) }
}
