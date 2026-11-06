import Foundation
import PrintCore

/// `--report … --strings` (roadmap 3.7): the interface's language and whether it is complete. Each String Catalog's keys
/// (`Localizable`, the app's own text, every key Xcode extracted from it; `CoreStrings`, PrintCore's and PrintMac's), as the
/// build's "Catalog keys" phase wrote them into the bundle (`CatalogKeys.json`, catalog-keys.py), against the compiled
/// Spanish table, every key missing there named; then the sentences PrintCore was asked for during the run that had no
/// Spanish (`CoreLanguage.untranslated`). "complete" only when nothing is missing, so a report run in
/// Spanish (`-AppleLanguages '(es)'` or `--lang es`) fails on an untranslated string.
enum ReportStrings {
    static func lines() -> [String] {
        var lines = ["language: \(AppLanguage.current) (macOS offers \(Bundle.main.localizations.sorted().joined(separator: ", "))); "
            + "locale \(Locale.current.identifier); Spanish ready \(AppLanguage.spanishReady); Settings › Language \(AppLanguage.choice.rawValue)"]
        var missing = 0
        let catalogs = catalogKeys()
        for table in ["Localizable", "CoreStrings"] {
            // Not the compiled English table: Xcode writes into it only the keys whose English differs from the key.
            guard let catalog = catalogs[table], !catalog.isEmpty else {
                missing += 1
                lines.append("  \(table): the catalog's keys are not in the bundle (CatalogKeys.json)")
                continue
            }
            let spanish = keys(table, "es")
            let left = catalog.subtracting(spanish).sorted()
            missing += left.count
            lines.append("  \(table): \(catalog.count - left.count) of the catalog's \(catalog.count) sentences in Spanish, \(left.count) without")
            lines += left.prefix(40).map { "    untranslated: \($0)" }
        }
        let asked = CoreLanguage.untranslated
        missing += asked.count
        lines += asked.map { "  asked without Spanish: \($0)" }
        let number = 1_234_567.89.formatted(.number.precision(.fractionLength(2)))
        let date = Date(timeIntervalSince1970: 1_793_000_000).formatted(date: .long, time: .shortened)
        lines.append("  formats: \(number); \(date)")
        lines.append("strings: \(missing == 0 ? "complete" : "\(missing) untranslated")")
        return lines
    }

    /// Each catalog's keys, as the build wrote them: table name → its keys.
    private static func catalogKeys() -> [String: Set<String>] {
        guard let url = Bundle.main.url(forResource: "CatalogKeys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tables = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return tables.mapValues(Set.init)
    }

    /// The keys of a compiled table (`<language>.lproj/<table>.strings`): only the translated ones in a language other
    /// than the source's.
    private static func keys(_ table: String, _ language: String) -> Set<String> {
        guard let url = Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        var keys = Set(dictionary.keys)
        // Plural and device variations live in the .stringsdict beside it.
        if let dict = Bundle.main.url(forResource: table, withExtension: "stringsdict", subdirectory: nil, localization: language),
           let variations = NSDictionary(contentsOf: dict) as? [String: Any] {
            keys.formUnion(variations.keys)
        }
        return keys
    }
}
