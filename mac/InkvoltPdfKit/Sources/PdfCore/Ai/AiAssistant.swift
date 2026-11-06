import Foundation
import PrintCore

/// The assistant's saved settings, under the Windows app's names (`AppSettings`'s Ai…). Off by default. API keys are never
/// here: see `AiKeyStore`.
public struct AiSettings: Sendable, Equatable {
    public var enabled = false
    /// "Ollama", "LMStudio" or "Custom" (with `customUrl`).
    public var preset = "Ollama"
    public var customUrl = ""
    public var model = ""
    public var contextTokens = AiText.defaultContextTokens
    /// Endpoints the user chose "don't ask again" for, and internet endpoints already warned about (`AiEndpoint.key`s).
    public var noPreview: [String] = []
    public var cloudWarned: [String] = []
    public init() {}
}

/// The AI assistant's configuration: where to send, which model, how much it reads at once. For the Ollama preset the
/// context is asked from Ollama before each use (`AiService.resolve`), `contextSource` says how.
public struct AiConfig: Sendable, Equatable {
    public let endpoint: AiEndpoint
    public let preset: String
    public let model: String
    public var contextTokens: Int
    public var contextSource: String?

    public init(endpoint: AiEndpoint, preset: String, model: String, contextTokens: Int, contextSource: String? = nil) {
        self.endpoint = endpoint
        self.preset = preset
        self.model = model
        self.contextTokens = contextTokens
        self.contextSource = contextSource
    }

    /// "Ollama", "LM Studio", or the host for a custom endpoint.
    public var serverLabel: String {
        switch preset {
        case "Ollama": "Ollama"
        case "LMStudio": "LM Studio"
        default: endpoint.host
        }
    }

    public var isOllama: Bool { preset == "Ollama" }

    /// Estimated tokens of document text one request may carry.
    public var inputTokens: Int { AiText.inputTokens(contextTokens) }
}

/// The bring-your-own AI assistant's rules. Off by default; nothing here talks to any server until the user configures
/// an endpoint and confirms a send. There is no Inkvolt server, default key or telemetry.
public enum AiService {
    public static let presetNames = ["Ollama", "LMStudio", "Custom"]
    public static var presetLabels: [String] {
        [loc("Ollama (on this Mac)"), loc("LM Studio (on this Mac)"), loc("Custom: any OpenAI-compatible endpoint")]
    }

    /// The base URL a preset stands for (Custom: the saved custom URL).
    public static func urlOf(_ preset: String, _ customUrl: String) -> String {
        switch preset {
        case "Ollama": AiEndpoint.ollamaUrl
        case "LMStudio": AiEndpoint.lmStudioUrl
        default: customUrl
        }
    }

    /// The saved configuration, or nil with the reason when the assistant is off or incomplete.
    public static func current(_ s: AiSettings) -> (config: AiConfig?, problem: String?) {
        if !s.enabled { return (nil, loc("The AI assistant is off.")) }
        let parsed = AiEndpoint.tryParse(urlOf(s.preset, s.customUrl))
        guard let endpoint = parsed.endpoint else { return (nil, parsed.error) }
        let model = AiText.trim(s.model)
        if model.isEmpty { return (nil, loc("Choose a model for the AI assistant.")) }
        // Ollama: until it is asked (resolve), the size it uses unless told otherwise on most machines.
        let context = s.preset == "Ollama" ? AiText.defaultContextTokens : min(max(s.contextTokens, 1024), 2_000_000)
        return (AiConfig(endpoint: endpoint, preset: s.preset, model: model, contextTokens: context), nil)
    }

    /// For the Ollama preset, the context Ollama really gives the model (as loaded, or its num_ctx; else 4,096, Ollama's
    /// usual default), since a longer prompt is silently cut by Ollama. Other endpoints keep the size set in Settings.
    public static func resolve(_ config: AiConfig, keys: any AiKeyStore, handler: (any AiTransport)? = nil, cancel: CancelToken? = nil) async throws -> AiConfig {
        if !config.isOllama { return config }
        let client = AiClient(config.endpoint, config.model, apiKey: keys.get(config.endpoint.key), handler: handler)
        let answer = try await client.ollamaContext(cancel: cancel)
        var resolved = config
        if let n = answer.context {
            resolved.contextTokens = max(n, 1024)
            resolved.contextSource = answer.source
        } else {
            resolved.contextTokens = AiText.defaultContextTokens
            resolved.contextSource = loc("Ollama's usual default (it didn't say)")
        }
        return resolved
    }

