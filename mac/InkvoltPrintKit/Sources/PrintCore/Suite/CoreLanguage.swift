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
        /// Numbers and dates: the Mac's regional format in the interface's language (es_US groups 1,200; es_ES 1.200).
        public let locale: Locale

        public init(language: String, sentences: [String: String], locale: Locale? = nil) {
            self.language = language
            self.sentences = sentences
            self.locale = locale ?? Locale(identifier: language)
        }
    }

    /// What groups thousands in numbers written as .NET's N0: "," in English (the invariant culture, as the command lines
    /// write them), else the table's locale's.
    public static var groupingSeparator: String {
        table.map { $0.locale.groupingSeparator ?? "," } ?? ","
    }

    private static let installed = Mutex<Table?>(nil)
    private static let missed = Mutex<Set<String>>([])

    /// The table in use; nil (the default) is English. Set once at launch, before the first window (tests set and clear it).
    public static var table: Table? {
        get { installed.withLock { $0 } }
        set {
            installed.withLock { $0 = newValue }
            missed.withLock { $0 = [] }
        }
    }

    /// The language code text comes out in: "en" unless a table is installed.
    public static var language: String { table?.language ?? "en" }

    /// The English sentences asked for while a table was installed that it has no translation of (the report's check):
    /// each is shown in English, never as an empty line.
    public static var untranslated: [String] { missed.withLock { $0.sorted() } }

    /// `english` in the interface's language.
    static func text(_ english: String) -> String {
        guard let table = installed.withLock({ $0 }) else { return english }
        if let text = table.sentences[english], !text.isEmpty { return text }
        missed.withLock { _ = $0.insert(english) }
        return english
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
/// The key is always a literal written in English, so `CoreStringsTests` finds it in the sources. Values are written as
/// interpolation writes them; format a number or a date before passing it.
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
