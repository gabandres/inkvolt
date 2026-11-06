import AppKit
import PdfCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updates: Updates
    /// Set once the app is quitting (the start page doesn't come back while documents close).
    static var isTerminating = false

    init(updates: Updates) {
        self.updates = updates
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documents open as tabs of one window, as the Windows app's do.
        NSWindow.allowsAutomaticWindowTabbing = true
        DialogNames.start()
        Report.startIfAsked()
        // The Inkvolt Pro check: again here, after Report.startIfAsked, so the self-test reads its own settings suite and
        // never the shared key file (main.swift set it first, for the command line).
        ProSetup.configure(selfTest: Report.isRunning)
        AppSettings.applyTheme()
        FolderWatches.shared.startSaved()
        // Recovery copies: offer back what a crashed run left, then keep copies of unsaved work (unless Settings says not).
        if Report.isRunning { RecoveryCopies.shared.interval = Report.recoveryInterval }
        RecoveryCopies.shared.enabled = Report.isRunning || AppSettings.keepRecoveryCopies
        RecoveryCopies.shared.start(root: Report.recoveryRoot ?? RecoveryCopies.defaultRoot(), ask: !Report.isRunning)
        updates.startTestIfAsked()
        // Launched with no file (files from Finder arrive just after launch): the start page. After an update, once,
        // What's New.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                guard !Report.isRunning && !self.updates.isTesting else { return }
                if NSDocumentController.shared.documents.isEmpty { StartWindowController.show() }
                WhatsNew.showOnce()
            }
        }
    }

    /// A click on the Dock icon with no window open: the start page.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { StartWindowController.show() }
        return true
    }

    // MARK: App commands (the start page, new PDFs, scanning, settings, help)

    @objc func newWindow(_ sender: Any?) { StartWindowController.show() }
    @objc func newFromImages(_ sender: Any?) { NewDocuments.chooseImages() }
    @objc func newFromClipboard(_ sender: Any?) { NewDocuments.fromClipboard() }
    @objc func newFromOfficeFile(_ sender: Any?) { Converting.fromOfficeFile() }
    @objc func newFromWebPage(_ sender: Any?) { Converting.fromWebPage() }
    @objc func combineFiles(_ sender: Any?) { _ = CombineWindowController.show() }
    @objc func compareFiles(_ sender: Any?) { CompareWindowController.pick() }
    @objc func scan(_ sender: Any?) { ScanWindowController.show() }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(updates: updates) }
    @objc func showAbout(_ sender: Any?) { AboutWindowController.show() }
    @objc func showWhatsNew(_ sender: Any?) { WhatsNew.show(WhatsNew.notes()) }
    @objc func showPro(_ sender: Any?) { ProWindowController.show() }
    @objc func showBatch(_ sender: Any?) { BatchWindowController.show() }
    @objc func showWatchedFolders(_ sender: Any?) {
        if Pro.allows(.watchedFolders) { WatchedFoldersWindowController.show() } else { ProWindowController.show(feature: .watchedFolders) }
    }
    @objc func showCommandPalette(_ sender: Any?) { CommandPalette.show() }
    @objc func openSourcePage(_ sender: Any?) { NSWorkspace.shared.open(AboutWindowController.source) }
    @objc func reportProblem(_ sender: Any?) { ReportProblemWindowController.show() }

    /// No untitled document: a viewer opens files.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// A normal quit (after every document was saved or let go): the recovery copies go.
    func applicationWillTerminate(_ notification: Notification) {
        Self.isTerminating = true
        Converting.stopAll()
        RecoveryCopies.shared.quit()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}


/// The menu bar, built in code from the document command table (`DocumentCommands.menuBar` in PdfCore: each command's
/// title, key, place and what it needs to run): the app (About, Check for Updates…, Settings…), File, Edit, View, Go,
/// Pages, Tools (the tools with their single keys in submenus by task), Window, Help. Here only what needs AppKit: the
/// selectors, the tools' items (`Tool`), the menus AppKit or the app fills (Services, Open Recent, Place Saved Signature,
/// Window, Help) and Sparkle's item.
@MainActor
enum MainMenu {
    static func make(updates: Updates) -> NSMenu {
        let main = NSMenu()
        for spec in DocumentCommands.menuBar {
            let menu = build(spec, updates)
            main.addItem(holder(spec.shownTitle, menu))
            if spec.role == .windows { NSApp.windowsMenu = menu }
            if spec.role == .help { NSApp.helpMenu = menu }
        }
        return main
    }

    private static func holder(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func build(_ spec: CommandMenu, _ updates: Updates) -> NSMenu {
        let menu: NSMenu
        switch spec.role {
        // Leaves bare keys to the focused view (the tools' single keys).
        case .tools: menu = ToolsMenu(title: spec.shownTitle)
        case .savedSignatures: menu = SavedSignaturesMenu.make()
        default: menu = NSMenu(title: spec.shownTitle)
        }
        if spec.role == .services { NSApp.servicesMenu = menu }
        if spec.role == .recentDocuments {
            // Named as AppKit's recent-documents menu, so NSDocumentController fills this one rather than adding a second
            // Open Recent of its own (the UX review's menu listing showed two).
            menu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        }
        for entry in spec.resolvedEntries {
            switch entry {
            case .separator: menu.addItem(.separator())
            case .command(let command): menu.addItem(item(command))
            case .submenu(let sub): menu.addItem(holder(sub.shownTitle, build(sub, updates)))
            case .tools(let slot): for item in tools(slot) { menu.addItem(item) }
            case .checkForUpdates: menu.addItem(updates.menuItem())
            }
        }
        return menu
    }

    private static func item(_ command: DocumentCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.shownTitle, action: NSSelectorFromString(command.action), keyEquivalent: command.key)
        item.keyEquivalentModifierMask = flags(command.modifiers)
        // The jargon the Windows names keep, said plainly on the item (UX review, round 2; renames are proposed).
        item.toolTip = command.note
        return item
    }

    static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// A slot's tools: each picks its tool (the item's tag), with the tool's single key and picture; the measuring
    /// tools without either.
    private static func tools(_ slot: ToolSlot) -> [NSMenuItem] {
        let chosen: [Tool]
        switch slot {
        case .hand: chosen = [.hand]
        case .selectText: chosen = [.text]
        case .markText: chosen = Tool.groups[1]
        case .draw: chosen = Tool.groups[2]
        case .place: chosen = Tool.groups[3]
        case .fillSign: chosen = Tool.groups[4]
        case .editContent: chosen = [.editContent]
        case .redact: chosen = [.redact]
        case .measuring: chosen = Tool.measuring
        }
        let keyed = slot != .measuring
        return chosen.map { t in
            let item = NSMenuItem(title: t.shownTitle, action: #selector(DocumentWindowController.chooseTool(_:)), keyEquivalent: keyed ? t.key : "")
            item.keyEquivalentModifierMask = keyed ? [] : .command
            item.toolTip = PlainWords.note(for: t.title)
            item.tag = t.rawValue
            if keyed { item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil) }
            return item
        }
    }
}
