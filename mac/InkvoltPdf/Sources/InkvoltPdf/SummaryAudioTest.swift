import AppKit
import AVFoundation
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 4.24, a summary read aloud to a file (`--edit`, after `AskEditTest`;
/// `--only-summary-audio` runs it alone), on the synthetic text document, against a stand-in model on loopback: the
/// summary's send window first, then the answer read by a macOS voice into an M4A (AAC) and a WAV in a folder of the
/// test's own, each as long as the speech, the WAV's samples PCM. Only counts and lengths are written; a person must
/// listen to one.
@MainActor
struct SummaryAudioTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[summary-audio] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 30, _ done: @MainActor () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return done()
    }

    mutating func run() async {
        lines.append("== Summary to Audio (roadmap 4.24) on \(name), a stand-in model on loopback, a macOS voice")
        let c = controller
        AppSettings.aiKeys = AiMemoryKeyStore()
        guard let server = AiLoopbackServer(answer: { _ in .sse(["## Overview\nRevenue grew in the **north** [p. 1].\n\n", "- Costs rose more slowly."], pause: 0.005) }) else {
            check(false, "the stand-in model starts")
            return finish()
        }
        defer { server.stop() }
        var settings = AiSettings()
        settings.enabled = true
        settings.preset = "Custom"
        settings.customUrl = "http://127.0.0.1:\(server.port)/v1"
        settings.model = "test-model"
        AppSettings.ai = settings
        defer { AppSettings.ai = AiSettings() }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-audio-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else {
            lines.append("SKIP this Mac has no voices")
            return finish()
        }

        for ext in ["m4a", "wav"] {
            let path = (dir as NSString).appendingPathComponent("summary.\(ext)")
            let sent = server.received.count
            c.ai.lastAudio = nil
            c.ai.job = Task { @MainActor in await c.summaryToAudio([0], path: path) }
            let asked = await wait(30) { AiConfirmSheet.current != nil }
            check(asked && server.received.count == sent, "\(ext): the summary's send window shows before anything is sent")
            AiConfirmSheet.current?.sendClicked()
            await c.ai.job?.value
            let result = c.ai.lastAudio
            let exists = FileManager.default.fileExists(atPath: path)
            let parts = result?.parts.map { String(format: "%.1f", $0) }.joined(separator: " + ") ?? (c.ai.lastAudioError ?? "")
            check(server.received.count == sent + 1 && exists && (result?.duration ?? 0) > 1,
                  String(format: "\(ext): the summary read aloud to a file, %.1f s (\(parts))", result?.duration ?? 0))
            if ext == "m4a" {
                let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
                let seconds = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                check(file?.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC && abs(seconds - (result?.duration ?? 0)) < 0.5,
                      String(format: "m4a: AAC, as long as the speech (%.1f s)", seconds))
            } else {
                let info = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? WavFile.read([UInt8]($0)) }
                check(info?.bitsPerSample == 16 && info?.formatTag == 1 && abs((info?.duration ?? 0) - (result?.duration ?? 0)) < 0.01,
                      "wav: 16-bit PCM, \(info?.sampleRate ?? 0) Hz, \(info?.channels ?? 0) channel(s)")
            }
        }
        finish()
    }

    private func finish() {
        var out = lines
        out.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(out.joined(separator: "\n"))
    }
}
