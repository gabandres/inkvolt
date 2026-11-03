import Foundation

struct FileResult: Codable {
    let file: String
    let what: String
    let sha256: String
    let median: Measured
    let runs: [Measured]
}

struct BenchResults: Codable {
    let machine: String
    let date: String
    let repetitions: Int
    let notes: [String]
    let files: [FileResult]
}

/// Runs the measures (each repetition in a fresh process of this tool), keeps the medians, writes results.json and the
/// markdown (Windows' `Harness`).
enum Harness {
    static func run(_ dir: String, _ sizes: Sizes, reps: Int, notes: [String], log: (String) -> Void) throws -> BenchResults {
        var results: [FileResult] = []
        for f in Corpus.files {
            let path = (dir as NSString).appendingPathComponent(f.name)
            guard FileManager.default.fileExists(atPath: path) else { throw BenchError("\(f.name) isn't in \(dir): run make first.") }
            var runs: [Measured] = []
            for r in 0..<reps {
                log("\(f.name): run \(r + 1) of \(reps)…")
                runs.append(try runInChild(path, f.findWord))
            }
            let m = median(runs)
            log("\(f.name): first page \(Int(m.firstPageMs)) ms, \(Int(m.pageMsAverage)) ms/page (max \(Int(m.pageMsMax))), find \(Int(m.findMs)) ms (\(m.findHits) hits), comments \(Int(m.commentsMs)) ms (\(m.comments)), peak \(Int(m.peakMb)) MB")
            results.append(FileResult(file: f.name, what: f.describe(sizes), sha256: Corpus.sha256(path), median: m, runs: runs))
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let all = BenchResults(machine: machine(), date: df.string(from: Date()), repetitions: reps, notes: notes, files: results)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("results.json")))
        return all
    }

    private static func runInChild(_ path: String, _ word: String) throws -> Measured {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        p.arguments = ["one", path, word]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw BenchError("one \(path) exited \(p.terminationStatus)") }
        return try JSONDecoder().decode(Measured.self, from: data)
    }

    /// Each field the median over the runs, so one busy moment doesn't decide a number.
    private static func median(_ runs: [Measured]) -> Measured {
        func med(_ f: (Measured) -> Double) -> Double {
            let v = runs.map(f).sorted()
            return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        var m = runs[0]
        m.readMs = med(\.readMs)
        m.openMs = med(\.openMs)
        m.firstRenderMs = med(\.firstRenderMs)
        m.pageMs = m.pageMs.indices.map { i in med { $0.pageMs[i] } }
        m.pageAgainMs = m.pageAgainMs.indices.map { i in med { $0.pageAgainMs[i] } }
        m.findMs = med(\.findMs)
        m.findAgainMs = med(\.findAgainMs)
        m.commentsMs = med(\.commentsMs)
        m.peakMb = med(\.peakMb)
        return m
    }

    static func machine() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), \(ProcessInfo.processInfo.activeProcessorCount) cores, \(mem >> 30) GB, macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static func s(_ ms: Double) -> String { String(format: "%.2f s", ms / 1000) }
    private static func pass(_ ok: Bool) -> String { ok ? "pass" : "**miss**" }

    static func markdown(_ r: BenchResults) -> String {
        let files = r.files
        func row(_ label: String, _ target: String, _ cell: (FileResult) -> String) -> String {
            "| \(label) | \(target) | " + files.map(cell).joined(separator: " | ") + " |\n"
        }
        var md = "# Speed on huge files: Inkvolt PDF for Mac\n\n"
        md += "Made by `mac/tools/bench` (README.md) on \(r.date): **\(r.machine)**. The medians of \(r.repetitions) runs, each in a fresh process, over PdfCore in a release build.\n"
        md += "\n"
        for n in r.notes { md += "- \(n)\n" }
        if !r.notes.isEmpty { md += "\n" }
        md += "## The corpus\n\nThe same pages as Windows' (`pdf/tools/bench`: the same generator, seeds and words); the bytes differ (Apple's deflate and ImageIO's JPEG encoder), so the SHA-256s do too.\n\n"
        md += "| File | What | Size | SHA-256 |\n|---|---|---|---|\n"
        for f in files { md += "| `\(f.file)` | \(f.what) | \(String(format: "%.1f", Double(f.median.bytes) / 1_048_576)) MB | `\(f.sha256.prefix(16))…` |\n" }
        md += "\n## Measures against the targets\n\n| Measure | Target | " + files.map { "`\($0.file)`" }.joined(separator: " | ") + " |\n|---|---|" + files.map { _ in "---|" }.joined() + "\n"
        md += row("Pages", "") { n($0.median.pages) }
        md += row("First page (read + open + render)", "< 1 s") { "\(s($0.median.firstPageMs)) \(pass($0.median.firstPageMs < Targets.firstPageMs))" }
        md += row("  of which: read the file / open / render", "") { "\(Int($0.median.readMs)) / \(Int($0.median.openMs)) / \(Int($0.median.firstRenderMs)) ms" }
        md += row("Scrolling proxy: 20 pages after a cold open, ms/page (slowest)", "no page > 200 ms") {
            "\(Int($0.median.pageMsAverage)) ms (\(Int($0.median.pageMsMax))) \(pass($0.median.pagesOver200 == 0))" + ($0.median.pagesOver200 > 0 ? ", \($0.median.pagesOver200) over" : "")
        }
        md += row("  the same pages again, engine still holding them: ms/page", "") { "\(Int($0.median.pageAgainMsAverage)) ms" }
        md += row("Find a word across all pages", "< 5 s") { "\(s($0.median.findMs)) \(pass($0.median.findMs < Targets.findMs)) (\"\($0.median.findWord)\": \(n($0.median.findHits)) hits)" }
        md += row("  threads reading text", "") { "\($0.median.findThreads)" }
        md += row("  a second search (\"harbor\"), from what the first remembered", "") { s($0.median.findAgainMs) }
        md += row("Comment list ready", "< 2 s") { "\(s($0.median.commentsMs)) \(pass($0.median.commentsMs < Targets.commentsMs)) (\(n($0.median.comments)) comments)" }
        md += row("Peak resident memory", "< 1.5 GB") { String(format: "%.2f GB ", $0.median.peakMb / 1024) + pass($0.median.peakMb < Targets.memoryMb) }
        md += "\n## What missed\n\n"
        var missed: [String] = []
        for f in files {
            let m = f.median
            if m.firstPageMs >= Targets.firstPageMs { missed.append("`\(f.file)`: the first page took \(s(m.firstPageMs)).") }
            if m.pagesOver200 > 0 { missed.append("`\(f.file)`: \(m.pagesOver200) of the first \(m.pageMs.count) pages took over 200 ms to render (slowest \(Int(m.pageMsMax)) ms; \(Int(m.pageMsAverage)) ms on average).") }
            if m.findMs >= Targets.findMs { missed.append("`\(f.file)`: find across \(n(m.pages)) pages took \(s(m.findMs)).") }
            if m.commentsMs >= Targets.commentsMs { missed.append("`\(f.file)`: the comment list took \(s(m.commentsMs)).") }
            if m.peakMb >= Targets.memoryMb { missed.append("`\(f.file)`: peak memory \(String(format: "%.2f", m.peakMb / 1024)) GB.") }
        }
        md += missed.isEmpty ? "Nothing.\n" : missed.map { "- \($0)\n" }.joined()
        md += "\nThe on-screen scroll (Windows' `scrollbench`) isn't measured on the Mac yet: see README.md.\n"
        return md
    }
}
