import Foundation
import PrintCore

/// A language offered for translating into, with its tag for the copy's /Lang.
public struct TranslationLanguage: Sendable, Equatable {
    public let name: String
    public let tag: String
    public init(_ name: String, _ tag: String) {
        self.name = name
        self.tag = tag
    }
}

/// A paragraph's text to translate, once however often it repeats: the pieces it is sent in, the page it is first on.
/// `marked`: its pieces carry the paragraph's looks as markup (`TranslationMarkup`): sent whole, the model asked to keep the tags.
public struct TranslationJob: Sendable, Equatable {
    public let text: String
    public let page: Int
    public let pieces: [String]
    public let marked: Bool
    public init(_ text: String, _ page: Int, _ pieces: [String], marked: Bool = false) {
        self.text = text
        self.page = page
        self.pieces = pieces
        self.marked = marked
    }
}

/// How far a translation has come: texts finished (translated or given up on), of how many, the page (0-based) of the
/// text being sent, and how many failed.
public struct TranslationProgress: Sendable, Equatable {
    public let done: Int, total: Int, page: Int, failed: Int
}

/// The model's answers so far; a stopped or failed run keeps what it got.
public struct TranslationAnswers: Sendable {
    /// Source text → its translation.
    public var done: [String: String] = [:]
    /// Source text → why its answer wasn't used ("it …").
    public var failed: [String: String] = [:]
    public var cancelled = false
    /// Why the run gave up before the end (worded for the user); nil when it didn't.
    public var stoppedBecause: String?
    public init() {}
}

/// Timings of a run, shortened by the tests (seconds).
public struct TranslationSettings: Sendable {
    /// The longest one request may take, first word to last: a stream that never ends, or sends only keep-alives, stops here.
    public var replyDeadline = 15.0 * 60
    /// The waits before asking again after a failure that may pass (a busy server, a dropped connection).
    public var retryWaits: [Double] = [2, 8]
    /// Paragraphs failing in a row for the connection's reasons before the run stops.
    public var failuresBeforeStopping = 3
    public init() {}
}

/// Asks the endpoint once (in the app, `AiClient.chat`).
public typealias TranslationChat = @Sendable ([AiMessage], (@Sendable (String) -> Void)?, CancelToken) async throws -> AiReply

extension Translation {
    public static let languages: [TranslationLanguage] = [
        .init("English", "en"), .init("Spanish", "es"), .init("French", "fr"), .init("German", "de"), .init("Italian", "it"),
        .init("Portuguese", "pt"), .init("Dutch", "nl"), .init("Polish", "pl"), .init("Swedish", "sv"), .init("Danish", "da"),
        .init("Norwegian", "no"), .init("Finnish", "fi"), .init("Czech", "cs"), .init("Romanian", "ro"), .init("Hungarian", "hu"),
        .init("Greek", "el"), .init("Russian", "ru"), .init("Ukrainian", "uk"), .init("Turkish", "tr"), .init("Arabic", "ar"),
        .init("Hebrew", "he"), .init("Persian", "fa"), .init("Hindi", "hi"), .init("Bengali", "bn"),
        .init("Chinese (Simplified)", "zh-Hans"), .init("Chinese (Traditional)", "zh-Hant"), .init("Japanese", "ja"),
        .init("Korean", "ko"), .init("Vietnamese", "vi"), .init("Indonesian", "id"), .init("Thai", "th"),
    ]

    /// How many estimated tokens of a paragraph one request carries, so the prompt and its answer fit a model reading
    /// `contextTokens`.
    public static func pieceTokens(_ contextTokens: Int) -> Int {
        max(100, min(AiText.inputTokens(contextTokens), AiText.answerTokens(contextTokens)) * 3 / 4)
    }

    /// What goes out: each distinct text, a long one in pieces that fit the model. Markup goes only with a text sent
    /// whole: a piece could cut a stretch's tags apart, so a text in pieces goes without its looks.
    public static func jobs(_ plan: TranslationPlan, _ pieceTokens: Int) -> [TranslationJob] {
        plan.texts.map { job($0.text, $0.page, plan.marked.contains($0.text), pieceTokens) }
    }

