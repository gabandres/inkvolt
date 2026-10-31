import AppKit
import PdfCore
import UniformTypeIdentifiers

/// File › New PDF from Office File… / from Web Page…, and File › Open for .docx, .xlsx, .pptx (and the other Office
/// formats) and .html/.mht: the file is converted (Office through PdfCore's `OfficeConversion`, web pages through
/// `WebCapture`) and opens as a new, unsaved PDF; the original isn't changed. What the Windows `Converting` does.
@MainActor
enum Converting {
    /// The self-test's fake office apps, and its answers to the questions (a question nobody answers fails the test).
    static var testInstalls: OfficeInstalls?
    static var testConfirmsInternet: Bool?
    private(set) static var lastMessage: (title: String, text: String)?
    private(set) static var lastNotice = ""

    /// Conversions running, to stop at quit so nothing is left in a temp folder or running.
    private static var running: [ObjectIdentifier: (token: CancelToken, ended: DispatchSemaphore)] = [:]

    /// Files Open converts instead of reading itself.
    static func handles(_ url: URL) -> Bool { OfficeFiles.appFor(url.path) != nil || WebFiles.isWebFile(url.path) }

    /// Finds what is installed, each time: LibreOffice may have been installed since. Launch Services knows an app wherever
    /// it was put; the usual places cover a copy it hasn't seen.
    static func installs() -> OfficeInstalls {
        if let testInstalls { return testInstalls }
        let workspace = NSWorkspace.shared
        var bundles = OfficeInstalls.libreOfficeBundles()
        if let found = workspace.urlForApplication(withBundleIdentifier: OfficeInstalls.libreOfficeBundleId) { bundles.append(found.path) }
        let microsoft = OfficeInstalls.microsoftBundleIds.filter { workspace.urlForApplication(withBundleIdentifier: $0.1) != nil }.map(\.0)
        return OfficeInstalls(soffice: OfficeInstalls.soffice(in: bundles), microsoft: Set(microsoft))
    }

    /// Converts `url` and opens the PDF as a new document. Nil when it wasn't (cancelled or failed; said so).
    @discardableResult
    static func openConverted(_ url: URL) async -> PdfDocument? {
        let name = url.lastPathComponent
        guard let app = OfficeFiles.appFor(url.path) else {
            let options = savedWebOptions()
            let paper = options.paper == .a4 ? "A4" : options.paper.rawValue.capitalized
            return await run(title: "Opening \(name)", text: "Opening the page…", pdfName: OfficeFiles.pdfName(url.path),
                             done: "Made from \(name) (\(paper)\(options.landscape ? " landscape" : ""), \(options.margins.rawValue) margins). File › New PDF from Web Page… has the page options. Save it to keep it.") { token, status in
                try await WebCapture.print(url, options: options, status: status, cancel: token)
            }
        }
        let installs = installs()
        if let problem = OfficeConversion.precheck(url.path, installs) {
            tell("Can't open \(name)", problem)
            return nil
        }
        // The converter's macros and links are off, but a file from the internet could still ask for things from elsewhere.
        let internet = OfficeFiles.isFromInternet(url.path)
        if internet && !confirmInternet(name) { return nil }
        let converterName = installs.route(url.path)?.appName ?? "LibreOffice"
        let path = url.path
        return await run(title: "Opening \(name)", text: "Converting with \(converterName)…", pdfName: OfficeFiles.pdfName(path),
                         done: "Made from \(name) with \(converterName). Save it to keep it.") { token, _ in
            try await Task.detached { try OfficeConversion.convert(path, installs: installs, fromInternetConfirmed: internet, cancel: token) }.value
        }
    }

