import Foundation
import PrintCore

/// The self-test's `--strings` (roadmap 3.7, Inkvolt Print for Mac's `--report … --strings`): the interface's language and
/// whether it is complete. Each String Catalog's keys (`Localizable`, the app's own text; `PdfStrings`, PdfCore's;
/// `CoreStrings`, PrintCore's and PrintMac's), as assemble.sh wrote them into the bundle (`CatalogKeys.json`,
/// catalog-keys.py), against the compiled Spanish table, every key missing there named; at the end of the run, the
/// sentences asked for that had no Spanish (`CoreLanguage.untranslated`). A run in Spanish (`--lang es`, or
/// `-AppleLanguages '(es)'`) passes only when nothing is missing; in English the catalogs are counted the same way.
enum ReportStrings {
    /// The language, the catalogs against their Spanish, the formats: written as the run starts.
    static func catalogLines() -> (lines: [String], missing: Int) {
        var lines = ["strings: language \(AppLanguage.current) (macOS offers \(Set(Bundle.main.localizations).sorted().joined(separator: ", "))); "
            + "locale \(Locale.current.identifier); Spanish ready \(AppLanguage.spanishReady); Settings › Language \(AppLanguage.choice.rawValue)"]
        var missing = 0
        let catalogs = catalogKeys()
        for table in AppLanguage.tables {
            // Not the compiled English table: xcstringstool writes into it only the keys whose English differs from the key.
            guard let catalog = catalogs[table], !catalog.isEmpty else {
                missing += 1
                lines.append("  \(table): the catalog's keys are not in the bundle (CatalogKeys.json)")
                continue
            }
            let spanish = Set(AppLanguage.sentences(table, "es").keys)
            let left = catalog.subtracting(spanish).sorted()
            missing += left.count
            lines.append("  \(table): \(catalog.count - left.count) of the catalog's \(catalog.count) sentences in Spanish, \(left.count) without")
            lines += left.prefix(40).map { "    untranslated: \($0)" }
        }
        let number = 1_234_567.89.formatted(.number.precision(.fractionLength(2)))
        let date = Date(timeIntervalSince1970: 1_793_000_000).formatted(date: .long, time: .shortened)
        lines.append("  formats: \(number); \(date); \(CoreLanguage.number(12_345)); \(loc("Page {0} of {1}", 2, 14))")
        return (lines, missing)
    }

    /// What was asked for during the run without Spanish, and the verdict: written as the run ends.
    static func endLines(catalogMissing: Int) -> [String] {
        let asked = CoreLanguage.untranslated
        var lines = asked.prefix(60).map { "  asked without Spanish: \($0)" }
        let missing = catalogMissing + asked.count
        lines.append("\(missing == 0 ? "PASS" : "FAIL") strings: \(missing == 0 ? "complete" : "\(missing) untranslated") (\(AppLanguage.current))")
        return lines
    }

    /// Each catalog's keys, as the build wrote them: table name → its keys.
    private static func catalogKeys() -> [String: Set<String>] {
        guard let url = Bundle.main.url(forResource: "CatalogKeys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tables = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return tables.mapValues(Set.init)
    }
}
