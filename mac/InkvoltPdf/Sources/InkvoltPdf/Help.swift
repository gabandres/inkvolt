import AppKit
import PrintCore
import PdfCore

/// Help › What's New: the bundled WHATS-NEW.md (Inkvolt Print's `ReleaseNotes` reads it), shown once after an update
/// with what came since the version last run (nothing on a new install), as the Windows app's ReleaseNotes.
@MainActor
enum WhatsNew {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    /// Where the notes are read from (the self-test may point elsewhere).
    static var notesURL: URL? = Bundle.main.url(forResource: "WHATS-NEW", withExtension: "md")

    /// Every versioned entry of this build's notes, newest first (none when the file is missing).
    static func notes() -> [ReleaseNote] {
        guard let url = notesURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return ReleaseNotes.parse(text)
    }

    /// After an update, once: what came since the version last run. False when nothing was shown.
    @discardableResult
    static func showOnce(current: String = version) -> Bool {
        guard AppSettings.lastVersionSeen != current else { return false }
        let now = ReleaseNotes.normalize(current) ?? NoteVersion(0, 0, 0)
        let news = ReleaseNotes.since(notes(), lastSeen: AppSettings.lastVersionSeen, current: now, newInstall: AppSettings.isNewInstall)
        AppSettings.lastVersionSeen = current
        guard !news.isEmpty else { return false }
        show(news)
        return true
    }

    static func show(_ notes: [ReleaseNote]) {
        let controller = WhatsNewWindowController.shared ?? WhatsNewWindowController()
        WhatsNewWindowController.shared = controller
        controller.show(notes)
    }
}

@MainActor
final class WhatsNewWindowController: NSWindowController {
    static var shared: WhatsNewWindowController?

    let textView = NSTextView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "What's New in Inkvolt PDF"
        window.isRestorable = false
        super.init(window: window)
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("What's new")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\r"
        let stack = NSStackView(views: [scroll, close])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.contentView = stack
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ notes: [ReleaseNote]) {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.bullet]
        if notes.isEmpty { text.append(NSAttributedString(string: "No release notes in this build.", attributes: body)) }
        for (i, note) in notes.enumerated() {
            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor]
            text.append(NSAttributedString(string: (i == 0 ? "" : "\n") + "Version \(note.version)\n", attributes: heading))
            for item in note.items { text.append(NSAttributedString(string: "•\t\(item)\n", attributes: body)) }
        }
        textView.textStorage?.setAttributedString(text)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static let bullet: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        style.headIndent = 16
        style.paragraphSpacing = 6
        return style
    }()

    @objc func closeClicked() { window?.orderOut(nil) }
}

/// Inkvolt PDF › About Inkvolt PDF: the version, copyright, the AGPL notice and source link, what stays on this Mac, and
/// the third-party notices (the bundled THIRD-PARTY-NOTICES.md and Sparkle's license text).
@MainActor
final class AboutWindowController: NSWindowController {
    static var shared: AboutWindowController?
    static let source = URL(string: "https://github.com/gabandres/inkvolt")!

    let notices = NSTextView()
    let versionLabel = NSTextField(labelWithString: "")

    static func show() {
        let controller = shared ?? AboutWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return short == build ? "Version \(short)" : "Version \(short) (\(build))"
    }

