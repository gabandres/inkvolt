import Foundation
import PrintCore

/// What an Edit by Asking step does: one of a small set of the command palette's commands, each undoable or harmless.
public enum AskEditKind: Sendable, Equatable {
    case goToPage, rotatePages, deletePages, addBookmark, highlightText, findForRedaction
}

/// One step the model proposed, checked: its pages (0-based, in range), and its other arguments within their limits. It
/// runs only when the person ticks it and presses Run.
public struct AskEditStep: Sendable, Equatable {
    public let kind: AskEditKind
    public var pages: [Int] = []
    public var degrees = 0
    public var text = ""
    public var patterns: Set<RedactionPattern> = []

    public init(_ kind: AskEditKind, pages: [Int] = [], degrees: Int = 0, text: String = "", patterns: Set<RedactionPattern> = []) {
        self.kind = kind
        self.pages = pages
        self.degrees = degrees
        self.text = text
        self.patterns = patterns
    }

    /// What the step does, in the interface's language, as the person sees it before it runs.
    public func describe() -> String {
        switch kind {
        case .goToPage: return loc("Go to page {0}", CoreLanguage.number(pages[0] + 1))
        case .rotatePages:
            let which = AiText.pagesText(pages)
            switch degrees {
            case 90: return loc("Rotate {0} clockwise", which)
            case 270: return loc("Rotate {0} counterclockwise", which)
            default: return loc("Turn {0} upside down (180°)", which)
            }
        case .deletePages: return loc("Delete {0}", AiText.pagesText(pages))
        case .addBookmark: return loc("Add a bookmark \"{0}\" that goes to page {1}", text, CoreLanguage.number(pages[0] + 1))
        case .highlightText: return loc("Highlight every \"{0}\"", text)
        case .findForRedaction:
            let names = RedactionPattern.allCases.filter { patterns.contains($0) }.map(RedactionPatterns.name) + (text.isEmpty ? [] : ["\"\(text)\""])
            return loc("Find for redaction, to review in its list: {0}", names.joined(separator: ", "))
        }
    }
}

/// What the model answered: the steps it proposed that check out, what it proposed that doesn't (said why), and its words
/// when it called nothing.
public struct AskEditPlan: Sendable {
    public let steps: [AskEditStep]
    public let refused: [String]
    public let said: String?
}

/// The pages the steps run so far deleted (0-based, of the document as it was asked about), each once: kept in order, so
/// how many go before a page is a binary search, and in a set for asking about one (a 100,000-page file, half of it
/// deleted, then every page turned, takes a moment rather than billions of comparisons).
public struct DeletedPages: Sendable, Equatable, ExpressibleByArrayLiteral {
    public private(set) var sorted: [Int] = []
    private var all = Set<Int>()

    public init(arrayLiteral pages: Int...) { add(pages) }

    public var isEmpty: Bool { sorted.isEmpty }
    public func contains(_ page: Int) -> Bool { all.contains(page) }

    /// Adds the pages not already in.
    public mutating func add(_ pages: [Int]) {
        var new: [Int] = []
        for p in pages where all.insert(p).inserted { new.append(p) }
        if new.isEmpty { return }
        sorted = (sorted + new).sorted()
    }

