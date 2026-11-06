import AppKit
import PdfCore
import PrintCore

/// User preferences, in the app's UserDefaults under the Windows app's `AppSettings` names (Theme, RestorePosition,
/// KeepRecoveryCopies, AuthorName, ZoomMode, LastVersionSeen, the Scan… and Export… choices). The self-test points
/// `defaults` at a suite of its own, so it never changes the user's.
@MainActor
enum AppSettings {
    static var defaults = UserDefaults.standard

    enum Key {
        static let theme = "Theme"
        static let restorePosition = "RestorePosition"
        static let keepRecoveryCopies = "KeepRecoveryCopies"
        static let authorName = "AuthorName"
        static let zoomMode = "ZoomMode"
        static let lastVersionSeen = "LastVersionSeen"
        static let filePositions = "FilePositions"
        static let darkPages = "DarkPages"
        static let layout = "Layout"
        static let scanDevice = "ScanDevice"
        static let scanSource = "ScanSource"
        static let scanColor = "ScanColor"
        static let scanResolution = "ScanResolution"
        static let scanPageSize = "ScanPageSize"
        static let scanOcr = "ScanOcr"
        static let scanSkipBlank = "ScanSkipBlank"
        static let scanPresets = "ScanPresets"
        static let ocrLanguage = "OcrLanguage"
        static let ocrClean = "OcrClean"
        static let ocrSuspects = "OcrSuspects"
    }

    /// How many files' last pages are kept (the Windows app's MaxFiles).
    static let maxFiles = 300

