import Foundation
import PrintCore

/// The interface's language (roadmap 3.7, the Windows app's `AppLanguage`), chosen once at launch: the dev aids' `--lang
/// en|es`, else macOS's own choice for this app, which is Settings › Language here and the app's line in System Settings ›
/// General › Language & Region › Applications (both are the `AppleLanguages` key in the app's own settings), else the
/// Mac's languages. SwiftUI and `String(localized:)` read `Localizable.xcstrings` in that language; PrintCore's and
/// PrintMac's sentences come from `CoreStrings.xcstrings`, installed as `CoreLanguage.table`. Numbers and dates follow
/// the Mac's region in the interface's language (`Locale.current`). The command lines (`status --all`, `print`) start
/// before this and stay English, as on Windows.
enum AppLanguage {
    /// The Spanish translation is complete (every string of both catalogs; `CoreStringsTests`, `check-strings.sh` and the
    /// report's `--strings` check). While false, the interface is always English, Settings › Language is hidden and a saved
    /// choice is ignored (only `--lang` still picks Spanish): the switch for a language whose strings are still being written.
    static let spanishReady = true

    enum Choice: String, CaseIterable, Identifiable {
        case system, english, spanish
        var id: String { rawValue }
        /// The value `AppleLanguages` keeps for it; nil follows macOS.
        var languages: [String]? {
            switch self {
            case .system: nil
            case .english: ["en"]
            case .spanish: ["es"]
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

    /// Picks the language before the first window: `--lang` (or English while Spanish isn't ready) for this run only, through
    /// the arguments domain, which nothing saves; then installs PrintCore's sentences for it.
    static func apply(_ args: [String]) {
        let argument = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? language(args[$0 + 1]) : nil }
        if let forced = argument ?? (spanishReady ? nil : "en") {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["AppleLanguages"] = [forced]
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        current = language(Bundle.main.preferredLocalizations.first ?? "en") == "es" ? "es" : "en"
        guard current == "es" else { return }
        CoreLanguage.table = CoreLanguage.Table(language: "es", sentences: sentences("es"), locale: .current)
    }

    /// The compiled `CoreStrings` table of `language` (es.lproj/CoreStrings.strings): English sentence → its translation.
    static func sentences(_ language: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: "CoreStrings", withExtension: "strings", subdirectory: nil, localization: language),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }

    private static var bundleId: String { Bundle.main.bundleIdentifier ?? "com.bermudezsystems.InkvoltPrint" }

    /// "es-419", "es_PR", "ES" → "es".
    private static func language(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }
}
