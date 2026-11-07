import Foundation
import PrintCore

// The document command table (Mac only; the Windows app's commands are its ribbon's XAML and RelayCommands): every
// menu bar command once, with its title, key, place in the menus, when it can run and its plain-words note. The app
// builds the menu bar from it (`MainMenu`), checks its items against it (`DocumentWindowController.validateMenuItem`)
// and lists them in the command palette in its order; what can run is decided here, over a `DocumentState`, so the
// package tests reach it. A new command is one row here and its @objc method in the app.

/// A key equivalent's modifier keys (AppKit's `NSEvent.ModifierFlags`, without AppKit).
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

/// The keys a menu item's key equivalent names by code (AppKit's function-key characters).
public enum SpecialKey {
    public static let upArrow = "\u{F700}"
    public static let downArrow = "\u{F701}"
    public static let home = "\u{F729}"
    public static let end = "\u{F72B}"
    public static let backspace = "\u{8}"
}

/// What a command needs of the document in front before it can run. Each is one fact of a `DocumentState`.
public enum Requirement: String, Sendable, CaseIterable {
    /// A document is open (its session loaded).
    case document
    /// It has a page.
    case pages
    /// It has two pages or more (deleting or reversing them leaves one at least).
    case severalPages
    /// No long task (export, Recognize Text, Make Accessible…) and no progress sheet is running: the busy rule.
    case idle
    /// No redaction is being applied.
    case noRedactionRunning
    /// The AI assistant isn't answering.
    case aiIdle
    case selectedText
    /// A comment is selected on the pages.
    case selectedComment
    /// The document was opened from (or saved to) a file.
    case savedFile
    case formFields
    /// Redaction marks wait to be applied.
    case redactionMarks
    /// Find has matches.
    case searchMatches
    /// No digital signature is being made.
    case notSigning
    /// The document has digital signatures.
    case signatures
    /// The document is password protected.
    case protected
    /// Protect with Password's sheet isn't open.
    case noPasswordSheet
    /// Pages › Organize Pages isn't shown (the markup toolbar has nothing to mark there).
    case organizerHidden
    /// The view is split in two panes.
    case split
}

/// The small state of a document window that decides which commands can run.
public struct DocumentState: Sendable, Equatable {
    public var hasDocument = false
    public var pageCount = 0
    /// A long task or a progress sheet is running (the busy rule, once).
    public var isBusy = false
    public var redactionRunning = false
    public var aiBusy = false
    public var hasSelectedText = false
    public var hasSelectedComment = false
    public var hasSavedFile = false
    public var hasFormFields = false
    public var hasRedactionMarks = false
    public var hasSearchMatches = false
    public var isSigning = false
    public var hasSignatures = false
    public var isProtected = false
    public var passwordSheetOpen = false
    public var organizerShown = false
    public var splitShown = false

    public init() {}

    public func meets(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .document: hasDocument
        case .pages: pageCount > 0
        case .severalPages: pageCount > 1
        case .idle: !isBusy
        case .noRedactionRunning: !redactionRunning
        case .aiIdle: !aiBusy
        case .selectedText: hasSelectedText
        case .selectedComment: hasSelectedComment
        case .savedFile: hasSavedFile
        case .formFields: hasFormFields
        case .redactionMarks: hasRedactionMarks
        case .searchMatches: hasSearchMatches
        case .notSigning: !isSigning
        case .signatures: hasSignatures
        case .protected: isProtected
        case .noPasswordSheet: !passwordSheetOpen
        case .organizerHidden: !organizerShown
        case .split: splitShown
        }
    }
}

/// One menu bar command: what the menu shows, the Objective-C action it sends (`"exportWord:"`, the method the app
/// implements), and what it needs to run.
public struct DocumentCommand: Sendable, Hashable {
    public let title: String
    public let action: String
    public let key: String
    public let modifiers: KeyModifiers
    public let needs: [Requirement]

