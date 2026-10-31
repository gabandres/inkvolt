import AppKit
import PdfCore

extension AppSettings {
    enum AiKey {
        static let enabled = "AiEnabled"
        static let preset = "AiPreset"
        static let customUrl = "AiCustomUrl"
        static let model = "AiModel"
        static let contextTokens = "AiContextTokens"
        static let noPreview = "AiNoPreview"
        static let cloudWarned = "AiCloudWarned"
    }

    /// The AI assistant's settings (bring your own; off by default), under the Windows names. API keys are never here:
    /// they are in the Keychain (`aiKeys`). Reset to Defaults keeps them, as on Windows.
    static var ai: AiSettings {
        get {
            var s = AiSettings()
            s.enabled = defaults.object(forKey: AiKey.enabled) as? Bool ?? false
            s.preset = defaults.string(forKey: AiKey.preset) ?? s.preset
            s.customUrl = defaults.string(forKey: AiKey.customUrl) ?? ""
            s.model = defaults.string(forKey: AiKey.model) ?? ""
            s.contextTokens = defaults.object(forKey: AiKey.contextTokens) as? Int ?? s.contextTokens
            s.noPreview = defaults.stringArray(forKey: AiKey.noPreview) ?? []
            s.cloudWarned = defaults.stringArray(forKey: AiKey.cloudWarned) ?? []
            return s
        }
        set {
            defaults.set(newValue.enabled, forKey: AiKey.enabled)
            defaults.set(newValue.preset, forKey: AiKey.preset)
            defaults.set(newValue.customUrl, forKey: AiKey.customUrl)
            defaults.set(newValue.model, forKey: AiKey.model)
            defaults.set(newValue.contextTokens, forKey: AiKey.contextTokens)
            defaults.set(newValue.noPreview, forKey: AiKey.noPreview)
            defaults.set(newValue.cloudWarned, forKey: AiKey.cloudWarned)
        }
    }

    /// Where API keys are kept. The self-test puts a store in memory here, so it never touches the user's keychain.
    static var aiKeys: any AiKeyStore = AiKeychainStore()
}

/// A rounded box with an icon and a line: where text goes, calm or amber, or what's wrong with the address.
@MainActor
final class AiReachBox: NSView {
    enum Mood { case calm, caution, error, info }

    let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private var mood = Mood.calm

