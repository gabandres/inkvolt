import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// The bar over the pages that says what just happened (the Windows app's notifications): a recognition's counts, an
/// export, a form script's message. It goes after a while; VoiceOver reads it out.
@MainActor
final class NoticeBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let undo = NSButton(title: loc("Undo"), target: nil, action: nil)
    private var hideTimer: Timer?
    var onUndo: (() -> Void)?
    /// What it says now (the self-test reads it).
    var message: String { label.stringValue }
    /// Every message shown, oldest first (the self-test reads them).
    private(set) var history: [String] = []

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: loc("Note"))!)
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: loc("Close"))!, target: self, action: #selector(closeClicked))
        close.bezelStyle = .accessoryBarAction
        close.isBordered = false
        undo.bezelStyle = .rounded
        undo.controlSize = .small
        undo.target = self
        undo.action = #selector(undoClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, undo, close])
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(loc("Notice"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        dirtyRect.fill()
    }

    /// `stays`: shown until closed (a document's state, not something that just happened).
    func show(_ text: String, canUndo: Bool = false, stays: Bool = false) {
        label.stringValue = text
        history.append(text)
        undo.isHidden = !canUndo
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTimer?.invalidate()
        if stays { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
    }

    @objc private func closeClicked() { isHidden = true }
    @objc private func undoClicked() {
        isHidden = true
        onUndo?()
    }
}

/// A sheet with a progress bar and Cancel for work that takes a while (text recognition, export). It shows at once,
/// before the first page is done: Vision's first recognition on a Mac loads its model (about 50 s).
@MainActor
final class ProgressSheet: NSWindowController {
    let token = CancelToken()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    let cancelButton = NSButton(title: loc("Cancel"), target: nil, action: nil)
    private(set) var cancelled = false

    init(title: String, text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.stringValue = text
        label.preferredMaxLayoutWidth = 380
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        bar.widthAnchor.constraint(equalToConstant: 380).isActive = true
        bar.setAccessibilityLabel(title)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [heading, label, bar, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var text: String { label.stringValue }
    var isShown: Bool { window?.sheetParent != nil }

    func begin(on parent: NSWindow?) {
        guard let parent, let window else { return }
        parent.beginSheet(window)
    }

    /// `fraction` nil keeps the bar moving without an amount.
    func update(_ text: String, _ fraction: Double?) {
        label.stringValue = text
        if let fraction {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = fraction
        }
    }

    @objc func cancelClicked() {
        cancelled = true
        token.cancel()
        label.stringValue = loc("Cancelling…")
        cancelButton.isEnabled = false
    }

    /// No window to hang the sheet on (none open, or one already showing a sheet): a panel of its own, in the middle of
    /// the screen, above the app's windows.
    func showAlone() {
        guard let window else { return }
        window.level = .modalPanel
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func end() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
}

// MARK: Recognize Text and Export

/// Recognize Text's choices (its language, Straighten and clean, List the words to check) for the recognition that runs
/// outside it: Batch (the window, watched folders, the command line) and export, as Windows' `PageOcr.Recognize` with
/// suspect words. Vision in the chosen language, through `ScanText`, with the Mac's dictionary for suspect words.
@MainActor
enum SavedOcr {
    /// The language chosen (nil: Vision finds out for itself), kept with the text layer.
    static var language: String? { AppSettings.ocrLanguage.isEmpty ? nil : AppSettings.ocrLanguage }

    static func recognizer() -> Recognizer {
        let reader = VisionRecognizer(languages: language.map { [$0] })
        let options = RecognizeOptions(clean: AppSettings.ocrClean, checkWords: AppSettings.ocrSuspects)
        return PageOcr.recognizer(reader, options: options, spelling: options.checkWords ? MacSpelling(language: reader.language) : nil)
    }

    /// A batch's host: the recognizer and its language, and the password prompt when someone is there to answer.
    static func batchHost(askPassword: (@Sendable (BatchPasswordRequest, CancelToken?) async -> String?)? = nil) -> BatchHost {
        BatchHost(askPassword: askPassword, recognize: recognizer(), recognizeLanguage: language)
    }
}

/// Runs a closure when a checkbox changes (the Recognize Text dialog's Clean, which enables Replace the scans).
@MainActor
final class CheckToggle: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}

extension DocumentWindowController {
    /// A page choice for a dialog: all, the current page, or a range typed in.
    func pageChoice(allTitle: String) -> (view: NSView, read: () -> (pages: [Int]?, error: String?)) {
        let count = engine.pageCount, current = pages.currentPage
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [allTitle, loc("Current page ({0})", CoreLanguage.number(current + 1)), loc("Page range")])
        popup.setAccessibleName(loc("Pages"))
        let range = NSTextField(string: "\(current + 1)")
        range.placeholderString = loc("e.g. 1-3, 5")
        range.setAccessibleName(loc("Page range"))
        range.widthAnchor.constraint(equalToConstant: 120).isActive = true
        // The range box only when a range is chosen (it showed "1" beside "All pages"; UX review, round 2).
        range.isHidden = true
        _ = ControlAction(popup) {
            range.isHidden = popup.indexOfSelectedItem != 2
            if !range.isHidden { range.window?.makeFirstResponder(range) }
        }
        let stack = NSStackView(views: [popup, range])
        stack.alignment = .firstBaseline
        stack.detachesHiddenViews = false
        return (stack, {
            switch popup.indexOfSelectedItem {
            case 0: return (Array(0..<count), nil)
            case 1: return ([current], nil)
            default:
                let parsed = PageRange.tryParse(range.stringValue, count)
                return parsed.ok ? (parsed.pages, nil) : (nil, parsed.error ?? loc("That page range isn't valid."))
            }
        })
    }

    /// Tools › Recognize Text (OCR)…: which pages, the language, cleaning and suspect words, then the recognition (one
    /// undo step), as the Windows dialog asks.
    @objc func recognizeText(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Recognize Text (OCR)")
        alert.informativeText = loc("Finds the words on scanned pages, so you can search, select and copy them. It runs on this Mac; check important text.")
        let choice = pageChoice(allTitle: loc("All pages without text"))
        let languages = Self.ocrLanguages()
        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        language.addItems(withTitles: [loc("Detect the language")] + languages.map(\.name))
        language.selectItem(at: (languages.firstIndex { $0.tag == AppSettings.ocrLanguage }).map { $0 + 1 } ?? 0)
        language.setAccessibilityLabel(loc("Language"))
        language.toolTip = loc("The language of the text. Vision detects it when you don't choose one.")
        let clean = NSButton(checkboxWithTitle: loc("Straighten and clean the pages first"), target: nil, action: nil)
        clean.state = AppSettings.ocrClean ? .on : .off
        clean.toolTip = loc("Straightens pages up to 15°, turns sideways and upside-down pages upright, removes specks and evens out grey paper before recognizing.")
        let suspects = NSButton(checkboxWithTitle: loc("List the words to check"), target: nil, action: nil)
        suspects.state = AppSettings.ocrSuspects ? .on : .off
        suspects.toolTip = loc("Words the dictionary doesn't know, letters and digits mixed, odd characters, or words read differently before cleaning. Tools › Review Suspect Words lists them.")
        let replace = NSButton(checkboxWithTitle: loc("Keep the cleaned pages (instead of the scans)"), target: nil, action: nil)
        replace.state = .off
        replace.isEnabled = clean.state == .on
        replace.toolTip = loc("The pages then look straightened and cleaned, and upside-down or sideways pages are turned upright. Undo puts the scans back until you save.")
        let toggle = CheckToggle {
            replace.isEnabled = clean.state == .on
            if clean.state == .off { replace.state = .off }
        }
        clean.target = toggle
        clean.action = #selector(CheckToggle.changed)
        let form = SheetForm("RecognizeText")
        form.row(loc("Pages"), choice.view)
        form.row(loc("Language"), language)
        form.note(loc("Pages that already have text are skipped."))
        form.row(nil, clean, advanced: true)
        form.note(loc("Turns pages upright, straightens them (up to 15°) and removes specks and grey paper before reading."), advanced: true)
        form.row(nil, replace, advanced: true)
        form.row(nil, suspects, advanced: true)
        form.note(loc("Words it wasn't sure of are listed in Tools › Review Suspect Words."), advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Recognize"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(toggle) {}
                guard response == .alertFirstButtonReturn else { return }
                let read = choice.read()
                guard let chosen = read.pages, !chosen.isEmpty else {
                    self.pdf.showError(read.error ?? loc("No pages chosen."), nil)
                    return
                }
                let index = language.indexOfSelectedItem
                AppSettings.ocrLanguage = index > 0 && index <= languages.count ? languages[index - 1].tag : ""
                AppSettings.ocrClean = clean.state == .on
                AppSettings.ocrSuspects = suspects.state == .on
                let options = RecognizeOptions(clean: clean.state == .on, checkWords: suspects.state == .on,
                                               keepCleanedImage: clean.state == .on && replace.state == .on)
                // The alert's sheet is still closing: start once it's gone.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.startLongTask { await self.runRecognize(pages: chosen, options: options) } }
                }
            }
        }
    }

    /// The languages Vision reads, by name, for the dialog.
    static func ocrLanguages() -> [(tag: String, name: String)] {
        VisionRecognizer.supportedLanguages.map { tag in (tag, Locale.current.localizedString(forIdentifier: tag) ?? tag) }
    }

    /// Runs Recognize Text on `pages` with the progress sheet; what it did comes back (nil outcome: not started). With
    /// `recognizer` (a stand-in's): the pages as rendered, as before roadmap 2.2. Without: roadmap 2.2's
    /// pipeline with `options` (the saved choices when nil), `ocr` (Vision in the chosen language when nil) and the Mac's
    /// dictionary for suspect words.
    @discardableResult
    func runRecognize(pages chosen: [Int], recognizer: Recognizer? = nil, options: RecognizeOptions? = nil,
                      ocr: (any TextRecognizer)? = nil, spelling: (any Spelling)? = nil) async -> (outcome: EditOutcome?, report: RecognizeTextReport?) {
        let sheet = ProgressSheet(title: loc("Recognizing text"),
                                  text: loc("Starting text recognition… The first time on this Mac, macOS loads it, which can take about a minute."))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain {
                guard done < total else { return sheet.update(loc("Adding the text layer…"), 1) }
                sheet.update(loc("{0}: page {1} of {2}…", loc("Recognizing text"), CoreLanguage.number(done + 1), CoreLanguage.number(total)), Double(done) / Double(max(total, 1)))
            }
        }
        let outcome: EditOutcome?, report: RecognizeTextReport?
        if let recognizer {
            (outcome, report) = await editor.recognizeText(pages: chosen, recognizer: recognizer, cancel: sheet.token, progress: progress)
        } else {
            let options = options ?? RecognizeOptions(clean: AppSettings.ocrClean, checkWords: AppSettings.ocrSuspects)
            let language = AppSettings.ocrLanguage
            let reader: any TextRecognizer = ocr ?? VisionRecognizer(languages: language.isEmpty ? nil : [language])
            let dictionary: (any Spelling)? = options.checkWords ? (spelling ?? MacSpelling(language: reader.language)) : nil
            (outcome, report) = await editor.recognizeText(pages: chosen, ocr: reader, options: options, spelling: dictionary,
                                                           cancel: sheet.token, progress: progress)
        }
        // Pages the engine refused (too long to read, too large to draw) were left out: said after the rest.
        let skipped = SkippedPages.note(report?.skipped ?? []).map { " " + $0 } ?? ""
        switch outcome {
        case .done?:
            let words = report?.words ?? 0, hadText = report?.hadText ?? 0, pagesWithWords = report?.pagesWithWords ?? 0
            let suspect = report?.suspect ?? 0, replaced = report?.replaced ?? 0
            let cleaned = (replaced == 0 ? ""
                : " " + (replaced == 1 ? loc("{0} page was replaced with the cleaned image.", CoreLanguage.number(replaced)) : loc("{0} pages were replaced with the cleaned images.", CoreLanguage.number(replaced))))
                + skipped
            let recognized = words == 1 ? loc("Recognized {0} word on {1} page", CoreLanguage.number(words), CoreLanguage.number(pagesWithWords))
                : pagesWithWords == 1 ? loc("Recognized {1} words on {0} page", CoreLanguage.number(pagesWithWords), CoreLanguage.number(words))
                : loc("Recognized {1} words on {0} pages", CoreLanguage.number(pagesWithWords), CoreLanguage.number(words))
            if words == 0 {
                notify(loc("No text was recognized on these pages.") + cleaned, canUndo: true)
            } else if suspect > 0 {
                let found = suspect == 1 ? loc("{0}; {1} suspect word to check in the sidebar's Suspect Words.", recognized, CoreLanguage.number(suspect))
                    : loc("{0}; {1} suspect words to check in the sidebar's Suspect Words.", recognized, CoreLanguage.number(suspect))
                notify(found + cleaned, canUndo: true)
                reviewSuspectWords(nil)
            } else {
                let done = hadText > 0 ? loc("{0} ({1} already had text). They can be searched and selected now.", recognized, CoreLanguage.number(hadText))
                    : loc("{0}. They can be searched and selected now.", recognized)
                notify(done + cleaned, canUndo: true)
            }
        case .noChange?:
            let had = report?.hadText ?? 0
            let said = had == chosen.count ? (chosen.count == 1 ? loc("This page already has text: nothing to recognize.")
                                                                 : loc("These pages already have text: nothing to recognize."))
                                           : loc("No text was recognized on these pages.")
            notify(said + skipped)
        case .declined?:
            notify(loc("Text recognition cancelled. Nothing was changed."))
        default:
            break
        }
        return (outcome, report)
    }

    /// File › Export To (Word, Excel, plain text, PowerPoint, HTML): the pages and options, the file, then the export with
    /// progress.
    @objc func exportWord(_ sender: Any?) { askExport(.word) }
    @objc func exportExcel(_ sender: Any?) { askExport(.excel) }
    @objc func exportText(_ sender: Any?) { askExport(.text) }
    @objc func exportPowerPoint(_ sender: Any?) { askExport(.powerPoint) }
    @objc func exportHtml(_ sender: Any?) { askExport(.html) }

    static func exportTitle(_ format: ExportFormat) -> String {
        switch format {
        case .word: loc("Export to Word")
        case .excel: loc("Export Tables to Excel")
        case .text: loc("Export as Plain Text")
        case .powerPoint: loc("Export to PowerPoint")
        case .html: loc("Export to HTML")
        }
    }

    private static func exportNote(_ format: ExportFormat) -> String {
        switch format {
        case .word: loc("An editable Word document: paragraphs, headings, lists, tables and pictures. Complex layouts may need tidying.")
        case .excel: loc("Each table becomes a sheet, named after its page. Numbers stay numbers.")
        case .text: loc("The text in reading order, one paragraph per line (UTF-8).")
        case .powerPoint: loc("One slide per page, with editable text boxes, tables and pictures.")
        case .html: loc("A web page that fits any screen, in reading order. The pages' look isn't kept.")
        }
    }

    private func askExport(_ format: ExportFormat) {
        guard let window, let session = pdf.session else { return }
        let alert = NSAlert()
        alert.messageText = Self.exportTitle(format)
        alert.informativeText = Self.exportNote(format)
        let choice = pageChoice(allTitle: loc("All pages"))
        let ocr = NSButton(checkboxWithTitle: loc("Read the text of scanned pages too"), target: nil, action: nil)
        ocr.state = UserDefaults.standard.object(forKey: "ExportOcr") as? Bool == false ? .off : .on
        let open = NSButton(checkboxWithTitle: loc("Open the file when done"), target: nil, action: nil)
        open.state = UserDefaults.standard.bool(forKey: "ExportOpen") ? .on : .off
        let form = SheetForm("Export")
        form.row(loc("Pages"), choice.view)
        form.row(nil, ocr)
        form.row(nil, open)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Export…"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let read = choice.read()
                guard let chosen = read.pages, !chosen.isEmpty else {
                    self.pdf.showError(read.error ?? loc("No pages chosen."), nil)
                    return
                }
                UserDefaults.standard.set(ocr.state == .on, forKey: "ExportOcr")
                UserDefaults.standard.set(open.state == .on, forKey: "ExportOpen")
                if session.openPassword != nil && !self.confirmUnprotected() { return }
                let panel = NSSavePanel()
                let name = (session.displayName as NSString).deletingPathExtension
                panel.nameFieldStringValue = name + DocumentExport.fileExtension(format)
                if let type = UTType(filenameExtension: String(DocumentExport.fileExtension(format).dropFirst())) { panel.allowedContentTypes = [type] }
                if let path = session.filePath { panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        panel.beginSheetModal(for: window) { r in
                            MainActor.assumeIsolated {
                                guard r == .OK, let url = panel.url else { return }
                                let opens = open.state == .on, recognize = ocr.state == .on
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        self.startLongTask {
                                            if let report = await self.runExport(format, to: url, pages: chosen, recognize: recognize), report.saved, opens {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func confirmUnprotected() -> Bool {
        let alert = NSAlert()
        alert.messageText = loc("The exported file is saved without its password protection: anyone can open it.")
        alert.addButton(withTitle: loc("Export Anyway"))
        alert.addButton(withTitle: loc("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The engine an export reads: the document with `layers` shown or hidden as in the Layers pane (none: as it is).
    nonisolated static func exportEngine(_ data: [UInt8], _ password: String?, _ layers: [Int: Bool]) throws -> PdfEngine {
        if layers.isEmpty { return try PdfEngine.open(data, password: password) }
        return try PdfEngine.open(try Layers.withVisibility(data, password, layers))
    }

    /// The layers shown differently from the document's default (by the Layers pane), by object number; empty: none.
    var shownLayerVisibility: [Int: Bool] {
        Dictionary(layerList.compactMap { l in layerChoice[l.name].map { (l.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Exports `pages` to `url` with the progress sheet (from a copy of the document's bytes, so edits meanwhile don't
    /// matter); the report, or nil when cancelled or failed (said in the notice bar or an alert).
    @discardableResult
    func runExport(_ format: ExportFormat, to url: URL, pages chosen: [Int], recognize: Bool, recognizer: Recognizer? = nil) async -> ExportReport? {
        guard let session = pdf.session else { return nil }
        let title = Self.exportTitle(format)
        let sheet = ProgressSheet(title: title, text: loc("Reading the pages…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let data = session.data, password = session.password
        let name = (session.displayName as NSString).deletingPathExtension
        let recognizeWith: Recognizer? = recognize ? (recognizer ?? SavedOcr.recognizer()) : nil
        // PowerPoint and HTML read the language and alternate text from the PDF itself; the others have no use for its bytes.
        let source = format == .powerPoint || format == .html ? data : nil
        let options = ExportOptions(pages: chosen, title: name, recognize: recognizeWith, source: source, sourcePassword: password) { at in
            let text: String
            switch at.stage {
            case .reading: text = loc("Reading page {0} ({1} of {2})…", CoreLanguage.number(at.page + 1), CoreLanguage.number(at.index + 1), CoreLanguage.number(at.count))
            case .recognizing: text = loc("Recognizing text on page {0} ({1} of {2})… The first time, macOS loads text recognition (about a minute).", CoreLanguage.number(at.page + 1), CoreLanguage.number(at.index + 1), CoreLanguage.number(at.count))
            case .writing: text = loc("Writing the file…")
            }
            let fraction = at.fraction
            onMain { sheet.update(text, fraction) }
        }
        let token = sheet.token
        let path = url.path
        // What is shown: the layers chosen in the Layers pane, as Windows exports from its view engine.
        let layers = shownLayerVisibility
        let result: Result<ExportReport, Error> = await Task.detached {
            do {
                let engine = try Self.exportEngine(data, password, layers)
                defer { engine.close() }
                return .success(try DocumentExport.exportToFile(engine, format, path, options: options, cancel: token))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let report):
            lastExport = report
            if !report.saved {
                var why = ""
                if report.noText > 0 {
                    let none = report.noText == chosen.count ? (chosen.count == 1 ? loc("The page has no text") : loc("None of the pages has text"))
                        : report.noText == 1 ? loc("{0} page had no text", 1) : loc("{0} pages had no text", CoreLanguage.number(report.noText))
                    let reason = !recognize ? loc("{0}: turn on \"Recognize text on scanned pages\" to read scans.", none)
                        : report.recognitionFailed.isEmpty ? loc("{0}, even after text recognition.", none)
                        : loc("{0}; text recognition failed on some of them.", none)
                    why = " " + reason
                }
                let one = chosen.count == 1
                if format == .excel {
                    notify((one ? loc("No tables were found on this page, so no workbook was saved.") : loc("No tables were found on these pages, so no workbook was saved.")) + why)
                } else {
                    notify((one ? loc("Nothing could be extracted from this page, so no file was saved.") : loc("Nothing could be extracted from these pages, so no file was saved.")) + why)
                }
                return report
            }
            var notes: [String] = []
            if format == .excel { notes.append(report.tables == 1 ? loc("1 table") : loc("{0} tables", CoreLanguage.number(report.tables))) }
            if report.recognized > 0 {
                notes.append(report.recognized == 1 ? loc("{0} page recognized with OCR", 1) : loc("{0} pages recognized with OCR", CoreLanguage.number(report.recognized)))
            }
            if report.noText > 0 { notes.append(report.noText == 1 ? loc("{0} page without text", 1) : loc("{0} pages without text", CoreLanguage.number(report.noText))) }
            if report.suspectWords > 0 {
                notes.append(report.suspectWords == 1 ? loc("1 suspect word (check it against the PDF)") : loc("{0} suspect words (check them against the PDF)", CoreLanguage.number(report.suspectWords)))
            }
            let failed = report.recognitionFailed.count, unreadable = report.unreadable.count
            if failed > 0 { notes.append(failed == 1 ? loc("text recognition failed on {0} page", 1) : loc("text recognition failed on {0} pages", CoreLanguage.number(failed))) }
            if unreadable > 0 { notes.append(unreadable == 1 ? loc("{0} page couldn't be read", 1) : loc("{0} pages couldn't be read", CoreLanguage.number(unreadable))) }
            let file = url.lastPathComponent, count = chosen.count
            if notes.isEmpty {
                notify(count == 1 ? loc("Exported {0} page to {1}.", CoreLanguage.number(count), file) : loc("Exported {0} pages to {1}.", CoreLanguage.number(count), file))
            } else {
                let list = notes.joined(separator: ", ")
                notify(count == 1 ? loc("Exported {0} page to {1} ({2}).", CoreLanguage.number(count), file, list) : loc("Exported {0} pages to {1} ({2}).", CoreLanguage.number(count), file, list))
            }
            return report
        case .failure(let error):
            lastExport = nil
            if error is CancellationError {
                notify(loc("Export cancelled. Nothing was saved."))
            } else {
                pdf.showError(loc("“{0}” didn't work.", title), error)
            }

            return nil
        }
    }
}
