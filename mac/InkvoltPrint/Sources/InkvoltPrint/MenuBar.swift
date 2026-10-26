import AppKit
import PrintCore
import SwiftUI

/// The menu bar item's menu (the Windows tray's): a line per printer, problems first; opening the app; quitting.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lines = model.menuLines.enumerated()
            .sorted { $0.element.line.level != $1.element.line.level ? $0.element.line.level > $1.element.line.level : $0.offset < $1.offset }
            .map(\.element)
        if lines.isEmpty {
            Text(model.localNetwork == .denied ? "No Local Network access" : "No printers yet")
        }
        ForEach(lines, id: \.id) { entry in
            Button("\(MenuBarIcon.mark(entry.line.level)) \(entry.line.name): \(entry.line.text)") {
                model.selectedID = entry.id
                open()
            }
        }
        Divider()
        Button("Open Inkvolt Print") { open() }.keyboardShortcut("o")
        Divider()
        Button("Quit Inkvolt Print") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open() {
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// The menu bar icon: a printer, with a badge for the worst printer's state. A template image, so it follows the menu bar.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(model.overall))
            .onAppear {
                let open = openWindow
                model.openMainWindow = { open(id: MainWindow.id) }
            }
    }
}

enum MenuBarIcon {
    /// A mark before each printer's line in the menu (menus show no colours).
    static func mark(_ level: AlertLevel) -> String {
        switch level {
        case .ok: "●"
        case .offline: "○"
        case .warning: "▲"
        case .error: "■"
        }
    }

    static func image(_ level: AlertLevel) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let description: String
        let badgeName: String?
        switch level {
        case .ok: (description, badgeName) = ("Inkvolt Print", nil)
        case .offline: (description, badgeName) = ("Inkvolt Print: a printer is offline", "minus.circle.fill")
        case .warning: (description, badgeName) = ("Inkvolt Print: a printer needs attention", "exclamationmark.circle.fill")
        case .error: (description, badgeName) = ("Inkvolt Print: a printer has a problem", "xmark.circle.fill")
        }
        guard let base = NSImage(systemSymbolName: "printer", accessibilityDescription: description)?.withSymbolConfiguration(config) else {
            return NSImage()
        }
        guard let badgeName, let badge = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let spot = NSRect(x: size.width - badge.size.width, y: 0, width: badge.size.width, height: badge.size.height)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: spot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