    init(fontSize: CGFloat = NSFont.systemFontSize) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: fontSize)
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, label])
        stack.alignment = .top
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, _ mood: Mood) {
        label.stringValue = text
        self.mood = mood
        let symbol: String
        switch mood {
        case .calm:
            symbol = "checkmark.circle"
            icon.contentTintColor = .systemGreen
        case .caution:
            symbol = "exclamationmark.triangle"
            icon.contentTintColor = .systemOrange
        case .error:
            symbol = "exclamationmark.octagon"
            icon.contentTintColor = .systemRed
        case .info:
            symbol = "info.circle"
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityValue(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        switch mood {
        case .caution: fill = NSColor.systemOrange.withAlphaComponent(0.16)
        case .error: fill = NSColor.systemRed.withAlphaComponent(0.14)
        default: fill = NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private func note(_ text: String = "", bold: Bool = false) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.smallSystemFontSize)
    if !bold { f.textColor = .secondaryLabelColor }
    f.isSelectable = false
    return f
}

/// A sheet window with a vertical stack of controls and its buttons in the usual place, ended through `finish`.
@MainActor
class AiSheet: NSWindowController {
    let stack = NSStackView()
    private let contentWidth: CGFloat
    private var answer: CheckedContinuation<Bool, Never>?
    private weak var parent: NSWindow?

    init(width: CGFloat) {
        contentWidth = width - 40
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds a view that fills the sheet's width.
    func addWide(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        if let label = view as? NSTextField { label.preferredMaxLayoutWidth = contentWidth }
        if let box = view as? AiReachBox { box.label.preferredMaxLayoutWidth = contentWidth - 44 }
    }

    /// The window as tall as what it holds now.
    func fitWindow() {
        guard let window else { return }
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: contentWidth + 40, height: stack.fittingSize.height))
    }

    /// Shows the sheet on `window`; true when it ended with its main button.
    func run(on parent: NSWindow) async -> Bool {
        self.parent = parent
        guard let panel = window else { return false }
        return await withCheckedContinuation { c in
            answer = c
            fitWindow()
            parent.beginSheet(panel)
        }
    }

    func finish(_ result: Bool) {
        if let panel = window { parent?.endSheet(panel) }
        window?.orderOut(nil)
        answer?.resume(returning: result)
        answer = nil
    }
}

/// Settings › AI assistant (the Windows `AiActions.ShowSettings`): the endpoint, model, key and context size, with Test
/// Connection. Nothing is sent from here but the request for the endpoint's models, with the key when there is one.
@MainActor
final class AiSettingsSheet: AiSheet {
    /// The sheet while it is open (the self-test fills it in and presses its buttons).
    private(set) static var current: AiSettingsSheet?
    /// Called once Test Connection has its answer (the self-test waits on it).
    var onTested: (() -> Void)?

    let enabled = NSButton(checkboxWithTitle: "Use an AI assistant: Summarize, Ask about this document, Explain selection", target: nil, action: nil)
    let preset = NSPopUpButton(frame: .zero, pullsDown: false)
    let url = NSTextField()
    let reach = AiReachBox()
    let model = NSComboBox()
    let test = NSButton(title: "Test Connection", target: nil, action: nil)
    let testResult = note()
    let key = NSSecureTextField()
    let forgetKey = NSButton(title: "Remove Saved Key", target: nil, action: nil)
    let keyNote = note()
    let context = NSComboBox()
    private let contextPanel = NSStackView()
    let ollamaContext = note(AiService.ollamaContextHelp)
    let trustNote = note()
    let resetTrust = NSButton(title: "Ask Before Every Send Again", target: nil, action: nil)
    let problem = note(bold: true)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    private var settings = AppSettings.ai
    private var customUrl: String
    private var trusted: [String]
    private let draft: AiKeyDraft
    private var testing: CancelToken?

    init(why: String?) {
        let s = settings
        customUrl = s.customUrl
        trusted = s.noPreview
        draft = AiKeyDraft(AiEndpoint.tryParse(AiService.urlOf(s.preset, s.customUrl)).endpoint?.key)
        super.init(width: 600)
        window?.title = "AI assistant"

        if let why { addWide(note(why, bold: true)) }
        let intro = NSTextField(wrappingLabelWithString: AiService.intro)
        intro.isSelectable = false
        addWide(intro)
        enabled.state = s.enabled ? .on : .off
        enabled.target = self
        enabled.action = #selector(refreshClicked)
        enabled.setAccessibilityLabel("Use an AI assistant")
        addWide(enabled)

        preset.addItems(withTitles: AiService.presetLabels)
        preset.selectItem(at: max(AiService.presetNames.firstIndex(of: s.preset) ?? 0, 0))
        preset.target = self
        preset.action = #selector(presetChanged)
        preset.setAccessibilityLabel("Endpoint")
        url.stringValue = AiService.urlOf(s.preset, s.customUrl)
        url.setAccessibilityLabel("Base URL")
        url.toolTip = "The endpoint's base URL, usually ending in /v1"
        url.delegate = self
        let endpointRow = NSStackView(views: [NSTextField(labelWithString: "Endpoint:"), preset])
        addWide(endpointRow)
        addWide(url)
        addWide(reach)

        model.stringValue = s.model
        model.isEditable = true
        model.completes = false
        model.usesDataSource = false
        model.setAccessibilityLabel("Model")
        model.toolTip = "Pick one of the endpoint's models (Test Connection lists them) or type its name, as in \"ollama list\""
        model.setContentHuggingPriority(.defaultLow, for: .horizontal)
        test.target = self
        test.action = #selector(testClicked)
        test.toolTip = "Asks the endpoint for its models: sends the API key (if any), no document text"
        addWide(NSStackView(views: [NSTextField(labelWithString: "Model:"), model, test]))
        testResult.isHidden = true
        addWide(testResult)

        key.setAccessibilityLabel("API key")
        key.delegate = self
        key.setContentHuggingPriority(.defaultLow, for: .horizontal)
        forgetKey.target = self
        forgetKey.action = #selector(forgetClicked)
        addWide(NSStackView(views: [NSTextField(labelWithString: "API key (optional):"), key, forgetKey]))
        addWide(keyNote)

        context.isEditable = true
        context.completes = false
        context.addItems(withObjectValues: AiText.contextSizes.map { AiText.n0($0) })
        context.stringValue = AiText.n0(s.contextTokens)
        context.setAccessibilityLabel("Context size in tokens")
        context.widthAnchor.constraint(equalToConstant: 140).isActive = true
        contextPanel.orientation = .vertical
        contextPanel.alignment = .leading
        contextPanel.spacing = 4
        contextPanel.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Context size (tokens the model reads at once):"), context]))
        let help = note(AiService.contextHelp)
        contextPanel.addArrangedSubview(help)
        addWide(contextPanel)
        help.widthAnchor.constraint(equalTo: contextPanel.widthAnchor).isActive = true
        help.preferredMaxLayoutWidth = 560
        addWide(ollamaContext)

        addWide(trustNote)
        resetTrust.target = self
        resetTrust.action = #selector(resetTrustClicked)
        stack.addArrangedSubview(resetTrust)
        addWide(problem)
        problem.textColor = .systemRed
        problem.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(NSStackView(views: [spacer, cancel, saveButton]))
        showTrust()
        refresh()
    }

    private var parsed: (endpoint: AiEndpoint?, error: String?) { AiEndpoint.tryParse(url.stringValue) }

    /// The settings dialog on `window`. True when saved. `why` heads it when a use found the assistant off.
    static func show(on window: NSWindow, why: String? = nil) async -> Bool {
        let sheet = AiSettingsSheet(why: why)
        current = sheet
        defer { current = nil }
        let saved = await sheet.run(on: window)
        sheet.testing?.cancel()
        return saved
    }

    private func showTrust() {
        trustNote.stringValue = AiService.trustNote(trusted)
        trustNote.isHidden = trusted.isEmpty
        resetTrust.isHidden = trusted.isEmpty
    }

    /// What depends on the address and the switch.
    func refresh() {
        defer { fitWindow() }
        problem.isHidden = true // said again by the next Save, if it still applies
        let on = enabled.state == .on
        for c in [preset, url, model, key, context, test, forgetKey] as [NSControl] { c.isEnabled = on }
        url.isEditable = preset.indexOfSelectedItem == 2 && on
        contextPanel.isHidden = preset.indexOfSelectedItem == 0
        ollamaContext.isHidden = preset.indexOfSelectedItem != 0
        let p = parsed
        if let ep = p.endpoint {
            reach.show(AiService.reachNote(ep), ep.reach == .internet ? .caution : .calm)
        } else {
            reach.show(p.error ?? "", .error)
        }
        if draft.endpointChanged(p.endpoint?.key) && !key.stringValue.isEmpty { key.stringValue = "" }
        let saved = p.endpoint.map { AppSettings.aiKeys.has($0.key) } == true && !draft.remove
        keyNote.stringValue = AiService.keyNote(saved: saved)
        forgetKey.isHidden = !saved
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func presetChanged() {
        let index = max(preset.indexOfSelectedItem, 0)
        url.stringValue = index == 2 ? customUrl : AiService.urlOf(AiService.presetNames[index], "")
        model.removeAllItems()
        testResult.stringValue = ""
        testResult.isHidden = true
        refresh()
    }

    @objc private func forgetClicked() {
        draft.removeSaved()
        key.stringValue = ""
        refresh()
    }

    @objc private func resetTrustClicked() {
        trusted = []
        showTrust()
    }

    @objc func testClicked() {
        let p = parsed
        testResult.isHidden = false
        guard let ep = p.endpoint else {
            testResult.stringValue = p.error ?? ""
            return
        }
        testing?.cancel()
        let token = CancelToken()
        testing = token
        test.isEnabled = false
        testResult.stringValue = "Connecting to \(ep.host)…"
        let apiKey = draft.keyToUse { AppSettings.aiKeys.get($0) }
        let typed = AiText.trim(model.stringValue)
        let isOllama = preset.indexOfSelectedItem == 0
        Task { @MainActor in
            defer {
                test.isEnabled = enabled.state == .on
                onTested?()
            }
            do {
                let client = AiClient(ep, typed, apiKey: apiKey)
                let models = try await client.listModels(cancel: token)
                if token.isCancelled { return }
                model.removeAllItems()
                model.addItems(withObjectValues: models)
                model.stringValue = typed.isEmpty ? models.first ?? "" : typed
                var result = AiService.testResult(host: ep.host, models: models, typed: typed)
                testResult.stringValue = result
                let chosen = AiText.trim(model.stringValue)
                if isOllama && !chosen.isEmpty {
                    let probe = AiClient(ep, chosen, apiKey: apiKey)
                    let answer = try await probe.ollamaContext(cancel: token)
                    if token.isCancelled { return }
                    result += AiService.ollamaContextNote(chosen, context: answer.context, source: answer.source)
                    testResult.stringValue = result
                }
            } catch let e as AiError {
                if !token.isCancelled { testResult.stringValue = e.message }
            } catch {
                // Stopped: the sheet closed, or another test began.
            }
        }
    }

    @objc func cancelClicked() { finish(false) }

    @objc func saveClicked() {
        let on = enabled.state == .on
        if let wrong = AiService.validate(enabled: on, url: url.stringValue, model: model.stringValue, context: context.stringValue) {
            problem.stringValue = wrong
            problem.isHidden = false
            fitWindow()
            return
        }
        var s = AppSettings.ai
        s.enabled = on
        s.preset = AiService.presetNames[max(preset.indexOfSelectedItem, 0)]
        s.customUrl = AiText.trim(customUrl)
        s.model = AiText.trim(model.stringValue)
        s.contextTokens = AiService.parseContext(context.stringValue) ?? s.contextTokens
        s.noPreview = trusted
        AppSettings.ai = s
        if let endpointKey = draft.endpointKey {
            do {
                if let typed = draft.typed {
                    try AppSettings.aiKeys.set(endpointKey, typed)
                } else if draft.remove {
                    try AppSettings.aiKeys.set(endpointKey, nil)
                }
            } catch let e as AiError {
                problem.stringValue = "API key not saved: \(e.message)"
                problem.isHidden = false
                return
            } catch {
                return
            }
        }
        finish(true)
    }
}

extension AiSettingsSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === key {
            draft.type(key.stringValue)
            return
        }
        if preset.indexOfSelectedItem == 2 { customUrl = url.stringValue }
        refresh()
    }
}

