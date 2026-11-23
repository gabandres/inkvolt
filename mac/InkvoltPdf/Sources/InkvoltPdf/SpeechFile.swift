import AppKit
import AVFoundation
import PdfCore
import PrintCore

/// What a spoken recording came to: where it was written and how long it is (seconds).
struct SpeechFileResult {
    let path: String
    let duration: Double
    /// Each paragraph's length (seconds), in order (the self-test reads them).
    var parts: [Double] = []
}

/// One paragraph synthesized to samples by `AVSpeechSynthesizer.write(_:toBufferCallback:)`, as a 16-bit WAV.
@MainActor
private final class ParagraphRecorder: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var samples: [Int16] = []
    private var rate = 22050
    private var channels = 1
    private var done: CheckedContinuation<Void, Never>?
    /// When the last buffer came: a voice that never sends its empty last buffer is taken as done after a while.
    private var lastBuffer = Date()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The paragraph's recording as a WAV file (16-bit PCM, the voice's own rate).
    func record(_ text: String, voice: String?, speed: Double) async -> [UInt8] {
        samples = []
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = v }
        let r = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        utterance.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        lastBuffer = Date()
        let watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastBuffer) > (self.samples.isEmpty ? 30 : 5) { return self.finish() }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            done = c
            synthesizer.write(utterance) { [weak self] buffer in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(buffer) } }
            }
        }
        watchdog.cancel()
        return Self.wav(samples, rate: rate, channels: channels)
    }

    private func take(_ buffer: AVAudioBuffer) {
        guard done != nil, let pcm = buffer as? AVAudioPCMBuffer else { return }
        lastBuffer = Date()
        if pcm.frameLength == 0 { return finish() } // the end
        rate = Int(pcm.format.sampleRate.rounded()) // bounded: a voice's rate, 8,000 to 48,000 Hz
        channels = Int(pcm.format.channelCount)
        let frames = Int(pcm.frameLength)
        if let data = pcm.int16ChannelData {
            for f in 0..<frames { for ch in 0..<channels { samples.append(data[ch][f * pcm.stride]) } }
        } else if let data = pcm.floatChannelData {
            for f in 0..<frames {
                for ch in 0..<channels {
                    let x = data[ch][f * pcm.stride]
                    let v = x.isFinite ? max(-1, min(1, x)) : 0
                    samples.append(Int16(v * 32767)) // bounded: clamped to -1...1, NaN said 0
                }
            }
        }
    }

    private func finish() {
        done?.resume()
        done = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish() } }
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    /// 16-bit interleaved samples as a WAV file.
    static func wav(_ samples: [Int16], rate: Int, channels: Int) -> [UInt8] {
        var out = [UInt8]()
        func put16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func put32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        let data = samples.count * 2
        out += Array("RIFF".utf8)
        put32(36 + data)
        out += Array("WAVEfmt ".utf8)
        put32(16)
        put16(1)
        put16(channels)
        put32(rate)
        put32(rate * channels * 2)
        put16(channels * 2)
        put16(16)
        out += Array("data".utf8)
        put32(data)
        out.reserveCapacity(out.count + data)
        for s in samples { put16(Int(UInt16(bitPattern: s))) }
        return out
    }
}

/// A summary read aloud to a file (roadmap 4.24; the Windows `SpeechFile`): the answer's paragraphs (`AiAnswerSpeech`)
/// spoken by Read Aloud's macOS voice and speed, each synthesized on its own (`AVSpeechSynthesizer.write`) and joined
/// (`WavParts`), written as an M4A (AAC, through `AVAudioFile`; Windows makes MP3) or, when the name ends in .wav, as a WAV.
@MainActor
enum SpeechFile {
    static func save(_ paragraphs: [String], to path: String, voice: String?, speed: Double,
                     progress: (Int, Int) -> Void, cancel: CancelToken) async throws -> SpeechFileResult {
        let recorder = ParagraphRecorder()
        let id = cancel.register { DispatchQueue.main.async { MainActor.assumeIsolated { recorder.stop() } } }
        defer { cancel.unregister(id) }
        // Counted as each paragraph comes: past one WAV file's 2 GB it stops there, not once all are in memory.
        let parts = WavParts(pause: 0.35)
        var lengths: [Double] = []
        for (i, paragraph) in paragraphs.enumerated() {
            try cancel.check()
            let wav = await recorder.record(paragraph, voice: voice, speed: speed)
            try cancel.check()
            let info = try? WavFile.read(wav)
            lengths.append(info?.duration ?? 0)
            if info?.dataLength ?? 0 > 0 { try parts.add(wav) }
            progress(i + 1, paragraphs.count)
        }
        guard parts.count > 0 else { throw WavError("No samples.") }
        let joined = try parts.join()
        let info = try WavFile.read(joined)
        let temp = path + ".partial"
        defer { unlink(temp) }
        if path.lowercased().hasSuffix(".wav") {
            guard FileManager.default.createFile(atPath: temp, contents: Data(joined)) else { throw WavError("Couldn't write.") }
        } else {
            try Self.writeM4a(joined, info, to: temp)
        }
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
        return SpeechFileResult(path: path, duration: info.duration, parts: lengths)
    }

