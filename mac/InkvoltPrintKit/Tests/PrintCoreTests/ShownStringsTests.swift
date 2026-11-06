import Foundation
import Testing

/// The Spanish interface's third check (roadmap 3.7): `CoreStringsTests` and check-strings.sh see only the strings already
/// wrapped (`loc`, `LocKey`, `String(localized:)`, SwiftUI's literals), so an English literal handed straight to the
/// interface slipped past both. This reads PrintCore's, PrintMac's and the app's sources and names every literal of words
/// given, unwrapped, to what the interface shows:
///
/// - a `Repair`, `CheckResult`, `PrinterStatus`, `PrinterAlert`, `AlertCondition`, `RepairOutcome`, `UNNotificationAction`
///   or `NSMenuItem` (unlabelled, or as its title, message, body, detail or question);
/// - any argument labelled as shown text (`title:`, `message:`, `detail:`, `question:`, `prompt:`, `help:`…);
/// - an assignment to a shown property (`.messageText =`, `.informativeText =`, `.title =`, `.prompt =`, `.message =`…);
/// - a line added to `notes`, `problems` or `warnings`, or a constant named as shown text (`scannersNote = "…"`);
/// - a SwiftUI view or modifier (`Text`, `Button`, `Window`, `.help`, `.accessibilityLabel`…) given a String built from
///   a literal (`cond ? "A" : "B"`, `"A" + b`): only a literal on its own is a localized key.
///
/// Text that stays English on purpose is allowed by file (`englishFiles`: the `--report` dev aid, the command lines) or
/// by a `// English: <why>` comment on its line (protocol words, log lines, an export's columns). A literal of words is
/// one with a run of two letters and a space, or a capital then a small letter ("Ready"); keys and identifiers
/// ("ready", "printer.fill") never count.
struct ShownStringsTests {
    /// Files whose text is English by design, as on Windows.
    static let englishFiles: Set<String> = [
        // `--report`: the dev aid's report, read by the developer and in bug reports.
        "Report.swift", "ReportBatchPrint.swift", "ReportProblem.swift", "ReportRecording.swift", "ReportSnmp.swift",
        "ReportStrings.swift",
        // The command lines (`status --all`, `print`, `record`) write English whatever the Mac's language.
        "BatchPrintCommandLine.swift", "BatchPrintCommand.swift", "FleetCommand.swift", "RecordCommand.swift",
    ]

    static let viewCalls: Set<String> = [
        "Text", "Label", "Button", "Toggle", "Picker", "Section", "help", "navigationTitle", "alert", "confirmationDialog",
        "TextField", "SecureField", "LabeledContent", "Menu", "GroupBox", "Link", "Stepper", "DisclosureGroup", "ProgressView",
        "ContentUnavailableView", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "Tab", "Window",
        "WindowGroup", "Settings", "CommandMenu", "MenuBarExtra", "TableColumn",
    ]
    static let shownCalls: Set<String> = [
        "Repair", "CheckResult", "PrinterStatus", "PrinterAlert", "AlertCondition", "RepairOutcome", "UNNotificationAction",
        "NSMenuItem",
    ]
    static let shownCallLabels: Set<String> = ["title", "message", "body", "detail", "question"]
    static let shownLabels: Set<String> = [
        "title", "message", "body", "detail", "question", "headline", "prompt", "help", "informativeText", "messageText",
        "note", "summary", "subtitle", "caption", "hint", "explanation",
    ]
    static let shownProperties: Set<String> = [
        "messageText", "informativeText", "title", "prompt", "message", "toolTip", "nameFieldLabel", "placeholderString",
        "stringValue", "detail", "headline", "note", "subtitle",
    ]
    static let shownLists: Set<String> = ["notes", "problems", "warnings"]
    static let shownNameEndings = ["Note", "Message", "Title", "Detail", "Headline", "Question"]

    /// What counts as reaching the interface: Inkvolt Print's (`printRules`, above) or Inkvolt PDF's AppKit and PdfCore calls
    /// (`PdfStringsTests.pdfRules`).
    struct Rules {
        var viewCalls: Set<String>
        var shownCalls: Set<String>
        var shownCallLabels: Set<String>
        var shownLabels: Set<String>
        var shownProperties: Set<String>
        var shownLists: Set<String>
        var shownNameEndings: [String]
        /// A literal in an array literal counts for the call around the array (`addItems(withTitles: ["A", "B"])`).
        var looksThroughArrays = false
    }