    private static func confirmInternet(_ name: String) -> Bool {
        if Report.isRunning { return testConfirmsInternet ?? false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) came from the internet"
        alert.informativeText = "macOS marks this file as downloaded from the internet. LibreOffice opens it here with its macros and link updates off, "
            + "but it is still read by another program, and a damaged or crafted file could try to fetch content from elsewhere. Convert it only if you trust where it came from."
        alert.addButton(withTitle: "Convert Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func tell(_ title: String, _ text: String) {
        lastMessage = (title, text)
        Report.note("message: \(title): \(text.prefix(200))")
        guard !Report.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// File › New PDF from Office File…: always in the menu (Windows hides it without Office), so what is missing gets said.
    static func fromOfficeFile() {
        let installs = installs()
        guard installs.soffice != nil else {
            tell("LibreOffice isn't installed", installs.missing(nil))
            return
        }
        let panel = NSOpenPanel()
        panel.title = "New PDF from Office File"
        panel.prompt = "Create PDF"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = types(OfficeFiles.panelExtensions(OfficeApp.allCases))
        guard let urls = StartWindowController.pick(panel) else { return }
        Task {
            for url in urls where await openConverted(url) == nil { break }
        }
    }

    static func types(_ extensions: [String]) -> [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

    // MARK: From a web page

    /// File › New PDF from Web Page…: an address or a saved page, with paper, margins and backgrounds.
    static func fromWebPage() {
        guard let (source, options) = askWebPage() else { return }
        saveWebOptions(options)
        Task {
            let name = source.isFileURL ? OfficeFiles.pdfName(source.path) : WebFiles.pdfName(source)
            let label = source.isFileURL ? source.lastPathComponent : (source.host ?? source.absoluteString)
            await run(title: "New PDF from Web Page", text: WebCaptureRules(source: source).loadingText, pdfName: name, done: "Made from \(label). Save it to keep it.") { token, status in
                try await WebCapture.print(source, options: options, status: status, cancel: token)
            }
        }
    }

    private static func askWebPage() -> (URL, WebPdfOptions)? {
        let saved = savedWebOptions()
        let alert = NSAlert()
        alert.messageText = "New PDF from Web Page"
        alert.informativeText = "The page loads on this Mac with WebKit, from the internet as a browser would, in a private session that keeps no cookies or history. "
            + "Scripts on a web page run; a saved page runs none. Pop-ups, downloads and permission requests are blocked."
        alert.addButton(withTitle: "Create PDF")
        alert.addButton(withTitle: "Cancel")
        let address = NSTextField(string: "")
        address.placeholderString = "example.com, or a saved page (.html, .mht)"
        address.setAccessibilityLabel("Web address or file")
        address.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let browse = BrowseButton(title: "Browse…", target: nil, action: nil)
        browse.field = address
        browse.target = browse
        browse.action = #selector(BrowseButton.browse)
        func popup(_ label: String, _ titles: [String], _ selected: Int) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.addItems(withTitles: titles)
            button.selectItem(at: selected)
            button.setAccessibilityLabel(label)
            return button
        }
        let paper = popup("Paper", ["Letter", "A4", "Legal"], WebPaper.allCases.firstIndex(of: saved.paper) ?? 0)
        let orientation = popup("Orientation", ["Portrait", "Landscape"], saved.landscape ? 1 : 0)
        let margins = popup("Margins", ["None", "Narrow (0.25 in)", "Normal (0.4 in)", "Wide (1 in)"], WebMargins.allCases.firstIndex(of: saved.margins) ?? 2)
        let backgrounds = NSButton(checkboxWithTitle: "Background colors and pictures", target: nil, action: nil)
        backgrounds.state = saved.backgrounds ? .on : .off
        let headers = NSButton(checkboxWithTitle: "Header and footer (title, address, date, page numbers)", target: nil, action: nil)
        headers.state = saved.headerAndFooter ? .on : .off
        let problem = NSTextField(labelWithString: "")
        problem.textColor = .systemRed
        problem.lineBreakMode = .byWordWrapping
        problem.maximumNumberOfLines = 2
        problem.preferredMaxLayoutWidth = 400
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Address:"), NSStackView(views: [address, browse])],
                                      [NSTextField(labelWithString: "Paper:"), NSStackView(views: [paper, orientation])],
                                      [NSTextField(labelWithString: "Margins:"), margins],
                                      [NSGridCell.emptyContentView, backgrounds], [NSGridCell.emptyContentView, headers], [NSGridCell.emptyContentView, problem]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = address
        while alert.runModal() == .alertFirstButtonReturn {
            let parsed = WebFiles.parseSource(address.stringValue)
            guard let url = parsed.url else {
                problem.stringValue = parsed.error ?? "That isn't a web address."
                grid.frame.size = grid.fittingSize
                alert.layout()
                continue
            }
            return (url, WebPdfOptions(paper: WebPaper.allCases[max(paper.indexOfSelectedItem, 0)], landscape: orientation.indexOfSelectedItem == 1,
                                       margins: WebMargins.allCases[max(margins.indexOfSelectedItem, 0)], backgrounds: backgrounds.state == .on, headerAndFooter: headers.state == .on))
        }
        return nil
    }

    /// The page options last used (paper by the region's measurement system at first).
    static func savedWebOptions() -> WebPdfOptions {
        let d = AppSettings.defaults
        let metric = Locale.current.measurementSystem == .metric
        return WebPdfOptions(paper: d.string(forKey: "WebPaper").flatMap(WebPaper.init(rawValue:)) ?? (metric ? .a4 : .letter),
                             landscape: d.bool(forKey: "WebLandscape"),
                             margins: d.string(forKey: "WebMargins").flatMap(WebMargins.init(rawValue:)) ?? .normal,
                             backgrounds: d.object(forKey: "WebBackgrounds") as? Bool ?? true,
                             headerAndFooter: d.bool(forKey: "WebHeaderFooter"))
    }

    static func saveWebOptions(_ o: WebPdfOptions) {
        let d = AppSettings.defaults
        d.set(o.paper.rawValue, forKey: "WebPaper")
        d.set(o.landscape, forKey: "WebLandscape")
        d.set(o.margins.rawValue, forKey: "WebMargins")
        d.set(o.backgrounds, forKey: "WebBackgrounds")
        d.set(o.headerAndFooter, forKey: "WebHeaderFooter")
    }

    // MARK: Running one

    /// Runs a conversion behind a progress window with Cancel, then opens the PDF as a new document.
    @discardableResult
    private static func run(title: String, text: String, pdfName: String, done: String,
                            convert: @escaping @MainActor (CancelToken, @escaping (String) -> Void) async throws -> [UInt8]) async -> PdfDocument? {
        let sheet = ProgressSheet(title: title, text: text)
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        if let parent, parent.sheetParent == nil, parent.attachedSheet == nil, !(parent is NSPanel) { sheet.begin(on: parent) } else { sheet.showAlone() }
        let id = ObjectIdentifier(sheet), ended = DispatchSemaphore(value: 0)
        running[id] = (sheet.token, ended)
        defer {
            running[id] = nil
            ended.signal()
            sheet.end()
        }
        do {
            let pdf = try await convert(sheet.token) { sheet.update($0, nil) }
            sheet.end()
            guard let document = NewDocuments.open(pdf, name: pdfName) else { return nil }
            lastNotice = done
            (document.windowControllers.first as? DocumentWindowController)?.notify(done)
            return document
        } catch is CancellationError {
            sheet.end()
            lastNotice = "Cancelled. Nothing was opened."
            (NSDocumentController.shared.currentDocument?.windowControllers.first as? DocumentWindowController)?.notify(lastNotice)
            return nil
        } catch {
            sheet.end()
            tell("Couldn't make the PDF", (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        }
    }

    /// At quit: ends the conversions running and waits a moment for them to clean up (the converter gets its 2 + 3 seconds).
    static func stopAll() {
        let all = Array(running.values)
        for r in all { r.token.cancel() }
        let until = DispatchTime.now() + 6
        // The main thread stays free for what a web page's end needs: only the converter's own thread cleans up unseen.
        while !running.isEmpty, DispatchTime.now() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }
}

/// The web page dialog's Browse…: a saved page's path in the address box.
@MainActor
private final class BrowseButton: NSButton {
    weak var field: NSTextField?

    @objc func browse() {
        let panel = NSOpenPanel()
        panel.title = "Saved web page"
        panel.allowedContentTypes = Converting.types(WebFiles.extensions.map { String($0.dropFirst()) })
        if panel.runModal() == .OK, let url = panel.url { field?.stringValue = url.path }
    }
}

/// Files Open would read itself go on as ever; Office files and saved web pages (from the Open panel, the Dock or Finder)
/// are converted into a new document. Made first in `main.swift`: AppKit keeps the first document controller it sees.
final class DocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let isConverted = MainActor.assumeIsolated { Converting.handles(url) }
        guard isConverted else { return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler) }
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor in
            let document = await Converting.openConverted(url)
            // AppKit shows no error for a user's cancel; the reason, if any, was said already.
            finish(document, false, document == nil ? CocoaError(.userCancelled) : nil)
        }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        let extra = OfficeFiles.panelExtensions(OfficeApp.allCases) + WebFiles.extensions.map { String($0.dropFirst()) }
        super.beginOpenPanel(openPanel, forTypes: (inTypes ?? []) + extra, completionHandler: completionHandler)
    }
}
