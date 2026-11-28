import AppKit
import PrintCore
import UniformTypeIdentifiers
import UserNotifications

extension Report {
    /// `--extras` (with `--demo`): what the Windows app's shell integration, jump list, tray, Help, Ctrl+K palette, Store rating
    /// and toasts became on the Mac. Files: the document types offered (never the default PDF app), a picture and a PDF handed
    /// in as Finder hands them (Print Photos opens with the picture; the PDF's printer is chosen, its print panel not opened);
    /// presets: Scan With's, the Dock menu's, a distributed notification read back as `--preset`'s hand-over sends it, and a
    /// preset run from outside scanning on the demo inkjet; Help's window and shortcuts; the palette's list (each icon drawn),
    /// opened and run; the rating request's rule on a store of its own; the notifications' categories and their buttons.
    static func extrasCheck(_ model: AppModel) async -> [String] {
        var lines = ["extras:"]
        lines += filesLines(model)
        lines += await handedLines(model)
        lines += await presetLines(model)
        lines += helpLines(model)
        lines += await paletteLines(model)
        lines += ratingLines()
        lines += await notificationLines()
        return lines
    }

    private static func filesLines(_ model: AppModel) -> [String] {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        var lines = types.map { t in
            let list = (t["LSItemContentTypes"] as? [String] ?? []).joined(separator: ", ")
            return "  document type \(t["CFBundleTypeName"] ?? "?"): \(t["CFBundleTypeRole"] ?? "?"), \(t["LSHandlerRank"] ?? "?"), \(list)"
        }
        let me = Bundle.main.bundleURL.standardizedFileURL
        let pdfDefault = NSWorkspace.shared.urlForApplication(toOpen: .pdf)?.standardizedFileURL
        let offered = NSWorkspace.shared.urlsForApplications(toOpen: .pdf).map(\.standardizedFileURL)
        lines.append("  PDFs open in \(pdfDefault?.lastPathComponent ?? "nothing") by default (this copy: \(pdfDefault == me)); this copy offered for PDFs: \(offered.contains(me))")
        let jpeg = NSWorkspace.shared.urlsForApplications(toOpen: .jpeg).map(\.standardizedFileURL)
        lines.append("  this copy offered for JPEGs: \(jpeg.contains(me)); command line \"a.pdf --queue Office\": files \(HandedFiles.files(in: ["a.pdf", "--queue", "Office"])), queue \(HandedFiles.value("--queue", in: ["a.pdf", "--queue", "Office"]) ?? "-")")
        return lines
    }

    /// A picture handed in: Print Photos asked for on the printer chosen. A PDF: the printer it goes to (its print panel is
    /// a person's to see, so it isn't opened here).
    private static func handedLines(_ model: AppModel) async -> [String] {
        let folder = AppModel.dataFolder.appendingPathComponent("extras", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("handed.png")
        if let tiff = NSImage(size: NSSize(width: 40, height: 30), flipped: false, drawingHandler: { r in
            NSColor.systemTeal.setFill()
            r.fill()
            return true
        }).tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: picture)
        }
        for _ in 0..<40 where !model.printers.contains(where: { !$0.isScannerOnly }) { try? await Task.sleep(for: .milliseconds(250)) }
        AppCommands.open([picture, folder.appendingPathComponent("notes.txt")], app: model)
        var asked = false
        for _ in 0..<150 where !asked {
            asked = model.requested.contains(.printPhotos([picture]))
            if !asked { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let pdf = folder.appendingPathComponent("handed.pdf")
        let target = HandedFiles.target(model.printers, selected: model.selected, prints: { !$0.isScannerOnly })
        return ["  a picture handed in: Print Photos asked for on \(model.selected?.name ?? "no printer"): \(asked)",
                "  a PDF handed in goes to \(target?.name ?? "no printer") (\(HandedFiles.choose([pdf.path, picture.path]) { $0 == picture.path || $0 == pdf.path }))"]
    }

    private static func presetLines(_ model: AppModel) async -> [String] {
        let offered = AppCommands.presetsToOffer(model)
        var lines = ["  Scan With (menu bar, File): \(offered.map(\.name).joined(separator: ", "))"]
        let dock = AppCommands.dockMenu(model)
        lines.append("  Dock menu: \(dock?.items.map(\.title).joined(separator: ", ") ?? "none")")
        // A distributed notification's object, as `--preset`'s hand-over sends it, read back in this process.
        let name = Notification.Name("com.bermudezsystems.InkvoltPrint.preset-check")
        let heard = Heard()
        let token = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            heard.set(note.object as? String)
        }
        DistributedNotificationCenter.default().postNotificationName(name, object: "check-preset", userInfo: nil, deliverImmediately: true)
        for _ in 0..<30 where heard.value == nil { try? await Task.sleep(for: .milliseconds(100)) }
        DistributedNotificationCenter.default().removeObserver(token)
        lines.append("  a distributed notification's preset id arrived: \(heard.value ?? "nothing")")
        // A preset run from outside: the demo inkjet's Scan tab scans with it.
        guard var preset = offered.first, let inkjet = model.printers.first(where: { $0.canScan && !$0.isScannerOnly }) else {
            return lines + ["  preset from outside: no preset or scanner"]
        }
        model.selectedID = inkjet.id
        preset.review = true // stops on the pages: a save would ask where (a panel no one answers here)
        AppCommands.run(preset, app: model)
        for _ in 0..<150 where inkjet.scan.pages.isEmpty || inkjet.scan.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
        lines.append("  preset \(preset.name) from outside on \(inkjet.name): \(inkjet.scan.pages.pages.count) pages, \(inkjet.scan.status)")
        AppCommands.runPreset("no such preset", app: model) // asked for after it was deleted: nothing runs, nothing said
        return lines
    }

