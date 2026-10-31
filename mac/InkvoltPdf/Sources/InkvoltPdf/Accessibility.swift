import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Tools › Accessibility Check… (the Windows app's Review › Accessibility Check…): the PDF/UA-1 machine checks
/// (`AccessibilityCheck`) run in the background with a progress sheet (Cancel stops it), then the sidebar's Accessibility
/// pane lists what fails (choosing one goes there and outlines it), keeps the person's checklist, and saves the report as a
/// web page (`AccessibilityReportHtml`). The pane's segment appears with the first check, as Windows' rail button does.
extension DocumentWindowController {
    @objc func checkAccessibility(_ sender: Any?) {
        guard pdf.session != nil else { return }
        startLongTask { await self.runAccessibilityCheck() }
    }

    /// Runs the check and shows the pane; false when it didn't run or the document changed meanwhile.
    @discardableResult
    func runAccessibilityCheck() async -> Bool {
        guard let session = pdf.session, let window else { return false }
        let data = session.data, password = session.password
        let sheet = ProgressSheet(title: "Accessibility Check", text: "Reading the tags…")
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update("Checking page \(done) of \(total)…", Double(done) / Double(max(total, 1))) }
        }
        let result = await Task.detached { () -> Result<AccessibilityReport, Error> in
            Result { try AccessibilityCheck.run(data, password, progress: progress, cancel: token) }
        }.value
        switch result {
        case .success(let report):
            guard pdf.session?.data == data else { return false }
            showAccessibility(report)
            return true
        case .failure(is CancellationError):
            return false
        case .failure(let error):
            pdf.showError("The accessibility check couldn't run.", error)
            return false
        }
    }

    private func showAccessibility(_ report: AccessibilityReport) {
        let pane = sidebar.accessibility
        pane.onGo = { [weak self] finding in self?.goToFinding(finding) }
        pane.onCheckAgain = { [weak self] in self?.checkAccessibility(nil) }
        pane.onSave = { [weak self] in self?.saveAccessibilityReport() }
        pane.show(report, checkedAt: Date())
        showAccessibilityPane()
        // Keyboard and VoiceOver users land on the result.
        window?.makeFirstResponder(pane.landingControl)
        NSAccessibility.post(element: window as Any, notification: .announcementRequested,
                             userInfo: [.announcement: report.summary, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Scrolls to the page and outlines the element (a document-wide finding has no place).
    func goToFinding(_ f: AccessibilityFinding) {
        guard f.page >= 0 && f.page < pages.pageRects.count else { return }
        if f.box.isEmpty {
            go(f.page)
        } else {
            go(f.page, targetY: f.box.y)
            pages.flash(f.page, f.box)
        }
    }

    private func saveAccessibilityReport() {
        guard let window, sidebar.accessibility.report != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = AccessibilityReportHtml.fileName(for: pdf.session?.displayName ?? pdf.name)
        panel.message = "The report is saved on this Mac only."
        if let path = pdf.session?.filePath { panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.writeAccessibilityReport(to: url)
            }
        }
    }

    /// Writes the report with the checklist's ticks; the pane then offers to open it.
    @discardableResult
    func writeAccessibilityReport(to url: URL) -> Bool {
        let pane = sidebar.accessibility
        guard let report = pane.report else { return false }
        let html = AccessibilityReportHtml.write(report, pdf.session?.displayName ?? pdf.name, checkedAt: pane.checkedAt, done: pane.done)
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            pane.saved = url
            notify("Report saved: \(url.lastPathComponent)")
            return true
        } catch {
            pdf.showError("The report couldn't be saved.", error)
            return false
        }
    }
}

