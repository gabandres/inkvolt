import CryptoKit
import Foundation
@testable import PdfCore

// run --pdfs <dir> [--out dir] [--corpus corpus.json] [--only a,b] [--files a.pdf,b.pdf] [--timeout s] [--jobs n] [--no-pdfjs]
//     [--update-baseline]
//     Fills every form of the corpus found in <dir> and the synthetic ones (each in its own process, killed after the time
//     limit: a hang), reads the originals and the filled files with pdf.js, and writes <out>/results.json and
//     <out>/summary.md. Exit code 1 when a form fails in a way baseline.json doesn't list.
// one <in.pdf> <out-dir> <name> [password]   One form, in this process: <out-dir>/<name>.report.json and <name>.filled.pdf.
// synth <out-dir>                            The synthetic forms as files.

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func readBytes(_ path: String) -> [UInt8]? { FileManager.default.contents(atPath: path).map { [UInt8]($0) } }

func writeReport(_ report: FormReport, _ path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) { FileManager.default.createFile(atPath: path, contents: data) }
}

func one() -> Int32 {
    guard arguments.count >= 4, let file = readBytes(arguments[1]) else { return 2 }
    let (outDir, name) = (arguments[2], arguments[3])
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    // The bytes the app would open.
    let report = FormsHarness.fillOne(name, StaleTail.normalized(file), outDir, password: arguments.count > 4 ? arguments[4] : nil)
    writeReport(report, (outDir as NSString).appendingPathComponent(name + ".report.json"))
    return 0
}

/// `probe <file.pdf>`: how MuPDF reads a file's trailer, catalog and bookmarks, for a failure the summary doesn't explain.
func probe() -> Int32 {
    guard arguments.count >= 2, let data = readBytes(arguments[1]), let doc = try? PdfEdit.openToRead(data, nil) else { return 2 }
    let catalog = doc.catalog
    print("appendable \(doc.canAppend), objects \(doc.objectCount), trailer \(doc.trailer.keys), catalog \(catalog.isRef ? catalog.num : -1) \(catalog.keys)")
    print("outlines \(catalog.dict("Outlines")?.keys ?? []), first \(catalog.dict("Outlines")?.dict("First")?.keys ?? []), bookmarks \((try? Bookmarks.read(data, nil).count) ?? -1)")
    print("widgets \((try? FormEditor.read(data, nil).count) ?? -1), struct tree \(catalog.dict("StructTreeRoot")?.keys ?? [])")
    return 0
}

func synth() -> Int32 {
    guard arguments.count >= 2 else { return 2 }
    try? FileManager.default.createDirectory(atPath: arguments[1], withIntermediateDirectories: true)
    for (name, _) in SyntheticForms.all {
        FileManager.default.createFile(atPath: (arguments[1] as NSString).appendingPathComponent(name + ".pdf"), contents: Data(SyntheticForms.build(name)))
    }
    return 0
}

struct CorpusEntry: Decodable {
    var name: String
    var url: String
    var sha256: String?
}