    private static func helpLines(_ model: AppModel) -> [String] {
        HelpWindow.show(model)
        let window = NSApp.windows.first { $0.title == String(localized: "Inkvolt Print Help") && $0.isVisible }
        let size = window.map { "\(Int($0.frame.width)) × \(Int($0.frame.height)) pt" } ?? "not shown"
        HelpWindow.close()
        return ["  Help: \(size), \(HelpWindow.shortcuts.count) shortcuts: \(HelpWindow.shortcuts.map(\.keys).joined(separator: " | "))"]
    }

    private static func paletteLines(_ model: AppModel) async -> [String] {
        let (entries, printers) = PrintCommandPalette.entries(model)
        let undrawn = entries.filter { NSImage(systemSymbolName: $0.glyph, accessibilityDescription: nil) == nil }.map(\.glyph)
        var lines = ["  palette: \(entries.count) entries (\(entries.filter(PrintPalette.shownWhenEmpty).count) before a word), "
            + "icons not drawn: \(undrawn.isEmpty ? "none" : Set(undrawn).sorted().joined(separator: ", "))"]
        PrintCommandPalette.show(model)
        let shown = NSApp.windows.contains { $0.title == String(localized: "Command Palette") && $0.isVisible }
        PrintCommandPalette.close()
        // Two words of Go to Scan's name in the interface's language ("go scan", "ir escanear"), the first and the last.
        let words = (entries.first { $0.id == "section:1" }?.name ?? "").split(separator: " ")
        let query = [words.first, words.last].compactMap { $0 }.joined(separator: " ").lowercased()
        let found = PaletteSearch.filter(entries, query, name: \.name, category: \.category).first
        lines.append("  palette shown: \(shown); \"\(query)\" finds \(found?.name ?? "nothing")")
        if let other = printers.indices.first(where: { printers[$0].id != model.selectedID }) {
            PrintCommandPalette.run("show:\(other)", app: model, asBuilt: printers)
            lines.append("  palette Show: \(model.selected?.name == printers[other].name)")
        }
        let before = model.requested.count
        PrintCommandPalette.run("section:1", app: model, asBuilt: printers)
        lines.append("  palette Go to Scan asks for the Scan tab: \(model.requested.dropFirst(before) == [.scan])")
        return lines
    }

    private static func ratingLines() -> [String] {
        let store = StateStore(memory: PrintState())
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let asks = (0..<RatingProgress.successesNeeded).map { RatingRequest.note(store, now: day0.addingTimeInterval(Double($0) * 60), windowShows: true) }
        let later = day0.addingTimeInterval(RatingProgress.wait)
        let closed = RatingRequest.note(store, now: later, windowShows: false)
        let open = RatingRequest.note(store, now: later, windowShows: true)
        let again = RatingRequest.note(store, now: later.addingTimeInterval(86_400), windowShows: true)
        return ["  rating: asks in the first session \(asks.contains(true)); after two days with the window closed \(closed), open \(open), again \(again); "
            + "this copy is the App Store's: \(RatingRequest.isStoreCopy)"]
    }

    private static func notificationLines() async -> [String] {
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        return categories.sorted { $0.identifier < $1.identifier }.map { c in
            "  notification \(c.identifier): \(c.actions.map { "\($0.title) (\($0.identifier))" }.joined(separator: ", "))"
        }
    }

    /// The check's notification, read on the main queue.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        var value: String? { lock.withLock { text } }
        func set(_ s: String?) { lock.withLock { text = s } }
    }
}
