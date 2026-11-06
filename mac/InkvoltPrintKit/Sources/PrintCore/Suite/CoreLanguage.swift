import Foundation
import Synchronization

/// The language of the text PrintCore (and PrintMac) writes for an interface: English unless an app installs another
/// (Windows' `CoreLanguage` and `CoreStrings`). Inkvolt Print for Mac installs Spanish at launch from its
/// `CoreStrings.xcstrings` when macOS (or Settings › Language) runs it in Spanish; the command lines (`status --all`,
/// `print`) and Inkvolt PDF never do, so their output stays English whatever the Mac's language.
///
/// Every sentence is keyed by its English, as `loc` is called with it; `{0}`, `{1}`… stand for the values, as in
/// Windows' resources, so a Spanish sentence written there is used here word for word. `CoreStringsTests` checks that
/// every `loc` call in the sources is in the catalog with its Spanish and the same placeholders.
public enum CoreLanguage {
    /// The interface's language and its sentences, keyed by English.
    public struct Table: Sendable {
        /// The language code ("es"), for the report and `Locale`.
        public let language: String
        public let sentences: [String: String]
        /// Numbers and dates: the Mac's regional format in the interface's language (es_US groups 1,200; es_ES 12.000).
        public let locale: Locale
        private let missed = Missed()

        public init(language: String, sentences: [String: String], locale: Locale? = nil) {
            self.language = language
            self.sentences = sentences
            self.locale = locale ?? Locale(identifier: language)
        }

        /// The English sentences asked of this table that it has no translation of, each shown in English.
        public var untranslated: [String] { missed.list.withLock { $0.sorted() } }

        func text(_ english: String) -> String {
            if let text = sentences[english], !text.isEmpty { return text }
            missed.list.withLock { _ = $0.insert(english) }
            return english
        }
    }

    private final class Missed: Sendable {
        let list = Mutex<Set<String>>([])
    }

    /// A table for the current task only (`withTable`), over the installed one; nil inside is English.
    private struct Scope: Sendable { let table: Table? }

    @TaskLocal private static var scoped: Scope?
    private static let installed = Mutex<Table?>(nil)

    /// The app's table, installed once at launch before the first window; nil (the default) is English. Tests never
    /// install one: they use `withTable`, which other suites running at the same time don't see.
    public static func install(_ table: Table?) {
        installed.withLock { $0 = table }
    }

    /// `body` with `table` (nil: English) as the language of this task and the tasks it starts, whatever is installed.
    public static func withTable<R>(_ table: Table?, _ body: () throws -> R) rethrows -> R {
        try $scoped.withValue(Scope(table: table), operation: body)
    }

    /// The table in effect: this task's (`withTable`), else the installed one; nil is English.
    public static var table: Table? {
        if let scoped { return scoped.table }
        return installed.withLock { $0 }
    }

    /// The language code text comes out in: "en" unless a table is in effect.
    public static var language: String { table?.language ?? "en" }

    /// The locale numbers are written in: the table's, else English as the command lines write them (.NET's invariant
    /// culture: 12,345).
    public static var locale: Locale { table?.locale ?? english }

    private static let english = Locale(identifier: "en_US")

    /// A whole number as .NET's N0 writes it, grouped in `locale`'s way: 12,345 in English, 12.345 in Spain. The one
    /// formatter for every number in the interface's sentences.
    public static func number(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }

    /// The English sentences asked for while the table in effect was in use that it has no translation of (the report's
    /// check): each is shown in English, never as an empty line.
    public static var untranslated: [String] { table?.untranslated ?? [] }

    /// `english` in the interface's language.
    static func text(_ english: String) -> String {
        guard let table else { return english }
        return table.text(english)
    }

    /// `{0}`, `{1}`… in `format` replaced by `values` (as interpolation writes them); a placeholder without a value stays.
    static func fill(_ format: String, _ values: [Any]) -> String {
        guard !values.isEmpty, format.contains("{") else { return format }
        var out = ""
        var rest = format[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let i = Int(after[..<close]), i >= 0, i < values.count {
                out += String(describing: values[i])
                rest = after[after.index(after: close)...]
            } else {
                out.append("{")
                rest = after
            }
        }
        return out + rest
    }
}

/// A sentence the interface shows, in its language (`CoreLanguage`): `loc("Paper jam")`, `loc("About {0} pages left", n)`.
/// The key is a literal written in English, so `CoreStringsTests` finds it in the sources (or a `LocKey`'s, which a static
/// table keeps). Values are written as interpolation writes them; format a number (`CoreLanguage.number`) or a date first.
public func loc(_ english: String, _ values: Any...) -> String {
    CoreLanguage.fill(CoreLanguage.text(english), values)
}

/// The same English that Spanish says two ways ("Black": "negro", or "negra" after "tinta"): the catalog's key is
/// `english [context]`; English shows `english`.
public func loc(_ english: String, context: String, _ values: Any...) -> String {
    let key = "\(english) [\(context)]"
    let text = CoreLanguage.text(key)
    return CoreLanguage.fill(text == key ? english : text, values)
}

/// A sentence a static table keeps in English by id ("jamInPrinter": "Paper jam"), turned into the interface's language
/// only where it is shown (`text`), so a lookup translates one sentence, not the table. Its literal is a key
/// `CoreStringsTests` finds, as `loc`'s.
public struct LocKey: Hashable, Sendable {
    public let english: String
    public let context: String?

    public init(_ english: String, context: String? = nil) {
        self.english = english
        self.context = context
    }

    /// The sentence in the interface's language.
    public var text: String { context.map { loc(english, context: $0) } ?? loc(english) }
}
