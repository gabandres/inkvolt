import AppKit
import PdfCore
import UniformTypeIdentifiers

/// What's in This PDF (the Windows app's `InventoryActions`): Tools › What's in This PDF… (also See What's in It… in
/// the Sanitize Document sheet). `DocumentInventory` runs in the background with a progress sheet (Cancel stops it), then
/// one report lists, by section, everything the file carries besides its pages and what it does when opened; addresses
/// reached without a click are marked, an item on a page goes to it. Save Report… writes it as a web page or JSON, Copy
/// Report puts it on the clipboard, Sanitize… (from the menu, when there is something to remove) opens Sanitize
/// Document. Nothing in the file is opened or contacted.
extension DocumentWindowController {
    @objc func whatsInThisPdf(_ sender: Any?) {
        guard pdf.session != nil, redaction.inventorySheet == nil else { return }
        startLongTask { await self.showInventory(on: self.window, offerSanitize: true) }
    }

    /// The report in a sheet over `parent` (the window, or the Sanitize Document sheet); `offerSanitize`: a Sanitize…
    /// button when Sanitize has something to remove.
    func showInventory(on parent: NSWindow?, offerSanitize: Bool) async {
        guard let parent, redaction.inventorySheet == nil, let report = await runInventory(on: parent) else { return }
        let session = pdf.session
        let sheet = InventorySheet(report, fileName: session?.displayName ?? pdf.name, offerSanitize: offerSanitize && !report.counts.isClean,
                                   folder: session?.filePath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) })
        redaction.inventorySheet = sheet
        sheet.done = { [weak self] outcome in
            guard let self else { return }
            self.redaction.inventorySheet = nil
            switch outcome {
            case .close: break
            case .goTo(let page): self.go(page)
            case .sanitize: self.sanitizeDocument(nil)
            }
        }
        if let panel = sheet.window { parent.beginSheet(panel, completionHandler: nil) }
    }

    /// The report with a progress sheet (Cancel stops it); nil when cancelled, failed or the document changed meanwhile.
    func runInventory(on parent: NSWindow) async -> InventoryReport? {
        guard let session = pdf.session else { return nil }
        let data = session.data, password = session.password
        let sheet = ProgressSheet(title: "What's in This PDF", text: "Looking through the file…")
        progressSheet = sheet
        sheet.begin(on: parent)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update("Looking at the pages: step \(done) of \(total)…", Double(done) / Double(max(total, 1))) }
        }
        let result = await Task.detached { () -> Result<InventoryReport, Error> in
            Result { try DocumentInventory.run(data, password, progress: progress, cancel: token) }
        }.value
        switch result {
        case .success(let report):
            guard pdf.session?.data == data else { return nil }
            redaction.lastInventory = report
            return report
        case .failure(is CancellationError):
            return nil
        case .failure(let error):
            pdf.showError("This document couldn't be looked through.", error)
            return nil
        }
    }
}

/// The What's in This PDF sheet: the summary, then each section with its items (what, where, whether it runs without a
/// click, the thing itself, what it calls, and what removes it), the notes, and Save Report…, Copy Report, Close and
/// Sanitize….
@MainActor
final class InventorySheet: NSWindowController {
    enum Outcome { case close, sanitize, goTo(Int) }

    /// Most rows shown per section (Save Report lists them all): a sheet of thousands of rows is slow to lay out.
    static let maxRows = 300

    let report: InventoryReport
    let fileName: String
    let folder: URL?
    let summary: NSTextField
    let sanitizeButton: NSButton?
    /// The section headings shown, in order (the self-test reads them).
    private(set) var headings: [String] = []
    private(set) var rowCount = 0
    var done: ((Outcome) -> Void)?

    init(_ report: InventoryReport, fileName: String, offerSanitize: Bool, folder: URL?) {
        self.report = report
        self.fileName = fileName
        self.folder = folder
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        summary = RedactPatternSheet.wrapped(report.summary + " Nothing in the file was opened or contacted to make this report.")
        summary.preferredMaxLayoutWidth = 680
        sanitizeButton = offerSanitize ? NSButton(title: "Sanitize…", target: nil, action: nil) : nil
        super.init(window: panel)
        let title = NSTextField(labelWithString: "What's in This PDF")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)

        var views: [NSView] = [title, summary]
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        for section in InventorySection.allCases {
            let items = report.items(in: section)
            if items.isEmpty { continue }
            let heading = "\(DocumentInventory.title(section)) (\(items.count))"
            headings.append(heading)
            let h = NSTextField(labelWithString: heading)
            h.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
            h.setAccessibilityRole(.staticText)
            h.setAccessibilityLabel("Heading: \(heading)")
            if list.arrangedSubviews.last != nil { list.setCustomSpacing(16, after: list.arrangedSubviews[list.arrangedSubviews.count - 1]) }
            list.addArrangedSubview(h)
            for i in items.prefix(Self.maxRows) { list.addArrangedSubview(row(i)) }
            rowCount += min(items.count, Self.maxRows)
            if items.count > Self.maxRows {
                list.addArrangedSubview(RedactPatternSheet.caption("… and \(items.count - Self.maxRows) more: Save Report… lists them all."))
            }
        }
        if !list.arrangedSubviews.isEmpty {
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            list.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(list)
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = document
            scroll.setAccessibilityLabel("What the file carries")
            NSLayoutConstraint.activate([
                list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
                list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
                list.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
                list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                scroll.widthAnchor.constraint(equalToConstant: 680),
                scroll.heightAnchor.constraint(equalToConstant: 400),
            ])
            views.append(scroll)
        }
        for note in report.notes {
            let n = RedactPatternSheet.caption(note)
            n.preferredMaxLayoutWidth = 680
            views.append(n)
        }

