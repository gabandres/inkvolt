import AppKit
import PdfCore

/// The licence key lives in the settings (`AppSettings.proKey`), so it survives reinstalling with them; read and written
/// from any thread (`Pro` asks from wherever a feature runs).
final class SettingsProStore: ProStore, @unchecked Sendable {
    static let key = "ProKey"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func read() -> String? {
        let key = defaults.string(forKey: Self.key) ?? ""
        return key.isEmpty ? nil : key
    }

    func write(_ key: String?) { defaults.set(key ?? "", forKey: Self.key) }
}

/// Help › Inkvolt Pro… (the Windows app's `ProWindow`): Free or Pro (licensed to whom), a box to paste a key with its
/// refusal in plain words, Get Inkvolt Pro, Remove Licence. A Pro feature that isn't unlocked opens it too, with what the
/// feature does at the top. While `Pro.enforced` is off the copy says everything is free and the purchase supports the
/// project.
@MainActor
final class ProWindowController: NSWindowController {
    static var shared: ProWindowController?

    private let body = NSStackView()
    private let keyText = NSTextView()
    private let keyScroll = NSScrollView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private var feature: ProFeature?
    /// The texts shown, top to bottom (the self-test reads them).
    private(set) var texts: [String] = []

    static func show(feature: ProFeature? = nil) {
        let controller = shared ?? ProWindowController()
        shared = controller
        controller.feature = feature
        controller.refresh()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Inkvolt Pro"
        window.isRestorable = false
        super.init(window: window)

        keyText.isRichText = false
        keyText.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        keyText.isAutomaticQuoteSubstitutionEnabled = false
        keyText.isAutomaticTextReplacementEnabled = false
        keyText.textContainerInset = NSSize(width: 4, height: 4)
        keyText.setAccessibilityLabel("Licence key")
        keyScroll.documentView = keyText
        keyScroll.hasVerticalScroller = true
        keyScroll.borderType = .bezelBorder
        keyScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        keyText.autoresizingMask = [.width]
        keyText.isVerticallyResizable = true
        keyText.textContainer?.widthTracksTextView = true
        error.textColor = .systemRed
        error.preferredMaxLayoutWidth = 500
        error.isHidden = true

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        let title = NSTextField(labelWithString: "Inkvolt Pro")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), close])
        let root = NSStackView(views: [title, body, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        body.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        window.contentView = content
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func add(_ view: NSView) {
        body.addArrangedSubview(view)
        if let field = view as? NSTextField { texts.append(field.stringValue) } else if let button = view as? NSButton { texts.append("[\(button.title)]") }
    }

    private func caption(_ text: String) -> NSTextField { RedactPatternSheet.caption(text) }

    private func heading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 16, weight: .semibold)
        return f
    }

    func refresh() {
        for v in body.arrangedSubviews { body.removeArrangedSubview(v); v.removeFromSuperview() }
        texts = []
        error.isHidden = true
        let licence = Pro.licence

        if let feature, !Pro.allows(feature) {
            let box = NSBox()
            box.boxType = .custom
            box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12)
            box.borderColor = .clear
            box.cornerRadius = 6
            box.contentViewMargins = NSSize(width: 14, height: 10)
            let lockedText = RedactPatternSheet.heading(Pro.locked(feature))
            let detail = RedactPatternSheet.wrapped("\(Pro.title(feature)): \(Pro.describe(feature))")
            let stack = NSStackView(views: [lockedText, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            box.contentView = stack
            add(box)
            texts += [lockedText.stringValue, detail.stringValue]
        }

        if let licence {
            add(heading("Pro licensed to \(licence.name)"))
            let issued = licence.issuedDate.map { DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .none) } ?? licence.issued
            add(caption("Key for \(licence.email), issued \(issued). It is checked on this Mac, works offline, on Windows and on the Mac, and stays through reinstalling. Thank you for supporting Inkvolt PDF."))
            if !Pro.enforced {
                add(caption("Everything in Inkvolt PDF is free while it launches; your licence will keep the Pro features (batch presets, watched folders, the command line) when they start asking for a key."))
            }
            add(NSButton(title: "Remove Licence", target: self, action: #selector(removeClicked)))
            return
        }

        if Pro.enforced {
            add(heading("Free"))
            add(caption("Inkvolt Pro unlocks batch presets, watched folders, the command line, Make Accessible, the reading order's fixes and PDF/A-2a: a one-time \(Pro.priceText), no account. The key is checked on this Mac, works offline, on Windows and on the Mac, and stays through reinstalling. Everything else in Inkvolt PDF is free and stays free."))
        } else {
            add(heading("Everything is free while Inkvolt PDF launches"))
            add(caption("That includes the Pro features: batch presets, watched folders, the command line, Make Accessible, the reading order's fixes and PDF/A-2a. Inkvolt Pro (\(Pro.priceText), one time, no account) supports the project, and gives a business a licence it can put on an invoice; the key keeps the Pro features when they start asking for one, on Windows and on the Mac."))
        }
        if let problem = Pro.problem {
            let text = RedactPatternSheet.wrapped(problem)
            text.textColor = .systemRed
            add(text)
        }
        let get = NSButton(title: "Get Inkvolt Pro (\(Pro.priceText))", target: self, action: #selector(getClicked))
        get.bezelStyle = .rounded
        get.keyEquivalent = ""
        add(get)

        let have = RedactPatternSheet.heading("Have a key? Paste it here")
        add(have)
        body.setCustomSpacing(16, after: get)
        keyScroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        body.addArrangedSubview(keyScroll)
        body.addArrangedSubview(error)
        let enter = NSButton(title: "Enter Key", target: self, action: #selector(enterClicked))
        enter.keyEquivalent = "\r"
        add(enter)
    }

    @objc private func closeClicked() { window?.close() }

    @objc private func getClicked() { NSWorkspace.shared.open(URL(string: Pro.buyUrl)!) }

    @objc private func enterClicked() { enter(keyText.string) }

    /// Checks and keeps the key; a refusal shows under the box.
    func enter(_ key: String) {
        do {
            let licence = try Pro.install(key)
            Report.note("Inkvolt Pro licence entered (issued \(licence.issued))")
            error.isHidden = true
            keyText.string = ""
            refresh()
        } catch let e as ProKeyError {
            error.stringValue = e.message
            error.isHidden = false
        } catch {
            self.error.stringValue = "\(error)"
            self.error.isHidden = false
        }
    }

    @objc private func removeClicked() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the Inkvolt Pro licence from this Mac?"
        alert.informativeText = "Presets you saved and files the Pro features made stay as they are. You can enter the key again any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self.removeNow()
            }
        }
    }

    func removeNow() {
        Pro.remove()
        refresh()
    }

    /// What the window shows, for the self-test.
    var state: String {
        "\(Pro.licence.map { "Pro licensed to \($0.name)" } ?? "Free"); enforced=\(Pro.enforced); feature=\(feature.map { "\($0)" } ?? "-"); "
            + "error='\(error.isHidden ? "" : error.stringValue)'; text='\(texts.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }.joined(separator: " | "))'"
    }
}