    static func job(_ text: String, _ page: Int, _ marked: Bool, _ tokens: Int) -> TranslationJob {
        let pieces = AiText.pieces(text, tokens)
        if pieces.count > 1 && marked { return TranslationJob(text, page, AiText.pieces(TranslationMarkup.plain(text), tokens)) }
        return TranslationJob(text, page, pieces, marked: marked)
    }

    /// The requests, as the "what is sent, where" window shows them.
    public static func requests(_ jobs: [TranslationJob], _ language: String) -> [[AiMessage]] {
        jobs.flatMap { j in j.pieces.map { TranslationText.request($0, language, marked: j.marked) } }
    }

    private static var noEnd: String { loc("its answer didn't end in time") }

    /// Sends the jobs one at a time and keeps each answer it can use. A reply that can't be used is asked for once more;
    /// a failure that may pass (a busy server, a dropped connection) is tried again after a wait. The run stops, keeping
    /// what it has, on a refusal or redirect from the server and after a few paragraphs in a row fail for the connection.
    /// Stopping is not an error: the answers come back with `cancelled`.
    public static func translate(_ jobs: [TranslationJob], _ language: String, _ chat: TranslationChat, settings: TranslationSettings = .init(),
                                 progress: ((TranslationProgress) -> Void)? = nil, cancel: CancelToken = CancelToken()) async -> TranslationAnswers {
        var answers = TranslationAnswers()
        var failuresInRow = 0
        for (i, job) in jobs.enumerated() {
            progress?(TranslationProgress(done: i, total: jobs.count, page: job.page, failed: answers.failed.count))
            do {
                try cancel.check()
                let (text, problem) = try await translateOne(job, language, chat, settings, cancel)
                if let text { answers.done[job.text] = text } else { answers.failed[job.text] = problem! }
                // A bad answer says nothing about the next; answers that don't end say the endpoint isn't working.
                failuresInRow = problem == noEnd ? failuresInRow + 1 : 0
                if failuresInRow >= settings.failuresBeforeStopping {
                    answers.stoppedBecause = loc("The endpoint's answers don't come to an end, so the translation stopped.")
                    break
                }
            } catch is CancellationError where cancel.isCancelled {
                answers.cancelled = true
                break
            } catch let error as AiError {
                answers.failed[job.text] = loc("the endpoint didn't answer")
                failuresInRow += 1
                let s = error.status
                if s == 401 || s == 403 || s == 404 || (300..<400).contains(s) || failuresInRow >= settings.failuresBeforeStopping {
                    answers.stoppedBecause = error.message
                    break
                }
            } catch {
                // A body that can't even be read: what was already translated is kept.
                answers.failed[job.text] = loc("the endpoint's answer couldn't be read")
                answers.stoppedBecause = loc("The endpoint sent something that can't be read as an answer.")
                break
            }
        }
        progress?(TranslationProgress(done: jobs.count, total: jobs.count, page: jobs.last?.page ?? 0, failed: answers.failed.count))
        return answers
    }

    /// One text's pieces in turn, joined. The text, or nil and why not. Connection failures throw `AiError` after their retries.
    private static func translateOne(_ job: TranslationJob, _ language: String, _ chat: TranslationChat, _ settings: TranslationSettings,
                                     _ cancel: CancelToken) async throws -> (String?, String?) {
        var parts: [String] = []
        for piece in job.pieces {
            let (text, problem) = try await translatePiece(piece, job.marked, language, chat, settings, cancel, depth: 0)
            guard let text else { return (nil, problem) }
            parts.append(text)
        }
        return (parts.joined(separator: " "), nil)
    }