    /// The notices shown: Inkvolt PDF's list, then Sparkle's license as it ships.
    static func noticesText() -> String {
        var parts: [String] = []
        for (name, ext) in [("THIRD-PARTY-NOTICES", "md"), ("Sparkle-LICENSE", "txt")] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext), let text = try? String(contentsOf: url, encoding: .utf8) {
                parts.append(name == "Sparkle-LICENSE" ? "Sparkle's license\n\n" + text : text)
            }
        }
        return parts.isEmpty ? "The notices aren't in this build; they are at \(source.absoluteString)." : parts.joined(separator: "\n\n")
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "About Inkvolt PDF"
        window.isRestorable = false
        window.minSize = NSSize(width: 460, height: 420)
        super.init(window: window)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Inkvolt PDF")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        versionLabel.stringValue = Self.versionText
        versionLabel.textColor = .secondaryLabelColor
        let copyright = NSTextField(labelWithString: "© 2026 Bermudez Systems LLC")
        let titles = NSStackView(views: [name, versionLabel, copyright])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [icon, titles])
        header.spacing = 16

        let privacy = NSTextField(wrappingLabelWithString: "Nothing you open leaves this Mac unless you send text to an AI you set up. No account, no tracking, no analytics: documents, "
            + "text recognition and exports are all done here. Update checks ask Inkvolt PDF's feed on GitHub and send nothing about you.")
        let license = NSTextField(wrappingLabelWithString: "Inkvolt PDF is free software: you can share and change it under the GNU Affero General "
            + "Public License, version 3 (AGPL-3.0), which MuPDF, the engine it is built on, requires. It comes with no warranty. "
            + "The complete source code is on GitHub.")
        for label in [privacy, license] { label.preferredMaxLayoutWidth = 500 }
        let sourceButton = NSButton(title: "Source Code on GitHub", target: self, action: #selector(openSource))
        let licenseButton = NSButton(title: "License (AGPL-3.0)…", target: self, action: #selector(showLicense))
        let links = NSStackView(views: [sourceButton, licenseButton])
        let noticesTitle = NSTextField(labelWithString: "Third-party notices")
        noticesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        notices.isEditable = false
        notices.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        notices.string = Self.noticesText()
        notices.textContainerInset = NSSize(width: 8, height: 8)
        notices.autoresizingMask = [.width]
        notices.setAccessibilityLabel("Third-party notices")
        let scroll = NSScrollView()
        scroll.documentView = notices
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let stack = NSStackView(views: [header, privacy, license, links, noticesTitle, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        window.contentView = stack
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func openSource() { NSWorkspace.shared.open(Self.source) }

    /// The AGPL's full text (bundled as LICENSE.txt), else the license on gnu.org.
    @objc func showLicense() {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSWorkspace.shared.open(URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
            return
        }
        notices.string = text
        notices.scrollToBeginningOfDocument(nil)
    }
}

/// Help › Report a Problem… (the Windows app's `AppHelp.ShowReport`): the details a report needs, scrubbed
/// (`ProblemReport`, masked by PrintCore's `Diagnostics.scrub`), shown first, then copied for the user to paste into a
/// GitHub issue. Nothing is sent from the app. The Mac app keeps no log, so the report says "(no log yet)".
@MainActor
final class ReportProblemWindowController: NSWindowController {
    static var shared: ReportProblemWindowController?
    let details = NSTextView()
    let status = NSTextField(labelWithString: "")
    /// The issue address Copy and Open a GitHub Issue last opened (the self-test reads it instead of a browser opening).
    private(set) var openedIssue: URL?

    static func show() {
        let controller = shared ?? ReportProblemWindowController()
        shared = controller
        controller.details.string = report()
        controller.status.stringValue = ""
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The report: the version, macOS, a few settings (scrubbed), no log.
    static func report() -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        let ai = AppSettings.ai
        let open = NSDocumentController.shared.documents.count
        let print = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bermudezsystems.InkvoltPrint") != nil
        let settings: [(name: String, value: String)] = [
            ("Theme", AppSettings.theme),
            ("Reopen at last page", onOff(AppSettings.restorePosition)),
            ("Recovery copies", onOff(AppSettings.keepRecoveryCopies)),
            ("Dark pages", onOff(AppSettings.darkPages)),
            ("Reading mode", AppSettings.readingMode),
            ("AI assistant", ai.enabled ? "on (\(ai.preset))" : "off"),
            ("Inkvolt Pro", PdfCore.Pro.licence != nil ? "licensed" : PdfCore.Pro.problem != nil ? "key not accepted" : "none"),
            ("Open documents", "\(open)"),
            ("Inkvolt Print", print ? "installed" : "not installed"),
        ]
        let who = Diagnostics.Identity.current
        return ProblemReport.report(app: "Inkvolt PDF", version: WhatsNew.version, system: system, architecture: architecture,
                                    packaged: false, settings: settings, logTail: [], scrub: { Diagnostics.scrub($0, who) })
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Report a Problem"
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 380)
        super.init(window: window)
        let note = NSTextField(wrappingLabelWithString: "These details help find the problem: the version, macOS and a few settings. "
            + "IP addresses, file paths and your names are masked; document contents are never in them. Nothing is sent: copy them, "
            + "then paste them into a GitHub issue or an e-mail. Delete anything you'd rather not share.")
        note.preferredMaxLayoutWidth = 600
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
        let issue = NSButton(title: "Copy and Open a GitHub Issue", target: self, action: #selector(issueClicked))
        issue.toolTip = "Copies the details, then opens a new issue on GitHub in your browser to paste them in"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [status, spacer, issue, copy, close])
        let stack = NSStackView(views: [note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window.contentView = stack
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Copies the details (as shown, with the user's deletions) to `pasteboard`.
    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let ok = pasteboard.setString(details.string, forType: .string)
        status.stringValue = ok ? "Copied." : "Couldn't copy: select the text and press ⌘C."
        return ok
    }

    @objc func copyClicked() { copy() }

    @objc func issueClicked() {
        guard copy(to: Report.isRunning ? NSPasteboard(name: .init("com.bermudezsystems.InkvoltPdf.selftest.report")) : .general) else { return }
        let address = ProblemReport.issueUrl(repository: AboutWindowController.source.absoluteString, app: "Inkvolt PDF",
                                             version: WhatsNew.version, system: Self.system)
        guard let url = URL(string: address) else { return }
        openedIssue = url
        if !Report.isRunning { NSWorkspace.shared.open(url) }
        status.stringValue = "Copied. Paste the details into the issue under Details, then submit it."
    }

    @objc func closeClicked() { window?.orderOut(nil) }
}