    static let printRules = Rules(viewCalls: viewCalls, shownCalls: shownCalls, shownCallLabels: shownCallLabels, shownLabels: shownLabels,
                                  shownProperties: shownProperties, shownLists: shownLists, shownNameEndings: shownNameEndings)

    /// A literal given to the interface unwrapped: where, why, and its text (`{…}` for an interpolation).
    struct Finding: CustomStringConvertible, Equatable {
        let file: String, line: Int, why: String, text: String
        var description: String { "\(file):\(line): \(why): \"\(text.prefix(80))\"" }
    }

    static var sourceRoots: [URL] {
        var mac = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { mac.deleteLastPathComponent() } // mac/
        return ["InkvoltPrintKit/Sources/PrintCore", "InkvoltPrintKit/Sources/PrintMac", "InkvoltPrint/Sources/InkvoltPrint"]
            .map { mac.appendingPathComponent($0) }
    }

    @Test func No_English_literal_reaches_the_interface_unwrapped() throws {
        var found: [Finding] = []
        var files = 0
        for root in Self.sourceRoots {
            let all = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in all where file.pathExtension == "swift" {
                files += 1
                guard !Self.englishFiles.contains(file.lastPathComponent) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                found += Self.findings(in: text, file: file.lastPathComponent)
            }
        }
        #expect(files > 150, "Read only \(files) Swift files")
        #expect(found.isEmpty, "Unwrapped English shown to the user (\(found.count)); wrap it in loc/String(localized:) or mark it // English: <why>:\n\(found.map(\.description).joined(separator: "\n"))")
    }

