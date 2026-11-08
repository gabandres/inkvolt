import AppKit
import PdfCore
import PrintCore
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

    /// Finds what is installed, each time: an app may have been installed since. Launch Services knows an app wherever
    /// it was put; the usual places cover a LibreOffice it hasn't seen. Word, Excel and PowerPoint convert their own kinds
    /// first (driven through AppleScript, `MicrosoftOfficeConverter`), LibreOffice the rest.
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
        guard OfficeFiles.appFor(url.path) != nil else {
            let options = savedWebOptions()
            let done = loc("Made from {0} ({1}). File › New PDF from Web Page… has the page options. Save it to keep it.", name, describe(options))
            return await run(title: loc("Opening {0}", name), text: loc("Opening the page…"), pdfName: OfficeFiles.pdfName(url.path), done: { done }) { token, status in
                try await WebCapture.print(url, options: options, status: status, cancel: token)
            }
        }
        guard let (job, internet) = prepareOffice(url, cantTitle: loc("Can't open {0}", name)) else { return nil }
        let made = Made()
        return await run(title: loc("Opening {0}", name), text: loc("Converting with {0}…", job.appName), pdfName: OfficeFiles.pdfName(url.path),
                         done: { made.result?.notice(name) ?? "" }) { token, _ in
            let result = try await OfficeConversion.run(job, fromInternetConfirmed: internet, cancel: token)
            made.result = result
            return result.pdf
        }
    }

    /// What converted an Office file, for the notice once the document is open.
    @MainActor private final class Made { var result: OfficeResult? }

    /// The checks before an Office file is converted, for Open and Compare alike: what converts it (chosen once, so the
    /// progress names the converter that runs first), and the question for a file from the internet. Nil when it won't
    /// be converted (said why, under `cantTitle`).
    private static func prepareOffice(_ url: URL, cantTitle: String) -> (job: OfficeJob, internet: Bool)? {
        let job: OfficeJob
        do {
            job = try OfficeConversion.job(url.path, installs())
        } catch {
            tell(cantTitle, (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        }
        // The converter's macros and links are off, but a file from the internet could still ask for things from elsewhere.
        let internet = OfficeFiles.isFromInternet(url.path)
        if internet && !confirmInternet(url.lastPathComponent, job.converters.first) { return nil }
        return (job, internet)
    }

    /// File › Compare Files' Office side (Windows' `Comparing.LoadFile`): the file made into PDF bytes behind a progress
    /// window with Cancel, with the same checks as opening one; nothing is opened. Nil when it wasn't (cancelled, or failed
    /// and said so).
    static func pdfForCompare(_ url: URL) async -> [UInt8]? {
        let name = url.lastPathComponent
        guard let (job, internet) = prepareOffice(url, cantTitle: loc("Can't compare {0}", name)) else { return nil }
        let sheet = ProgressSheet(title: loc("Comparing {0}", name), text: loc("Converting with {0}…", job.appName))
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        if let parent, parent.sheetParent == nil, parent.attachedSheet == nil, !(parent is NSPanel) { sheet.begin(on: parent) } else { sheet.showAlone() }
        let id = ObjectIdentifier(sheet), ended = DispatchSemaphore(value: 0)
        running[id] = (sheet.token, ended)
        defer {
            running[id] = nil
            ended.signal()
            sheet.end()
        }
        let token = sheet.token
        do {
            return try await OfficeConversion.run(job, fromInternetConfirmed: internet, cancel: token).pdf
        } catch is CancellationError {
            return nil
        } catch {
            sheet.end()
            tell(loc("Couldn't convert {0}", name), (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        }
    }

    /// How a web page was laid out, for the notice: "Letter landscape, narrow margins", as Windows says it.
    private static func describe(_ options: WebPdfOptions) -> String {
        let paper = switch options.paper {
        case .letter: loc("Letter")
        case .a4: "A4" // English: a paper size's name in every language
        case .legal: loc("Legal")
        }
        let margins = switch options.margins {
        case .none: loc("none margins")
        case .narrow: loc("narrow margins")
        case .normal: loc("normal margins")
        case .wide: loc("wide margins")
        }
        return options.landscape ? loc("{0} landscape, {1}", paper, margins) : loc("{0}, {1}", paper, margins)
    }

    private static func confirmInternet(_ name: String, _ converter: (any OfficeConverter)?) -> Bool {
        if Report.skipsDialogs { return testConfirmsInternet ?? false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("{0} came from the internet", name)
        if let converter, converter is MicrosoftOfficeConverter {
            // Word, Excel and PowerPoint open the copy with the person's own settings for macros and links.
            alert.informativeText = loc("macOS marks this file as downloaded from the internet. {0} opens a copy of it with its own settings for macros and links, and a damaged or crafted file could try to run macros or fetch content from elsewhere. Convert it only if you trust where it came from.", converter.appName)
        } else {
            alert.informativeText = loc("macOS marks this file as downloaded from the internet. LibreOffice opens it here with its macros and link updates off, but it is still read by another program, and a damaged or crafted file could try to fetch content from elsewhere. Convert it only if you trust where it came from.")
        }
        alert.addButton(withTitle: loc("Convert Anyway"))
        alert.addButton(withTitle: loc("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func tell(_ title: String, _ text: String) {
        lastMessage = (title, text)
        Report.note("message: \(title): \(text.prefix(200))")
        guard !Report.skipsDialogs else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// File › New PDF from Office File…: always in the menu (Windows hides it without Office), so what is missing gets said.
    static func fromOfficeFile() {
        let installs = installs()
        guard installs.hasAny else {
            tell(loc("No app to convert Office files"), installs.missing(nil))
            return
        }
        let panel = NSOpenPanel()
        panel.title = loc("New PDF from Office File")
        panel.prompt = loc("Create PDF")
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
            await run(title: loc("New PDF from Web Page"), text: WebCaptureRules(source: source).loadingText, pdfName: name,
                      done: loc("Made from {0}. Save it to keep it.", label)) { token, status in
                try await WebCapture.print(source, options: options, status: status, cancel: token)
            }
        }
    }

    private static func askWebPage() -> (URL, WebPdfOptions)? {
        let saved = savedWebOptions()
        let alert = NSAlert()
        alert.messageText = loc("New PDF from Web Page")
        alert.informativeText = loc("The page loads on this Mac with WebKit, from the internet as a browser would, in a private session that keeps no cookies or history. Scripts on a web page run; a saved page runs none. Pop-ups, downloads and permission requests are blocked.")
        alert.addButton(withTitle: loc("Create PDF"))
        alert.addButton(withTitle: loc("Cancel"))
        let address = NSTextField(string: "")
        address.placeholderString = loc("example.com, or a saved page (.html, .mht)")
        address.setAccessibilityLabel(loc("Web address or file"))
        address.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let browse = BrowseButton(title: loc("Browse…"), target: nil, action: nil)
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
        let paper = popup(loc("Paper"), [loc("Letter"), "A4", loc("Legal")], WebPaper.allCases.firstIndex(of: saved.paper) ?? 0)
        let orientation = popup(loc("Orientation"), [loc("Portrait"), loc("Landscape")], saved.landscape ? 1 : 0)
        let marginTitles = [loc("None", context: "margins"), loc("Narrow (0.25 in)"), loc("Normal (0.4 in)"), loc("Wide (1 in)")]
        let margins = popup(loc("Margins"), marginTitles, WebMargins.allCases.firstIndex(of: saved.margins) ?? 2)
        let backgrounds = NSButton(checkboxWithTitle: loc("Background colors and pictures"), target: nil, action: nil)
        backgrounds.state = saved.backgrounds ? .on : .off
        let headers = NSButton(checkboxWithTitle: loc("Header and footer (title, address, date, page numbers)"), target: nil, action: nil)
        headers.state = saved.headerAndFooter ? .on : .off
        let problem = NSTextField(labelWithString: "")
        problem.textColor = .systemRed
        problem.lineBreakMode = .byWordWrapping
        problem.maximumNumberOfLines = 2
        problem.preferredMaxLayoutWidth = 400
        let grid = NSGridView(views: [[NSTextField(labelWithString: loc("Address:")), NSStackView(views: [address, browse])],
                                      [NSTextField(labelWithString: loc("Paper:")), NSStackView(views: [paper, orientation])],
                                      [NSTextField(labelWithString: loc("Margins:")), margins],
                                      [NSGridCell.emptyContentView, backgrounds], [NSGridCell.emptyContentView, headers], [NSGridCell.emptyContentView, problem]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.window.initialFirstResponder = address
        while alert.runModal() == .alertFirstButtonReturn {
            let parsed = WebFiles.parseSource(address.stringValue)
            guard let url = parsed.url else {
                problem.stringValue = parsed.error ?? loc("That isn't a web address.")
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
    /// - Parameter done: the notice once the document is open, worked out then (it can name what converted it).
    private static func run(title: String, text: String, pdfName: String, done: () -> String,
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
            lastNotice = done()
            (document.windowControllers.first as? DocumentWindowController)?.notify(lastNotice)
            return document
        } catch is CancellationError {
            sheet.end()
            lastNotice = loc("Cancelled. Nothing was opened.")
            (NSDocumentController.shared.currentDocument?.windowControllers.first as? DocumentWindowController)?.notify(lastNotice)
            return nil
        } catch {
            sheet.end()
            tell(loc("Couldn't make the PDF"), (error as? PdfEditError)?.message ?? error.localizedDescription)
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
        panel.title = loc("Saved web page")

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