    public init(_ title: String, _ action: String, key: String = "", _ modifiers: KeyModifiers = .command, needs: [Requirement] = []) {
        self.title = title
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.needs = needs
    }

    /// The title the menu shows, in the interface's language (`loc`); `title` stays the English name the palette, the
    /// notes and the tests know it by. Every title in this table is a key of the catalog (`PdfStringsTests`).
    public var shownTitle: String { loc(title) }

    /// The plain words shown as its tooltip (the commands named in jargon only).
    public var note: String? { PlainWords.note(for: title) }

    public func isEnabled(in state: DocumentState) -> Bool { needs.allSatisfy(state.meets) }
}

/// The page tools a menu lists (the app's `Tool` groups): each item picks the tool, with the tool's single key.
public enum ToolSlot: String, Sendable, CaseIterable {
    case hand, selectText, markText, draw, place, fillSign, editContent, redact
    /// Tools › Measure's tools, without keys or pictures.
    case measuring
}

/// A menu the app fills or treats in its own way.
public enum MenuRole: Sendable {
    case plain
    /// The Tools menu and its submenus: their single-key tools leave bare keys to the focused view.
    case tools
    /// macOS's Services menu.
    case services
    /// AppKit's recent documents (it fills the submenu holding Clear Menu).
    case recentDocuments
    /// The saved signatures, filled each time the menu opens.
    case savedSignatures
    /// The Window menu (AppKit adds the window list).
    case windows
    case help
}

/// A menu of the menu bar: its title, entries in order, and role.
public struct CommandMenu: Sendable {
    public let title: String
    public let role: MenuRole
    public let entries: [MenuEntry]

    public init(_ title: String, _ role: MenuRole, _ entries: [MenuEntry]) {
        self.title = title
        self.role = role
        self.entries = entries
    }

    public init(_ title: String, _ entries: [MenuEntry]) { self.init(title, .plain, entries) }

    /// The menu's title in the interface's language (macOS's own words in Spanish: Archivo, Edición, Visualización…).
    public var shownTitle: String { loc(title) }

    /// A menu's role passes to its submenus that keep the plain one (the Tools menu's submenus are tools menus too).
    func inherit(_ parent: MenuRole) -> CommandMenu {
        guard role == .plain, parent == .tools else { return self }
        return CommandMenu(title, .tools, entries)
    }
}

public indirect enum MenuEntry: Sendable {
    case command(DocumentCommand)
    case separator
    case submenu(CommandMenu)
    case tools(ToolSlot)
    /// Sparkle's Check for Updates… (the updater's own item).
    case checkForUpdates
}

public enum DocumentCommands {
    private static func c(_ title: String, _ action: String, _ key: String = "", _ modifiers: KeyModifiers = .command,
                          needs: [Requirement] = []) -> MenuEntry {
        .command(DocumentCommand(title, action, key: key, modifiers, needs: needs))
    }

    private static let sep = MenuEntry.separator

    /// What the long document tasks need: nothing else long running, no redaction being applied.
    private static let longTask: [Requirement] = [.idle, .noRedactionRunning]

    /// The menu bar, in order: the app menu first.
    public static let menuBar: [CommandMenu] = [appMenu, fileMenu, editMenu, viewMenu, goMenu, pagesMenu, toolsMenu, windowMenu, helpMenu]

