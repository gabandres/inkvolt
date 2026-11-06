import Foundation
import Testing
@testable import PrintCore

/// The Spanish interface's sentences from PrintCore and PrintMac (roadmap 3.7, Windows' LocalizationTests): every
/// `loc("…")` in the sources is in the app's `CoreStrings.xcstrings` with its Spanish, the same `{0}`, `{1}`… and nothing
/// the sources no longer ask for; the text then reads in Spanish once the table is installed, and in English without it.
struct CoreStringsTests {
    /// mac/InkvoltPrint/Resources/CoreStrings.xcstrings, read in place: each key's Spanish ("" when it has none).
    static let spanish: [String: String] = {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/CoreStringsTests.swift
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("InkvoltPrint/Resources/CoreStrings.xcstrings")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: [String: Any]] else { return [:] }
        return strings.mapValues { entry in
            let es = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any]
            let unit = es?["stringUnit"] as? [String: Any]
            return unit?["state"] as? String == "translated" ? unit?["value"] as? String ?? "" : ""
        }
    }()

    /// Every key `loc` is called with in PrintCore's and PrintMac's sources: `loc("english")`, or `english [context]`.
    static let keysInSources: [String: String] = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() } // mac/InkvoltPrintKit
        var found: [String: String] = [:]
        for module in ["Sources/PrintCore", "Sources/PrintMac"] {
            let root = url.appendingPathComponent(module)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for (key, _) in keys(in: code.joined(separator: "\n")) { found[key] = file.lastPathComponent }
            }
        }
        return found
    }()

    /// The keys of `loc("…")` and `loc("…", context: "…")` calls in Swift source, then of `LocKey("…")` (the same with a
    /// context), the English a static table keeps.
    static func keys(in text: String) -> [(String, String?)] {
        keys(in: text, after: "loc(\"") + keys(in: text, after: "LocKey(\"")
    }

    private static func keys(in text: String, after opening: String) -> [(String, String?)] {
        var out: [(String, String?)] = []
        var rest = text[...]
        while let r = rest.range(of: opening) {
            let before = rest[..<r.lowerBound].last
            rest = rest[r.upperBound...]
            if let before, before.isLetter || before.isNumber || before == "_" || before == "." { continue }
            guard let (english, after) = literal(rest) else { continue }
            rest = after
            var context: String?
            let trimmed = after.drop { $0 == " " }
            if trimmed.hasPrefix(", context: \"") {
                let start = trimmed.dropFirst(", context: \"".count)
                if let (c, after2) = literal(start) {
                    context = c
                    rest = after2
                }
            }
            out.append((context.map { "\(english) [\($0)]" } ?? english, context))
        }
        return out
    }

    /// A Swift string literal's value up to its closing quote (`text` starts after the opening one), and what follows.
    private static func literal(_ text: Substring) -> (String, Substring)? {
        var value = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" { return (value, text[text.index(after: i)...]) }
            if c == "\n" { return nil }
            if c == "\\" {
                let n = text.index(after: i)
                guard n < text.endIndex else { return nil }
                switch text[n] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "u":
                    guard let close = text[n...].firstIndex(of: "}"),
                          let scalar = UInt32(text[text.index(n, offsetBy: 2)..<close], radix: 16).flatMap(Unicode.Scalar.init) else { return nil }
                    value.unicodeScalars.append(scalar)
                    i = text.index(after: close)
                    continue
                case "(": return nil // interpolation: a key is never built at run time
                default: value.append(text[n])
                }
                i = text.index(after: n)
                continue
            }
            value.append(c)
            i = text.index(after: i)
        }
        return nil
    }

    /// The tokens a sentence fills in: `{0}`, `{1}`… (loc's values) and a preset's own (`{date}`, `{time}`, `{date:yyyy}`,
    /// `{n:000}`): a brace, a name of letters and digits, an optional `:format` without spaces, a brace. Prose braces ("A {
    /// has no closing }", "{{") are not tokens.
    static func placeholders(_ s: String) -> [String] {
        var found: Set<String> = []
        var rest = s[...]
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            rest = after
            guard let close = after.firstIndex(of: "}") else { break }
            let inside = after[..<close]
            let name = inside.prefix { $0 != ":" }
            let format = inside.dropFirst(name.count)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  !format.contains(where: { $0 == " " || $0 == "{" }) else { continue }
            found.insert("{\(inside)}")
        }
        return found.sorted()
    }

    @Test func Placeholders_are_loc_values_and_preset_tokens() {
        #expect(Self.placeholders("About {0} pages left, {1}") == ["{0}", "{1}"])
        #expect(Self.placeholders("Receipt {date} {n:000}") == ["{date}", "{n:000}"])
        #expect(Self.placeholders("Scans/Receipts/{date:yyyy} {time}") == ["{date:yyyy}", "{time}"])
        #expect(Self.placeholders("A { has no closing }. Type {{ for a brace.").isEmpty)
        #expect(Self.placeholders("Recibo {fecha} {n:000}") != Self.placeholders("Receipt {date} {n:000}"))
    }

    @Test func Every_sentence_the_sources_ask_for_is_in_the_catalog_with_its_Spanish() {
        #expect(!Self.spanish.isEmpty, "CoreStrings.xcstrings not found or not read")
        let missing = Self.keysInSources.keys.filter { (Self.spanish[$0] ?? "").isEmpty }.sorted()
        #expect(missing.isEmpty, "No Spanish for \(missing.count): \(missing.prefix(40).map { "\($0) (\(Self.keysInSources[$0]!))" })")
    }

    @Test func The_catalog_has_nothing_the_sources_no_longer_ask_for() {
        let stale = Self.spanish.keys.filter { Self.keysInSources[$0] == nil }.sorted()
        #expect(stale.isEmpty, "Not asked for by any loc(): \(stale.prefix(40))")
    }

    @Test func Each_Spanish_sentence_keeps_its_placeholders() {
        let wrong = Self.spanish.filter { key, es in
            !es.isEmpty && Self.placeholders(Self.english(key)) != Self.placeholders(es)
        }.keys.sorted()
        #expect(wrong.isEmpty, "Placeholders differ: \(wrong.prefix(20))")
    }

    /// A key's English: the key, less its `[context]`.
    static func english(_ key: String) -> String {
        guard key.hasSuffix("]"), let open = key.range(of: " [", options: .backwards) else { return key }
        return String(key[..<open.lowerBound])
    }

    @Test func The_scanner_finds_keys_with_and_without_a_context() {
        let source = #"""
            let a = loc("Paper jam"), b = loc("About {0} pages left", n)
            let c = loc("Black", context: "supply color"), d = myloc("Not this"), e = x.loc("Nor this")
            let f = loc("Say \"Hi\" \u{201C}now\u{201D}")
            let g: [String: LocKey] = ["ready": LocKey("Ready"), "group": LocKey("General", context: "settings group")]
            let h = LocKey(verbatim: "A4 (21 × 29.7 cm)")
            """#
        let keys = Self.keys(in: source).map(\.0)
        #expect(keys == ["Paper jam", "About {0} pages left", "Black [supply color]", "Say \"Hi\" “now”", "Ready", "General [settings group]"])
    }

    /// The status, settings and page-size tables keep English by id: a lookup asks the language for its own sentence only,
    /// so the report's "asked without Spanish" lists what was shown, not every entry of a table.
    @Test func A_table_lookup_asks_for_its_own_sentence_only() {
        let table = CoreLanguage.Table(language: "es", sentences: ["Paper jam": "Atasco de papel"])
        CoreLanguage.withTable(table) {
            #expect(LedmStatusText.describe("jamInPrinter") == "Atasco de papel")
            #expect(IppStatusText.describe("media-jam") == "Atasco de papel")
            #expect(LedmStatusText.explain("ready") == "Waiting for something to print or scan.")
            #expect(LedmSettingCatalog.all[0].label == "Printer name")
            #expect(ScanChoices.pageSizes[0].label == "Letter (8.5 × 11 in)")
            #expect(PhotoPaperText.paper(nil, 8.27, 11.69) == "A4 (21 × 29.7 cm)")
        }
        #expect(table.untranslated == ["Letter (8.5 × 11 in)", "Printer name", "Waiting for something to print or scan."])
    }

    /// The catalog's Spanish as the app installs it.
    static var spanishTable: CoreLanguage.Table {
        .init(language: "es", sentences: spanish.filter { !$0.value.isEmpty })
    }

    @Test func Without_a_table_text_is_English_and_with_one_Spanish() {
        let supply = Consumable(name: "Black toner", kind: "toner", colorCode: "K", percentRemaining: 12, state: "low",
                                estimatedPagesRemaining: 12_000)
        CoreLanguage.withTable(nil) {
            #expect(SupplyText(supply).headline == "About 12,000 pages left")
            #expect(SupplyText(supply).name == "Black toner")
        }
        let table = Self.spanishTable
        CoreLanguage.withTable(table) {
            #expect(SupplyText(supply).headline == "Quedan unas 12.000 páginas")
            #expect(SupplyText(supply).name == "Tóner negro")
            let ink = Consumable(name: "Black ink", kind: "ink", colorCode: "K", percentRemaining: 50, state: "ok")
            #expect(SupplyText(ink).name == "Tinta negra")
            #expect(SupplyNames.display("Toner Cartridge HP 26A") == "Toner Cartridge HP 26A") // a printer's own name
        }
        #expect(table.untranslated.isEmpty)
    }

    /// Every colour agrees with the kind before it: feminine after "tinta", masculine after "tóner", "cartucho de tinta"…
    @Test(arguments: [
        ("Black ink", "Tinta negra"), ("Yellow ink", "Tinta amarilla"), ("Photo black ink", "Tinta negra fotográfica"),
        ("Matte black ink", "Tinta negra mate"), ("Cyan ink", "Tinta cian"), ("Gray ink", "Tinta gris"),
        ("Tri-color ink", "Tinta tricolor"), ("Magenta ink", "Tinta magenta"),
        ("Black toner", "Tóner negro"), ("Yellow toner", "Tóner amarillo"), ("Photo black toner", "Tóner negro fotográfico"),
        ("Matte black toner", "Tóner negro mate"), ("Black ink cartridge", "Cartucho de tinta negro"),
        ("Photo black ink cartridge", "Cartucho de tinta negro fotográfico"), ("Yellow ink tank", "Depósito de tinta amarillo"),
        ("Black drum", "Tambor negro"),
    ])
    func Supply_colours_agree_with_their_kind(_ english: String, _ spanish: String) {
        let table = Self.spanishTable
        CoreLanguage.withTable(table) { #expect(SupplyNames.display(english) == spanish) }
        #expect(table.untranslated.isEmpty)
    }

    @Test func A_sentence_the_table_lacks_shows_in_English_and_is_listed() {
        let table = CoreLanguage.Table(language: "es", sentences: ["Paper jam": "Atasco de papel"])
        CoreLanguage.withTable(table) {
            #expect(loc("Paper jam") == "Atasco de papel")
            #expect(loc("{0} is offline", "Office") == "Office is offline")
            #expect(CoreLanguage.untranslated == ["{0} is offline"])
        }
        #expect(table.untranslated == ["{0} is offline"])
    }

    /// The language is the task's own: a test (or a window) in Spanish leaves the suites running beside it in English.
    @Test func A_table_for_one_task_leaves_the_others_English() async {
        let table = CoreLanguage.Table(language: "es", sentences: ["Paper jam": "Atasco de papel"])
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        CoreLanguage.withTable(table) { #expect(loc("Paper jam") == "Atasco de papel") }
                    } else {
                        #expect(loc("Paper jam") == "Paper jam")
                        #expect(CoreLanguage.number(12_345) == "12,345")
                    }
                }
            }
        }
        #expect(CoreLanguage.table == nil)
    }

    @Test func Placeholders_take_their_values_in_any_order() {
        #expect(CoreLanguage.fill("{1}, unos {0} días", [3, "quedan 40 páginas"]) == "quedan 40 páginas, unos 3 días")
        #expect(CoreLanguage.fill("{0} {2}", ["a"]) == "a {2}")
        #expect(CoreLanguage.fill("{x} {0}", ["a"]) == "{x} a")
    }
}