    private static func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }

    /// "System", "Light" or "Dark".
    static var theme: String {
        get { defaults.string(forKey: Key.theme) ?? "System" }
        set { defaults.set(newValue, forKey: Key.theme) }
    }

    /// Reopen each file at the page it was left at.
    static var restorePosition: Bool {
        get { bool(Key.restorePosition, true) }
        set { defaults.set(newValue, forKey: Key.restorePosition) }
    }

    /// Dark pages for night reading: pages drawn with their lightness flipped, hue kept (`NightColors`).
    static var darkPages: Bool {
        get { bool(Key.darkPages, false) }
        set { defaults.set(newValue, forKey: Key.darkPages) }
    }

    /// The reading mode new windows open with (Windows' `Layout`: SinglePage, Continuous, Facing, FacingCover).
    static var readingMode: String {
        get { defaults.string(forKey: Key.layout) ?? "Continuous" }
        set { defaults.set(newValue, forKey: Key.layout) }
    }

    /// The markup toolbar (the comment, drawing, Fill & Sign and redaction tools) under the window's toolbar: hidden until
    /// asked for (View › Show Markup Toolbar, the toolbar's Markup button, or a markup tool picked), as Preview's.
    static var markupShown: Bool {
        get { bool("MarkupToolbarShown", false) }
        set { defaults.set(newValue, forKey: "MarkupToolbarShown") }
    }

    /// Turns dark pages on or off in every window (pages, thumbnails, the organizer).
    static func setDarkPages(_ on: Bool) {
        guard on != darkPages else { return }
        darkPages = on
        NotificationCenter.default.post(name: PageRenderer.darkPagesChanged, object: nil)
    }

    /// Keep a recovery copy of documents with unsaved changes (`RecoveryCopies`).
    static var keepRecoveryCopies: Bool {
        get { bool(Key.keepRecoveryCopies, true) }
        set { defaults.set(newValue, forKey: Key.keepRecoveryCopies) }
    }

    /// The author name on new comments; empty: the Mac user's full name.
    static var authorName: String {
        get { defaults.string(forKey: Key.authorName) ?? "" }
        set { defaults.set(newValue, forKey: Key.authorName) }
    }

    /// The Mac user's full name (the author when none is set).
    static var userName: String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    /// The name written into new comments.
    static var author: String {
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? userName : name
    }

    /// How a document opens: "FitWidth" (pages narrower than the window stay at actual size), "FitPage" or "ActualSize".
    static var zoomMode: String {
        get { defaults.string(forKey: Key.zoomMode) ?? "FitWidth" }
        set { defaults.set(newValue, forKey: Key.zoomMode) }
    }

    static var zoomModes: [(String, String)] { [("FitWidth", loc("Fit width")), ("FitPage", loc("Fit page")), ("ActualSize", loc("Actual size"))] }

    /// Recognize Text's language (a BCP-47 tag; empty: Vision finds out for itself), and its two checks (on by default).
    static var ocrLanguage: String {
        get { defaults.string(forKey: Key.ocrLanguage) ?? "" }
        set { defaults.set(newValue, forKey: Key.ocrLanguage) }
    }

    static var ocrClean: Bool {
        get { bool(Key.ocrClean, true) }
        set { defaults.set(newValue, forKey: Key.ocrClean) }
    }

    static var ocrSuspects: Bool {
        get { bool(Key.ocrSuspects, true) }
        set { defaults.set(newValue, forKey: Key.ocrSuspects) }
    }

    /// The version this was last run as ("1.0.0"): What's New after an update shows what came since.
    static var lastVersionSeen: String? {
        get { defaults.string(forKey: Key.lastVersionSeen) }
        set { defaults.set(newValue, forKey: Key.lastVersionSeen) }
    }

    /// No preferences at all when this run started: a new install, with nothing new to tell about (read in main.swift,
    /// before Sparkle writes its own keys).
    private(set) static var isNewInstall = false

    static func noteFirstRun() {
        let id = Bundle.main.bundleIdentifier ?? "com.bermudezsystems.InkvoltPdf"
        isNewInstall = UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true
    }

    // MARK: Where each file was left

    /// The page `path` was last left at (nil: none kept, or Reopen at last page is off).
    static func lastPage(_ path: String) -> Int? {
        guard restorePosition else { return nil }
        let all = defaults.dictionary(forKey: Key.filePositions) as? [String: [String: Any]]
        return all?[path]?["page"] as? Int
    }

    /// The view's turn `path` was left at (nil: upright, none kept, or Reopen at last page is off).
    static func lastRotation(_ path: String) -> Int? {
        guard restorePosition else { return nil }
        let all = defaults.dictionary(forKey: Key.filePositions) as? [String: [String: Any]]
        return (all?[path]?["rotation"] as? Int).flatMap { $0 == 0 ? nil : $0 }
    }

    static func remember(page: Int, rotation: Int = 0, for path: String) {
        var all = defaults.dictionary(forKey: Key.filePositions) as? [String: [String: Any]] ?? [:]
        all[path] = ["page": page, "rotation": rotation, "at": Date().timeIntervalSince1970]
        if all.count > maxFiles {
            let oldest = all.sorted { ($0.value["at"] as? Double ?? 0) < ($1.value["at"] as? Double ?? 0) }.prefix(all.count - maxFiles)
            for entry in oldest { all.removeValue(forKey: entry.key) }
        }
        defaults.set(all, forKey: Key.filePositions)
    }

    // MARK: Applying them

    /// The app's look: the Mac's setting, light or dark.
    static func applyTheme() {
        switch theme {
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Settings back to how Inkvolt PDF starts; recent files, where files were left, What's New and the Scan and Export
    /// choices are kept (as Windows' Reset to defaults keeps recent files and signatures).
    static func resetToDefaults() {
        let dark = darkPages
        for key in [Key.theme, Key.restorePosition, Key.keepRecoveryCopies, Key.authorName, Key.zoomMode, Key.darkPages, Key.layout] { defaults.removeObject(forKey: key) }
        if dark != darkPages { NotificationCenter.default.post(name: PageRenderer.darkPagesChanged, object: nil) }
    }

    /// Clears everything the self-test's suite holds.
    static func clearTestSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

/// Inkvolt PDF › Settings… (⌘,): the Windows Settings dialog's choices that apply on the Mac. Save writes them; Reset to
/// Defaults fills in how Inkvolt PDF starts (saved with Save).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static var shared: SettingsWindowController?

    let theme = NSPopUpButton(frame: .zero, pullsDown: false)
    let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
    let restore = NSButton(checkboxWithTitle: loc("Reopen each file at the page where I left off"), target: nil, action: nil)
    let recovery = NSButton(checkboxWithTitle: loc("Keep recovery copies of unsaved changes"), target: nil, action: nil)
    let dark = NSButton(checkboxWithTitle: loc("Dark pages (inverted colors for night reading)"), target: nil, action: nil)
    let updates = NSButton(checkboxWithTitle: loc("Check for updates automatically"), target: nil, action: nil)
    let author = NSTextField(string: "")
    /// Settings › Language (shown while `AppLanguage.spanishReady`): Same as macOS, English, Español, from the next launch.
    let language = NSPopUpButton(frame: .zero, pullsDown: false)
    let aiState = NSTextField(wrappingLabelWithString: "")
    private let updater: Updates?
    /// Called after Save (the self-test waits on it).
    var onSaved: (() -> Void)?

    static func show(updates: Updates?) {
        let controller = shared ?? SettingsWindowController(updater: updates)
        shared = controller
        controller.load()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(updater: Updates?) {
        self.updater = updater
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = loc("Inkvolt PDF Settings")
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        theme.addItems(withTitles: [loc("Use my Mac's setting"), loc("Light"), loc("Dark")])
        zoom.addItems(withTitles: AppSettings.zoomModes.map(\.1))
        recovery.toolTip = loc("Offered back if Inkvolt PDF closes unexpectedly (a crash, a power cut)")
        updates.toolTip = loc("Asks Inkvolt PDF's update feed on GitHub whether a newer version is ready. Nothing about you or this Mac is sent.")
        author.placeholderString = AppSettings.userName
        author.setAccessibleName(loc("Author name on comments"))

        aiState.preferredMaxLayoutWidth = 300
        aiState.isSelectable = false
        let aiSetUp = NSButton(title: loc("AI Assistant Settings…"), target: self, action: #selector(aiSettingsClicked))
        let aiRow = NSStackView(views: [aiState, aiSetUp])
        aiRow.orientation = .vertical
        aiRow.alignment = .leading
        aiRow.spacing = 6
        // Each pop-up named by its label (VoiceOver read them as nameless; the audit found them).
        theme.setAccessibleName(loc("App theme"))
        zoom.setAccessibleName(loc("Open documents at"))
        language.addItems(withTitles: AppLanguage.Choice.allCases.map(\.title))
        language.setAccessibleName(loc("Language"))
        let languageNote = NSTextField(wrappingLabelWithString: loc("Takes effect the next time Inkvolt PDF starts."))
        languageNote.textColor = .secondaryLabelColor
        languageNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let languageRow = NSStackView(views: [language, languageNote])
        languageRow.orientation = .vertical
        languageRow.alignment = .leading
        languageRow.spacing = 4
        var rows: [[NSView]] = [
            [NSTextField(labelWithString: loc("App theme:")), theme],
            [NSTextField(labelWithString: loc("Open documents at:")), zoom],
        ]
        if AppLanguage.spanishReady { rows.append([NSTextField(labelWithString: loc("Language:")), languageRow]) }
        rows += [
            [NSGridCell.emptyContentView, restore],
            [NSGridCell.emptyContentView, dark],
            [NSGridCell.emptyContentView, recovery],
            [NSGridCell.emptyContentView, updates],
            [NSTextField(labelWithString: loc("Author name on comments:")), author],
            [NSTextField(labelWithString: loc("AI assistant:")), aiRow],
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        author.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let note = NSTextField(wrappingLabelWithString:
            loc("To make Inkvolt PDF your default PDF app: select a PDF in the Finder, choose File › Get Info, pick Inkvolt PDF under Open with, then click Change All."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 460
        // A change applies at once, as in every Mac app's settings (no Save or Cancel; UX review, 2026-11-03).
        let reset = NSButton(title: loc("Reset to Defaults"), target: self, action: #selector(resetClicked))
        reset.toolTip = loc("These settings back to how Inkvolt PDF starts; the language follows macOS from the next launch. Recent files are kept.")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer])
        for control in [theme, zoom, language, restore, recovery, dark, updates] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        author.target = self
        author.action = #selector(changed(_:))
        author.delegate = self
        let stack = NSStackView(views: [grid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        window.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The controls from the settings as they are.
    func load() {
        theme.selectItem(at: ["System", "Light", "Dark"].firstIndex(of: AppSettings.theme) ?? 0)
        zoom.selectItem(at: AppSettings.zoomModes.firstIndex { $0.0 == AppSettings.zoomMode } ?? 0)
        language.selectItem(at: AppLanguage.Choice.allCases.firstIndex(of: AppLanguage.choice) ?? 0)
        restore.state = AppSettings.restorePosition ? .on : .off
        recovery.state = AppSettings.keepRecoveryCopies ? .on : .off
        dark.state = AppSettings.darkPages ? .on : .off
        updates.state = updater?.controller.updater.automaticallyChecksForUpdates == true ? .on : .off
        updates.isEnabled = updater != nil
        author.stringValue = AppSettings.authorName.isEmpty ? AppSettings.userName : AppSettings.authorName
        aiState.stringValue = AiService.describe(AppSettings.ai)
    }

    /// Its own sheet, saved on its own, as on Windows.
    @objc func aiSettingsClicked() {
        guard let window else { return }
        Task { @MainActor in
            guard await AiSettingsSheet.show(on: window) else { return }
            aiState.stringValue = AiService.describe(AppSettings.ai)
            DocumentWindowController.refreshAllAiPanes()
        }
    }

    /// Every control back to Inkvolt PDF's defaults; the language back to Same as macOS (macOS's own setting for the app,
    /// read at the next launch, as picking one is).
    @objc func resetClicked() {
        theme.selectItem(at: 0)
        zoom.selectItem(at: 0)
        language.selectItem(at: AppLanguage.Choice.allCases.firstIndex(of: .system) ?? 0)
        restore.state = .on
        recovery.state = .on
        dark.state = .off
        updates.state = .on
        author.stringValue = AppSettings.userName
        saveClicked()
    }

    @objc func changed(_ sender: Any?) { saveClicked() }

    /// The author's name applies as it is typed in.
    func controlTextDidChange(_ obj: Notification) { saveClicked() }

    /// Applies every control's value now (each control calls it; the self-test too).
    @objc func saveClicked() {
        AppSettings.theme = ["System", "Light", "Dark"][max(theme.indexOfSelectedItem, 0)]
        AppSettings.zoomMode = AppSettings.zoomModes[max(zoom.indexOfSelectedItem, 0)].0
        // The language is macOS's own setting for the app (the next launch's), never the self-test's to change.
        let chosen = AppLanguage.Choice.allCases[max(language.indexOfSelectedItem, 0)]
        if chosen != AppLanguage.choice && !Report.isRunning { AppLanguage.save(chosen) }
        AppSettings.restorePosition = restore.state == .on
        AppSettings.keepRecoveryCopies = recovery.state == .on
        AppSettings.setDarkPages(dark.state == .on)
        let name = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.authorName = name == AppSettings.userName ? "" : name // empty: follow the Mac user's name
        if let updater, updates.isEnabled, !Report.isRunning { updater.controller.updater.automaticallyChecksForUpdates = updates.state == .on }
        AppSettings.applyTheme()
        RecoveryCopies.shared.enabled = AppSettings.keepRecoveryCopies
        onSaved?()
    }
}
