import Foundation
import PrintCore

/// A summary read aloud to a file (roadmap 4.24; the Windows `AiAnswerSpeech`): an AI answer as the paragraphs a voice
/// reads, in order. What was asked first, then the answer's headings, bullets and text as sentences (its Markdown marks
/// gone, "[p. 3]" read as "page 3"), then that an AI model wrote it and may be wrong. A paragraph longer than
/// `maxParagraphChars` (UTF-16 units) is cut at a sentence, so each synthesis stays small.
public enum AiAnswerSpeech {
    public static let maxParagraphChars = 2000

    /// The paragraphs to read for `exchanges`, in order.
    public static func paragraphs(_ exchanges: [AiExchange]) -> [String] {
        var list: [String] = []
        for e in exchanges {
            list.append(sentence(spoken(e.shown)))
            var text = ""
            func flush() {
                if !text.isEmpty { list += cut(text) }
                text = ""
            }
            for (kind, line) in AiAnswerExport.blocks(e.answer) {
                if kind == .blank || kind == .heading {
                    flush()
                    if kind == .heading {
                        let heading = spoken(line)
                        if !heading.isEmpty { list.append(sentence(heading)) }
                    }
                    continue
                }
                var source = line
                if kind == .numbered {
                    source = AiAnswerExport.numbered.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
                }
                let said = spoken(source)
                if said.isEmpty { continue }
                if !text.isEmpty { text += " " }
                text += sentence(said)
            }
            flush()
            list.append(AiAnswerExport.note(e))
        }
        return list.filter { !$0.isEmpty }
    }

    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    /// A line as a voice should read it: without **, `, #, and with citations as words ("[p. 3]" → "(page 3)").
    public static func spoken(_ line: String) -> String {
        let plain = AiAnswerExport.plain(line).replacingOccurrences(of: "`", with: "")
        let ns = plain as NSString
        var out = ""
        var at = 0
        for c in AiText.citations(plain, Int(Int32.max)) {
            out += ns.substring(with: NSRange(location: at, length: c.start - at))
            out += "(" + loc("page {0}", CoreLanguage.number(c.page + 1)) + ")"
            at = c.start + c.length
        }
        out += ns.substring(from: at)
        let joined = spaces.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: " ")
        return AiText.trim(joined)
    }

    /// The text ending in a full stop (or the mark it has), so a voice pauses after a heading or a bullet.
    private static func sentence(_ text: String) -> String {
        guard let last = text.unicodeScalars.last else { return text }
        return ".!?:;…。".unicodeScalars.contains(last) ? text : text + "."
    }

    private static func cut(_ whole: String) -> [String] {
        var units = Array(whole.utf16)[...]
        var out: [String] = []
        let stops: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x3002]
        while units.count > maxParagraphChars {
            let start = units.startIndex
            // .NET's LastIndexOfAny(…, maxParagraphChars - 1, maxParagraphChars / 2): from 1,999 back to 1,000.
            var cut = -1
            var i = maxParagraphChars - 1
            while i >= maxParagraphChars - maxParagraphChars / 2 {
                if stops.contains(units[start + i]) {
                    cut = i + 1
                    break
                }
                i -= 1
            }
            if cut <= 0 {
                i = maxParagraphChars - 1
                while i >= maxParagraphChars - maxParagraphChars / 2 {
                    if units[start + i] == 0x20 {
                        cut = i
                        break
                    }
                    i -= 1
                }
            }
            if cut <= 0 { cut = UTF16.isLeadSurrogate(units[start + maxParagraphChars - 1]) ? maxParagraphChars - 1 : maxParagraphChars }
            out.append(AiText.trim(String(decoding: units[start..<(start + cut)], as: UTF16.self)))
            units = Array(AiText.trim(String(decoding: units[(start + cut)...], as: UTF16.self)).utf16)[...]
        }
        if !units.isEmpty { out.append(String(decoding: units, as: UTF16.self)) }
        return out
    }
}

/// A WAV file that isn't one of PCM samples, parts that don't match, or nothing to join.
public struct WavError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ why: String) { description = why }
}

/// The recording would be past what one WAV file holds (`WavFile.maxDataLength`); its message says so plainly.
public struct WavTooLong: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String {
        loc("This is too long to read aloud to one file (a WAV file holds at most 2 GB). Read fewer answers at a time.")
    }
}

/// What a WAV file holds: its PCM format and where its samples are.
public struct WavInfo: Sendable, Equatable {
    public let channels: Int
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let formatTag: Int
    public let dataOffset: Int
    public let dataLength: Int

    /// Seconds.
    public var duration: Double { Double(dataLength) / Double(max(1, sampleRate * channels * (bitsPerSample / 8))) }
}

/// WAV files (RIFF, a "fmt " chunk, a "data" chunk; other chunks skipped; the Windows `WavFile`): read, and several of one
/// format joined into one, so a summary read paragraph by paragraph is one recording.
public enum WavFile {
    /// Most sample bytes one joined file holds (its sizes are 32-bit).
    public static let maxDataLength = Int(Int32.max) - 64

    private static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
    private static func tag(_ b: [UInt8], _ at: Int, _ s: String) -> Bool { b.count >= at + 4 && Array(b[at..<(at + 4)]) == Array(s.utf8) }