/// The window before each send (the Windows `AiActions.ConfirmSend`): where (host, model, whether it leaves this Mac), how
/// much (characters, an estimate of tokens, requests) and exactly what (every message, under a disclosure button).
/// Send stays off until what must be ticked is.
@MainActor
final class AiConfirmSheet: AiSheet {
    /// The sheet while it is open (the self-test reads it and presses its buttons).
    private(set) static var current: AiConfirmSheet?

    let toBox = AiReachBox()
    let whatLabel = NSTextField(wrappingLabelWithString: "")
    let disclosure = NSButton(title: "", target: nil, action: nil)
    let previewScroll = NSScrollView()
    let preview = NSTextView()
    let copyAll = NSButton(title: "Copy All", target: nil, action: nil)
    let cloudOk: NSButton?
    let restrictedOk: NSButton?
    let dontAsk: NSButton?
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let blockedNote = note()

    private let consent: AiConsent
    private let host: String
    private let outgoing: AiOutgoing
    private var fullPreview: String?

    init(_ config: AiConfig, _ outgoing: AiOutgoing, consent: AiConsent, title: String?) {
        let ep = config.endpoint
        self.consent = consent
        self.outgoing = outgoing
        host = ep.host
        cloudOk = consent.firstCloud ? NSButton(checkboxWithTitle: AiConsent.cloudTick(ep.host), target: nil, action: nil) : nil
        restrictedOk = consent.restricted ? NSButton(checkboxWithTitle: AiConsent.restrictedTick, target: nil, action: nil) : nil
        dontAsk = consent.offersDontAsk ? NSButton(checkboxWithTitle: AiConsent.dontAskTick(ep.host), target: nil, action: nil) : nil
        super.init(width: 640)
        let heading = title ?? "Send to the AI assistant?"
        window?.title = heading
        let head = NSTextField(labelWithString: heading)
        head.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(head)

        let server = config.serverLabel == ep.host ? "" : " (\(config.serverLabel))"
        toBox.show("To \(ep.host)\(server), model \(config.model)\n\(ep.reachText).", ep.reach == .internet ? .caution : .calm)
        toBox.setAccessibilityLabel("Where")
        addWide(toBox)
        whatLabel.stringValue = outgoing.summary
        whatLabel.isSelectable = false
        addWide(whatLabel)
        addWide(note(AiConsent.onlyThis))

        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.imagePosition = .imageLeading
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        disclosure.state = .off
        let disclosureTitle = NSTextField(labelWithString: "Show exactly what will be sent")
        disclosure.setAccessibilityLabel("Show exactly what will be sent")
        stack.addArrangedSubview(NSStackView(views: [disclosure, disclosureTitle]))

        preview.isEditable = false
        preview.isSelectable = true
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("Exactly what will be sent")
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.isHidden = true
        previewScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        addWide(previewScroll)
        copyAll.target = self
        copyAll.action = #selector(copyAllClicked)
        copyAll.isHidden = true
        stack.addArrangedSubview(copyAll)

        if let cloudOk {
            addWide(note(AiConsent.cloudNote(ep.host), bold: true))
            cloudOk.target = self
            cloudOk.action = #selector(tickChanged)
            addWide(cloudOk)
        }
        if let restrictedOk {
            addWide(note(AiConsent.restrictedNote, bold: true))
            restrictedOk.target = self
            restrictedOk.action = #selector(tickChanged)
            addWide(restrictedOk)
        }
        if let dontAsk {
            dontAsk.state = consent.dontAskNow ? .on : .off
            addWide(dontAsk)
        }
        addWide(blockedNote)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(NSStackView(views: [spacer, cancel, sendButton]))
        tickChanged()
    }

