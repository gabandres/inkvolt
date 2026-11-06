import Foundation
import Testing

/// Inkvolt PDF for Mac's Spanish interface (roadmap 3.7), checked here because this target builds on the PC and in the
/// `mac` CI job, while PdfCoreTests needs MuPDF (the Mac and CI's `pdf` job only). The app and PdfCore show every sentence
/// through PrintCore's `loc` (or a `LocKey`, or a title of PdfCore's menu table, `DocumentCommands`); their Spanish is in
/// mac/InkvoltPdf/Resources: `PdfStrings.xcstrings` for PdfCore's, `Localizable.xcstrings` for the app's own (a sentence
/// PdfCore or Inkvolt Print's `CoreStrings` already has needs no second entry). As `CoreStringsTests` and
/// `ShownStringsTests` check Inkvolt Print: every key has its Spanish with the same `{0}`, `{1}`…, nothing stale, no key in
/// two catalogs, and no English literal reaches the interface unwrapped.
struct PdfStringsTests {
    static var mac: URL {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/PdfStringsTests.swift
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    /// A catalog's keys and their Spanish ("" when it has none).
    static func catalog(_ path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: mac.appendingPathComponent(path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: [String: Any]] else { return [:] }
        return strings.mapValues { entry in
            let es = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any]
            let unit = es?["stringUnit"] as? [String: Any]
            return unit?["state"] as? String == "translated" ? unit?["value"] as? String ?? "" : ""
        }
    }

    static let pdfStrings = catalog("InkvoltPdf/Resources/PdfStrings.xcstrings")
    static let localizable = catalog("InkvoltPdf/Resources/Localizable.xcstrings")
    static let coreStrings = catalog("InkvoltPrint/Resources/CoreStrings.xcstrings")

    static let coreRoot = "InkvoltPdfKit/Sources/PdfCore"
    static let appRoot = "InkvoltPdf/Sources/InkvoltPdf"

    /// The menu table's titles are keys too: `c("Open…", …)` and `CommandMenu("File", …)` (shown through `shownTitle`).
    static let menuTable = "DocumentCommands.swift"