    /// The file's format and samples.
    /// - Throws: `WavError` when it isn't a WAV file of PCM samples, or its chunks run past its end.
    public static func read(_ wav: [UInt8]) throws -> WavInfo {
        guard wav.count >= 12, tag(wav, 0, "RIFF"), tag(wav, 8, "WAVE") else { throw WavError("Not a WAV file.") }
        var format: (channels: Int, rate: Int, bits: Int, tag: Int)?
        var at = 12
        while at + 8 <= wav.count {
            let size = Int(u32(wav, at + 4))
            let body = at + 8
            if size > wav.count - body {
                // A synthesizer's stream may leave the data chunk's size unset (0xFFFFFFFF): the samples run to the end.
                if tag(wav, at, "data"), let format { return info(format, body, wav.count - body) }
                throw WavError("A chunk runs past the end.")
            }
            if tag(wav, at, "fmt ") {
                if size < 16 { throw WavError("A short format chunk.") }
                let t = u16(wav, body), channels = u16(wav, body + 2), rate = Int(u32(wav, body + 4)), bits = u16(wav, body + 14)
                guard t == 1 || t == 0xFFFE, (1...8).contains(channels), rate > 0, rate <= 384_000, [8, 16, 24, 32].contains(bits) else {
                    throw WavError("Not PCM samples.")
                }
                format = (channels, rate, bits, t)
            } else if tag(wav, at, "data") {
                guard let format else { throw WavError("Samples before their format.") }
                return info(format, body, size)
            }
            at = body + size + (size & 1) // chunks are padded to an even length
        }
        throw WavError("No samples.")
    }

    private static func info(_ f: (channels: Int, rate: Int, bits: Int, tag: Int), _ offset: Int, _ length: Int) -> WavInfo {
        WavInfo(channels: f.channels, sampleRate: f.rate, bitsPerSample: f.bits, formatTag: f.tag, dataOffset: offset,
                dataLength: length - length % max(1, f.channels * f.bits / 8))
    }

    /// One WAV file of `parts`' samples one after another, with `pause` seconds of silence between them.
    /// - Throws: `WavError` when a part isn't a WAV file of PCM samples, its format differs from the first's, or there is
    ///   none; `WavTooLong` when the joined file would be past `maxDataLength`.
    public static func join(_ parts: [[UInt8]], pause: Double = 0) throws -> [UInt8] {
        guard !parts.isEmpty else { throw WavError("Nothing to join.") }
        let infos = try parts.map(read)
        let first = infos[0]
        if infos.contains(where: { $0.channels != first.channels || $0.sampleRate != first.sampleRate || $0.bitsPerSample != first.bitsPerSample }) {
            throw WavError("The parts' formats differ.")
        }
        let frame = first.channels * first.bitsPerSample / 8
        let silence = parts.count > 1 ? silenceLength(first, pause) : 0
        let total = infos.reduce(0) { $0 + $1.dataLength } + silence * (parts.count - 1)
        if total > maxDataLength { throw WavTooLong() }
        var out = [UInt8]()
        out.reserveCapacity(44 + total)
        func put16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func put32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        out += Array("RIFF".utf8)
        put32(36 + total)
        out += Array("WAVEfmt ".utf8)
        put32(16)
        put16(1)
        put16(first.channels)
        put32(first.sampleRate)
        put32(first.sampleRate * frame)
        put16(frame)
        put16(first.bitsPerSample)
        out += Array("data".utf8)
        put32(total)
        let silent: UInt8 = first.bitsPerSample == 8 ? 0x80 : 0 // 8-bit samples are unsigned: their silence is the middle
        for (i, part) in parts.enumerated() {
            if i > 0 { out += [UInt8](repeating: silent, count: silence) }
            out += part[infos[i].dataOffset..<(infos[i].dataOffset + infos[i].dataLength)]
        }
        return out
    }

    /// The bytes of `pause` seconds of silence in `format`'s samples (whole frames, never negative).
    static func silenceLength(_ format: WavInfo, _ pause: Double) -> Int {
        let frames = pause.isFinite ? min(max(pause * Double(format.sampleRate), 0), Double(maxDataLength)) : 0
        return Int(frames) * (format.channels * format.bitsPerSample / 8) // bounded: clamped to 0...maxDataLength, NaN and infinity said 0
    }
}

/// The parts of a recording as they are made, their total kept as each comes: one that would take the joined file past
/// `WavFile.maxDataLength` stops it there (`WavTooLong`), before the rest are made and kept in memory.
public final class WavParts: @unchecked Sendable {
    private var parts: [[UInt8]] = []
    private let pause: Double
    /// The joined file's samples so far, silences between parts included.
    public private(set) var dataLength = 0
    public var count: Int { parts.count }

    public init(pause: Double) { self.pause = pause }

    /// Adds the next part.
    /// - Throws: `WavError` when it isn't a WAV file of PCM samples; `WavTooLong` when the joined file would be too long.
    public func add(_ part: [UInt8]) throws {
        let info = try WavFile.read(part)
        let silence = parts.isEmpty ? 0 : WavFile.silenceLength(info, pause)
        let total = dataLength + silence + info.dataLength
        if total > WavFile.maxDataLength { throw WavTooLong() }
        parts.append(part)
        dataLength = total
    }

    /// The parts as one WAV file (`WavFile.join`).
    public func join() throws -> [UInt8] { try WavFile.join(parts, pause: pause) }
}
