import AppKit
import PDFKit
import PrintCore
import PrintMac
import UniformTypeIdentifiers

/// Printing from Inkvolt Print (the Windows app's Print a PDF and Copy): through macOS's print panel, with the printer's
/// macOS queue chosen when it has one, so copies, page ranges, two-sided printing and paper are macOS's and its driver's.
/// A network printer macOS has no queue for gets Print a PDF's pages straight from Inkvolt Print when it takes a raster
/// format over IPP (`DirectPrinting`, roadmap 2.1, one page per sheet); otherwise it can still be picked in the panel (macOS
/// lists printers nearby and sets one up).
@MainActor
enum Printing {
    /// Print a PDF…: the user picks the file, and its layout under the file list (roadmap 4.18: one page per sheet as before,
    /// several, a booklet or a poster, `SheetPrinting`).
    static func printPdf(on printer: PrinterModel, app: AppModel) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a PDF to print on \(printer.name).")
        panel.prompt = String(localized: "Print…")
        let layout = SheetChoiceView()
        panel.accessoryView = layout
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await printPdf(url, choice: layout.choice, on: printer, app: app)
    }

    /// A PDF file printed as Print a PDF prints it (its password asked when it has one) in the layout chosen: the picked one,
    /// or one copied in Finder (Print the Clipboard, roadmap 4.13: one page per sheet).
    static func printPdf(_ url: URL, choice: SheetChoice = SheetChoice(.normal), on printer: PrinterModel, app: AppModel) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else {
            alert(String(localized: "This file couldn't be opened as a PDF."))
            return
        }
        var password: String?
        if document.isLocked {
            password = askPassword(url.lastPathComponent)
            guard let password, document.unlock(withPassword: password) else {
                if document.isLocked { alert(String(localized: "That password doesn't open \(url.lastPathComponent).")) }
                return
            }
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard let setup = SheetPrint.setup(choice) else {
            // A network printer macOS has no queue for, taking raster over IPP: straight to it (roadmap 2.1).
            if printer.queueName == nil, let ipp = await DirectPrinting.route(printer) {
                await DirectPrinting.print(url, password: password, name: name, on: printer, ipp: ipp)
                return
            }
            print(document, name: name, on: printer, app: app)
            return
        }
        var bothSides: Bool? // the queue's say (demo mode's made-up ones too), when it has one; else the panel's printer decides
        if SheetPrint.twoSided(setup, asked: false) { bothSides = await HandDuplexPrinting.queueTwoSided(printer, app: app) }
        let byHand = HandDuplex.offered(bothSides)
        if let problem = sheetProblem(setup, document, bothSides: bothSides, byHand: byHand) {
            alert(problem)
            return
        }
        // A booklet on a queue that prints one side: by hand, as Windows' SheetPrinting.PrintAsync (roadmap 4.2).
        if SheetPrint.route(setup, asked: false, printerTwoSided: bothSides ?? true, byHand: byHand) == .byHand {
            if let message = await HandDuplexPrinting.printSheets(document, choice: choice, name: name, on: printer, app: app)?.items.first?.message {
                alert(message)
            }
            return
        }
        printSheets(document, choice: choice, name: name, on: printer, app: app)
    }

    /// Prints a document with the panel, on the printer's queue when it has one. `actualSize`: at its own size (photos laid
    /// out for `paper`), else each page fitted to the paper.
    static func print(_ document: PDFDocument, name: String, on printer: PrinterModel, app: AppModel, actualSize: Bool = false,
                      paper: NSSize? = nil, borderless: Bool = false) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        if let target = macPrinter(for: printer, app: app) { info.printer = target }
        if let paper { info.paperSize = paper }
        if borderless { (info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin) = (0, 0, 0, 0) }
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        guard let operation = document.printOperation(for: info, scalingMode: actualSize ? .pageScaleNone : .pageScaleToFit,
                                                      autoRotate: !actualSize) else {
            alert(String(localized: "macOS couldn't prepare the pages for printing."))
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
        alert.messageText = String(localized: "\(file) is protected with a password.")
        alert.informativeText = String(localized: "Type its password to print it.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Print"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
