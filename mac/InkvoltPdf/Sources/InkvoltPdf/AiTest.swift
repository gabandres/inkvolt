import AppKit
import PdfCore

/// The self-test's scenario for E11 (`--edit`, on the synthetic text document; `--only-ai` runs it alone): the AI assistant
/// through its own menu commands, sheets and pane, against a fake OpenAI-compatible server on loopback
/// (`AiLoopbackServer`), so the app's real connection is used and no AI service is. The promise is what it checks most:
/// off by default, nothing sent until the endpoint is set up and what goes was approved, exactly what was shown is what
/// arrives. Keys stay in memory (`AppSettings.aiKeys` is replaced), never the user's keychain. Only counts and the test's
/// own words are written.
@MainActor
struct AiTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func waitFor(_ seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func settings() async -> AiSettingsSheet? {
        _ = await waitFor { AiSettingsSheet.current != nil }
        return AiSettingsSheet.current
    }

    private func confirm() async -> AiConfirmSheet? {
        _ = await waitFor { AiConfirmSheet.current != nil }
        return AiConfirmSheet.current
    }

    private func snapshot(_ window: NSWindow?, _ file: String) {
        guard let dir = Report.snapshots, let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// A chat request's messages, as the server got them.
    private func messages(_ received: AiLoopbackServer.Received) -> [(role: String, content: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(received.body.utf8)) as? [String: Any],
              let list = root["messages"] as? [[String: Any]] else { return [] }
        return list.map { ($0["role"] as? String ?? "", $0["content"] as? String ?? "") }
    }

    mutating func run() async {
        guard controller.pdf.session != nil else {
            Report.write("== \(name): AI assistant\nRESULT: FAIL (no session)")
            return
        }
        lines.append("== \(name): AI assistant (\(controller.engine.pageCount) pages)")
        let keys = AiMemoryKeyStore()
        AppSettings.aiKeys = keys
        AppSettings.ai = AiSettings()
        defer { AppSettings.ai = AiSettings() }
        // What the fake server says: its model list, and answers by what is asked.
        guard let server = AiLoopbackServer(answer: { received in
            if received.requestLine.contains("/models") { return .json(200, #"{"data":[{"id":"test-model"},{"id":"other"}]}"#) }
            if received.body.contains("STALL") {
                var stalled = AiLoopbackServer.Answer.sse(["The start"])
                stalled.pieces.removeLast(2)
                stalled.holdOpen = true
                return stalled
            }
            if received.body.contains("REFUSE") { return .json(404, #"{"error":{"message":"model not found"}}"#) }
            if received.body.contains("These are summaries") { return .sse(["<think>let me see</think>", "The whole ", "summary [p. 1]."]) }
            return .sse(["The ", "answer ", "**says** it ", "[p. 1] and [p. 2]."], pause: 0.01)
        }) else {
            check(false, "the fake server starts")
            return finish()
        }
        defer { server.stop() }
        func chats() -> [AiLoopbackServer.Received] { server.received.filter { $0.requestLine.hasPrefix("POST") } }
        let url = "http://127.0.0.1:\(server.port)/v1"

        // Off by default: the menu asks for setup, and nothing has talked to anything.
        check(!AppSettings.ai.enabled && AiService.current(AppSettings.ai).problem == "The AI assistant is off.", "off by default")
        check(AiService.describe(AppSettings.ai).hasPrefix("Off."), "Settings says Off: \(AiService.describe(AppSettings.ai).prefix(40))")
        controller.aiAsk(nil)
        var sheet = await settings()
        check(sheet?.enabled.state == .off, "Ask with the assistant off opens its settings, off")
        snapshot(sheet?.window, "ai-settings-off.png")
        sheet?.cancelClicked()
        await controller.ai.job?.value
        check(!controller.isAiPaneOpen && server.received.isEmpty, "Cancel: no pane, nothing sent to anything (\(server.received.count) requests)")

        // Selected text: the context menu's Explain appears only with the assistant on.
        let hasText = (try? controller.engine.text(0))?.isEmpty == false
        controller.pages.select(0, (0, 20))
        let menuOff = controller.pages.menu(for: Self.rightClick(controller)).map { $0.items.map(\.title) } ?? []
        check(hasText && !menuOff.contains("Explain with AI"), "no Explain with AI on the selection's menu while off")

        // Set up: an address on this Mac, Test Connection, a key that isn't real.
        controller.aiSettings(nil)
        sheet = await settings()
        guard let s = sheet else {
            check(false, "AI Assistant Settings… opens")
            return finish()
        }
        s.enabled.performClick(nil)
        s.preset.selectItem(at: 2)
        s.preset.sendAction(s.preset.action, to: s.preset.target)
        s.url.stringValue = "http://8.8.8.8/v1"
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.url))
        check(s.reach.label.stringValue.contains("https://"), "plain http to the internet is refused as typed: \(s.reach.label.stringValue.prefix(50))")
        s.saveClicked()
        check(AiSettingsSheet.current === s && !s.problem.isHidden, "Save refuses it, with the reason")
        s.url.stringValue = "https://api.example.com/v1"
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.url))
        check(s.reach.label.stringValue.hasPrefix("Leaves this Mac: sent to api.example.com"), "an internet address is labeled as leaving this Mac")
        snapshot(s.window, "ai-settings-internet.png")
        s.url.stringValue = url
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.url))
        check(s.reach.label.stringValue.hasPrefix("Stays on this Mac"), "the loopback address is labeled as staying on this Mac")
        s.key.stringValue = "not-a-real-key"
        s.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: s.key))
        var tested = false
        s.onTested = { tested = true }
        s.test.performClick(nil)
        _ = await waitFor { tested }
        let listed = (0..<s.model.numberOfItems).compactMap { s.model.itemObjectValue(at: $0) as? String }
        check(listed == ["other", "test-model"] && s.testResult.stringValue.contains("2 models"), "Test Connection lists the models: \(s.testResult.stringValue.prefix(60))")
        let asked = server.received.first
        check(server.received.count == 1 && asked?.requestLine.hasPrefix("GET /v1/models") == true && asked?.head.contains("Bearer not-a-real-key") == true && asked?.body.isEmpty == true,
              "Test Connection sends the key and no document text")
        s.model.stringValue = "test-model"
        snapshot(s.window, "ai-settings.png")
        s.saveClicked()
        await controller.ai.job?.value
        let saved = AppSettings.ai
        check(saved.enabled && saved.preset == "Custom" && saved.model == "test-model" && saved.customUrl == url, "Save keeps the endpoint and the model")
        let endpoint = AiEndpoint.tryParse(url).endpoint!
        check(keys.get(endpoint.key) == "not-a-real-key", "the key goes to the key store")
        let inDefaults = AppSettings.defaults.dictionaryRepresentation().values.contains { "\($0)".contains("not-a-real-key") }
        check(!inDefaults, "the key isn't in the settings")
        check(AiService.describe(saved).hasPrefix("On: test-model"), "Settings says On: \(AiService.describe(saved))")

        // The pane, and a question that is shown before it goes.
        controller.aiAsk(nil)
        await controller.ai.job?.value
        guard let pane = controller.ai.pane else {
            check(false, "the pane opens")
            return finish()
        }
        _ = await waitFor(2) { controller.isAiPaneOpen }
        check(controller.isAiPaneOpen && pane.whereBox.label.stringValue == "test-model · Stays on this Mac", "the pane shows the model and where text goes: \(pane.whereBox.label.stringValue)")
        snapshot(controller.window, "ai-pane-empty.png")
        let menuOn = controller.pages.menu(for: Self.rightClick(controller)).map { $0.items.map(\.title) } ?? []
        check(menuOn.contains("Explain with AI"), "Explain with AI is on the selection's menu")
        controller.pages.clearSelection()

        pane.questionText = "What does it say?"
        pane.askClicked()
        var send = await confirm()
        guard let first = send else {
            check(false, "the window shows before anything is sent")
            return finish()
        }
        check(chats().isEmpty, "nothing was sent while the window is up")
        check(first.toBox.label.stringValue.hasPrefix("To 127.0.0.1:\(server.port)") && first.toBox.label.stringValue.contains("model test-model") && first.toBox.label.stringValue.contains("Stays on this Mac"),
              "the window says where: \(first.toBox.label.stringValue.replacingOccurrences(of: "\n", with: " "))")
        check(first.whatLabel.stringValue.contains("characters (about") && first.whatLabel.stringValue.contains("1 request"), "and how much: \(first.whatLabel.stringValue.prefix(70))")
        first.disclosure.performClick(nil)
        let shown = first.preview.string
        check(!first.previewScroll.isHidden && shown.contains("── system ──") && shown.contains("── user ──\nWhat does it say?"), "and, opened, exactly what")
        snapshot(first.window, "ai-confirm.png")
        first.cancelClicked()
        await controller.ai.job?.value
        check(chats().isEmpty && pane.statusLabel.stringValue == "Not sent." && pane.answers.isEmpty && pane.questionText == "What does it say?", "Cancel sends nothing, and keeps the question")

        pane.askClicked()
        send = await confirm()
        let previewed = send.map { _ in AiConfirmSheet.current?.disclosure.state == .off }
        send?.disclosure.performClick(nil)
        let approved = send?.preview.string ?? ""
        send?.sendClicked()
        await controller.ai.job?.value
        check(previewed == true && chats().count == 1, "Send sends one request")
        let got = chats().first
        check(got?.requestLine == "POST /v1/chat/completions HTTP/1.1" && got?.head.contains("Authorization: Bearer not-a-real-key") == true, "to the endpoint, with the key as a bearer token")
        let sent = got.map(messages) ?? []
        let rebuilt = AiPrompts.preview([sent.map { AiMessage(role: $0.role, content: $0.content) }])
        check(!sent.isEmpty && rebuilt == approved, "what arrives is exactly what was shown (\(rebuilt.utf16.count) characters)")
        if let body = got?.body, let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            check(Set(root.keys) == ["model", "messages", "stream"] && root["model"] as? String == "test-model", "the request carries only model, messages and stream")
        } else {
            check(false, "the request is JSON")
        }
        let fileName = controller.pdf.fileURL?.lastPathComponent ?? "no-file-name"
        check(got?.head.contains(fileName) == false && got?.body.contains(fileName) == false, "no file name goes")
        let answer = pane.answers.last
        check(answer?.text == "The answer **says** it [p. 1] and [p. 2]." && answer?.finished == true, "the answer arrived in the card: \(answer?.text.prefix(50) ?? "none")")
        let attributed = answer?.shownText ?? ""
        check(attributed.contains("says") && !attributed.contains("**") && answer?.links == [0, 1] && answer?.isCopyEnabled == true, "bold drawn, two citations linked, Copy on")
        snapshot(controller.window, "ai-pane-answer.png")
        controller.go(3 < controller.engine.pageCount ? 3 : 0)
        answer?.followFirstLink()
        _ = await waitFor(2) { controller.pages.currentPage == 0 }
        check(controller.pages.currentPage == 0, "a citation goes to its page")
        answer?.copyClicked()
        check(NSPasteboard.general.string(forType: .string)?.hasSuffix("(AI-generated, may be wrong)") == true, "Copy keeps the AI-generated note")
        check(pane.questionText.isEmpty && pane.statusLabel.stringValue.hasPrefix("Answer ready. AI-generated"), "the box is cleared, and the status says to check it")

        // A follow-up carries the conversation; "don't ask again" skips the window for this endpoint only.
        pane.questionText = "And then?"
        pane.askClicked()
        send = await confirm()
        check(send?.whatLabel.stringValue.contains("conversation so far (1 earlier answer)") == true, "a follow-up says it carries the conversation")
        send?.dontAsk?.performClick(nil)
        send?.sendClicked()
        await controller.ai.job?.value
        let second = chats().last.map(messages) ?? []
        check(second.map(\.role) == ["system", "user", "assistant", "user"] && second.last?.content == "And then?", "and does: \(second.map(\.role))")
        check(AppSettings.ai.noPreview == [endpoint.key], "Don't ask again is kept for this endpoint")
        pane.questionText = "Once more?"
        pane.askClicked()
        await controller.ai.job?.value
        check(AiConfirmSheet.current == nil && chats().count == 3, "then it sends without the window")
        var settingsAgain = AppSettings.ai
        settingsAgain.noPreview = []
        AppSettings.ai = settingsAgain

        // The Pages box.
        pane.scopeField.stringValue = "99"
        pane.questionText = "On a page that isn't there?"
        pane.askClicked()
        await controller.ai.job?.value
        check(chats().count == 3 && pane.statusLabel.stringValue.hasPrefix("Pages: "), "a wrong Pages box sends nothing: \(pane.statusLabel.stringValue.prefix(50))")
        pane.scopeField.stringValue = "1"
        pane.askClicked()
        send = await confirm()
        check(send?.whatLabel.stringValue.contains("page 1") == true && send?.whatLabel.stringValue.contains("pages") == false, "the Pages box limits what goes")
        send?.cancelClicked()
        await controller.ai.job?.value
        pane.scopeField.stringValue = "All"
        pane.clearQuestion()

        // Explain a selection, through the menu command.
        controller.pages.select(0, (0, 20))
        let selected = controller.pages.selectedText ?? ""
        controller.aiExplain(nil)
        send = await confirm()
        check(send?.whatLabel.stringValue.hasPrefix("The selected text (page 1)") == true, "Explain says what goes")
        send?.sendClicked()
        await controller.ai.job?.value
        let explained = chats().last.map(messages) ?? []
        check(explained.count == 2 && explained[1].content.contains(AiText.clean(selected)) && explained[1].content.contains("page 1"), "Explain sends the selection, quoted")
        controller.pages.clearSelection()

        // Summarize, through its dialog; at a small context a long summary would combine, shown first (Kit's tests).
        controller.aiSummarize(nil)
        _ = await waitFor { controller.aiSummaryAlert != nil }
        if let ask = controller.aiSummaryAlert, let window = controller.window {
            ask.field.stringValue = "1"
            window.endSheet(ask.alert.window, returnCode: .alertFirstButtonReturn)
        }
        send = await confirm()
        check(send?.whatLabel.stringValue.hasPrefix("The text of page 1") == true, "Summarize asks for pages, then shows what goes")
        send?.sendClicked()
        await controller.ai.job?.value
        check(chats().last?.body.contains("Summarize this document text (page 1)") == true && pane.answers.last?.finished == true, "and sends one request")

        // Stop.
        let before = pane.answers.count
        pane.questionText = "STALL please"
        pane.askClicked()
        send = await confirm()
        send?.sendClicked()
        _ = await waitFor { pane.answers.count == before + 1 && pane.isBusy && server.received.contains { $0.body.contains("STALL please") } }
        check(pane.isBusy, "Stop shows while an answer runs")
        controller.aiAsk(nil)
        await controller.ai.job?.value
        pane.stopClicked()
        await waitPaneIdle(pane)
        check(!pane.isBusy && pane.answers.last?.note == "Stopped." && pane.statusLabel.stringValue == "Stopped.", "Stop ends it: \(pane.answers.last?.note ?? "no note")")

        // An error is an error on the card.
        pane.questionText = "REFUSE this"
        pane.askClicked()
        send = await confirm()
        send?.sendClicked()
        await waitPaneIdle(pane)
        check(pane.answers.last?.note?.contains("isn't available") == true && pane.answers.last?.isCopyEnabled == false, "the server's refusal is worded on the card: \(pane.answers.last?.note?.prefix(50) ?? "none")")
        snapshot(controller.window, "ai-pane-error.png")

        // The window's rules for what must be ticked (nothing is sent: both are cancelled).
        if let config = AiService.current(AppSettings.ai).config {
            let owner = controller
            let restricted = Task { @MainActor in await owner.confirmSend(config, AiOutgoing([[.user("x")]], what: "X"), restricted: true) }
            let r = await confirm()
            check(r?.sendButton.isEnabled == false && r?.blockedNote.stringValue.contains("Send it anyway") == true, "restricted text: Send is off until ticked")
            r?.restrictedOk?.performClick(nil)
            check(r?.sendButton.isEnabled == true, "and on once it is")
            r?.cancelClicked()
            _ = await restricted.value
        }
        var cloudSettings = AppSettings.ai
        cloudSettings.customUrl = "https://api.example.com/v1"
        AppSettings.ai = cloudSettings
        if let cloud = AiService.current(AppSettings.ai).config {
            let owner = controller
            let task = Task { @MainActor in await owner.confirmSend(cloud, AiOutgoing([[.user("x")]], what: "X"), restricted: false) }
            let c = await confirm()
            check(c?.sendButton.isEnabled == false && c?.toBox.label.stringValue.contains("Leaves this Mac: sent to api.example.com") == true, "the first send to the internet says so, and needs I understand")
            snapshot(c?.window, "ai-confirm-internet.png")
            c?.cancelClicked()
            let ok = await task.value
            check(!ok && AppSettings.ai.cloudWarned.isEmpty, "cancelled: nothing sent, not marked as warned")
        }
        cloudSettings.customUrl = url
        AppSettings.ai = cloudSettings

        // Clear, close, off again.
        pane.clearClicked()
        check(pane.answers.isEmpty && controller.ai.turns.isEmpty && pane.statusLabel.stringValue == "Conversation cleared", "Clear empties the conversation")
        controller.closeAiPane()
        _ = await waitFor(2) { !controller.isAiPaneOpen }
        check(!controller.isAiPaneOpen, "Close hides the pane")
        let requests = server.received.count
        var off = AppSettings.ai
        off.enabled = false
        AppSettings.ai = off
        controller.pages.select(0, (0, 20))
        controller.aiExplain(nil)
        sheet = await settings()
        check(sheet != nil && server.received.count == requests, "turned off, Explain asks for setup and sends nothing")
        sheet?.cancelClicked()
        await controller.ai.job?.value
        controller.pages.clearSelection()
        lines.append("note: \(pane.stateReport().prefix(160))")
        finish()
    }

    private func waitPaneIdle(_ pane: AiPane) async {
        _ = await waitFor { !pane.isBusy && controller.ai.cancel == nil }
    }

    private static func rightClick(_ controller: DocumentWindowController) -> NSEvent {
        let pages = controller.pages
        let spot = pages.convert(pages.viewPoint(PointD(5, 5), pages.pageRects[0]), to: nil)
        return NSEvent.mouseEvent(with: .rightMouseDown, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