    /// `marked`: the piece carries its paragraph's looks as markup (`TranslationJob.marked`).
    private static func translatePiece(_ piece: String, _ marked: Bool, _ language: String, _ chat: TranslationChat, _ settings: TranslationSettings,
                                       _ cancel: CancelToken, depth: Int) async throws -> (String?, String?) {
        var problem: String?
        for attempt in 0..<2 {
            let messages = TranslationText.request(piece, language, firm: attempt > 0, marked: marked)
            let (reply, cut) = try await ask(messages, piece, chat, settings, cancel)
            if cut == noEnd { return (nil, cut) } // it has had all the time a text gets
            if let cut {
                problem = cut
                continue
            }
            let answer = reply!
            // The model's own length limit cut it: half as much at a time.
            if answer.wasCutOff {
                if depth < 3 && piece.utf16.count > 40 {
                    // Without its markup: a half could cut a stretch's tags apart.
                    let whole = marked ? TranslationMarkup.plain(piece) : piece
                    let halves = AiText.pieces(whole, max(20, AiText.estimateTokens(whole) / 2))
                    var parts: [String] = []
                    for h in halves {
                        let (text, why) = try await translatePiece(h, false, language, chat, settings, cancel, depth: depth + 1)
                        guard let text else { return (nil, why) }
                        parts.append(text)
                    }
                    return (parts.joined(separator: " "), nil)
                }
                return (nil, loc("the model's answer was cut off by its length limit"))
            }
            var (clean, bad) = TranslationText.cleanReply(answer.text, piece, marked: marked)
            if let c = clean, TranslationText.slipsIntoAnotherScript(c, piece, language) {
                (clean, bad) = (nil, loc("its answer has words in another script"))
            }
            if let clean { return (clean, nil) }
            problem = bad
        }
        return (nil, problem)
    }

    /// One request, with its retries. A reply past its limit of length or time is stopped: (nil, why).
    private static func ask(_ messages: [AiMessage], _ piece: String, _ chat: TranslationChat, _ settings: TranslationSettings,
                            _ cancel: CancelToken) async throws -> (AiReply?, String?) {
        var retry = 0
        while true {
            let limit = AiDeadline(cancel)
            limit.cancelAfter(settings.replyDeadline)
            let guardian = TranslationText.ReplyGuard(piece)
            let token = limit.token
            do {
                let reply = try await chat(messages, { text in
                    if guardian.add(text) { token.cancel() }
                }, token)
                limit.finish()
                return guardian.isTooLong ? (nil, loc("its answer was far longer than the text")) : (reply, nil)
            } catch is CancellationError where !cancel.isCancelled {
                limit.finish()
                // Its own limit, not the user's Stop.
                return (nil, guardian.isTooLong ? loc("its answer was far longer than the text") : noEnd)
            } catch let error as AiError where retry < settings.retryWaits.count && (error.status == 0 || error.status == 429 || error.status >= 500) {
                limit.finish()
                // A stream stopped by this run's own limits comes back as the client's words for it: still its own limit.
                if token.isCancelled && !cancel.isCancelled {
                    return (nil, guardian.isTooLong ? loc("its answer was far longer than the text") : noEnd)
                }
                try await pause(settings.retryWaits[retry], cancel)
                retry += 1
            } catch {
                limit.finish()
                if token.isCancelled && !cancel.isCancelled && error is AiError {
                    return (nil, guardian.isTooLong ? loc("its answer was far longer than the text") : noEnd)
                }
                throw error
            }
        }
    }

    /// Waits `seconds`, or throws `CancellationError` as soon as `cancel` fires.
    static func pause(_ seconds: Double, _ cancel: CancelToken) async throws {
        try cancel.check()
        if seconds <= 0 { return }
        let once = AiOnce<Int>()
        let id = cancel.register { once.resume(with: .failure(CancellationError())) }
        defer { cancel.unregister(id) }
        let timer = DispatchWorkItem { once.resume(with: .success(0)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        _ = try await withCheckedThrowingContinuation { once.begin($0) }
    }

    /// The copy's name: "report (Spanish).pdf", with what a file name can't hold (on a Mac or a PC it may be copied to)
    /// taken out of the language as typed.
    public static func copyName(_ original: String, _ language: String) -> String {
        let stem = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
        let bad = Set("\"<>|:*?\\/".unicodeScalars)
        var lang = TranslationText.trim(String(String.UnicodeScalarView(language.unicodeScalars.filter { !bad.contains($0) && $0.value >= 32 })))
        if lang.utf16.count > 40 { lang = TranslationText.trim(String(decoding: Array(lang.utf16)[0..<40], as: UTF16.self)) }
        return lang.isEmpty ? "\(stem) (translated).pdf" : "\(stem) (\(lang)).pdf"
    }
}