    /// A client for a configuration: for Ollama with the answer's limit, so the prompt and the answer fit its context.
    public static func client(_ config: AiConfig, keys: any AiKeyStore, handler: (any AiTransport)? = nil) -> AiClient {
        AiClient(config.endpoint, config.model, apiKey: keys.get(config.endpoint.key), handler: handler,
                 maxAnswerTokens: config.isOllama ? AiText.answerTokens(config.contextTokens) : nil)
    }

    public static func skipsPreview(_ s: AiSettings, _ endpoint: AiEndpoint) -> Bool {
        s.noPreview.contains { $0.lowercased() == endpoint.key.lowercased() }
    }

    public static func warnedAbout(_ s: AiSettings, _ endpoint: AiEndpoint) -> Bool {
        endpoint.reach != .internet || s.cloudWarned.contains { $0.lowercased() == endpoint.key.lowercased() }
    }

    /// The one-line state for Settings: "Off", or "On: model at host (stays on this Mac)".
    public static func describe(_ s: AiSettings) -> String {
        if !s.enabled { return loc("Off. Inkvolt PDF has no AI of its own; you can connect one you choose.") }
        let now = current(s)
        if let c = now.config { return loc("On: {0} at {1}. {2}.", c.model, c.serverLabel, c.endpoint.reachText) }
        return loc("On, but not set up: {0}", now.problem ?? "")
    }

    /// What the settings say about an endpoint's address.
    public static func reachNote(_ endpoint: AiEndpoint) -> String {
        switch endpoint.reach {
        case .internet: loc("{0}. Text you send is handled under that provider's terms.", endpoint.reachText)
        case .thisMac: loc("{0}: text goes only to the server running on this computer.", endpoint.reachText)
        case .localNetwork: "\(endpoint.reachText)."
        }
    }

    /// What the settings say about the endpoint's key.
    public static func keyNote(saved: Bool) -> String {
        saved ? loc("A key is saved for this endpoint, in your keychain. Leave the box empty to keep it.")
            : loc("Only if the endpoint needs one (local servers don't). Kept in your keychain, sent only to this endpoint.")
    }

    /// The context size typed in the settings ("4,096"), nil unless a number from 1,024 to 2,000,000.
    public static func parseContext(_ text: String) -> Int? {
        var digits = text
        for separator in [",", ".", " ", "\u{00A0}"] { digits = digits.replacingOccurrences(of: separator, with: "") }
        guard let n = Int(digits), n >= 1024, n <= 2_000_000 else { return nil }
        return n
    }

    /// What's wrong with the settings as filled in, or nil. The context is checked even with the assistant off, as on Windows.
    public static func validate(enabled: Bool, url: String, model: String, context: String) -> String? {
        if parseContext(context) == nil { return loc("Enter a context size from 1,024 to 2,000,000 tokens.") }
        if !enabled { return nil }
        let parsed = AiEndpoint.tryParse(url)
        if parsed.endpoint == nil { return parsed.error }
        if AiText.trim(model).isEmpty { return loc("Choose or type a model (Test connection lists the endpoint's models).") }
        return nil
    }

    /// What Test connection found.
    public static func testResult(host: String, models: [String], typed: String) -> String {
        let n = models.count
        if models.isEmpty { return loc("Connected to {0}, but it doesn't list its models: type the model's name.", host) }
        if !typed.isEmpty && !models.contains(where: { $0.lowercased() == typed.lowercased() }) {
            if n == 1 { return loc("Connected: {0} model, but not \"{1}\". Pick one from the list.", CoreLanguage.number(n), typed) }
            return loc("Connected: {0} models, but not \"{1}\". Pick one from the list.", CoreLanguage.number(n), typed)
        }
        if n == 1 { return loc("Connected to {1}: {0} model available.", CoreLanguage.number(n), host) }
        return loc("Connected to {1}: {0} models available.", CoreLanguage.number(n), host)
    }

