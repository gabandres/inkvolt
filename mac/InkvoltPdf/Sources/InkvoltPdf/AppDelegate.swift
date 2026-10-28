import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updates: Updates

    init(updates: Updates) {
        self.updates = updates
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documents open as tabs of one window, as the Windows app's do.
        NSWindow.allowsAutomaticWindowTabbing = true
        Report.startIfAsked()
        // Recovery copies: offer back what a crashed run left, then keep copies of unsaved work.
        if Report.isRunning { RecoveryCopies.shared.interval = Report.recoveryInterval }
        RecoveryCopies.shared.start(root: Report.recoveryRoot ?? RecoveryCopies.defaultRoot(), ask: !Report.isRunning)
        updates.startTestIfAsked()
        // Launched with no file (files from Finder arrive just after launch): the Open panel, as Preview does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                if NSDocumentController.shared.documents.isEmpty && !Report.isRunning && !self.updates.isTesting {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
        }
    }

    /// No untitled document: a viewer opens files.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// A normal quit (after every document was saved or let go): the recovery copies go.
    func applicationWillTerminate(_ notification: Notification) { RecoveryCopies.shared.quit() }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// The menu bar, built in code: the app (with Check for Updates…), File (Open, Open Recent, Close, Save, Save As, Revert,
/// Reload, Export To, Form Data), Edit (Undo, Redo, Copy, Delete, Find), View (zoom, sidebar, comments), Go (pages, comments), Tools (the tools
/// with their single keys, the text marks, stamps, pictures, links, the inspector), Window.
@MainActor
enum MainMenu {
    static func make(updates: Updates) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(updates)))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        main.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu(_ updates: Updates) -> NSMenu {
        let menu = NSMenu(title: "Inkvolt PDF")
        menu.addItem(item("About Inkvolt PDF", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(updates.menuItem())
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Inkvolt PDF", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Inkvolt PDF", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // AppKit fills the submenu that holds Clear Menu with the recent documents.
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = item("Open Recent", nil)
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(item("Reload from Disk", #selector(DocumentWindowController.reloadFromDisk(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        let export = NSMenu(title: "Export To")
        export.addItem(item("Word…", #selector(DocumentWindowController.exportWord(_:))))
        export.addItem(item("Excel (Tables)…", #selector(DocumentWindowController.exportExcel(_:))))
        export.addItem(item("Plain Text…", #selector(DocumentWindowController.exportText(_:))))
        let exportItem = item("Export To", nil)
        exportItem.submenu = export
        menu.addItem(exportItem)
        let formData = NSMenu(title: "Form Data")
        formData.addItem(item("Reset Form…", #selector(DocumentWindowController.resetForm(_:))))
        formData.addItem(item("Import Form Data…", #selector(DocumentWindowController.importFormData(_:))))
        formData.addItem(item("Export Form Data…", #selector(DocumentWindowController.exportFormData(_:))))
        let formItem = item("Form Data", nil)
        formItem.submenu = formData
        menu.addItem(formItem)
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(DocumentWindowController.showFind(_:)), "f"))
        find.addItem(item("Find Next", #selector(DocumentWindowController.findNext(_:)), "g"))
        find.addItem(item("Find Previous", #selector(DocumentWindowController.findPrevious(_:)), "g", [.command, .shift]))
        let findItem = item("Find", nil)
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0"))
        menu.addItem(item("Zoom to Width", #selector(DocumentWindowController.fitWidth(_:)), "9"))
        menu.addItem(item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Show Comments", #selector(DocumentWindowController.showComments(_:)), "3", [.command, .option]))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Next Page", #selector(DocumentWindowController.nextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))
        menu.addItem(item("Previous Page", #selector(DocumentWindowController.previousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        menu.addItem(item("First Page", #selector(DocumentWindowController.firstPage(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), []))
        menu.addItem(item("Last Page", #selector(DocumentWindowController.lastPage(_:)), String(UnicodeScalar(NSEndFunctionKey)!), []))
        menu.addItem(.separator())
        menu.addItem(item("Next Comment", #selector(DocumentWindowController.nextComment(_:)), "]", [.command, .option]))
        menu.addItem(item("Previous Comment", #selector(DocumentWindowController.previousComment(_:)), "[", [.command, .option]))
        return menu
    }

    /// Tools: each tool with its single key (active while the pages have the focus), then the commands.
    private static func toolsMenu() -> NSMenu {
        let menu = ToolsMenu(title: "Tools")
        for tool in Tool.allCases {
            let entry = item(tool.title, #selector(DocumentWindowController.chooseTool(_:)), tool.key, [])
            entry.tag = tool.rawValue
            entry.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
            if ([.text, .textBox, .arrow, .link, .signature] as [Tool]).contains(tool) { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Highlight Selected Text", #selector(DocumentWindowController.highlightText(_:)), "h", [.command, .control]))
        menu.addItem(item("Underline Selected Text", #selector(DocumentWindowController.underlineText(_:)), "u", [.command, .control]))
        menu.addItem(item("Strike Out Selected Text", #selector(DocumentWindowController.strikeOutText(_:)), "x", [.command, .control]))
        menu.addItem(item("Link Selected Text…", #selector(DocumentWindowController.linkSelectedText(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Picture from File…", #selector(DocumentWindowController.chooseImageFile(_:))))
        menu.addItem(item("Picture from Clipboard", #selector(DocumentWindowController.imageFromClipboard(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Draw Signature…", #selector(DocumentWindowController.drawSignature(_:))))
        menu.addItem(item("Type Signature…", #selector(DocumentWindowController.typeSignature(_:))))
        menu.addItem(item("Draw Initials…", #selector(DocumentWindowController.drawInitials(_:))))
        menu.addItem(item("Type Initials…", #selector(DocumentWindowController.typeInitials(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Recognize Text (OCR)…", #selector(DocumentWindowController.recognizeText(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Inspector", #selector(DocumentWindowController.openInspector(_:)), "i"))
        menu.addItem(item("Reply to Comment…", #selector(DocumentWindowController.replyToSelected(_:)), "r", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