    /// How many deleted pages go before `page`.
    public func countBelow(_ page: Int) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < page { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Edit by Asking (roadmap 4.23, free; the Windows `AskEdit`): the user's own endpoint, with tool calling, maps a request in
/// the person's words onto a few of the command palette's commands (go to a page, rotate or delete pages, add a bookmark,
/// highlight a word or phrase, find pattern matches for redaction's review list). The request sends the person's words,
/// the page count and the current page: no document text. The answer is data: only calls of these tools with arguments
/// that check out become steps; nothing runs from the model's text, every step is shown and runs only on the person's
/// click, and each edit is one undo step. A model that can't call tools is refused with a word on which can.
public enum AskEdit {
    /// Most steps taken from one answer (the rest are said to be left out).
    public static let maxSteps = 10
    /// Most calls read from one answer, refused ones counted: past it the rest are left out and said.
    public static let maxCalls = 50
    /// Longest request, bookmark title, text to highlight or find, and pages argument ("1-3, 5"), in UTF-16 units.
    public static let maxRequestChars = 500, maxTitleChars = 120, maxTextChars = 200, maxPagesChars = 200

    public static let systemPrompt =
        "You turn a person's request about the PDF they have open into calls of the tools you are given, in the order to do them. "
        + "Use only those tools; page numbers start at 1. Page numbers always mean the pages as they are now, before any of the steps. "
        + "If the request can't be done with these tools, call none and say so in one short sentence. Never invent text to add."

    /// Kinds a redaction step can look for, by the names the tool offers.
    private static let patternNames: [String: RedactionPattern] = [
        "email": .email, "phone": .phone, "ssn": .socialSecurity, "card": .paymentCard, "date": .date, "iban": .iban,
        "ip": .ipAddress, "zip": .zipCode,
    ]

    /// The messages: the instructions, where the person is (page count and page), and their request. No document text.
    public static func messages(_ request: String, pageCount: Int, currentPage: Int) -> [AiMessage] {
        // .NET's ReplaceLineEndings(" "): CR, LF, CR LF, NEL, LS, PS and FF.
        let ends: Set<Character> = ["\r\n", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}", "\u{0C}"]
        let joined = String(AiText.trim(request).map { ends.contains($0) ? " " : $0 })
        // At most maxRequestChars UTF-16 units, cut between characters.
        var text = ""
        var units = 0
        for c in joined {
            if units + c.utf16.count > maxRequestChars { break }
            text.append(c)
            units += c.utf16.count
        }
        let page = min(max(currentPage, 0), max(0, pageCount - 1)) + 1
        return [
            .system("\(systemPrompt)\n\nThe document has \(pageCount) \(pageCount == 1 ? "page" : "pages"); the person is on page \(page)."),
            .user(text),
        ]
    }

    /// The tools as the OpenAI-compatible API takes them (shown in the send window as they go).
    public static let toolsJson = """
        [
          {"type":"function","function":{"name":"go_to_page","description":"Show a page.","parameters":{"type":"object","properties":{"page":{"type":"integer","description":"Page number, from 1."}},"required":["page"]}}},
          {"type":"function","function":{"name":"rotate_pages","description":"Turn pages a quarter turn clockwise (90), half a turn (180) or a quarter turn counterclockwise (270).","parameters":{"type":"object","properties":{"pages":{"type":"string","description":"Pages such as \\"1-3, 5\\" or \\"all\\"."},"degrees":{"type":"integer","enum":[90,180,270]}},"required":["pages","degrees"]}}},
          {"type":"function","function":{"name":"delete_pages","description":"Delete pages.","parameters":{"type":"object","properties":{"pages":{"type":"string","description":"Pages such as \\"1-3, 5\\"."}},"required":["pages"]}}},
          {"type":"function","function":{"name":"add_bookmark","description":"Add a bookmark that goes to a page.","parameters":{"type":"object","properties":{"title":{"type":"string"},"page":{"type":"integer","description":"Page number, from 1."}},"required":["title","page"]}}},
          {"type":"function","function":{"name":"highlight_text","description":"Highlight every place a word or phrase appears.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}},
          {"type":"function","function":{"name":"find_for_redaction","description":"Find things to redact and list them for the person to review: kinds of data, or a word or phrase.","parameters":{"type":"object","properties":{"kinds":{"type":"array","items":{"type":"string","enum":["email","phone","ssn","card","date","iban","ip","zip"]}},"text":{"type":"string"}}}}}
        ]
        """

    /// The request body: model, messages, the tools, not streamed. Nothing else.
    public static func requestJson(_ model: String, _ messages: [AiMessage]) -> String {
        let list = messages.map { "{\"role\":\(AiProtocol.quote($0.role)),\"content\":\(AiProtocol.quote($0.content))}" }.joined(separator: ",")
        let tools = toolsJson.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        return "{\"model\":\(AiProtocol.quote(model)),\"messages\":[\(list)],\"tools\":\(tools),\"stream\":false}"
    }

    /// Reads a chat completion's tool calls into steps for a document of `pageCount` pages. A call of another tool, with
    /// arguments that aren't JSON, pages out of range or other values out of their limits is refused and said; past
    /// `maxSteps` steps, or `maxCalls` calls read, the rest are left out and said. Its cost is bounded by the answer's
    /// length (a pages argument past `maxPagesChars` is refused unread).
    /// - Throws: `AiError` when the answer isn't a chat completion.
    public static func parse(_ json: String, pageCount: Int) throws -> AskEditPlan {
        guard let any = AiProtocol.parse(json) else { throw AiError(loc("The endpoint sent an answer Inkvolt PDF can't read (not JSON).")) }
        if let root = any as? [String: Any], root["error"] != nil, let error = AiProtocol.errorMessageOf(json: root) {
            throw AiError(loc("The model stopped with an error: \"{0}\"", error))
        }
        guard let root = any as? [String: Any], let choices = root["choices"] as? [Any], let first = choices.first as? [String: Any],
              let message = first["message"] as? [String: Any] else {
            throw AiError(loc("The endpoint's answer isn't an OpenAI-compatible chat completion."))
        }
        var said: String?
        if let content = message["content"] as? String { said = AiText.trim(AiText.withoutThinking(content).text) }
        var steps: [AskEditStep] = []
        var refused: [String] = []
        if let calls = message["tool_calls"] as? [Any] {
            var read = 0
            for call in calls {
                if steps.count >= maxSteps {
                    refused.append(loc("Only the first {0} steps are shown; the rest were left out.", CoreLanguage.number(maxSteps)))
                    break
                }
                if read >= maxCalls {
                    refused.append(loc("The answer held more than {0} calls; the rest were left out.", CoreLanguage.number(maxCalls)))
                    break
                }
                read += 1
                switch Self.read(call, pageCount) {
                case .success(let step): steps.append(step)
                case .failure(let why): refused.append(why.message)
                }
            }
        }
        if let s = said, s.isEmpty { said = nil }
        return AskEditPlan(steps: steps, refused: refused, said: said.map { AiProtocol.shorten($0, 600) })
    }

    private static func read(_ call: Any, _ pageCount: Int) -> Result<AskEditStep, AiError> {
        guard let call = call as? [String: Any], let f = call["function"] as? [String: Any], let name = f["name"] as? String else {
            return .failure(AiError(loc("A proposed step wasn't a call of a command and was left out.")))
        }
        let shown = AiProtocol.shorten(name, 40)
        let bad = AiError(loc("A {0} step had values that don't make sense and was left out.", shown))
        let noPage = AiError(loc("A {0} step named a page this document doesn't have (it has {1}) and was left out.", shown, CoreLanguage.number(pageCount)))
        // Arguments come as a JSON string (OpenAI) or an object (Ollama).
        var args: [String: Any] = [:]
        if let a = f["arguments"] {
            if let s = a as? String {
                guard let parsed = AiProtocol.parse(s.isEmpty ? "{}" : s), let object = parsed as? [String: Any] else { return .failure(bad) }
                args = object
            } else if let object = a as? [String: Any] {
                args = object
            } else if !(a is NSNull) {
                return .failure(bad)
            }
        }
        func str(_ key: String) -> String? {
            if let s = args[key] as? String { return s }
            if let n = args[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                // .NET's GetRawText of a number: what was written; an integer reads back the same.
                if let i = Int(exactly: n.doubleValue) { return String(i) }
                return n.stringValue
            }
            return nil
        }
        func int(_ key: String) -> Int? { str(key).flatMap { Int(AiText.trim($0)) } }
        func page() -> Int? { int("page").flatMap { $0 >= 1 && $0 <= pageCount ? $0 - 1 : nil } }
        func pageList() -> [Int]? {
            guard let s = str("pages").map(AiText.trim), !s.isEmpty, s.utf16.count <= maxPagesChars else { return nil }
            if s.caseInsensitiveCompare("all") == .orderedSame { return Array(0..<pageCount) }
            let parsed = PageRange.tryParse(s, pageCount)
            return parsed.ok && !parsed.pages.isEmpty ? parsed.pages : nil
        }
        func words(_ key: String, _ max: Int) -> String? {
            guard let s = str(key) else { return nil }
            let t = clean(s)
            return !t.isEmpty && t.utf16.count <= max ? t : nil
        }
        switch name {
        case "go_to_page":
            guard let go = page() else { return .failure(noPage) }
            return .success(AskEditStep(.goToPage, pages: [go]))
        case "rotate_pages":
            guard let pages = pageList() else { return .failure(noPage) }
            let degrees = int("degrees").map { (($0 % 360) + 360) % 360 } ?? -1
            guard [90, 180, 270].contains(degrees) else { return .failure(bad) }
            return .success(AskEditStep(.rotatePages, pages: pages, degrees: degrees))
        case "delete_pages":
            guard let pages = pageList() else { return .failure(noPage) }
            if pages.count >= pageCount { return .failure(AiError(loc("A step deleting every page was left out: a PDF keeps at least one page."))) }
            return .success(AskEditStep(.deletePages, pages: pages))
        case "add_bookmark":
            guard let p = page() else { return .failure(noPage) }
            guard let title = words("title", maxTitleChars) else { return .failure(bad) }
            return .success(AskEditStep(.addBookmark, pages: [p], text: title))
        case "highlight_text":
            guard let text = words("text", maxTextChars) else { return .failure(bad) }
            return .success(AskEditStep(.highlightText, text: text))
        case "find_for_redaction":
            var kinds = Set<RedactionPattern>()
            if let k = args["kinds"] {
                guard let list = k as? [Any] else { return .failure(bad) }
                for item in list {
                    guard let s = item as? String, let pattern = patternNames[s.lowercased()] else { return .failure(bad) }
                    kinds.insert(pattern)
                }
            }
            var phrase: String? = ""
            if let raw = str("text"), !AiText.trim(raw).isEmpty { phrase = words("text", maxTextChars) }
            guard let phrase, !(kinds.isEmpty && phrase.isEmpty) else { return .failure(bad) }
            return .success(AskEditStep(.findForRedaction, text: phrase, patterns: kinds))
        default:
            return .failure(AiError(loc("A step called {0}, which isn't one of the commands offered, was left out.", shown)))
        }
    }

    /// Text from the model as one line without control characters, trimmed.
    private static func clean(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(u)
            }
        }
        return AiText.trim(String(scalars))
    }

    /// A step's pages once `deleted` (0-based, of the document as it was asked about) are gone: each page after them moves
    /// up. Nil when every page the step needs went (it is then left out and said).
    public static func afterDelete(_ step: AskEditStep, _ deleted: DeletedPages) -> AskEditStep? {
        if deleted.isEmpty || step.pages.isEmpty { return step }
        let kept: [Int] = step.pages.filter { !deleted.contains($0) }.map { (p: Int) -> Int in p - deleted.countBelow(p) }
        if kept.isEmpty { return nil }
        var moved = step
        moved.pages = kept
        return moved
    }

    /// True when the server's refusal says the model can't call tools (Ollama: "… does not support tools").
    public static func isNoToolsError(_ status: Int, _ serverMessage: String?) -> Bool {
        guard [400, 404, 422, 500].contains(status), let m = serverMessage, m.range(of: "tool", options: .caseInsensitive) != nil else { return false }
        return ["support", "not allowed", "unknown"].contains { m.range(of: $0, options: .caseInsensitive) != nil }
    }
}