    /// Test connection's second sentence for Ollama.
    public static func ollamaContextNote(_ model: String, context: Int?, source: String) -> String {
        if let context { return " " + loc("{0} reads {1} tokens at once ({2}).", model, CoreLanguage.number(context), source) }
        return " " + loc("Ollama didn't say how much {0} reads at once (it isn't loaded yet): Inkvolt PDF assumes {1} tokens, its usual default.", model, CoreLanguage.number(AiText.defaultContextTokens))
    }

    public static var intro: String {
        loc("Inkvolt PDF has no AI of its own. If you want one, connect a model you run (Ollama, LM Studio) or an OpenAI-compatible service you have an account with. Only text you pick is sent, after you see it, to the endpoint below. Bermudez Systems receives nothing.")
    }

    public static var contextHelp: String {
        loc("Set it to the context the server runs the model with (LM Studio: Context Length when loading the model; 4,096 by default). Larger than that, the server cuts the text and answers go wrong; smaller, long documents are summarized in more parts.")
    }

    public static var ollamaContextHelp: String {
        loc("Context size: asked from Ollama before each use (the model as loaded, or its num_ctx; 4,096 when Ollama can't tell, its usual default). To give the model more, set OLLAMA_CONTEXT_LENGTH or the context length in Ollama's settings.")
    }

    public static func trustNote(_ endpoints: [String]) -> String {
        loc("Sends without showing what goes first to: {0}. (Text the PDF forbids copying is always asked about.)", endpoints.joined(separator: ", "))
    }
}

/// What one use of the AI assistant will send: the first requests (shown in the preview) and how it is described.
public struct AiOutgoing: Sendable, Equatable {
    public let requests: [[AiMessage]]
    /// "The text of pages 1–12" and the like.
    public let what: String
    /// More requests the job makes later from the model's own answers (map-reduce), or nil.
    public let followUp: String?

    public init(_ requests: [[AiMessage]], what: String, followUp: String? = nil) {
        self.requests = requests
        self.what = what
        self.followUp = followUp
    }

    public var characters: Int { requests.reduce(0) { $0 + $1.reduce(0) { $0 + $1.content.utf16.count } } }
    public var tokens: Int { requests.reduce(0) { $0 + AiText.estimateTokens($1) } }

    /// The window's "What" line.
    public var summary: String {
        let n = requests.count
        let chars = CoreLanguage.number(characters)
        let toks = CoreLanguage.number(tokens)
        if let followUp {
            if n == 1 { return loc("{1}: {2} characters (about {3} tokens) in {0} request, then {4}.", n, what, chars, toks, followUp) }
            return loc("{1}: {2} characters (about {3} tokens) in {0} requests, then {4}.", CoreLanguage.number(n), what, chars, toks, followUp)
        }
        if n == 1 { return loc("{1}: {2} characters (about {3} tokens) in {0} request.", CoreLanguage.number(n), what, chars, toks) }
        return loc("{1}: {2} characters (about {3} tokens) in {0} requests.", CoreLanguage.number(n), what, chars, toks)
    }
}

/// When the window that shows what goes where appears, and what it must get from the user first. Asks before sending;
/// skipped for an endpoint the user chose "don't ask again" for, except for the first send to an internet endpoint and
/// for text the PDF forbids copying.
public struct AiConsent: Sendable, Equatable {
    /// False: send without showing the window (the user's "don't ask again").
    public let asks: Bool
    /// The first send to this internet endpoint: "I understand" must be ticked.
    public let firstCloud: Bool
    /// The PDF forbids copying its text: "Send it anyway" must be ticked.
    public let restricted: Bool
    /// The window offers "Don't ask again" (not in one shown regardless of that choice).
    public let offersDontAsk: Bool
    /// Its state as the window opens.
    public let dontAskNow: Bool