/// The sidebar's Accessibility pane: the result, Check Again and Save Report…, then what fails (each with its condition,
/// place, what is wrong and what fixes it) or the checklist for a person. Ticks last as long as the document is open and go
/// into the saved report.
@MainActor
final class AccessibilityPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["Fails", "Checklist"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let none = NSTextField(wrappingLabelWithString: "Nothing fails the machine checks. A document is accessible once a person has also made the checks under Checklist.")
    private let checklistScroll = NSScrollView()
    private let checklist = NSStackView()
    private let againButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Report…", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Report", target: nil, action: nil)
    private var following = false

    private(set) var report: AccessibilityReport?
    private(set) var checkedAt = Date()
    /// The person's checks ticked (`HumanCheck.id`).
    private(set) var done = Set<String>()
    private var boxes: [String: NSButton] = [:]
    /// The report saved last, which Open Report opens.
    var saved: URL? {
        didSet { openButton.isHidden = saved == nil }
    }

    var onGo: ((AccessibilityFinding) -> Void)?
    var onCheckAgain: (() -> Void)?
    var onSave: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.isSelectable = true
        none.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        none.textColor = .secondaryLabelColor
        none.isHidden = true

        for (button, tip) in [(againButton, "Check the document as it is now"), (saveButton, "Save the report, with your checklist, as a web page"), (openButton, "Open the report you saved")] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.bezelStyle = .rounded
            button.toolTip = tip
            button.target = self
        }
        againButton.action = #selector(againClicked)
        saveButton.action = #selector(saveClicked)
        openButton.action = #selector(openClicked)
        openButton.isHidden = true
        let buttons = NSStackView(views: [againButton, saveButton, openButton])
        buttons.spacing = 6
        buttons.distribution = .gravityAreas
        buttons.alignment = .centerY

        tabs.target = self
        tabs.action = #selector(tabChosen)
        tabs.selectedSegment = 0
        tabs.controlSize = .small
        tabs.setAccessibilityLabel("Accessibility pane shows")

        let column = NSTableColumn(identifier: .init("finding"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("What fails")
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        checklist.orientation = .vertical
        checklist.alignment = .leading
        checklist.spacing = 10
        checklist.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 10, right: 2)
        checklist.translatesAutoresizingMaskIntoConstraints = false
        let flipped = PaneFlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(checklist)
        checklistScroll.documentView = flipped
        checklistScroll.hasVerticalScroller = true
        checklistScroll.drawsBackground = false
        checklistScroll.isHidden = true
        let intro = NSTextField(wrappingLabelWithString: "The machine can't judge these. Tick each once you've checked it; the saved report says which are done.")
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor
        intro.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checklist.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: checklist.widthAnchor, constant: -4).isActive = true
        for check in AccessibilityCheck.humanChecks { addCheck(check) }

        let stack = NSStackView(views: [summaryLabel, buttons, tabs, none, tableScroll, checklistScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: checklistScroll.contentView.widthAnchor),
            checklist.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), checklist.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            checklist.topAnchor.constraint(equalTo: flipped.topAnchor), checklist.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ]
        // Everything in the stack is as wide as the pane (less its margins); wrapping labels then know their width.
        for v in [summaryLabel, none, tableScroll, checklistScroll, buttons, tabs] as [NSView] {
            constraints.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(constraints)
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        checklistScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func addCheck(_ check: HumanCheck) {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked))
        box.identifier = .init(check.id)
        box.setAccessibilityLabel(check.question)
        box.setAccessibilityHelp(check.how)
        boxes[check.id] = box
        let question = NSTextField(wrappingLabelWithString: check.question)
        question.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let how = NSTextField(wrappingLabelWithString: check.how)
        how.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        how.textColor = .secondaryLabelColor
        let words = NSStackView(views: [question, how])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let row = NSStackView(views: [box, words])
        row.alignment = .top
        row.spacing = 4
        checklist.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: checklist.widthAnchor, constant: -4).isActive = true
        question.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        how.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// What the keyboard lands on after a check: the first failure, else Check Again.
    var landingControl: NSView { (report?.passed ?? true) ? againButton : table }

    func show(_ report: AccessibilityReport, checkedAt: Date) {
        self.report = report
        self.checkedAt = checkedAt
        summaryLabel.stringValue = report.paneSummary
        tabs.setLabel(report.failuresTabTitle, forSegment: 0)
        tabs.selectedSegment = report.passed ? 1 : 0
        following = true
        table.reloadData()
        table.deselectAll(nil)
        following = false
        tabChosen()
    }

    // MARK: The self-test's hands

    var shownFailures: Int { table.numberOfRows }
    var showsChecklist: Bool { tabs.selectedSegment == 1 }
    var summary: String { summaryLabel.stringValue }
    var failuresTitle: String { tabs.label(forSegment: 0) ?? "" }

    func showTab(_ index: Int) {
        tabs.selectedSegment = index
        tabChosen()
    }

    func choose(row: Int) { table.selectRowIndexes([row], byExtendingSelection: false) }

    func tick(_ id: String) { boxes[id]?.performClick(nil) }

    func press(again: Bool) { (again ? againButton : saveButton).performClick(nil) }

    // MARK: Actions

    @objc private func tabChosen() {
        let list = tabs.selectedSegment == 0
        let passed = report?.passed ?? false
        none.isHidden = !list || !passed
        tableScroll.isHidden = !list || passed
        checklistScroll.isHidden = list
    }

    @objc private func ticked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { done.insert(id) } else { done.remove(id) }
    }

    @objc private func againClicked() { onCheckAgain?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func openClicked() { if let saved { NSWorkspace.shared.open(saved) } }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { report?.failures.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let f = report?.failures[row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("finding")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FindingCell ?? {
            let made = FindingCell()
            made.identifier = id
            return made
        }()
        cell.show(f)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !following, let failures = report?.failures, table.selectedRow >= 0, table.selectedRow < failures.count else { return }
        onGo?(failures[table.selectedRow])
    }
}

/// The checklist's document view: from the top down.
private final class PaneFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One failure in the Accessibility pane: its condition, place and element; what is wrong; what fixes it.
@MainActor
private final class FindingCell: NSTableCellView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let fix = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fix.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fix.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, problem, fix])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for label in [title, problem, fix] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ f: AccessibilityFinding) {
        title.stringValue = f.rowTitle
        problem.stringValue = f.rowProblem
        fix.stringValue = f.rowFix
        setAccessibilityLabel(f.spoken)
    }
}
