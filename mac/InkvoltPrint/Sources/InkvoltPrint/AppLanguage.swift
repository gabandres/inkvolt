import Foundation
import PrintCore

/// The interface's language (roadmap 3.7, the Windows app's `AppLanguage`), chosen once at launch: the dev aids' `--lang
/// en|es|pt-BR`, else macOS's own choice for this app, which is Settings › Language here and the app's line in System
/// Settings › General › Language & Region › Applications (both are the `AppleLanguages` key in the app's own settings),
/// else the Mac's languages. SwiftUI and `String(localized:)` read `Localizable.xcstrings` in that language; PrintCore's
/// and PrintMac's sentences come from `CoreStrings.xcstrings`, installed as `CoreLanguage.table`. Numbers and dates follow
/// the Mac's region in the interface's language (`Locale.current`). The command lines (`status --all`, `print`) start
/// before this and stay English, as on Windows.
enum AppLanguage {
    /// The Spanish translation is complete (every string of both catalogs; `CoreStringsTests`, `check-strings.sh` and the
    /// report's `--strings` check).
    static let spanishReady = true

    /// The Brazilian Portuguese translation is complete (every string of both catalogs; `CoreStringsTests`,
    /// `check-strings.sh` and the report's `--strings` check).
    static let portugueseReady = true

    enum Choice: String, CaseIterable, Identifiable {
        case system, english, spanish, portugueseBrazil
        var id: String { rawValue }
        /// The value `AppleLanguages` keeps for it; nil follows macOS.
        var languages: [String]? {
            switch self {
            case .system: nil
            case .english: ["en"]
            case .spanish: ["es"]
            case .portugueseBrazil: ["pt-BR"]
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

    /// Picks the language before the first window: `--lang` (or English for an unready/unsupported Portuguese variant such
    /// as pt-PT) for this run only, through the arguments domain, which nothing saves; then installs PrintCore's sentences.
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
        CoreLanguage.install(CoreLanguage.Table(language: current, sentences: sentences(current), locale: .current))
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

    /// The compiled `CoreStrings` table of `language` (`es.lproj` / `pt-BR.lproj`): English sentence → its translation.
    static func sentences(_ language: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: "CoreStrings", withExtension: "strings", subdirectory: nil, localization: language),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }

    private static var bundleId: String { Bundle.main.bundleIdentifier ?? "com.bermudezsystems.InkvoltPrint" }

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