    /// - Parameter force: ask even when the user chose "don't ask again" for this endpoint.
    public init(_ s: AiSettings, _ endpoint: AiEndpoint, copyRestricted: Bool, force: Bool = false) {
        firstCloud = !AiService.warnedAbout(s, endpoint)
        restricted = copyRestricted
        dontAskNow = AiService.skipsPreview(s, endpoint)
        asks = !dontAskNow || copyRestricted || firstCloud || force
        offersDontAsk = !force
    }

    /// Why Send can't be pressed yet, or nil.
    public func blocked(host: String, understood: Bool, sendAnyway: Bool) -> String? {
        if firstCloud && !understood { return loc("Tick \"I understand\" to send text to {0}, or Cancel.", host) }
        if restricted && !sendAnyway { return loc("Tick \"Send it anyway\" to send text the author restricted, or Cancel.") }
        return nil
    }

    /// What Send leaves in the settings: "don't ask again" as ticked, and this internet endpoint as warned about.
    public func applied(to s: AiSettings, _ endpoint: AiEndpoint, dontAsk: Bool) -> AiSettings {
        var out = s
        if offersDontAsk {
            out.noPreview.removeAll { $0.lowercased() == endpoint.key.lowercased() }
            if dontAsk { out.noPreview.append(endpoint.key) }
        }
        if firstCloud { out.cloudWarned.append(endpoint.key) }
        return out
    }

    public static var onlyThis: String {
        loc("Only this text, the instructions shown below and the model's name are sent: no file name, folder, document properties or other documents.")
    }

    public static func cloudNote(_ host: String) -> String {
        loc("This is the first time you send text to {0}. It leaves this Mac, and that provider may keep and use it under its own terms, not Inkvolt PDF's. Only send documents you're allowed to share with it.", host)
    }

    public static func cloudTick(_ host: String) -> String { loc("I understand: this text leaves this Mac for {0}", host) }
    public static var restrictedNote: String { loc("The author of this PDF restricted copying its text. Sending it to an AI copies it out of the document.") }
    public static var restrictedTick: String { loc("Send it anyway: I'm allowed to use this text") }
    public static func dontAskTick(_ host: String) -> String { loc("Don't ask again for {0} (change this in Settings › AI assistant)", host) }
    /// The preview shows at most this many characters; Copy All has everything.
    public static let maxShown = 400_000

    /// The preview's text, cut at `maxShown` with a word about what is left out.
    public static func shownPreview(_ full: String) -> String {
        let count = full.utf16.count
        if count <= maxShown { return full }
        return String(decoding: Array(full.utf16.prefix(maxShown)), as: UTF16.self) + "\n" + loc("… and {0} more characters (Copy All has everything).", CoreLanguage.number(count - maxShown))
    }
}

/// True when the PDF's permissions forbid copying its text and it wasn't opened with its permissions password (as the
/// author would). Inkvolt PDF lets the user copy anyway, as other readers do; sending it elsewhere is asked about.
public enum AiCopyRestriction {
    public static func isRestricted(_ data: [UInt8], password: String?, hasEncryption: Bool) -> Bool {
        if !hasEncryption { return false }
        do {
            let info = try PdfSecurity.readSecurity(data, password)
            if !info.isEncrypted || info.permissions.copy { return false }
            let hasOwnerPassword = !(password ?? "").isEmpty && !PdfSecurity.isOpenPassword(data, password)
            return !hasOwnerPassword
        } catch {
            return true // unreadable: asked about as if copying were restricted
        }
    }
}

/// Page text already read for the AI, for the engine it came from (an edit replaces the engine and so the cache).
public final class AiPageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: PdfEngine?
    private var texts: [Int: String] = [:]

    public init() {}

    /// The pages not read yet (forgetting what was read from another engine).
    public func missing(_ pages: [Int], engine current: PdfEngine) -> [Int] {
        lock.withLock {
            if engine !== current {
                texts = [:]
                engine = current
            }
            return pages.filter { texts[$0] == nil }
        }
    }

    /// Reads `pages` in the background. A page that can't be read counts as empty. `progress` gets pages done every 25.
    /// - Throws: `CancellationError`.
    public func read(_ pages: [Int], engine: PdfEngine, cancel: CancelToken, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [AiPageText] {
        let missing = missing(pages, engine: engine)
        if !missing.isEmpty {
            let read = try await Task.detached(priority: .userInitiated) { () throws -> [Int: String] in
                var result: [Int: String] = [:]
                for (i, page) in missing.enumerated() {
                    try cancel.check()
                    do {
                        result[page] = try engine.text(page, cache: false, cancel: cancel).text
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result[page] = ""
                    }
                    if i % 25 == 24 { progress?(i + 1) }
                }
                return result
            }.value
            lock.withLock {
                if self.engine === engine { texts.merge(read) { _, new in new } }
            }
        }
        return lock.withLock { pages.map { AiPageText($0, texts[$0] ?? "") } }
    }

    public func clear() {
        lock.withLock {
            texts = [:]
            engine = nil
        }
    }
}

