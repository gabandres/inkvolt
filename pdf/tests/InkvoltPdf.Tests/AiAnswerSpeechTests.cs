using System.Buffers.Binary;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 4.24, a summary read aloud to a file: the answer becomes the sentences a voice reads (no Markdown marks,
/// citations as words, the AI note last), and the paragraphs' recordings are joined into one WAV file.
/// </summary>
public sealed class AiAnswerSpeechTests
{
    private static AiExchange Summary(string answer) =>
        new(AiAnswerKind.Summary, "Summarize pages 1–3", "Summarize", answer, "llama3.2", new DateTimeOffset(2026, 11, 22, 9, 0, 0, TimeSpan.Zero));

    [Fact]
    public void An_answer_is_read_as_sentences_without_its_marks_and_with_the_ai_note_last()
    {
        var paragraphs = AiAnswerSpeech.Paragraphs([Summary("## Overview\nRevenue grew in the **north** [p. 1]\n\n- The south made `3.1` million [pp. 3-4]\n1. First point\n* Second point!")]);
        Assert.Equal("Summarize pages 1–3.", paragraphs[0]);
        Assert.Equal("Overview.", paragraphs[1]);
        Assert.Equal("Revenue grew in the north (page 1).", paragraphs[2]);
        Assert.Equal("The south made 3.1 million (page 3). First point. Second point!", paragraphs[3]);
        Assert.StartsWith("Written by an AI model (llama3.2)", paragraphs[^1]);
        Assert.Equal(5, paragraphs.Count);
    }

    [Fact]
    public void A_long_paragraph_is_cut_at_sentences()
    {
        var text = string.Join(" ", Enumerable.Repeat("This sentence about the quarterly numbers is one of many.", 120));
        var paragraphs = AiAnswerSpeech.Paragraphs([Summary(text)]);
        var body = paragraphs.Skip(1).SkipLast(1).ToList();
        Assert.True(body.Count >= 3);
        Assert.All(body, p => Assert.InRange(p.Length, 1, AiAnswerSpeech.MaxParagraphChars));
        Assert.All(body, p => Assert.EndsWith(".", p));
        Assert.Equal(text, string.Join(" ", body));
    }

    /// <summary>A WAV file of <paramref name="samples"/> 16-bit mono samples at 16 kHz, with a LIST chunk of odd length before the samples.</summary>
    private static byte[] Wav(short[] samples, int rate = 16000, bool unsetSize = false)
    {
        var list = "LIST"u8.ToArray().Concat(BitConverter.GetBytes(3)).Concat("abc\0"u8.ToArray()).ToArray(); // 3 bytes and a pad byte
        var data = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++) BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(i * 2), samples[i]);
        var fmt = new byte[24];
        "fmt "u8.CopyTo(fmt);
        BinaryPrimitives.WriteInt32LittleEndian(fmt.AsSpan(4), 16);
        BinaryPrimitives.WriteInt16LittleEndian(fmt.AsSpan(8), 1);
        BinaryPrimitives.WriteInt16LittleEndian(fmt.AsSpan(10), 1);
        BinaryPrimitives.WriteInt32LittleEndian(fmt.AsSpan(12), rate);
        BinaryPrimitives.WriteInt32LittleEndian(fmt.AsSpan(16), rate * 2);
        BinaryPrimitives.WriteInt16LittleEndian(fmt.AsSpan(20), 2);
        BinaryPrimitives.WriteInt16LittleEndian(fmt.AsSpan(22), 16);
        var head = "data"u8.ToArray().Concat(BitConverter.GetBytes(unsetSize ? -1 : data.Length)).ToArray();
        var body = "WAVE"u8.ToArray().Concat(fmt).Concat(list).Concat(head).Concat(data).ToArray();
        return [.. "RIFF"u8.ToArray(), .. BitConverter.GetBytes(body.Length), .. body];
    }

    [Fact]
    public void Recordings_are_read_and_joined_with_a_pause_between_them()
    {
        var a = Wav([1, 2, 3]);
        var info = WavFile.Read(a);
        Assert.Equal((1, 16000, 16, 6), (info.Channels, info.SampleRate, info.BitsPerSample, info.DataLength));
        Assert.Equal(6, WavFile.Read(Wav([1, 2, 3], unsetSize: true)).DataLength); // a stream that left the size unset

        var joined = WavFile.Join([a, Wav([4, 5])], TimeSpan.FromMilliseconds(1)); // 16 samples of silence
        var j = WavFile.Read(joined);
        Assert.Equal(44, j.DataOffset);
        Assert.Equal((3 + 16 + 2) * 2, j.DataLength);
        Assert.Equal(1, BinaryPrimitives.ReadInt16LittleEndian(joined.AsSpan(44)));
        Assert.Equal(0, BinaryPrimitives.ReadInt16LittleEndian(joined.AsSpan(44 + 6)));
        Assert.Equal(4, BinaryPrimitives.ReadInt16LittleEndian(joined.AsSpan(44 + 6 + 32)));
        Assert.Equal(joined.Length - 8, BinaryPrimitives.ReadInt32LittleEndian(joined.AsSpan(4)));
        Assert.Equal(TimeSpan.FromSeconds(21 / 16000.0), j.Duration);
    }

    [Fact]
    public void Anything_but_matching_PCM_recordings_is_refused()
    {
        Assert.Throws<InvalidDataException>(() => WavFile.Join([Wav([1]), Wav([1], rate: 22050)]));
        Assert.Throws<InvalidDataException>(() => WavFile.Read("RIFF\0\0\0\0WAVE"u8));
        Assert.Throws<InvalidDataException>(() => WavFile.Read("ID3 an mp3"u8));
        var cut = Wav([1, 2, 3]);
        BinaryPrimitives.WriteInt32LittleEndian(cut.AsSpan(16), 4000); // the format chunk says it runs past the end
        Assert.Throws<InvalidDataException>(() => WavFile.Read(cut));
        var notPcm = Wav([1]);
        BinaryPrimitives.WriteInt16LittleEndian(notPcm.AsSpan(20), 85); // MP3 in a WAV
        Assert.Throws<InvalidDataException>(() => WavFile.Read(notPcm));
        Assert.Throws<ArgumentException>(() => WavFile.Join([]));
    }
}
