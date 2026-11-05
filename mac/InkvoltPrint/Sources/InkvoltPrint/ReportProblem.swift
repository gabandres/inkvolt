import AppKit
import PrintCore
import PrintMac

/// Help › Report a Problem… (Windows' `ReportProblemDialog` and `AppHelp.Report`; Inkvolt PDF for Mac's window of the same
/// name): the details a report needs, scrubbed (`ProblemReport`, `Diagnostics.scrub`), shown first and editable, then
/// copied for the user to paste into a GitHub issue. Record This Printer records the printer shown (`ReportRecording`,
/// as `record`): a .zip in the app's Recordings folder, which the user reads and attaches by hand. Nothing is sent.
/// Closing the window stops a recording under way, and it leaves nothing behind. The Mac app keeps no log.
@MainActor
final class ReportProblemWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ReportProblemWindowController?
    static let repository = "https://github.com/gabandres/inkvolt"

    let details = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "")
    let recordNote = NSTextField(wrappingLabelWithString: "")
    let recordButton = NSButton(title: "Record This Printer", target: nil, action: nil)
    let showButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    /// The issue address Copy and Open a GitHub Issue last opened (`--report` reads it instead of a browser opening).
    private(set) var openedIssue: URL?
    /// The last recording's .zip.
    private(set) var recording: URL?
    private var printer: PrinterModel?
    private var model: AppModel?
    private var recordingTask: Task<Void, Never>?

    @discardableResult
    static func show(_ model: AppModel) -> ReportProblemWindowController {
        let controller = shared ?? ReportProblemWindowController()
        shared = controller
        controller.load(model)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return controller
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The report (Windows' `AppHelp.Report`, the settings the Mac has): the version, macOS, the printers and a few settings,
    /// scrubbed. No log: the Mac app keeps none. Not "(Store package)": every copy of Print for Mac is the App Store's (a
    /// receipt check would need StoreKit for one word).
    static func report(_ model: AppModel) -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        let remembered = model.store.current.printers.map { $0.model ?? "unknown model" }
        let pdf = InkvoltPdfApp.url == nil ? "not installed" : "installed, open scans \(onOff(InkvoltPdfApp.openScans))"
        let s = model.settings
        let settings: [(name: String, value: String)] = [
            ("Printers remembered", remembered.isEmpty ? "none" : "\(remembered.count): \(remembered.joined(separator: ", "))"),
            ("Printers listed now", "\(model.printers.count)"),
            ("macOS queues", model.destinations.map { "\($0.filter(CupsQueues.isRealQueue).count)" } ?? "not read"),
            ("Local Network", "\(model.localNetwork)"),
            ("Scan presets", "\(model.presets.count)"),
            ("Inkvolt PDF", pdf),
            ("Menu bar", s.menuBar ? "on, alerts \(onOff(s.alerts)), offline alerts \(onOff(s.offlineAlerts))" : "off"),
            ("Demo", onOff(model.isDemo)),
            ("Inkvolt Pro", Pro.licence != nil ? "licensed" : Pro.problem != nil ? "key not accepted" : "none"),
        ]
        let who = Diagnostics.Identity.current
        return ProblemReport.report(app: "Inkvolt Print", version: version, system: system, architecture: architecture,
                                    packaged: false, settings: settings, logTail: [], scrub: { Diagnostics.scrub($0, who) })
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Report a Problem"
        window.isRestorable = false
        window.isReleasedWhenClosed = false // shown again by the next Report a Problem…
        window.minSize = NSSize(width: 520, height: 460)
        super.init(window: window)
        window.delegate = self
        let intro = NSTextField(wrappingLabelWithString: "These details help find the problem: the version, macOS and a few settings. "
            + "IP addresses, printer IDs and serial numbers, file paths and your names are masked. Nothing is sent: copy them, "
            + "then paste them into a GitHub issue or an e-mail. Delete anything you'd rather not share.")
        intro.preferredMaxLayoutWidth = 640
        details.isEditable = true // the user may delete what they'd rather not share before copying
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.setAccessibilityLabel("Details to report")
        details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        status.preferredMaxLayoutWidth = 640

        recordNote.textColor = .secondaryLabelColor
        recordNote.preferredMaxLayoutWidth = 460
        recordNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.toolTip = "Asks the printer shown for everything Inkvolt Print reads from it, read only, and saves the replies "
            + "with what identifies it taken out"
        showButton.target = self
        showButton.action = #selector(showClicked)
        showButton.isHidden = true
        let recordButtons = NSStackView(views: [recordButton, showButton])
        recordButtons.orientation = .vertical
        recordButtons.alignment = .trailing
        let recordRow = NSStackView(views: [recordNote, recordButtons])
        recordRow.alignment = .top
        recordRow.spacing = 16

        let issue = NSButton(title: "Copy and Open a GitHub Issue", target: self, action: #selector(issueClicked))
        issue.toolTip = "Copies the details, then opens a new issue on GitHub in your browser to paste them in"
        issue.keyEquivalent = "\r"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [issue, copy, spacer, close])

        let stack = NSStackView(views: [intro, scroll, status, recordRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        for v in [scroll, recordRow, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        window.contentView = stack
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The details again and the printer shown (the selected one), as each opening of Windows' dialog. A recording under way
    /// is kept, with the window as it is: Windows' dialog is modal, so it can't be opened again while it records.
    func load(_ model: AppModel) {
        guard recordingTask == nil else { return }
        self.model = model
        printer = model.printers.first { $0.id == model.selectedID }
        details.string = Self.report(model)
        say(nil)
        showButton.isHidden = true
        recording = nil
        recordButton.isEnabled = printer?.recordHost != nil
        recordNote.stringValue = Self.recordNote(printer)
    }

    static func recordNote(_ printer: PrinterModel?) -> String {
        guard let printer else { return "To record a printer, show it first and come back here." }
        guard printer.recordHost != nil else { return "\(printer.name) has no network address, so there's nothing to record." }
        return "Also useful: record \(printer.name). Every reply Inkvolt Print reads from it, read only, with serial numbers, addresses "
            + "and names taken out, saved as a .zip file for you to read and attach. It can take a minute or two."
    }

    private func say(_ text: String?) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
    }

    @objc func recordClicked() {
        guard printer?.recordHost != nil, model != nil else { return }
        recordingTask?.cancel()
        recordingTask = Task { await record() }
    }

    /// Records the printer shown; `--report`'s `--problem-record` waits for it. Never throws: what went wrong is said here.
    func record() async {
        guard let printer, let model else { return }
        let who = Diagnostics.Identity.current
        recordButton.isEnabled = false
        showButton.isHidden = true
        say("Recording \(printer.name). Close this window to stop.")
        defer {
            if !Task.isCancelled {
                recordButton.isEnabled = printer.recordHost != nil
                recordingTask = nil // done: Report a Problem… loads the window again
            }
        }
        do {
            let done = try await printer.recordForReport()
            if Task.isCancelled { // closed as the recording came back: nothing stays
                ReportRecording.discard(done)
                return
            }
            recording = done.zip
            details.string = details.string.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + ReportRecording.reportLine(done, who) + "\n"
            say(model.isDemo ? "Demo: saved as \(done.zip.lastPathComponent) in a temporary folder, from the made-up printer."
                : "Saved as \(done.zip.lastPathComponent) in Inkvolt Print's Recordings folder. Read it before you share it, then attach it to the issue.")
            showButton.isHidden = model.isDemo
        } catch {
            if Task.isCancelled { return } // closed: nothing left to say it in
            say(ReportRecording.failureText(error, who))
        }
    }

    /// Closing stops a recording under way; `ReportRecording` removes what it wrote, or `record` does once it came back.
    func windowWillClose(_ notification: Notification) {
        recordingTask?.cancel()
        recordingTask = nil
    }

    @objc func showClicked() {
        guard let recording, !Report.isRunning else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recording])
    }

    /// Copies the details (as shown, with the user's deletions) to `pasteboard`.
    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let ok = pasteboard.setString(details.string, forType: .string)
        say(ok ? "Copied." : "Couldn't copy: select the text and press ⌘C.")
        return ok
    }

    @objc func copyClicked() { copy() }

    @objc func issueClicked() {
        // `--report` copies to a pasteboard of its own, released at once: the user's clipboard is left alone, and the
        // pasteboard server keeps nothing after the run.
        let own = Report.isRunning ? NSPasteboard(name: .init("com.bermudezsystems.InkvoltPrint.report.problem")) : nil
        defer { own?.releaseGlobally() }
        guard copy(to: own ?? .general) else { return }
        let address = ProblemReport.issueUrl(repository: Self.repository, app: "Inkvolt Print", version: Self.version, system: Self.system)
        guard let url = URL(string: address) else { return }
        openedIssue = url
        if !Report.isRunning { NSWorkspace.shared.open(url) }
        say("Copied. Paste the details into the issue under Details, then submit it.")
    }

    @objc func closeClicked() { window?.performClose(nil) }
}