func run() -> Int32 {
    let root = FileManager.default.currentDirectoryPath
    let toolDir = (root as NSString).appendingPathComponent("pdf/tools/forms-corpus")
    guard let pdfs = option("--pdfs") else {
        print("run needs --pdfs <folder with the corpus's PDFs>")
        return 2
    }
    let outDir = option("--out") ?? NSString(string: "~/inkvolt-forms-out").expandingTildeInPath
    let corpusPath = option("--corpus") ?? (toolDir as NSString).appendingPathComponent("corpus.json")
    let baselinePath = (root as NSString).appendingPathComponent("mac/tools/forms-corpus/baseline.json")
    let limit = Double(option("--timeout") ?? "") ?? 120
    let jobs = Int(option("--jobs") ?? "") ?? 6
    let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let synthDir = (outDir as NSString).appendingPathComponent("synth")
    try? fm.createDirectory(atPath: synthDir, withIntermediateDirectories: true)

    var work: [(name: String, path: String, skip: String?)] = []
    let corpus = (readBytes(corpusPath).flatMap { try? JSONDecoder().decode([CorpusEntry].self, from: Data($0)) }) ?? []
    for c in corpus where !c.url.hasPrefix("synthetic:") {
        if let only, !only.contains(c.name) { continue }
        let path = (pdfs as NSString).appendingPathComponent(c.name + ".pdf")
        guard let bytes = readBytes(path) else {
            work.append((c.name, path, "not downloaded"))
            continue
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        work.append((c.name, path, c.sha256.map { $0 != sha } == true ? "source changed" : nil))
    }
    // --damaged: each real form again as an overwritten longer copy leaves it, and with its end cut off (MuPDF repairs both).
    if arguments.contains("--damaged") {
        let damagedDir = (outDir as NSString).appendingPathComponent("damaged")
        try? fm.createDirectory(atPath: damagedDir, withIntermediateDirectories: true)
        for item in work where item.skip == nil {
            guard let bytes = readBytes(item.path) else { continue }
            let variants = [("tail", SyntheticForms.Damage.staleTail(bytes)), ("cut", Array(bytes.dropLast(min(64, bytes.count / 2))))]
            for (kind, damaged) in variants {
                let name = item.name + "~" + kind
                let path = (damagedDir as NSString).appendingPathComponent(name + ".pdf")
                fm.createFile(atPath: path, contents: Data(damaged))
                work.append((name, path, nil))
            }
        }
    }
    for (name, _) in SyntheticForms.all {
        if let only, !only.contains(name) { continue }
        let path = (synthDir as NSString).appendingPathComponent(name + ".pdf")
        fm.createFile(atPath: path, contents: Data(SyntheticForms.build(name)))
        work.append((name, path, nil))
    }
    for path in option("--files")?.split(separator: ",").map(String.init) ?? [] {
        work.append((((path as NSString).lastPathComponent as NSString).deletingPathExtension, path, nil))
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var reports: [FormReport] = []
    }
    let box = Box()
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let gate = DispatchSemaphore(value: max(jobs, 1))
    let group = DispatchGroup()
    let items = work
    for item in items {
        gate.wait()
        group.enter()
        DispatchQueue.global().async {
            defer {
                gate.signal()
                group.leave()
            }
            var report = FormReport()
            report.name = item.name
            if let skip = item.skip {
                report.status = "skip"
                report.skip = skip
            } else {
                report = runChild(exe, item.path, outDir, item.name, limit)
            }
            box.lock.lock()
            box.reports.append(report)
            box.lock.unlock()
        }
    }
    group.wait()
    var reports = box.reports.sorted { $0.name < $1.name }
    // A damaged copy has every field and widget of the sound one.
    let sound = Dictionary(reports.filter { !$0.name.contains("~") }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    for i in reports.indices {
        let parts = reports[i].name.split(separator: "~")
        guard parts.count == 2, let base = sound[String(parts[0])] else { continue }
        if reports[i].fields != base.fields || reports[i].widgets != base.widgets {
            reports[i].fail("damage-lost-fields", "", "\(base.fields) fields, \(base.widgets) widgets became \(reports[i].fields), \(reports[i].widgets)")
        }
        if reports[i].bookmarksAfter != base.bookmarksBefore {
            reports[i].fail("damage-lost-bookmarks", "", "\(base.bookmarksBefore) bookmarks became \(reports[i].bookmarksAfter)")
        }
        if !reports[i].failures.isEmpty { reports[i].status = "fail" }
    }

    // pdf.js over the originals and the filled files, unless there is no Node or pdf.js here.
    let paths = Dictionary(items.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a })
    let node = option("--node") ?? findNode()
    let script = (toolDir as NSString).appendingPathComponent("pdfjs-fields.mjs")
    let installed = fm.fileExists(atPath: (root as NSString).appendingPathComponent("pdf/tools/pdfjs-check/node_modules/pdfjs-dist/package.json"))
    if !arguments.contains("--no-pdfjs"), let node, installed {
        func filled(_ name: String) -> String { (outDir as NSString).appendingPathComponent(name + ".filled.pdf") }
        var files: [String] = []
        for r in reports where r.skip != "not downloaded" && r.skip != "source changed" {
            if let p = paths[r.name] { files.append(p) }
            if !r.plan.isEmpty { files.append(filled(r.name)) }
        }
        let listings = PdfJs.read(node: node, script: script, files: files, jobs: jobs)
        for i in reports.indices where reports[i].skip != "not downloaded" && reports[i].skip != "source changed" {
            // A damaged copy's original is pdf.js's own repair, not the form: its fields were compared with the sound copy's above.
            let damaged = reports[i].name.contains("~")
            let original = damaged ? nil : paths[reports[i].name].flatMap { listings[$0] }
            PdfJs.compare(&reports[i], original: original, filled: listings[filled(reports[i].name)])
        }
    } else {
        print("pdf.js not run (--no-pdfjs, no node, or `npm ci` not run in pdf/tools/pdfjs-check)")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(reports) {
        fm.createFile(atPath: (outDir as NSString).appendingPathComponent("results.json"), contents: data)
    }
    let summary = Summary.markdown(reports) { name in
        paths[name].flatMap { (try? fm.attributesOfItem(atPath: $0))?[.size] as? Int } ?? Int.max
    }
    fm.createFile(atPath: (outDir as NSString).appendingPathComponent("summary.md"), contents: Data(summary.utf8))
    print(summary)

    // The baseline: each failing form's groups. New failures fail the run.
    var now: [String: [String]] = [:]
    for r in reports where !r.failures.isEmpty { now[r.name] = Array(Set(r.failures.map(Summary.group))).sorted() }
    if arguments.contains("--update-baseline") {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(now) { fm.createFile(atPath: baselinePath, contents: data) }
        return 0
    }
    guard only == nil else { return now.isEmpty ? 0 : 1 }
    let baseline = readBytes(baselinePath).flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data($0)) } ?? [:]
    var new = 0
    for (name, groups) in now.sorted(by: { $0.key < $1.key }) {
        for g in groups where baseline[name]?.contains(g) != true {
            print("NEW: \(name): \(g)")
            new += 1
        }
    }
    return new == 0 ? 0 : 1
}