        let save = NSButton(title: "Save Report…", target: self, action: #selector(saveClicked))
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = sanitizeButton == nil ? "\r" : "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var buttons: [NSView] = [save, copy, spacer, close]
        if let sanitizeButton {
            sanitizeButton.target = self
            sanitizeButton.action = #selector(sanitizeClicked)
            sanitizeButton.keyEquivalent = "\r"
            buttons.append(sanitizeButton)
        }
        let bar = NSStackView(views: buttons)
        views.append(bar)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func row(_ i: InventoryItem) -> NSView {
        let bold = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let plain = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = NSMutableAttributedString(string: i.what, attributes: [.font: bold])
        text.append(NSAttributedString(string: " · \(i.place)", attributes: [.font: plain]))
        if i.withoutClick { text.append(NSAttributedString(string: " · no click needed", attributes: [.font: bold, .foregroundColor: NSColor.systemOrange])) }
        let head = NSTextField(labelWithAttributedString: text)
        head.lineBreakMode = .byWordWrapping
        head.maximumNumberOfLines = 0
        head.preferredMaxLayoutWidth = i.page >= 0 ? 540 : 650
        var top: [NSView] = [head]
        if i.page >= 0 {
            let go = NSButton(title: "Go to page \(i.page + 1)", target: self, action: #selector(goClicked(_:)))
            go.isBordered = false
            go.contentTintColor = .linkColor
            go.tag = i.page
            top.append(go)
        }
        let headLine = NSStackView(views: top)
        headLine.alignment = .firstBaseline
        let found = NSTextField(wrappingLabelWithString: i.detail)
        found.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        found.isSelectable = true
        found.preferredMaxLayoutWidth = 650
        var parts: [NSView] = [headLine, found]
        let caption = Self.caption(i)
        if !caption.isEmpty {
            let c = RedactPatternSheet.caption(caption)
            c.preferredMaxLayoutWidth = 650
            parts.append(c)
        }
        let row = NSStackView(views: parts)
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(i.what), \(i.place)\(i.withoutClick ? ", no click needed" : ""): \(i.detail). \(caption)")
        return row
    }

    static func caption(_ i: InventoryItem) -> String {
        var parts: [String] = []
        if !i.calls.isEmpty { parts.append("It \(i.calls.joined(separator: ", ")).") }
        if i.removedBy != nil || i.section == .earlierVersions {
            parts.append("Sanitize removes it.")
        } else if i.section == .hidden || i.section == .redaction {
            parts.append("Redacting its area removes it.")
        }
        return parts.joined(separator: " ")
    }

    /// The report as text (Copy Report).
    static func text(_ report: InventoryReport, _ fileName: String) -> String {
        var s = "What's in this PDF: \(fileName)\n\(report.summary)\n"
        for section in InventorySection.allCases {
            let items = report.items(in: section)
            if items.isEmpty { continue }
            s += "\n\(DocumentInventory.title(section))\n"
            for i in items {
                s += "- \(i.what) · \(i.place)\(i.withoutClick ? " (no click needed)" : ""): \(i.detail.replacingOccurrences(of: "\n", with: " "))"
                if !i.calls.isEmpty { s += " [it \(i.calls.joined(separator: ", "))]" }
                s += "\n"
            }
        }
        for n in report.notes { s += "\n\(n)\n" }
        return s
    }

    /// Writes the report to `url`: JSON for a .json file, else the web page. False (and nothing written) when it can't be.
    @discardableResult
    func save(to url: URL) -> Bool {
        let text = url.pathExtension.lowercased() == "json"
            ? InventoryReportFiles.json(report, fileName, madeAt: Date())
            : InventoryReportFiles.html(report, fileName, madeAt: Date())
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            guard let panel = window else { return false }
            let alert = NSAlert()
            alert.messageText = "The report couldn't be saved."
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: panel)
            return false
        }
    }

    @objc func saveClicked() {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = (fileName as NSString).deletingPathExtension + " contents"
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ["Web page (HTML)", "JSON"])
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = base + ".html"
        panel.message = "The report is saved on this Mac only; nothing in it is contacted."
        if let folder { panel.directoryURL = folder }
        let chooser = FormatChooser(panel, base)
        format.target = chooser
        format.action = #selector(FormatChooser.changed(_:))
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                _ = chooser // kept alive while the panel is open
                guard response == .OK, let url = panel.url else { return }
                self.save(to: url)
            }
        }
    }

    /// Switches the save panel between the web page and JSON.
    private final class FormatChooser: NSObject {
        let panel: NSSavePanel
        let base: String
        init(_ panel: NSSavePanel, _ base: String) {
            self.panel = panel
            self.base = base
        }

        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            let json = sender.indexOfSelectedItem == 1
            panel.allowedContentTypes = [json ? .json : .html]
            let typed = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (typed.isEmpty ? base : typed) + (json ? ".json" : ".html")
        }
    }

    @objc func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text(report, fileName), forType: .string)
    }

    @objc func goClicked(_ sender: NSButton) { finish(.goTo(sender.tag)) }
    @objc func closeClicked() { finish(.close) }
    @objc func sanitizeClicked() { finish(.sanitize) }

    private func finish(_ outcome: Outcome) {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        let done = done
        self.done = nil
        done?(outcome)
    }
}
