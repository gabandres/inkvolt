import AppKit
import PDFKit
import PrintCore
import PrintMac
import UniformTypeIdentifiers

/// Printing from Inkvolt Print (the Windows app's Print a PDF and Copy): through macOS's print panel, with the printer's
/// macOS queue chosen when it has one, so copies, page ranges, two-sided printing and paper are macOS's and its driver's.
/// A network printer whose jobs go straight (no macOS queue, the person chose it, or macOS can't use its queue; roadmap 2.1)
/// gets every print's pages from Inkvolt Print itself when it takes a raster format over IPP (`DirectPrinting`); otherwise it
/// can still be picked in the panel (macOS lists printers nearby and sets one up).
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
        // Straight to the printer when the router sends this print there (roadmap 2.1).
        let direct = await DirectPrinting.route(printer)
        guard let setup = SheetPrint.setup(choice) else {
            if let direct {
                await DirectPrinting.printFile(url, password: password, name: name, on: printer, ipp: direct)
                return
            }
            panel(document, name: name, on: printer, app: app)
            return
        }
        // Past the limit on its page count alone: refused before any page is measured (a huge PDF's pages take a while).
        if SheetPrint.tooMany(setup, pages: document.pageCount) {
            alert(tooManySheets)
            return
        }
        var bothSides: Bool? // the queue's or the printer's say (demo mode's made-up ones too); else the panel's printer decides
        if SheetPrint.twoSided(setup, asked: false) { bothSides = await HandDuplexPrinting.queueTwoSided(printer, app: app) }
        let byHand = HandDuplex.offered(bothSides)
        let sizes = await SheetPrintView.measure(document) // once, for the limit and the layout
        if let problem = sheetProblem(setup, sizes, bothSides: bothSides, byHand: byHand) {
            alert(problem)
            return
        }
        // A booklet on a queue that prints one side: by hand, as Windows' SheetPrinting.PrintAsync (roadmap 4.2).
        if SheetPrint.route(setup, asked: false, printerTwoSided: bothSides ?? true, byHand: byHand) == .byHand {
            if let message = await HandDuplexPrinting.printSheets(document, choice: choice, name: name, on: printer, app: app,
                                                                  sizes: sizes)?.items.first?.message {
                alert(message)
            }
            return
        }
        if let direct {
            await DirectPrinting.printSheets(document, choice: choice, name: name, on: printer, ipp: direct, sizes: sizes)
            return
        }
        printSheets(document, choice: choice, name: name, on: printer, app: app, sizes: sizes)
    }

    /// Prints a document the app made or opened (Copy, a preset's print step, an ID card, the clipboard, a recent scan, Print
    /// Photos through the panel): straight to the printer when the router sends this print there (`DirectPrinting`: a page at
    /// its own size on `paper` is a sheet laid out for it), else with the panel. `actualSize`: at its own size (photos laid
    /// out for `paper`), else each page fitted to the paper.
    static func print(_ document: PDFDocument, name: String, on printer: PrinterModel, app: AppModel, actualSize: Bool = false,
                      paper: NSSize? = nil, borderless: Bool = false) {
        Task {
            if let ipp = await DirectPrinting.route(printer) {
                let layout: DirectPrintPages.Layout = !actualSize ? .fitted(.fitToPaper) : paper != nil ? .sheet : .fitted(.actualSize)
                await DirectPrinting.printDocument(document, name: name, on: printer, ipp: ipp, layout: layout,
                                                   paper: paper.map { (width: Double($0.width) / 72, height: Double($0.height) / 72) }, borderless: borderless)
                return
            }
            panel(document, name: name, on: printer, app: app, actualSize: actualSize, paper: paper, borderless: borderless)
        }
    }

    /// Prints a document with the panel, on the printer's queue when it has one.
    static func panel(_ document: PDFDocument, name: String, on printer: PrinterModel, app: AppModel, actualSize: Bool = false,
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
        if operation.run() { app.noteSuccess() }
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
