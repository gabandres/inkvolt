import AppKit
import PDFKit
import PrintCore
import UniformTypeIdentifiers

/// Printing from Inkvolt Print (the Windows app's Print a PDF and Copy): through macOS's print panel, with the printer's
/// macOS queue chosen when it has one, so copies, page ranges, two-sided printing and paper are macOS's and its driver's.
/// A network printer macOS has no queue for can still be picked in the panel (macOS lists printers nearby and sets one up).
@MainActor
enum Printing {
    /// Print a PDF…: the user picks the file.
    static func printPdf(on printer: PrinterModel, app: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF to print on \(printer.name)."
        panel.prompt = "Print…"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else {
            alert("This file couldn't be opened as a PDF.")
            return
        }
        if document.isLocked {
            guard let password = askPassword(url.lastPathComponent), document.unlock(withPassword: password) else {
                if document.isLocked { alert("That password doesn't open \(url.lastPathComponent).") }
                return
            }
        }
        print(document, name: url.deletingPathExtension().lastPathComponent, on: printer, app: app)
    }

    /// Prints a document with the panel, on the printer's queue when it has one. `actualSize`: at its own size (photos laid
    /// out for `paper`), else each page fitted to the paper.
    static func print(_ document: PDFDocument, name: String, on printer: PrinterModel, app: AppModel, actualSize: Bool = false,
                      paper: NSSize? = nil) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        if let target = macPrinter(for: printer, app: app) { info.printer = target }
        if let paper { info.paperSize = paper }
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        guard let operation = document.printOperation(for: info, scalingMode: actualSize ? .pageScaleNone : .pageScaleToFit,
                                                      autoRotate: !actualSize) else {
            alert("macOS couldn't prepare the pages for printing.")
            return
        }
        operation.jobTitle = name
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        operation.run()
    }

    /// The printer as AppKit names it: the queue's `printer-info` (what Printers & Scanners shows).
    static func macPrinter(for printer: PrinterModel, app: AppModel) -> NSPrinter? {
        guard let queue = printer.queueName, let d = app.destinations?.first(where: { $0.name == queue }) else { return nil }
        return NSPrinter(name: d.displayName) ?? NSPrinter(name: d.name)
    }

    private static func askPassword(_ file: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "\(file) is protected with a password."
        alert.informativeText = "Type its password to print it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Print")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
