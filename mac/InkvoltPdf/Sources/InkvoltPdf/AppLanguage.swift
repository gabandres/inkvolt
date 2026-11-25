import Foundation
import PrintCore

/// The interface's language (roadmap 3.7, the Windows app's `AppLanguage`; Inkvolt Print for Mac's), chosen once at
/// launch: `--lang en|es|pt-BR` for a run (the self-test's), else macOS's own choice for this app, which is Settings ›
/// Language here and the app's line in System Settings › General › Language & Region › Applications (both the
/// `AppleLanguages` key in the app's own settings), else the Mac's languages.
///
/// Every sentence the app, PdfCore and PrintCore show goes through `loc` (PrintCore's `CoreLanguage`), keyed by its
/// English with `{0}`, `{1}`… as in Windows' resources, so Windows' translations are used word for word. Translations
/// come from three String Catalogs compiled into the bundle by assemble.sh: `Localizable` (the app's own text),
/// `PdfStrings` (PdfCore's) and Inkvolt Print's `CoreStrings` (PrintCore's and PrintMac's, which Scan shows), installed
/// together as one table. AppKit's own text (the Open and Save panels, the text fields' menus, Services) follows the
/// bundle's localization (`es.lproj`, `pt-BR.lproj`). Numbers and dates: the Mac's region in the interface's language
/// (`Locale.current`). The command line (`--batch`, `--watch`, `--fill`) runs before this and stays English, as on Windows.
enum AppLanguage {
    /// The Spanish translation is complete (every key of the catalogs; `PdfStringsTests` and the self-test's `--strings`
    /// check).
    static let spanishReady = true

    /// The Brazilian Portuguese translation is complete (every key of the catalogs; `PdfStringsTests` and the self-test's
    /// `--strings` check).
    static let portugueseReady = true

    /// The catalogs installed as the interface's table, the app's last so its own sentence wins.
    static let tables = ["CoreStrings", "PdfStrings", "Localizable"]

    enum Choice: String, CaseIterable {
        case system, english, spanish, portugueseBrazil
        /// The value `AppleLanguages` keeps for it; nil follows macOS.
        var languages: [String]? {
            switch self {
            case .system: nil
            case .english: ["en"]
            case .spanish: ["es"]
            case .portugueseBrazil: ["pt-BR"]
            }
        }

        /// What Settings › Language lists: each language in its own name, as macOS lists them.
        var title: String {
            switch self {
            case .system: loc("Same as macOS")
            case .english: "English" // English: a language's own name
            case .spanish: "Español" // English: a language's own name
            case .portugueseBrazil: "Português (Brasil)" // English: a language's own name
            }
        }
    }

    /// What Settings › Language shows: the app's own `AppleLanguages`, as Settings or System Settings saved it.
    static var choice: Choice {
        let saved = (UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String])?.first
        switch saved.map(language) {
        case "es": return .spanish
        case "pt-BR": return .portugueseBrazil
        case "en": return .english
        default: return .system
        }
    }

    /// Keeps the choice for the next launch (macOS reads `AppleLanguages` once, as an app starts).
    static func save(_ choice: Choice) {
        if let languages = choice.languages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The language the interface is in since launch: "es", "pt-BR" or "en".
    nonisolated(unsafe) static private(set) var current = "en"

    /// Picks the language before the menu bar and the first window: `--lang` (or English for an unready/unsupported
    /// Portuguese variant such as pt-PT) for this run only, through the arguments domain, which nothing saves; then
    /// installs the catalogs' sentences for it.
    static func apply(_ args: [String]) {
        let argument = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? language(args[$0 + 1]) : nil }
        if let forced = argument ?? fallbackForSystemOrReadiness() {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["AppleLanguages"] = [forced]
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        let preferred = language(Bundle.main.preferredLocalizations.first ?? "en")
        current = (preferred == "es" || preferred == "pt-BR") ? preferred : "en"
        guard current != "en" else { return }
        var sentences: [String: String] = [:]
        for table in tables { sentences.merge(Self.sentences(table, current)) { _, mine in mine } }
        CoreLanguage.install(CoreLanguage.Table(language: current, sentences: sentences, locale: .current))
    }

    /// Forces English if the chosen/system language isn't ready or is a non-BR Portuguese variant (pt-PT).
    private static func fallbackForSystemOrReadiness() -> String? {
        switch choice {
        case .spanish: return spanishReady ? nil : "en"
        case .portugueseBrazil: return portugueseReady ? nil : "en"
        case .english: return nil
        case .system:
            for pref in Locale.preferredLanguages {
                let norm = language(pref)
                if norm == "es" { return spanishReady ? nil : "en" }
                if norm == "pt-BR" { return portugueseReady ? nil : "en" }
                if norm == "pt" || norm == "en" { return "en" }
            }
            return nil
        }
    }

    /// The compiled table `<language>.lproj/<table>.strings`: English sentence → its translation, without the sentences
    /// the catalog has no translation of (xcstringstool writes them empty), so every user of the table sees only real ones.
    static func sentences(_ table: String, _ language: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dictionary.filter { !$0.value.isEmpty }
    }

    private static var bundleId: String { Bundle.main.bundleIdentifier ?? "com.bermudezsystems.InkvoltPdf" }

    /// "es-419", "es_PR", "ES" → "es"; "pt-BR", "pt_BR", "pt-Latn-BR" → "pt-BR"; "pt-PT" → "pt".
    private static func language(_ code: String) -> String {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split { $0 == "-" || $0 == "_" }
            .map(String.init)
        guard let first = parts.first else { return "" }
        if first == "pt", parts.count >= 2, parts.last == "br" { return "pt-BR" }
        return first
    }
}
