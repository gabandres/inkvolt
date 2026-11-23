import Foundation
import Testing
@testable import PdfCore

/// Ported from AiAnswerSpeechTests.cs (roadmap 4.24, a summary read aloud to a file): the answer becomes the sentences a
/// voice reads (no Markdown marks, citations as words, the AI note last), and the paragraphs' recordings are joined into
/// one WAV file.
struct AiAnswerSpeechTests {
    private static func summary(_ answer: String) -> AiExchange {
        AiExchange(.summary, shown: "Summarize pages 1–3", asked: "Summarize", answer: answer, model: "llama3.2",
                   when: Date(timeIntervalSince1970: 1_795_338_000))
    }

    @Test func anAnswerIsReadAsSentencesWithoutItsMarksAndWithTheAiNoteLast() {
        let paragraphs = AiAnswerSpeech.paragraphs([Self.summary("## Overview\nRevenue grew in the **north** [p. 1]\n\n- The south made `3.1` million [pp. 3-4]\n1. First point\n* Second point!")])
        #expect(paragraphs[0] == "Summarize pages 1–3.")
        #expect(paragraphs[1] == "Overview.")
        #expect(paragraphs[2] == "Revenue grew in the north (page 1).")
        #expect(paragraphs[3] == "The south made 3.1 million (page 3). First point. Second point!")
        #expect(paragraphs.last?.hasPrefix("Written by an AI model (llama3.2)") == true)
        #expect(paragraphs.count == 5)
    }

    @Test func aLongParagraphIsCutAtSentences() {
        let text = Array(repeating: "This sentence about the quarterly numbers is one of many.", count: 120).joined(separator: " ")
        let paragraphs = AiAnswerSpeech.paragraphs([Self.summary(text)])
        let body = Array(paragraphs.dropFirst().dropLast())
        #expect(body.count >= 3)
        #expect(body.allSatisfy { (1...AiAnswerSpeech.maxParagraphChars).contains($0.utf16.count) })
        #expect(body.allSatisfy { $0.hasSuffix(".") })
        #expect(body.joined(separator: " ") == text)
    }

    /// A WAV file of `samples` 16-bit mono samples at 16 kHz, with a LIST chunk of odd length before the samples.
    static func wav(_ samples: [Int16], rate: Int = 16000, unsetSize: Bool = false) -> [UInt8] {
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        let list = Array("LIST".utf8) + le32(3) + Array("abc\0".utf8) // 3 bytes and a pad byte
        let data = samples.flatMap { le16(Int(UInt16(bitPattern: $0))) }
        let fmt = Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        let head = Array("data".utf8) + (unsetSize ? [0xFF, 0xFF, 0xFF, 0xFF] : le32(data.count))
        let body = Array("WAVE".utf8) + fmt + list + head + data
        return Array("RIFF".utf8) + le32(body.count) + body
    }

    private static func i16(_ b: [UInt8], _ at: Int) -> Int16 { Int16(bitPattern: UInt16(b[at]) | UInt16(b[at + 1]) << 8) }

    @Test func recordingsAreReadAndJoinedWithAPauseBetweenThem() throws {
        let a = Self.wav([1, 2, 3])
        let info = try WavFile.read(a)
        #expect(info.channels == 1 && info.sampleRate == 16000 && info.bitsPerSample == 16 && info.dataLength == 6)
        #expect(try WavFile.read(Self.wav([1, 2, 3], unsetSize: true)).dataLength == 6) // a stream that left the size unset

        let joined = try WavFile.join([a, Self.wav([4, 5])], pause: 0.001) // 16 samples of silence
        let j = try WavFile.read(joined)
        #expect(j.dataOffset == 44)
        #expect(j.dataLength == (3 + 16 + 2) * 2)
        #expect(Self.i16(joined, 44) == 1)
        #expect(Self.i16(joined, 44 + 6) == 0)
        #expect(Self.i16(joined, 44 + 6 + 32) == 4)
        let riff = Int(joined[4]) | Int(joined[5]) << 8 | Int(joined[6]) << 16 | Int(joined[7]) << 24
        #expect(riff == joined.count - 8)
        #expect(abs(j.duration - 21 / 16000.0) < 1e-12)
    }

    @Test func anythingButMatchingPcmRecordingsIsRefused() {
        #expect(throws: WavError.self) { try WavFile.join([Self.wav([1]), Self.wav([1], rate: 22050)]) }
        #expect(throws: WavError.self) { try WavFile.read(Array("RIFF\0\0\0\0WAVE".utf8)) }
        #expect(throws: WavError.self) { try WavFile.read(Array("ID3 an mp3".utf8)) }
        var cut = Self.wav([1, 2, 3])
        cut[16] = 0xA0; cut[17] = 0x0F; cut[18] = 0; cut[19] = 0 // the format chunk says it runs past the end (4000)
        #expect(throws: WavError.self) { try WavFile.read(cut) }
        var notPcm = Self.wav([1])
        notPcm[20] = 85; notPcm[21] = 0 // MP3 in a WAV
        #expect(throws: WavError.self) { try WavFile.read(notPcm) }
        #expect(throws: WavError.self) { try WavFile.join([]) }
    }
}
