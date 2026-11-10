import Foundation
import PrintCore

/// One page of a plan: where its table cells are and what else its text must keep clear of (pictures, figures, rules,
/// form fields); the cells of tables set sideways, by the quarter turns their text reads in (1 to 3), in that turn's
/// frame (`ExportPage.turned`).
public struct TranslationPagePlan: Sendable {
    public let page: Int
    public let cells: [RectD]
    public let obstacles: [RectD]
    public var turnedCells: [Int: [RectD]] = [:]
    public init(_ page: Int, _ cells: [RectD], _ obstacles: [RectD]) {
        self.page = page
        self.cells = cells
        self.obstacles = obstacles
    }
}

/// What a translation will do, read from the pages before anything is sent: the paragraphs' text, and what can't be
/// translated (scanned pages, text turned other than by quarter turns, pages with more pieces of text than can be
/// worked out).
public struct TranslationPlan: Sendable {
    public let data: [UInt8]
    public var password: String?
    /// The open password the copy keeps (AES-256 can't be saved without it); with `dropOpenPassword` it opens without one.
    public var openPassword: String?
    public var dropOpenPassword = false
    public let pages: [TranslationPagePlan]
    /// Each distinct paragraph text with words in it, in page order.
    public let texts: [(text: String, page: Int)]
    /// The texts of `texts` that carry their paragraph's looks as markup `TranslationMarkup.mark` wrote, as it wrote
    /// them (a paragraph's own "<b>" is text, not markup).
    public var marked: Set<String> = []
    /// Paragraphs with words in them, repeats included.
    public var paragraphCount = 0
    /// Paragraphs only of numbers or symbols: they stay as they are, nothing to send.
    public var noWords = 0
    /// Paragraphs that can't be rewritten (their reason says why), by page.
    public var blocked: [(page: Int, why: String)] = []
    public var scanPages: [Int] = []
    public var turnedTextPages: [Int] = []
    public var crowdedPages: [Int] = []
    public var unreadablePages: [Int] = []

    public init(data: [UInt8], pages: [TranslationPagePlan], texts: [(text: String, page: Int)]) {
        self.data = data
        self.pages = pages
        self.texts = texts
    }
}

/// Something in the copy to look at.
public enum TranslationFlagKind: Sendable, Equatable { case doesNotFit, notTranslated, charactersLeftOut }

/// A paragraph the reader should look at: its page, where it is and why. `noted`: it gets a comment in the copy.
/// Paragraphs a stopped run never reached don't: the summary names their pages, and a comment on each of thousands
/// would bury the rest.
public struct TranslationFlag: Sendable, Equatable {
    public let kind: TranslationFlagKind
    public let page: Int
    public let box: RectD
    public let message: String
    public var noted = true
}

/// What a translated copy holds.
public struct TranslationReport: Sendable {
    /// Paragraphs written in the target language, shrunk or not.
    public var translated = 0
    /// Those drawn smaller than the original to stay in their box.
    public var shrunk = 0
    /// Those that run past their box at the smallest size allowed (flagged).
    public var doNotFit = 0
    /// The model gave the same text back (a name, a code).
    public var unchanged = 0
    /// Paragraphs with words that stay in the original language: no usable answer, can't be rewritten, or the run was
    /// stopped first.
    public var notTranslated = 0
    /// Paragraphs of numbers or symbols: nothing to translate.
    public var noWords = 0
    public var flags: [TranslationFlag] = []
    /// The installed fonts that draw text the page's own fonts couldn't.
    public var fonts: [String] = []
    public var scanPages: [Int] = []
    public var turnedTextPages: [Int] = []
    public var crowdedPages: [Int] = []
    /// Pages that couldn't be read or rewritten: they stay as they were.
    public var failedPages: [Int] = []
    /// Comments left in the copy for the flags; past the limit they are only counted here.
    public var notes = 0
    public var cancelled = false
    public var stoppedBecause: String?
    public init() {}
}

/// The translated copy and what it holds. `data` is nil when nothing was translated.
public struct TranslationResult: Sendable {
    public let data: [UInt8]?
    public let report: TranslationReport
}

/// Translate side by side (roadmap 3.1; the Windows app's `Translation`): reads a PDF's paragraphs (`makePlan`), sends
/// each through the user's endpoint (`translate`) and writes a translated copy with each paragraph in its box (`apply`).
/// The original's bytes are only read. A model's answer is treated as hostile: it only ever becomes characters drawn
/// through fonts' encodings, and `TranslationText.cleanReply` and a limit on each answer's length and time decide whether
/// it is used at all.
public enum Translation {}
