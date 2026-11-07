import Foundation

/// pdf.js's view of a file (pdf/tools/forms-corpus/pdfjs-fields.mjs, pdfjs-dist from pdf/tools/pdfjs-check).
struct PdfJsWidget {
    var page: Int
    var name: String?
    var type: String?
    var value: Any?
    var hasAppearance: Bool
    var buttonValue: Any?
    var exportValue: String?
    var hidden: Bool
}

struct PdfJsListing {
    var error: String?
    var widgets: [PdfJsWidget]
}

enum PdfJs {
    /// Reads the files with pdf.js, a few per Node process, several processes at once.
    static func read(node: String, script: String, files: [String], jobs: Int) -> [String: PdfJsListing] {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var result: [String: PdfJsListing] = [:]
        }
        let box = Box()
        let chunks = stride(from: 0, to: files.count, by: 10).map { Array(files[$0..<min($0 + 10, files.count)]) }
        let gate = DispatchSemaphore(value: max(jobs, 1))
        let group = DispatchGroup()
        for chunk in chunks {
            gate.wait()
            group.enter()
            DispatchQueue.global().async {
                defer {
                    gate.signal()
                    group.leave()
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: node)
                p.arguments = [script] + chunk
                p.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let file = json["file"] as? String else { continue }
                    let widgets = (json["widgets"] as? [[String: Any]] ?? []).map { w in
                        PdfJsWidget(page: w["page"] as? Int ?? 0, name: w["name"] as? String, type: w["type"] as? String, value: w["value"],
                                    hasAppearance: w["hasAppearance"] as? Bool ?? false, buttonValue: w["buttonValue"],
                                    exportValue: w["exportValue"] as? String, hidden: w["hidden"] as? Bool ?? false)
                    }
                    box.lock.lock()
                    box.result[file] = PdfJsListing(error: json["error"] as? String, widgets: widgets)
                    box.lock.unlock()
                }
            }
        }
        group.wait()
        return box.result
    }

    private static func str(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { str($0) }.joined(separator: "\n")
        default: return ""
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { unifiedLines(a) == unifiedLines(b) }

    /// The fields pdf.js lists in the original (what other readers would offer to fill) are all among Inkvolt's; in the
    /// filled file every filled field reads the value Inkvolt stored, and every widget of it has an appearance.
    static func compare(_ report: inout FormReport, original: PdfJsListing?, filled: PdfJsListing?) {
        if report.status == "skip" {
            // "No form fields" is only true if pdf.js finds none to show either.
            let shown = original?.widgets.contains { !$0.hidden && !($0.name ?? "").isEmpty } == true
            if report.skip != "no form fields" || !shown { return }
            report.skip = nil
            report.status = "fail"
        }
        if let original, original.error == nil {
            let named = original.widgets.filter { !($0.name ?? "").isEmpty }
            var theirs: [String] = []
            var seen = Set<String>()
            for w in named where seen.insert(w.name ?? "").inserted { theirs.append(w.name ?? "") }
            report.pdfJsFields = theirs.count
            let ours = Set(report.names)
            for name in theirs where !ours.contains(name) {
                let w = named.first { $0.name == name }
                report.fail("field-not-found", name, "pdf.js lists a \(w?.type ?? "") field (page \(w?.page ?? 0)) that Inkvolt doesn't")
            }
            // Each field's visible widgets: as many on the page view as pdf.js shows.
            for (name, group) in Dictionary(grouping: named.filter { !$0.hidden }, by: { $0.name ?? "" }) where ours.contains(name) {
                if let n = report.widgetCounts[name], n < group.count {
                    report.fail("widget-not-shown", name, "\(group[0].type ?? ""): pdf.js shows \(group.count) widget(s), the page view \(n)")
                }
            }
            let extra = report.names.filter { !seen.contains($0) }
            if !extra.isEmpty { report.notes.append("Inkvolt lists \(extra.count) field(s) pdf.js doesn't, e.g. \(extra[0])") }
        } else {
            report.notes.append("pdf.js can't read the original: \(original?.error ?? "not run")")
        }
        let opened = !report.failures.contains { ["fill-exception", "reopen-exception", "read-exception"].contains($0.kind) }
        if report.plan.isEmpty || !opened {
            report.status = report.failures.isEmpty ? report.status : "fail"
            return
        }
        guard let filled, filled.error == nil else {
            report.fail("pdfjs-cannot-read-filled", "", filled?.error ?? "not run")
            report.status = "fail"
            return
        }
        let byName = Dictionary(grouping: filled.widgets.filter { $0.name != nil }, by: { $0.name ?? "" })
        for p in report.plan {
            guard let ws = byName[p.name], let first = ws.first else {
                report.fail("pdfjs-field-missing-after-save", p.name, p.kind)
                continue
            }
            // A button's off widgets may lack an "Off" face: only the one turned on must show. pdf.js names a button by its
            // /Opt export value when there is one, else by its on state: what Inkvolt reads back.
            let shown: [PdfJsWidget]
            switch p.kind {
            case "Radio": shown = ws.filter { str($0.buttonValue) == p.stored }
            case "CheckBox": shown = ws.filter { $0.exportValue == p.stored }
            default: shown = ws
            }
            let button = p.kind == "Radio" || p.kind == "CheckBox"
            let undrawn = shown.filter { !$0.hasAppearance }.count
            if button ? (!shown.isEmpty && undrawn == shown.count) : undrawn > 0 {
                report.fail("pdfjs-no-appearance", p.name, "\(p.kind): \(undrawn) of \(shown.count) widget(s)")
            }
            var problem: String?
            switch p.kind {
            case "Text":
                if !same(str(first.value), p.stored) { problem = "pdf.js reads '\(esc(str(first.value)))', Inkvolt stored '\(esc(p.stored))'" }
            case "Choice":
                let want = String(p.stored.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                if let list = first.value as? [Any] {
                    if !list.map({ str($0) }).contains(want) { problem = "pdf.js reads [\(esc(str(first.value)))], stored '\(esc(p.stored))'" }
                } else if !same(str(first.value), want) {
                    problem = "pdf.js reads '\(esc(str(first.value)))', stored '\(esc(p.stored))'"
                }
            case "CheckBox":
                if !ws.contains(where: { str($0.value) != "Off" && !str($0.value).isEmpty }) { problem = "pdf.js reads it unticked" }
            case "Radio":
                if !ws.contains(where: { str($0.value) != "Off" && !str($0.value).isEmpty }) { problem = "pdf.js reads no button chosen" }
            default:
                break
            }
            if let problem { report.fail("pdfjs-value-differs", p.name, "\(p.kind): \(problem)") }
        }
        report.status = report.failures.isEmpty ? "pass" : "fail"
    }
}