    /// Asks; true when Send was pressed, with what it means for the settings saved.
    static func ask(on window: NSWindow, _ config: AiConfig, _ outgoing: AiOutgoing, consent: AiConsent, title: String?) async -> Bool {
        let sheet = AiConfirmSheet(config, outgoing, consent: consent, title: title)
        current = sheet
        defer { current = nil }
        let sent = await sheet.run(on: window)
        if sent {
            AppSettings.ai = consent.applied(to: AppSettings.ai, config.endpoint, dontAsk: sheet.dontAsk?.state == .on)
        }
        return sent
    }

    private func full() -> String {
        if let fullPreview { return fullPreview }
        let made = AiPrompts.preview(outgoing.requests)
        fullPreview = made
        return made
    }

    @objc func disclosureClicked() {
        let open = disclosure.state == .on
        if open && preview.string.isEmpty { preview.string = AiConsent.shownPreview(full()) }
        previewScroll.isHidden = !open
        copyAll.isHidden = !open
        fitWindow()
    }

    @objc func copyAllClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full(), forType: .string)
    }

    @objc func tickChanged() {
        let why = consent.blocked(host: host, understood: cloudOk?.state == .on, sendAnyway: restrictedOk?.state == .on)
        sendButton.isEnabled = why == nil
        blockedNote.stringValue = why ?? ""
        blockedNote.isHidden = why == nil
    }

    @objc func cancelClicked() { finish(false) }

    @objc func sendClicked() {
        guard sendButton.isEnabled else { return }
        finish(true)
    }
}
