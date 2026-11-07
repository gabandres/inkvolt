import Foundation
import PdfCore

// InkvoltBench: roadmap 3.6's benchmark on the Mac (README.md).
//   make [--out dir] [--small] [--force]     the corpus (about 1.5 GB) into dir (default: a folder in the temp directory)
//   run  [--out dir] [--reps n] [--note t] [--md path]   every file measured n times, each in a fresh process; RESULTS.md
//   one  file word                            one measurement as JSON (what run starts)
//   scale file word [threads…]               Find's text reading on 1, 2, 4, 8 threads, each with its own engine
//   clean [--out dir]                         deletes the corpus

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func say(_ s: String) { print(s) }
let out = value("--out") ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-bench")
let sizes = args.contains("--small") ? Sizes.small : Sizes.full

do {
    switch args.first {
    case "make":
        try Corpus.make(out, sizes, force: args.contains("--force"), log: say)
    case "one":
        guard args.count >= 3 else { throw BenchError("usage: one file word") }
        let m = try Measures.run(args[1], findWord: args[2])
        let json = try JSONEncoder().encode(m)
        FileHandle.standardOutput.write(json)
        print()
    case "scale":
        guard args.count >= 3 else { throw BenchError("usage: scale file word [threads…]") }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        let counts = args.count > 3 ? args[3...].compactMap { Int($0) } : [1, 2, 4, 8]
        for n in counts {
            var times: [Double] = []
            var hits = 0
            for _ in 0..<3 {
                let r = try BenchFind.scaling(bytes, args[2], threads: n)
                times.append(r.ms)
                hits = r.hits
            }
            times.sort()
            say("threads \(n): \(Int(times[1])) ms (median of 3; \(times.map { Int($0) })), \(hits) hits, peak \(Int(Measures.peakMb())) MB")
        }
    case "run":
        let reps = value("--reps").flatMap { Int($0) } ?? 3
        let notes = args.indices.filter { args[$0] == "--note" && $0 + 1 < args.count }.map { args[$0 + 1] }
        let results = try Harness.run(out, sizes, reps: reps, notes: notes, log: say)
        let md = value("--md") ?? (out as NSString).appendingPathComponent("RESULTS.md")
        try Harness.markdown(results).write(toFile: md, atomically: true, encoding: .utf8)
        say("wrote \(md)")
    case "bands":
        // The first pages drawn as the scroll proxy draws them, split into n bands (1: one thread): cold (the display
        // list made, then drawn) and warm (drawn again), ms a page, median of 3 engines.
        guard args.count >= 2 else { throw BenchError("usage: bands file [bands…]") }
        let bytes = try PdfEngine.readFile(args[1])
        let counts = args.count > 2 ? args[2...].compactMap { Int($0) } : [1, 4, 8, 16]
        for n in counts {
            var cold: [Double] = [], warm: [Double] = []
            for _ in 0..<3 {
                let r = try PdfEngine.$bandsForTests.withValue(n) { try Measures.paint(bytes, pages: 5) }
                cold.append(r.cold)
                warm.append(r.warm)
            }
            say("bands \(n): cold \(Int(cold.sorted()[1])) ms a page, warm \(Int(warm.sorted()[1])) ms (\(cold.map { Int($0) }), \(warm.map { Int($0) }))")
        }
    case "jpegsize":
        // The JPEG size of scan page 1 at several ImageIO qualities (to match Windows' encoder, 0.86 MB a page).
        let px = Corpus.scanPixels(1)
        for q in stride(from: 0.30, through: 0.80, by: 0.05) { say(String(format: "quality %.2f: %.3f MB", q, Double(Corpus.jpeg(px, Corpus.scanWidth, Corpus.scanHeight, quality: q).count) / 1_048_576)) }
    case "clean":
        try? FileManager.default.removeItem(atPath: out)
        say("removed \(out)")
    default:
        say("usage: InkvoltBench make|run|one|scale|clean (see README.md)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
