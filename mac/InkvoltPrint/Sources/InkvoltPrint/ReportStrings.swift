import Foundation
import PrintCore

/// `--report … --strings` (roadmap 3.7): the interface's language and whether it is complete. Each table the app has in
/// English (`Localizable`, the app's own text, every key Xcode extracted from it; `CoreStrings`, PrintCore's and PrintMac's)
/// against the same table in Spanish, every key missing there named; then the sentences PrintCore was asked for during the
/// run that had no Spanish (`CoreLanguage.untranslated`). "complete" only when nothing is missing, so a report run in
/// Spanish (`-AppleLanguages '(es)'` or `--lang es`) fails on an untranslated string.
enum ReportStrings {
    static func lines() -> [String] {
        var lines = ["language: \(AppLanguage.current) (macOS offers \(Bundle.main.localizations.sorted().joined(separator: ", "))); "
            + "locale \(Locale.current.identifier); Spanish ready \(AppLanguage.spanishReady); Settings › Language \(AppLanguage.choice.rawValue)"]
        var missing = 0
        for table in ["Localizable", "CoreStrings"] {
            // Xcode writes the source language's table with only the keys whose English differs from the key, so the
            // English side counts what both tables name; check-strings.sh checks every key the compiler extracted.
            let english = keys(table, "en"), spanish = keys(table, "es")
            let left = english.subtracting(spanish).sorted()
            missing += left.count
            lines.append("  \(table): \(spanish.count) sentences in Spanish, \(left.count) of the English table's \(english.count) without")
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

    /// The keys of a compiled table (`<language>.lproj/<table>.strings`); Xcode writes every key of a catalog into the
    /// source language's and only the translated ones into another's.
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