    @Test func The_scan_finds_what_reaches_the_interface_and_nothing_else() {
        let source = #"""
            list.append(Repair(.addAgain, "Add “\(shown)” again", loc("Fine")))
            let r = CheckResult(.ping, .failed, "No answer from \(host)")
            Text(flag ? "On now" : String(localized: "Off now"))
            alert.messageText = "Can't print"
            let s = PrinterStatus(code: "ready", message: "Not ready", severity: .info)
            notes.append("Scanners weren't read")
            static let scannersNote = "Scanners on their own aren't listed"
            Window(demo ? "Inkvolt Print — Demo" : "Inkvolt Print", id: "main") { }
            Text("Fine \(x)"); Button("Print") { }; Text(verbatim: "Inkvolt Print"); Label("Scan", systemImage: "scanner")
            let a = loc("Shown \(1)"), b = LocKey("Ready"), c = String(localized: "Saved \(n).")
            let d = Repair(.x, loc("Fine"), loc("Fine too"), queue: "Office printer")
            lines.append("setting \(x)") // not a shown list
            let e = PrinterAlert(id: "x", severity: .error, message: "Paper jam") // English: the printer's own words
            // Text(flag ? "Not code" : "At all")
            /* alert.messageText = "Nor this" */
            """#
        let found = Self.findings(in: source, file: "Sample.swift").map { "\($0.line) \($0.text)" }
        #expect(found == ["1 Add “{…}” again", "2 No answer from {…}", "3 On now", "4 Can't print", "5 Not ready",
                          "6 Scanners weren't read", "7 Scanners on their own aren't listed", "8 Inkvolt Print — Demo",
                          "8 Inkvolt Print"])
    }

    // MARK: The scan

    private struct Frame {
        let callee: String
        /// Where its arguments start, and the text before its opening bracket (for `notes.append(`).
        let start: Int
        let receiver: String
    }

    private struct Literal {
        let start: Int, end: Int, value: String, frames: [Frame]
    }

    static func findings(in text: String, file: String, rules: Rules = printRules) -> [Finding] {
        let src = Array(text.utf8)
        var out: [Finding] = []
        for literal in literals(src) where isWords(literal.value) {
            let line = src[..<literal.start].reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
            // Its line, by bytes: a CRLF checkout's "\r\n" is one Character.
            let lineStart = src[..<literal.start].lastIndex(of: 10).map { $0 + 1 } ?? 0
            let lineEnd = src[literal.start...].firstIndex(of: 10) ?? src.count
            if String(decoding: src[lineStart..<lineEnd], as: UTF8.self).contains("// English:") { continue }
            if let why = why(literal, src, rules) { out.append(Finding(file: file, line: line, why: why, text: literal.value)) }
        }
        return out
    }

    /// Why `literal` reaches the interface unwrapped, or nil.
    private static func why(_ literal: Literal, _ src: [UInt8], _ rules: Rules) -> String? {
        let wrappers: Set<String> = ["loc", "LocKey", "NSLocalizedString", "LocalizedStringKey", "LocalizedStringResource"]
        if literal.frames.contains(where: { wrappers.contains($0.callee) }) { return nil }
        var frames = literal.frames[...]
        if rules.looksThroughArrays { while frames.count > 1, frames.last?.callee == "[" { frames = frames.dropLast() } }
        if let top = frames.last {
            let argument = currentArgument(src, from: top.start, to: literal.start)
            let label = argumentLabel(argument)
            if label == "verbatim" || (top.callee == "String" && label == "localized") { return nil }
            if rules.viewCalls.contains(top.callee) {
                let alone = argument.allSatisfy { $0 == " " || $0 == "\n" } || (label != nil && afterLabel(argument).isEmpty)
                let next = src[literal.end...].first { $0 != 32 && $0 != 10 }
                return alone && (next == UInt8(ascii: ",") || next == UInt8(ascii: ")")) ? nil : "\(top.callee)(…) given a String"
            }
            if rules.shownCalls.contains(top.callee), label == nil || rules.shownCallLabels.contains(label!) {
                return "\(top.callee)(\(label ?? "_"):)"
            }
            if let label, rules.shownLabels.contains(label) { return "\(label):" }
            if top.callee == "append", rules.shownLists.contains(where: { top.receiver.hasSuffix("\($0).") }) { return "\(top.receiver)append" }
        }
        // `.messageText = "…"`
        let before = String(decoding: src[max(0, literal.start - 60)..<literal.start], as: UTF8.self)
        if let eq = before.lastIndex(of: "=") , before[before.index(after: eq)...].allSatisfy({ $0 == " " }) {
            let lhs = before[..<eq].reversed().drop { $0 == " " }
            let name = String(lhs.prefix { $0.isLetter || $0.isNumber }.reversed())
            let dot = lhs.dropFirst(name.count).first
            if dot == ".", rules.shownProperties.contains(name) { return ".\(name) =" }
            // `static let scannersNote = "…"`: a constant named as shown text.
            let declared = lhs.dropFirst(name.count).drop { $0 == " " }
            if declared.starts(with: "tel ") || declared.starts(with: "rav "),
               rules.shownNameEndings.contains(where: { name.hasSuffix($0) || name == $0.lowercased() }) {
                return "\(name) ="
            }
        }
        return nil
    }

    /// The text of the argument a literal is in: from the frame's last top-level comma to the literal.
    private static func currentArgument(_ src: [UInt8], from start: Int, to end: Int) -> String {
        var depth = 0, last = start
        var i = start
        while i < end {
            switch src[i] {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            case UInt8(ascii: ","): if depth == 0 { last = i + 1 }
            default: break
            }
            i += 1
        }
        return String(decoding: src[last..<end], as: UTF8.self)
    }

    /// `title` in " title: …"; nil for an unlabelled argument.
    private static func argumentLabel(_ argument: String) -> String? {
        let trimmed = argument.drop { $0 == " " || $0 == "\n" }
        let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let rest = trimmed.dropFirst(name.count).drop { $0 == " " }
        guard !name.isEmpty, rest.first == ":", rest.dropFirst().first != ":" else { return nil }
        return String(name)
    }

    private static func afterLabel(_ argument: String) -> Substring {
        guard let colon = argument.firstIndex(of: ":") else { return argument[...] }
        return argument[argument.index(after: colon)...].drop { $0 == " " || $0 == "\n" }
    }

    /// Words a person reads: a run of two letters, and a space or a capital then a small letter.
    private static func isWords(_ value: String) -> Bool {
        let text = value.replacingOccurrences(of: "{…}", with: "")
        var run = 0, hasRun = false
        for c in text { run = c.isLetter ? run + 1 : 0; if run >= 2 { hasRun = true; break } }
        guard hasRun else { return false }
        if text.trimmingCharacters(in: .whitespaces).contains(" ") { return true }
        let chars = Array(text)
        return chars.count > 1 && chars[0].isUppercase && chars[1].isLowercase
    }

    /// Every string literal outside comments, with the calls and brackets it sits in. An interpolation is `{…}` in its
    /// value and its own literals are not read.
    private static func literals(_ src: [UInt8]) -> [Literal] {
        let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\")
        let hash = UInt8(ascii: "#"), newline = UInt8(10)
        var out: [Literal] = []
        var frames: [Frame] = []
        var i = 0
        let n = src.count
        func starts(_ s: String, at j: Int) -> Bool {
            let b = Array(s.utf8)
            return j + b.count <= n && Array(src[j..<j + b.count]) == b
        }
        while i < n {
            let c = src[i]
            if c == slash, i + 1 < n, src[i + 1] == slash {
                while i < n, src[i] != newline { i += 1 }
                continue
            }
            if c == slash, i + 1 < n, src[i + 1] == star {
                i += 2
                while i + 1 < n, !(src[i] == star && src[i + 1] == slash) { i += 1 }
                i += 2
                continue
            }
            if c == hash, i + 1 < n, src[i + 1] == hash || src[i + 1] == quote {
                var hashes = 0
                while i + hashes < n, src[i + hashes] == hash { hashes += 1 }
                guard i + hashes < n, src[i + hashes] == quote else { i += hashes; continue }
                let multi = starts("\"\"\"", at: i + hashes)
                let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                let start = i
                var j = i + hashes + (multi ? 3 : 1)
                let valueStart = j
                while j < n, !starts(close, at: j) { j += 1 }
                out.append(Literal(start: start, end: min(n, j + close.utf8.count), value: String(decoding: src[valueStart..<min(j, n)], as: UTF8.self), frames: frames))
                i = j + close.utf8.count
                continue
            }
            if c == quote {
                let multi = starts("\"\"\"", at: i)
                let start = i
                var j = i + (multi ? 3 : 1)
                var value: [UInt8] = []
                while j < n {
                    if src[j] == backslash, j + 1 < n, src[j + 1] == UInt8(ascii: "(") {
                        value += Array("{…}".utf8)
                        j = skipInterpolation(src, j + 2)
                        continue
                    }
                    if src[j] == backslash, j + 1 < n {
                        value += [src[j], src[j + 1]]
                        j += 2
                        continue
                    }
                    if multi ? starts("\"\"\"", at: j) : src[j] == quote { break }
                    if !multi, src[j] == newline { break }
                    value.append(src[j])
                    j += 1
                }
                let end = min(n, j + (multi ? 3 : 1))
                out.append(Literal(start: start, end: end, value: unescaped(String(decoding: value, as: UTF8.self)), frames: frames))
                i = end
                continue
            }
            if c == UInt8(ascii: "(") || c == UInt8(ascii: "[") {
                let callee = c == UInt8(ascii: "(") ? identifier(before: i, src) : "["
                let receiverEnd = i - callee.utf8.count
                let receiver = String(decoding: src[max(0, receiverEnd - 30)..<max(0, receiverEnd)], as: UTF8.self)
                frames.append(Frame(callee: callee, start: i + 1, receiver: receiver))
            } else if c == UInt8(ascii: ")") || c == UInt8(ascii: "]") {
                if !frames.isEmpty { frames.removeLast() }
            }
            i += 1
        }
        return out
    }

    /// The identifier right before an opening parenthesis ("Text" in `Text(`), or "".
    private static func identifier(before i: Int, _ src: [UInt8]) -> String {
        var j = i - 1
        while j >= 0, src[j] == 32 { j -= 1 }
        var k = j
        while k >= 0, isIdentifierByte(src[k]) { k -= 1 }
        return k < j ? String(decoding: src[(k + 1)...j], as: UTF8.self) : ""
    }

    private static func isIdentifierByte(_ b: UInt8) -> Bool {
        if b == UInt8(ascii: "_") { return true }
        if b >= 48 && b <= 57 { return true }
        let lower = b | 0x20
        return lower >= 97 && lower <= 122
    }

    /// Past the `)` closing an interpolation that starts at `j` (after `\(`), over nested parentheses and strings.
    private static func skipInterpolation(_ src: [UInt8], _ start: Int) -> Int {
        var depth = 1, j = start
        while j < src.count, depth > 0 {
            switch src[j] {
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"): depth -= 1
            case UInt8(ascii: "\""):
                j += 1
                while j < src.count, src[j] != UInt8(ascii: "\"") { j += src[j] == UInt8(ascii: "\\") ? 2 : 1 }
            default: break
            }
            j += 1
        }
        return j
    }

    /// `\u{201C}` and `\"` as the characters they stand for, so a finding reads as the text.
    private static func unescaped(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var rest = s[...]
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[..<slash]
            let after = rest[rest.index(after: slash)...]
            if after.hasPrefix("u{"), let close = after.firstIndex(of: "}"),
               let code = UInt32(after[after.index(after: after.index(after: after.startIndex))..<close], radix: 16),
               let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
                rest = after[after.index(after: close)...]
            } else if let next = after.first {
                out.append(next == "n" ? "\n" : next)
                rest = after.dropFirst()
            } else {
                rest = after
            }
        }
        return out + rest
    }
}
