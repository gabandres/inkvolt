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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// The menu bar, built in code: the app (with Check for Updates…), File (Open, Open Recent, Close), Edit (Copy, Find), View (zoom, sidebar),
/// Go (pages), Window.
@MainActor
enum MainMenu {
    static func make(updates: Updates) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(updates)))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
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
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
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
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Next Page", #selector(DocumentWindowController.nextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))
        menu.addItem(item("Previous Page", #selector(DocumentWindowController.previousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        menu.addItem(item("First Page", #selector(DocumentWindowController.firstPage(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), []))
        menu.addItem(item("Last Page", #selector(DocumentWindowController.lastPage(_:)), String(UnicodeScalar(NSEndFunctionKey)!), []))
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