/// A job's request in the words the assistant shows: what to send, and how the conversation labels it. The rules of the
/// Windows tab's `AiSummarize`, `AiAsk` and `AiExplainSelection`, kept here so they are tested.
public enum AiJobs {
    /// The finish reason of a summary whose parts the user chose not to send back to be combined.
    public static let notCombined = "inkvolt:not-combined"

    public struct Summary: Sendable {
        public let chunks: [AiChunk]
        public let outgoing: AiOutgoing
        public let label: String
        /// Combining requests are shown before they go: always for an internet endpoint; on this Mac or the network
        /// unless the user chose not to be asked for it.
        public let showCombine: Bool
        public let pages: [Int]
    }

    public struct Question: Sendable {
        public let request: AiAskRequest
        public let outgoing: AiOutgoing
    }

    public struct Explanation: Sendable {
        public let messages: [AiMessage]
        public let outgoing: AiOutgoing
        public let label: String
        public let historyQuestion: String
    }

    /// The summary of `pages`, or the reason nothing goes.
    public static func summary(_ pages: [Int], _ texts: [AiPageText], _ config: AiConfig, settings: AiSettings) -> (job: Summary?, notSent: String?) {
        let chunks = AiText.chunk(texts, config.inputTokens)
        let named = AiText.pagesText(pages)
        if chunks.isEmpty {
            if pages.count == 1 { return (nil, loc("Not sent: {1} has no text. Scanned pages need Recognize Text (OCR) first.", 1, named)) }
            return (nil, loc("Not sent: {1} have no text. Scanned pages need Recognize Text (OCR) first.", CoreLanguage.number(pages.count), named))
        }
        let first = AiPrompts.summaryRequests(chunks)
        let showCombine = config.endpoint.reach == .internet || !AiService.skipsPreview(settings, config.endpoint)
        let followUp: String? = first.count == 1 ? nil
            : showCombine ? loc("the partial summaries the model writes, which you'll see before they're sent back to it to be combined")
            : loc("the partial summaries the model writes, sent back to it to be combined (without asking, as chosen for this endpoint)")
        let outgoing = AiOutgoing(first, what: loc("The text of {0}", named), followUp: followUp)
        return (Summary(chunks: chunks, outgoing: outgoing, label: loc("Summarize {0}", named), showCombine: showCombine, pages: pages), nil)
    }

    /// Runs a summary: the map step's answers are the model's own text and don't show; the final one streams to `onFinal`.
    public static func run(_ job: Summary, client: AiClient, config: AiConfig,
                           onFinal: (@Sendable (String) -> Void)?, onStep: @escaping @Sendable (AiStep) -> Void,
                           confirmCombine: @escaping @Sendable ([[AiMessage]], CancelToken?) async throws -> Bool,
                           cancel: CancelToken?) async throws -> AiReply {
        let state = SummaryState()
        let text = try await AiPrompts.summarize(job.chunks, inputTokens: config.inputTokens, ask: { messages, step, c in
            onStep(step)
            let reply = try await client.chat(messages, onText: step.isFinal ? onFinal : nil, cancel: c)
            if step.isFinal { state.setFinish(reply.finishReason) }
            return AiText.withoutThinking(reply.text).text
        }, cancel: cancel, confirmCombine: { round, c in
            let ok = try await confirmCombine(round, c)
            state.setDeclined(!ok)
            return ok
        })
        return AiReply(text, state.declined ? notCombined : state.finish)
    }

