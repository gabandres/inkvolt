import Foundation
import PrintCore

/// The interface's language (roadmap 3.7, the Windows app's `AppLanguage`; Inkvolt Print for Mac's), chosen once at
/// launch: `--lang en|es` for a run (the self-test's), else macOS's own choice for this app, which is Settings › Language
/// here and the app's line in System Settings › General › Language & Region › Applications (both the `AppleLanguages` key
/// in the app's own settings), else the Mac's languages.
///
/// Every sentence the app, PdfCore and PrintCore show goes through `loc` (PrintCore's `CoreLanguage`), keyed by its
/// English with `{0}`, `{1}`… as in Windows' resources, so Windows' Spanish is used word for word. The Spanish comes from
/// three String Catalogs compiled into the bundle by assemble.sh: `Localizable` (the app's own text), `PdfStrings`
/// (PdfCore's) and Inkvolt Print's `CoreStrings` (PrintCore's and PrintMac's, which Scan shows), installed together as
/// one table. AppKit's own text (the Open and Save panels, the text fields' menus, Services) follows the bundle's
/// localization, es.lproj. Numbers and dates: the Mac's region in the interface's language (`Locale.current`). The command
/// line (`--batch`, `--watch`, `--fill`) runs before this and stays English, as on Windows.
enum AppLanguage {
    /// The Spanish translation is complete (every key of the catalogs; `PdfStringsTests` and the self-test's `--strings`
    /// check). While false, the interface is always English, Settings › Language is hidden and a saved choice is ignored
    /// (only `--lang` still picks Spanish): the switch for a language whose strings are still being written.
    static let spanishReady = true

    /// The catalogs installed as the interface's table, the app's last so its own sentence wins.
    static let tables = ["CoreStrings", "PdfStrings", "Localizable"]

    enum Choice: String, CaseIterable {
        case system, english, spanish
        /// The value `AppleLanguages` keeps for it; nil follows macOS.
        var languages: [String]? {
            switch self {
            case .system: nil
            case .english: ["en"]
            case .spanish: ["es"]
            }
        }

        /// What Settings › Language lists: each language in its own name, as macOS lists them.
        var title: String {
            switch self {
            case .system: loc("Same as macOS")
            case .english: "English" // English: a language's own name
            case .spanish: "Español" // English: a language's own name
            }
        }
    }

    /// What Settings › Language shows: the app's own `AppleLanguages`, as Settings or System Settings saved it.
    static var choice: Choice {
        let saved = (UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String])?.first
        return saved.map(language) == "es" ? .spanish : saved.map(language) == "en" ? .english : .system
    }

    /// Keeps the choice for the next launch (macOS reads `AppleLanguages` once, as an app starts).
    static func save(_ choice: Choice) {
        if let languages = choice.languages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The language the interface is in since launch: "es" or "en".
    nonisolated(unsafe) static private(set) var current = "en"

    /// Picks the language before the menu bar and the first window: `--lang` (or English while Spanish isn't ready) for
    /// this run only, through the arguments domain, which nothing saves; then installs the catalogs' sentences for it.
    static func apply(_ args: [String]) {
        let argument = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? language(args[$0 + 1]) : nil }
        if let forced = argument ?? (spanishReady ? nil : "en") {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["AppleLanguages"] = [forced]
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        current = language(Bundle.main.preferredLocalizations.first ?? "en") == "es" ? "es" : "en"
        guard current == "es" else { return }
        var sentences: [String: String] = [:]
        for table in tables { sentences.merge(Self.sentences(table, "es")) { _, mine in mine } }
        CoreLanguage.install(CoreLanguage.Table(language: "es", sentences: sentences, locale: .current))
    }

    /// The compiled table `<language>.lproj/<table>.strings`: English sentence → its translation.
    static func sentences(_ table: String, _ language: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dictionary
    }

    private static var bundleId: String { Bundle.main.bundleIdentifier ?? "com.bermudezsystems.InkvoltPdf" }

    /// "es-419", "es_PR", "ES" → "es".
    private static func language(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }
}