    /// The joined samples as AAC in an M4A file.
    private static func writeM4a(_ wav: [UInt8], _ info: WavInfo, to path: String) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: info.sampleRate,
                                       AVNumberOfChannelsKey: info.channels, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(info.sampleRate), channels: AVAudioChannelCount(info.channels), interleaved: true) else {
            throw WavError("Not PCM samples.")
        }
        let frameBytes = info.channels * 2
        let chunk = 32_768
        var at = info.dataOffset
        let end = info.dataOffset + info.dataLength
        while at < end {
            let frames = min(chunk, (end - at) / frameBytes)
            if frames == 0 { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let out = buffer.int16ChannelData else {
                throw WavError("Couldn't write.")
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            wav.withUnsafeBytes { raw in
                let src = raw.baseAddress!.advanced(by: at)
                memcpy(out[0], src, frames * frameBytes)
            }
            try file.write(from: buffer)
            at += frames * frameBytes
        }
    }
}

/// Tools › AI Assistant › Summary to Audio… (roadmap 4.24, free; the Windows `AiSummaryToAudio`): the pages summarized (the
/// send window as always), then the summary read aloud to a file.
extension DocumentWindowController {
    @objc func aiSummaryToAudio(_ sender: Any?) {
        ai.job = Task { @MainActor in
            guard await aiReady(), let chosen = await askSummaryPages() else { return }
            await summaryToAudio(chosen)
        }
    }

    /// Summarizes `chosen`, then saves the summary read aloud: to `path` when given (the self-test), else where the person
    /// picks.
    func summaryToAudio(_ chosen: [Int], path given: String? = nil) async {
        let before = ai.turns.count
        await summarize(chosen)
        guard ai.turns.count > before, let turn = ai.turns.last, let window else { return }
        let model = AiService.current(AppSettings.ai).config?.model ?? ""
        let exchange = AiExchange(.summary, shown: turn.question, asked: turn.question, answer: turn.answer, model: model, when: Date())
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else {
            return notify(loc("This Mac has no voices to read with. Add one in System Settings › Accessibility › Spoken Content."))
        }
        var path = given
        if path == nil {
            let panel = NSSavePanel()
            panel.title = loc("Save as Audio")
            panel.allowedContentTypes = [.mpeg4Audio, .wav]
            let name = (pdf.name as NSString).deletingPathExtension
            panel.nameFieldStringValue = loc("{0} - summary", name) + ".m4a"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            path = url.path
        }
        guard let path else { return }
        let paragraphs = AiAnswerSpeech.paragraphs([exchange])
        let sheet = ProgressSheet(title: loc("Save as Audio"), text: loc("Reading the answer aloud…"))
        if window.attachedSheet == nil { sheet.begin(on: window) }
        defer { sheet.end() }
        do {
            let result = try await SpeechFile.save(paragraphs, to: path, voice: ReadAloud.chosenVoice, speed: ReadAloud.chosenSpeed, progress: { done, total in
                sheet.update(loc("Reading aloud: paragraph {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total)), Double(done) / Double(max(total, 1)))
            }, cancel: sheet.token)
            ai.lastAudio = result
            ai.lastAudioError = nil
            let seconds = Int(result.duration.rounded()) // bounded: a recording's length, at most 2 GB of samples
            let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
            notify(loc("Saved {0} ({1}).", (result.path as NSString).lastPathComponent, length))
        } catch is CancellationError {
            notify(loc("Stopped. No recording was saved."))
        } catch let e as WavTooLong {
            notify(e.description)
        } catch {
            ai.lastAudioError = "\(error)"
            notify(loc("The recording couldn't be made or saved. Check that the folder exists and the file isn't open in another app, then try again."))
        }
    }
}