func findNode() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    p.arguments = ["node"]
    let out = Pipe()
    p.standardOutput = out
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// One form in its own process: killed after `limit` seconds (a hang); a crash is reported as one.
func runChild(_ exe: String, _ path: String, _ outDir: String, _ name: String, _ limit: Double) -> FormReport {
    var report = FormReport()
    report.name = name
    let reportPath = (outDir as NSString).appendingPathComponent(name + ".report.json")
    try? FileManager.default.removeItem(atPath: reportPath)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["one", path, outDir, name]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do {
        try p.run()
    } catch {
        report.fail("crash", "", "couldn't start: \(error)")
        report.status = "fail"
        return report
    }
    if done.wait(timeout: .now() + limit) == .timedOut {
        p.terminate()
        kill(p.processIdentifier, SIGKILL)
        report.fail("hang", "", "killed after \(limit) s")
        report.status = "fail"
        return report
    }
    guard p.terminationStatus == 0, p.terminationReason == .exit, let data = readBytes(reportPath),
          let decoded = try? JSONDecoder().decode(FormReport.self, from: Data(data)) else {
        report.fail("crash", "", "exit \(p.terminationStatus), \(p.terminationReason == .exit ? "exited" : "signal")")
        report.status = "fail"
        return report
    }
    return decoded
}

switch arguments.first {
case "one": exit(one())
case "synth": exit(synth())
case "probe": exit(probe())
case "run": exit(run())
default:
    print("run --pdfs <dir> [--out dir] [--only a,b] [--files a.pdf,b.pdf] [--timeout s] [--jobs n] [--no-pdfjs] [--update-baseline]; one <in.pdf> <out-dir> <name> [password]; synth <out-dir>")
    exit(2)
}