    private final class SummaryState: @unchecked Sendable {
        private let lock = NSLock()
        private var finishValue: String?
        private var declinedValue = false
        var finish: String? { lock.withLock { finishValue } }
        var declined: Bool { lock.withLock { declinedValue } }
        func setFinish(_ s: String?) { lock.withLock { finishValue = s } }
        func setDeclined(_ d: Bool) { lock.withLock { declinedValue = d } }
    }

    /// The combining round as the window describes it.
    public static func combineOutgoing(_ round: [[AiMessage]], pages: [Int]) -> AiOutgoing {
        AiOutgoing(round, what: loc("The partial summaries the model wrote about {0}", AiText.pagesText(pages)))
    }

    public static var combineTitle: String { loc("Send the partial summaries to combine them?") }

    /// The pages a question is about: the Pages box's "All" (or nothing), or a range.
    public static func scope(_ text: String, pageCount: Int) -> (pages: [Int]?, error: String?) {
        let trimmed = AiText.trim(text)
        if trimmed.isEmpty || trimmed.lowercased() == "all" { return (Array(0..<pageCount), nil) }
        let parsed = PageRange.tryParse(trimmed, pageCount)
        return parsed.ok ? (parsed.pages, nil) : (nil, loc("Pages: {0}", parsed.error ?? ""))
    }

    /// A question about `pages`, with the conversation so far, or the reason nothing goes.
    public static func question(_ question: String, turns: [AiTurn], pages: [Int], _ texts: [AiPageText], _ config: AiConfig) -> (job: Question?, notSent: String?) {
        let request = AiPrompts.ask(question, history: turns, pages: texts, inputTokens: config.inputTokens)
        let all = AiText.pagesText(pages)
        if request.pages.isEmpty {
            if pages.count == 1 { return (nil, loc("Not sent: {1} has no text to ask about.", 1, all)) }
            return (nil, loc("Not sent: {1} have no text to ask about.", CoreLanguage.number(pages.count), all))
        }
        let asked = AiText.pagesText(request.pages)
        let n = turns.count
        let what: String
        if request.trimmed {
            if n == 0 {
                what = loc("Your question, the parts of {0} most related to it (all of {1} doesn't fit the model's context)", asked, all)
            } else if n == 1 {
                what = loc("Your question, the parts of {1} most related to it (all of {2} doesn't fit the model's context), and the conversation so far ({0} earlier answer)", CoreLanguage.number(n), asked, all)
            } else {
                what = loc("Your question, the parts of {1} most related to it (all of {2} doesn't fit the model's context), and the conversation so far ({0} earlier answers)", CoreLanguage.number(n), asked, all)
            }
        } else if n == 0 {
            what = loc("Your question and the text of {0}", asked)
        } else if n == 1 {
            what = loc("Your question and the text of {1}, and the conversation so far ({0} earlier answer)", CoreLanguage.number(n), asked)
        } else {
            what = loc("Your question and the text of {1}, and the conversation so far ({0} earlier answers)", CoreLanguage.number(n), asked)
        }
        return (Question(request: request, outgoing: AiOutgoing([request.messages], what: what)), nil)
    }

    /// Explains a selection, or the reason nothing goes.
    public static func explanation(_ selection: String, page: Int, _ config: AiConfig) -> (job: Explanation?, notSent: String?) {
        let messages: [AiMessage]
        do {
            messages = try AiPrompts.explain(selection, page: page, inputTokens: config.inputTokens)
        } catch let e as AiError {
            return (nil, e.message)
        } catch {
            return (nil, "\(error)")
        }
        let shown = AiText.clean(selection)
        let oneLine = shown.replacingOccurrences(of: "\n", with: " ")
        let label = loc("Explain: “{0}”", AiProtocol.shorten(oneLine, 120))
        let outgoing = AiOutgoing([messages], what: loc("The selected text ({0})", AiText.pagesText(page, page)))
        return (Explanation(messages: messages, outgoing: outgoing, label: label,
                            historyQuestion: "Explain this passage from page \(page + 1): \"\(AiProtocol.shorten(shown, 600))\""), nil)
    }