    static let appMenu = CommandMenu("Inkvolt PDF", [
        c("About Inkvolt PDF", "showAbout:"),
        .checkForUpdates,
        sep,
        c("Settings…", "showSettings:", ","),
        sep,
        .submenu(CommandMenu("Services", .services, [])),
        sep,
        c("Hide Inkvolt PDF", "hide:", "h"),
        c("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
        c("Show All", "unhideAllApplications:"),
        sep,
        c("Quit Inkvolt PDF", "terminate:", "q"),
    ])

    static let fileMenu = CommandMenu("File", [
        c("New Window", "newWindow:", "n"),
        c("Open…", "openDocument:", "o"),
        .submenu(CommandMenu("Open Recent", .recentDocuments, [c("Clear Menu", "clearRecentDocuments:")])),
        sep,
        // New PDFs in one submenu (titles kept whole: the command palette finds them by name).
        .submenu(CommandMenu("New PDF", [
            c("New PDF from Images…", "newFromImages:"),
            c("New PDF from Clipboard", "newFromClipboard:", "n", [.command, .option]),
            c("New PDF from Office File…", "newFromOfficeFile:"),
            c("New PDF from Web Page…", "newFromWebPage:"),
        ])),
        c("Combine Files…", "combineFiles:"),
        c("Compare Files…", "compareFiles:"),
        c("Scan…", "scan:"),
        sep,
        c("Close", "performClose:", "w"),
        c("Save", "saveDocument:", "s"),
        c("Save As…", "saveDocumentAs:", "s", [.command, .shift]),
        .submenu(CommandMenu("Save as PDF/A", [
            c("Save as PDF/A-2b…", "saveAsPdfA:", needs: longTask),
            c("Save as PDF/A-2a (Accessible Archive)…", "saveAsPdfA2a:", needs: longTask),
        ])),
        c("Revert to Saved", "revertDocumentToSaved:"),
        c("Reload from Disk", "reloadFromDisk:", "r", [.command, .option], needs: [.savedFile]),
        sep,
        .submenu(CommandMenu("Export To", [
            c("Word…", "exportWord:", needs: longTask),
            c("Excel (Tables)…", "exportExcel:", needs: longTask),
            c("Plain Text…", "exportText:", needs: longTask),
            c("PowerPoint Presentation…", "exportPowerPoint:", needs: longTask),
            c("HTML Web Page…", "exportHtml:", needs: longTask),
        ])),
        .submenu(CommandMenu("Form Data", [
            c("Reset Form…", "resetForm:", needs: [.formFields]),
            c("Import Form Data…", "importFormData:", needs: [.formFields]),
            c("Export Form Data…", "exportFormData:", needs: [.formFields]),
            sep,
            c("Fill Forms from CSV…", "fillFormsFromCsv:"),
        ])),
        sep,
        c("Share…", "shareDocument:"),
        sep,
        // Its title becomes Change Password Protection… on a protected document.
        c("Protect with Password…", "protectDocument:", needs: [.noPasswordSheet]),
        c("Remove Password Protection…", "removeProtection:", needs: [.protected]),
        c("Reduce File Size…", "reduceFileSize:", needs: longTask),
        sep,
        // Batch and watched folders: many files at once, a rarer job, near the end of the menu.
        c("Batch…", "showBatch:", "b", [.command, .shift]),
        c("Watched Folders…", "showWatchedFolders:"),
        sep,
        c("Document Properties…", "showDocumentProperties:", "i", [.command, .shift], needs: [.document]),
        sep,
        c("Page Setup…", "runPageLayout:", "p", [.command, .shift]),
        c("Print…", "printDocument:", "p"),
        // Opens Inkvolt Print (Windows: shown only when it's installed; here it offers the App Store page without it).
        c("Printer Settings (Inkvolt Print)", "openInkvoltPrint:"),
    ])

    static let editMenu = CommandMenu("Edit", [
        c("Undo", "undo:", "z"),
        c("Redo", "redo:", "z", [.command, .shift]),
        sep,
        c("Cut", "cut:", "x"),
        c("Copy", "copy:", "c"),
        c("Paste", "paste:", "v"),
        c("Delete", "delete:"),
        c("Select All", "selectAll:", "a"),
        sep,
        .submenu(CommandMenu("Find", [
            c("Find…", "showFind:", "f"),
            c("Find Next", "findNext:", "g"),
            c("Find Previous", "findPrevious:", "g", [.command, .shift]),
            sep,
            // Every PDF of the indexed folders (roadmap 3.5; Windows: Edit › Search Folders…, Ctrl+Alt+Shift+F).
            c("Search Folders…", "showFolderSearch:", "f", [.command, .option, .shift]),
        ])),
    ])

    static let viewMenu = CommandMenu("View", [
        c("Actual Size", "actualSize:", "0"),
        c("Zoom to Width", "fitWidth:", "9"),
        c("Zoom to Page", "fitPage:", "9", [.command, .option]),
        c("Zoom In", "zoomIn:", "+"),
        c("Zoom Out", "zoomOut:", "-"),
        sep,
        c("Single Page", "singlePageMode:", "4", needs: [.pages]),
        c("Continuous", "continuousMode:", "5", needs: [.pages]),
        c("Two Pages", "twoPagesMode:", "6", needs: [.pages]),
        c("Two Pages with Cover", "coverMode:", "7", needs: [.pages]),
        sep,
        c("Rotate View Clockwise", "rotateViewClockwise:", "r", [.command, .shift], needs: [.pages]),
        c("Rotate View Counterclockwise", "rotateViewCounterclockwise:", "l", [.command, .shift], needs: [.pages]),
        c("Dark Pages (Night Reading)", "toggleDarkPages:"),
        sep,
        c("Show Sidebar", "toggleSidebar:", "s", [.command, .control]),
        // Its title becomes Hide Markup Toolbar while the toolbar shows.
        c("Show Markup Toolbar", "toggleMarkup:", "a", [.command, .shift], needs: [.document, .organizerHidden]),
        c("Show Toolbar", "toggleToolbarShown:", "t", [.command, .option]),
        c("Customize Toolbar…", "runToolbarCustomizationPalette:"),
        c("Show Comments", "showComments:", "3", [.command, .option]),
        c("Show Signatures", "showSignatures:", "4", [.command, .option], needs: [.signatures]),
        c("Show Attachments", "showAttachments:", "5", [.command, .option]),
        c("Show Layers", "showLayers:", "6", [.command, .option]),
        sep,
        .submenu(CommandMenu("Split View", [
            c("Split Top and Bottom", "splitTopAndBottom:", needs: [.pages]),
            c("Split Side by Side", "splitSideBySide:", needs: [.pages]),
            c("Remove Split", "removeSplit:", needs: [.split]),
            sep,
            c("Switch Pane", "switchPane:", "'", needs: [.split]),
        ])),
        sep,
        c("Read Aloud", "toggleReadAloud:", "y", [.command, .shift], needs: [.pages]),
        c("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control]),
    ])

    static let goMenu = CommandMenu("Go", [
        c("Next Page", "nextPage:", SpecialKey.downArrow, [.command, .option]),
        c("Previous Page", "previousPage:", SpecialKey.upArrow, [.command, .option]),
        c("First Page", "firstPage:", SpecialKey.home, []),
        c("Last Page", "lastPage:", SpecialKey.end, []),
        c("Go to Page…", "goToPage:", "g", [.command, .option], needs: [.pages]),
        sep,
        c("Next Comment", "nextComment:", "]", [.command, .option]),
        c("Previous Comment", "previousComment:", "[", [.command, .option]),
    ])

    /// Pages: the organizer, the page commands (on the pages chosen in it or in the thumbnails, else the current page),
    /// bookmarks.
    static let pagesMenu = CommandMenu("Pages", [
        c("Organize Pages", "toggleOrganizer:", "o", [.command, .option]),
        sep,
        c("Rotate Left", "rotatePagesLeft:", "l"),
        c("Rotate Right", "rotatePagesRight:", "r"),
        c("Duplicate Pages", "duplicatePages:"),
        c("Reverse Page Order", "reversePageOrder:", needs: [.severalPages]),
        c("Delete Pages", "deletePages:", SpecialKey.backspace, [.command, .option], needs: [.severalPages]),
        sep,
        c("Insert Pages from File…", "insertPagesFromFile:", "i", [.command, .option]),
        c("Insert from Scanner…", "insertFromScanner:"),
        c("Insert Blank Page", "insertBlankPage:"),
        c("Extract Pages…", "extractPages:"),
        c("Split Document…", "splitDocument:"),
        c("Crop Pages…", "cropPages:"),
        sep,
        c("Add Header & Footer…", "addHeaderFooter:", needs: longTask),
        c("Remove Header & Footer", "removeHeaderFooter:", needs: longTask),
        c("Add Watermark…", "addWatermark:", needs: longTask),
        c("Remove Watermark", "removeWatermark:", needs: longTask),
        c("Flatten…", "flattenDocument:", needs: longTask),
        sep,
        c("Add Bookmark", "addBookmark:", "d"),
        c("Show Bookmarks", "showBookmarks:", "2", [.command, .option]),
    ])

    /// Tools: Hand and Select Text, then the tools in a few submenus by what a person is doing (Annotate, Fill & Sign,
    /// Redact, Forms, Measure, Accessibility, AI Assistant), as Preview's Tools › Annotate. Each tool keeps its single
    /// key (active while the pages have the focus).
    static let toolsMenu = CommandMenu("Tools", .tools, [
        .tools(.hand),
        .tools(.selectText),
        // Windows' Snapshot (key G there; every single key is a tool's here): a dragged rectangle copied as a picture.
        c("Snapshot", "chooseSnapshot:", "c", [.command, .option], needs: [.pages, .organizerHidden]),
        sep,
        .submenu(CommandMenu("Annotate", [
            .tools(.markText),
            sep,
            .tools(.draw),
            sep,
            .tools(.place),
            c("Picture from File…", "chooseImageFile:"),
            c("Picture from Clipboard", "imageFromClipboard:"),
            sep,
            c("Highlight Selected Text", "highlightText:", "h", [.command, .control]),
            c("Underline Selected Text", "underlineText:", "u", [.command, .control]),
            c("Strike Out Selected Text", "strikeOutText:", "x", [.command, .control]),
            c("Link Selected Text…", "linkSelectedText:", "k", needs: [.selectedText]),
            sep,
            c("Reply to Comment…", "replyToSelected:", "r", [.command, .control], needs: [.selectedComment]),
            sep,
            // Comments in and out (Windows: Review › Import Comments…, Export Comments…, Summarize Comments…).
            c("Import Comments…", "importComments:"),
            c("Export Comments…", "exportComments:"),
            c("Summarize Comments…", "summarizeComments:"),
        ])),
        .submenu(CommandMenu("Fill & Sign", [
            .tools(.fillSign),
            sep,
            c("Draw Signature…", "drawSignature:"),
            c("Type Signature…", "typeSignature:"),
            c("Draw Initials…", "drawInitials:"),
            c("Type Initials…", "typeInitials:"),
            .submenu(CommandMenu("Place Saved Signature", .savedSignatures, [])),
            sep,
            c("Sign Digitally…", "signDigitally:", needs: [.notSigning, .idle]),
        ])),
        .tools(.editContent),
        .submenu(CommandMenu("Redact", [
            .tools(.redact),
            c("Redact Selected Text", "redactSelectedText:", needs: [.selectedText]),
            c("Redact Search Matches", "redactSearchMatches:", needs: [.searchMatches]),
            c("Redact by Pattern…", "redactByPattern:", needs: longTask),
            sep,
            c("Apply Redactions…", "applyRedactions:", needs: [.redactionMarks, .idle]),
            c("Clear Redaction Marks", "clearRedactionMarks:", needs: [.redactionMarks, .idle]),
            sep,
            c("Check Redaction…", "checkRedaction:", needs: longTask),
            c("Sanitize Document…", "sanitizeDocument:", needs: longTask),
            c("What's in This PDF…", "whatsInThisPdf:", needs: longTask),
        ])),
        sep,
        c("Recognize Text (OCR)…", "recognizeText:", needs: longTask),
        c("Review Suspect Words", "reviewSuspectWords:"),
        .submenu(CommandMenu("Forms", [
            c("Prepare Form", "togglePrepareForm:", "f", [.command, .option], needs: [.document]),
            c("Detect Form Fields", "detectFormFields:", needs: [.document, .idle]),
        ])),
        // Measure (Windows: Review › Measure): the measuring tools, then the scale.
        .submenu(CommandMenu("Measure", [
            .tools(.measuring),
            sep,
            c("Set Measuring Scale…", "setMeasuringScale:", needs: [.document, .pages]),
        ])),
        .submenu(CommandMenu("Accessibility", [
            c("Accessibility Check…", "checkAccessibility:", needs: longTask),
            c("Make Accessible (Tag)…", "makeAccessible:", needs: longTask),
            c("Reading Order and Alt Text", "toggleReadingOrder:", needs: [.document, .idle]),
        ])),
        // AI Assistant (Windows: Review › AI Assistant): bring your own, off by default.
        .submenu(CommandMenu("AI Assistant", [
            c("Summarize with AI…", "aiSummarize:", needs: [.pages, .aiIdle]),
            c("Ask AI about This Document", "aiAsk:", needs: [.pages]),
            c("Explain Selection with AI", "aiExplain:", needs: [.selectedText, .aiIdle]),
            sep,
            c("AI Assistant Settings…", "aiSettings:"),
        ])),
        sep,
        c("Show Inspector", "openInspector:", "i", needs: [.selectedComment]),
        c("Command Palette…", "showCommandPalette:", "k", [.command, .shift]),
    ])

    static let windowMenu = CommandMenu("Window", .windows, [
        c("Minimize", "performMiniaturize:", "m"),
        c("Zoom", "performZoom:"),
        sep,
        c("Bring All to Front", "arrangeInFront:"),
    ])

    static let helpMenu = CommandMenu("Help", .help, [
        c("What's New in Inkvolt PDF", "showWhatsNew:"),
        c("Inkvolt Pro…", "showPro:"),
        c("Inkvolt PDF on GitHub", "openSourcePage:"),
        c("Report a Problem…", "reportProblem:"),
    ])

    /// A command with the menus it's in (["File", "Export To"]).
    public struct Placed: Sendable {
        public let path: [String]
        public let command: DocumentCommand
    }

    /// Each command with the menus it's in, in menu order.
    public static let all: [Placed] = {
        var out: [Placed] = []
        func walk(_ menu: CommandMenu, _ path: [String]) {
            for entry in menu.entries {
                switch entry {
                case .command(let command): out.append(Placed(path: path, command: command))
                case .submenu(let sub): walk(sub, path + [sub.title])
                case .separator, .tools, .checkForUpdates: break
                }
            }
        }
        for menu in menuBar { walk(menu, [menu.title]) }
        return out
    }()

    private static let byAction: [String: DocumentCommand] = Dictionary(all.map { ($0.command.action, $0.command) }, uniquingKeysWith: { a, _ in a })

    /// The command that sends `action` ("exportWord:"), if the menu bar has it.
    public static func command(action: String) -> DocumentCommand? { byAction[action] }

    /// Whether the command sending `action` can run in `state` (an action no command sends, a tool's, always can).
    public static func isEnabled(action: String, in state: DocumentState) -> Bool {
        byAction[action]?.isEnabled(in: state) ?? true
    }
}

extension CommandMenu {
    /// Its submenus, each with the role it has in the menu bar (the Tools menu's are tools menus).
    public var resolvedEntries: [MenuEntry] {
        entries.map { entry in
            if case .submenu(let sub) = entry { return .submenu(sub.inherit(role)) }
            return entry
        }
    }
}