    /// Every key asked for under `root`: key → the file asking.
    static func keys(under root: String) -> [String: String] {
        var found: [String: String] = [:]
        let url = mac.appendingPathComponent(root)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [:] }
        for case let file as URL in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let openers = file.lastPathComponent == menuTable ? ["c(\"", "CommandMenu(\""] : []
            for (key, _) in CoreStringsTests.keys(in: code.joined(separator: "\n"), openers: openers) { found[key] = file.lastPathComponent }
        }
        return found
    }

    static let coreKeys = keys(under: coreRoot)
    static let appKeys = keys(under: appRoot)

    @Test func The_catalogs_and_the_sources_are_read() {
        #expect(!Self.pdfStrings.isEmpty, "PdfStrings.xcstrings not found or not read")
        #expect(!Self.localizable.isEmpty, "Localizable.xcstrings not found or not read")
        #expect(Self.coreKeys["Open…"] == Self.menuTable && Self.coreKeys["View"] == Self.menuTable, "the menu table's titles weren't read")
        #expect(Self.appKeys["Same as macOS"] == "AppLanguage.swift")
    }

    @Test func Every_sentence_PdfCore_asks_for_is_in_PdfStrings_with_its_Spanish() {
        let missing = Self.coreKeys.keys.filter { (Self.pdfStrings[$0] ?? "").isEmpty }.sorted()
        #expect(missing.isEmpty, "No Spanish for \(missing.count): \(missing.prefix(60).map { "\($0) (\(Self.coreKeys[$0]!))" })")
    }

    @Test func Every_sentence_the_app_asks_for_has_its_Spanish() {
        let missing = Self.appKeys.keys.filter {
            (Self.localizable[$0] ?? Self.pdfStrings[$0] ?? Self.coreStrings[$0] ?? "").isEmpty
        }.sorted()
        #expect(missing.isEmpty, "No Spanish for \(missing.count): \(missing.prefix(60).map { "\($0) (\(Self.appKeys[$0]!))" })")
    }

    @Test func The_catalogs_hold_nothing_the_sources_no_longer_ask_for() {
        let staleCore = Self.pdfStrings.keys.filter { Self.coreKeys[$0] == nil }.sorted()
        #expect(staleCore.isEmpty, "PdfStrings: not asked for by PdfCore: \(staleCore.prefix(40))")
        let staleApp = Self.localizable.keys.filter { Self.appKeys[$0] == nil }.sorted()
        #expect(staleApp.isEmpty, "Localizable: not asked for by the app: \(staleApp.prefix(40))")
    }

    /// One Spanish per sentence: the app's catalog doesn't repeat PdfCore's (the app installs both as one table).
    @Test func No_sentence_is_in_both_catalogs() {
        let both = Set(Self.localizable.keys).intersection(Self.pdfStrings.keys).sorted()
        #expect(both.isEmpty, "In Localizable and PdfStrings: \(both.prefix(40))")
    }

    @Test func Each_Spanish_sentence_keeps_its_placeholders() {
        for (name, table) in [("PdfStrings", Self.pdfStrings), ("Localizable", Self.localizable)] {
            let wrong = table.filter { key, es in
                !es.isEmpty && CoreStringsTests.placeholders(CoreStringsTests.english(key)) != CoreStringsTests.placeholders(es)
            }.keys.sorted()
            #expect(wrong.isEmpty, "\(name): placeholders differ: \(wrong.prefix(20))")
        }
    }

    // MARK: What's New in Spanish

    /// Each `## ` heading of a What's New file with its number of `- ` lines, in order.
    static func sections(_ path: String) -> [String] {
        guard let text = try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8) else { return [] }
        var out: [(String, Int)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            if line.hasPrefix("## ") {
                out.append((String(line.dropFirst(3)), 0))
            } else if line.hasPrefix("- "), !out.isEmpty {
                out[out.count - 1].1 += 1
            }
        }
        return out.map { "\($0.0): \($0.1)" }
    }

    /// Both Mac apps' What's New in Spanish (shown when the app runs in Spanish; Inkvolt Print's for the App Store's es-MX
    /// listing): every version the English has, with as many lines, so an English line added without its Spanish fails.
    @Test(arguments: ["InkvoltPdf", "InkvoltPrint"])
    func Whats_New_in_Spanish_has_every_version_and_line(_ app: String) {
        let english = Self.sections("\(app)/WHATS-NEW.md")
        #expect(!english.isEmpty)
        #expect(Self.sections("\(app)/WHATS-NEW.es.md") == english)
    }

    // MARK: Unwrapped English

    /// Files whose text is English by design, as on Windows: the self-test (`--self-test`, a developer aid; its checks
    /// compare with `loc` where they read the interface), the command line (`--batch`, `--watch`, `--fill`, `--help`).
    static func isEnglishFile(_ name: String) -> Bool {
        name.hasSuffix("Test.swift") || [
            "Report.swift", "ReportStrings.swift", "UxShots.swift", "CommandLineRun.swift", "BatchCommandLine.swift",
        ].contains(name)
    }

    /// Inkvolt PDF's calls that show text: AppKit's controls, alerts and panels, the app's own helpers, PdfCore's errors.
    static let pdfRules = ShownStringsTests.Rules(
        viewCalls: [],
        shownCalls: [
            "NSMenuItem", "setAccessibilityLabel", "setAccessibilityHelp", "setAccessibilityTitle", "setAccessibilityValue",
            "setAccessibleName", "showError", "showStatus", "notify", "announce", "inform", "infoSheet", "problemAlert",
            "confirm", "PdfEditError", "SigningError", "AiError", "BatchPresetError", "ContentEditError", "PdfAError",
            "DesignRefusal", "problemNote", "askTitle", "askText", "editBookmarks", "sectionTitle", "noteOnce",
        ],
        shownCallLabels: ["title", "message", "detail", "question", "informativeText", "messageText"],
        shownLabels: [
            "title", "message", "body", "detail", "question", "headline", "prompt", "help", "informativeText", "messageText",
            "note", "summary", "subtitle", "caption", "hint", "explanation", "labelWithString", "wrappingLabelWithString",
            "checkboxWithTitle", "radioButtonWithTitle", "withTitle", "withTitles", "toolTip", "placeholder", "heading", "failure",
        ],
        shownProperties: [
            "messageText", "informativeText", "title", "prompt", "message", "toolTip", "nameFieldLabel", "placeholderString",
            "stringValue", "detail", "headline", "note", "subtitle", "label", "paletteLabel",
        ],
        shownLists: ["notes", "problems", "warnings"],
        shownNameEndings: ["Note", "Message", "Title", "Detail", "Headline", "Question", "Prompt"],
        looksThroughArrays: true)

    @Test func No_English_literal_reaches_Inkvolt_PDFs_interface_unwrapped() throws {
        var found: [ShownStringsTests.Finding] = []
        var files = 0
        for root in [Self.coreRoot, Self.appRoot] {
            let all = try #require(FileManager.default.enumerator(at: Self.mac.appendingPathComponent(root), includingPropertiesForKeys: nil))
            for case let file as URL in all where file.pathExtension == "swift" {
                files += 1
                guard !Self.isEnglishFile(file.lastPathComponent) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                found += ShownStringsTests.findings(in: text, file: file.lastPathComponent, rules: Self.pdfRules)
            }
        }
        #expect(files > 200, "Read only \(files) Swift files")
        #expect(found.isEmpty, "Unwrapped English shown to the user (\(found.count)); wrap it in loc or mark it // English: <why>:\n\(found.map(\.description).joined(separator: "\n"))")
    }

    @Test func The_PDF_scan_finds_AppKit_text() {
        let source = #"""
            let a = NSTextField(labelWithString: "Author name:"), b = NSButton(checkboxWithTitle: "Keep copies", target: nil, action: nil)
            theme.addItems(withTitles: ["Light", "Dark"])
            alert.informativeText = "It can't be undone."
            item.paletteLabel = "Markup"
            throw PdfEditError("This page is locked.")
            view.setAccessibilityLabel("Page thumbnails")
            let c = NSTextField(labelWithString: loc("Fine")), d = [loc("Light"), loc("Dark")]
            let e = NSButton(title: "OK", target: nil, action: nil) // English: Apple's own word
            """#
        let found = ShownStringsTests.findings(in: source, file: "Sample.swift", rules: Self.pdfRules).map { "\($0.line) \($0.text)" }
        #expect(found == ["1 Author name:", "1 Keep copies", "2 Light", "2 Dark", "3 It can't be undone.", "4 Markup",
                          "5 This page is locked.", "6 Page thumbnails"])
    }
}