    /// A suggestion of alternate text for a figure (Make Accessible's Reading Order pane; the Windows tab's
    /// `SuggestAltAsync`): the request with the picture, as the window describes it.
    public static func altText(png: [UInt8], nearby: String, language: String?, page: Int, number: Int) -> (messages: [AiMessage], outgoing: AiOutgoing) {
        let messages = AiPrompts.altText(png, nearby: nearby, language: language, page: page)
        return (messages, AiOutgoing([messages], what: loc("picture {0} of page {1} (as an image) and the text near it", CoreLanguage.number(number), CoreLanguage.number(page + 1))))
    }

    public static var altTextTitle: String { loc("Suggest alternate text?") }
    public static var altTextSetup: String {
        loc("Alternate text suggestions use your own AI model: one that reads pictures (a vision model such as llava or gemma3 in Ollama, or a cloud model).")
    }

    /// The note on a finished answer.
    public static func finishNote(_ reply: AiReply, answer: String) -> String? {
        if reply.finishReason == notCombined { return loc("The partial summaries, not combined: you chose not to send them back to the model.") }
        if reply.wasCutOff { return loc("The answer was cut off at the model's length limit.") }
        return answer.isEmpty ? loc("The model sent an empty answer.") : nil
    }

    /// The progress line of a step.
    public static func stepText(_ step: AiStep) -> String {
        step.total > 1 ? loc("{0} ({1} of {2})…", step.what, CoreLanguage.number(step.index), CoreLanguage.number(step.total)) : "\(step.what)…"
    }

    public static var emptyPane: String {
        loc("Ask a question about this document below, summarize it, or select text and Control-click › Explain with AI.\n\nBefore anything is sent you see exactly what goes where. Answers are AI-generated and may be wrong: check them against the pages they cite.")
    }
}

/// A piece of an answer as it is drawn: plain or bold, and a page link for a citation.
public struct AiRun: Sendable, Equatable {
    public let text: String
    public let bold: Bool
    /// The page a citation links to (0-based).
    public let page: Int?
    public init(_ text: String, bold: Bool = false, page: Int? = nil) {
        self.text = text
        self.bold = bold
        self.page = page
    }
}

/// How an answer is shown: simple Markdown (headings, bullets, bold), "[p. N]" citations as links to the pages.
public enum AiAnswerMarkup {
    public static var aiNote: String { loc("AI-generated, may be wrong") }

    /// What Copy puts on the clipboard.
    public static func copied(_ text: String) -> String { "\(text)\n\n(\(aiNote))" }

    private static let heading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*)$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+]|•)\s+(.*)$"#)

    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    /// The runs of an answer already without its reasoning (lines end in a "\n" run).
    public static func runs(_ shown: String, pageCount: Int) -> [AiRun] {
        var out: [AiRun] = []
        let lines = shown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            if i > 0 { out.append(AiRun("\n")) }
            if let h = match(heading, raw) {
                out += inline(h[0], allBold: true, pageCount)
                continue
            }
            var line = raw
            if let b = match(bullet, raw) { line = b[0] + "•  " + b[1] }
            out += inline(line, allBold: false, pageCount)
        }
        return out
    }

    /// A line's text with **bold** spans and page citations as links. An unclosed ** stays as text.
    private static func inline(_ line: String, allBold: Bool, _ pageCount: Int) -> [AiRun] {
        var out: [AiRun] = []
        let parts = line.components(separatedBy: "**")
        for (i, part) in parts.enumerated() {
            let bold = i % 2 == 1 && i < parts.count - 1
            let text = bold || i % 2 == 0 ? part : "**" + part
            let isBold = bold || allBold
            let ns = text as NSString
            var at = 0
            for c in AiText.citations(text, pageCount) {
                if c.start > at { out.append(AiRun(ns.substring(with: NSRange(location: at, length: c.start - at)), bold: isBold)) }
                out.append(AiRun(ns.substring(with: NSRange(location: c.start, length: c.length)), bold: isBold, page: c.page))
                at = c.start + c.length
            }
            if at < ns.length { out.append(AiRun(ns.substring(from: at), bold: isBold)) }
        }
        return out
    }
}
