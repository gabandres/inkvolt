using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// A summary read aloud to a file (roadmap 4.24): an AI answer as the paragraphs a voice reads, in order. What was asked
/// first, then the answer's headings, bullets and text as sentences (its Markdown marks gone, "[p. 3]" read as "page 3"),
/// then that an AI model wrote it and may be wrong. A paragraph longer than <see cref="MaxParagraphChars"/> is cut at a
/// sentence, so each synthesis stays small.
/// </summary>
public static partial class AiAnswerSpeech
{
    public const int MaxParagraphChars = 2000;

    /// <summary>The paragraphs to read for <paramref name="exchanges"/>, in order.</summary>
    public static IReadOnlyList<string> Paragraphs(IReadOnlyList<AiExchange> exchanges)
    {
        var list = new List<string>();
        foreach (var e in exchanges)
        {
            list.Add(Sentence(Spoken(e.Shown)));
            var text = new StringBuilder();
            foreach (var (kind, line) in AiAnswerExport.Blocks(e.Answer))
            {
                if (kind is AiAnswerExport.BlockKind.Blank or AiAnswerExport.BlockKind.Heading)
                {
                    Flush();
                    if (kind == AiAnswerExport.BlockKind.Heading && Spoken(line) is { Length: > 0 } heading) list.Add(Sentence(heading));
                    continue;
                }
                var spoken = Spoken(kind == AiAnswerExport.BlockKind.Numbered ? NumberMark().Replace(line, "") : line);
                if (spoken.Length == 0) continue;
                if (text.Length > 0) text.Append(' ');
                text.Append(Sentence(spoken));
            }
            Flush();
            list.Add(AiAnswerExport.Note(e));

            void Flush()
            {
                if (text.Length > 0) list.AddRange(Cut(text.ToString()));
                text.Clear();
            }
        }
        return [.. list.Where(p => p.Length > 0)];
    }

    /// <summary>A line as a voice should read it: without **, `, #, and with citations as words ("[p. 3]" → "(page 3)").</summary>
    public static string Spoken(string line)
    {
        var plain = string.Concat(AiAnswerExport.Runs(line).Select(r => r.Text)).Replace("`", "");
        var sb = new StringBuilder();
        var at = 0;
        foreach (var c in AiText.Citations(plain, int.MaxValue))
        {
            sb.Append(plain, at, c.Start - at);
            sb.Append('(').Append(Loc.Format(PdfStrings.Ai_PageN, c.Page + 1)).Append(')');
            at = c.Start + c.Length;
        }
        sb.Append(plain, at, plain.Length - at);
        return Spaces().Replace(sb.ToString(), " ").Trim();
    }

    /// <summary>The text ending in a full stop (or the mark it has), so a voice pauses after a heading or a bullet.</summary>
    private static string Sentence(string text) =>
        text.Length == 0 || ".!?:;…。".Contains(text[^1]) ? text : text + ".";

    private static IEnumerable<string> Cut(string text)
    {
        while (text.Length > MaxParagraphChars)
        {
            var cut = text.LastIndexOfAny(['.', '!', '?', '。'], MaxParagraphChars - 1, MaxParagraphChars / 2);
            cut = cut > 0 ? cut + 1 : text.LastIndexOf(' ', MaxParagraphChars - 1, MaxParagraphChars / 2) is > 0 and var space ? space : MaxParagraphChars;
            yield return text[..cut].Trim();
            text = text[cut..].Trim();
        }
        if (text.Length > 0) yield return text;
    }

    [GeneratedRegex(@"^\s*\d{1,3}[.)]\s+")]
    private static partial Regex NumberMark();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();
}

/// <summary>What a WAV file holds: its PCM format and where its samples are.</summary>
public sealed record WavInfo(int Channels, int SampleRate, int BitsPerSample, int FormatTag, int DataOffset, int DataLength)
{
    public TimeSpan Duration => TimeSpan.FromSeconds(DataLength / (double)Math.Max(1, SampleRate * Channels * (BitsPerSample / 8)));
}

/// <summary>
/// WAV files as Windows' speech synthesizer writes them (RIFF, a "fmt " chunk, a "data" chunk; other chunks skipped): read,
/// and several of one format joined into one, so a summary read paragraph by paragraph is one recording.
/// </summary>
public static class WavFile
{
    /// <summary>Most sample bytes one joined file holds (its sizes are 32-bit, and it is one array).</summary>
    public const int MaxDataLength = int.MaxValue - 64;

    /// <summary>The file's format and samples.</summary>
    /// <exception cref="InvalidDataException">It isn't a WAV file of PCM samples, or its chunks run past its end.</exception>
    public static WavInfo Read(ReadOnlySpan<byte> wav)
    {
        if (wav.Length < 12 || !wav[..4].SequenceEqual("RIFF"u8) || !wav.Slice(8, 4).SequenceEqual("WAVE"u8))
            throw new InvalidDataException("Not a WAV file.");
        (int Channels, int Rate, int Bits, int Tag)? format = null;
        var at = 12;
        while (at + 8 <= wav.Length)
        {
            var id = wav.Slice(at, 4);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(wav.Slice(at + 4, 4));
            var body = at + 8;
            if (size > (uint)(wav.Length - body))
            {
                // A synthesizer's stream may leave the data chunk's size unset (0xFFFFFFFF): the samples run to the end.
                if (id.SequenceEqual("data"u8) && format is not null) return Info(format.Value, body, wav.Length - body);
                throw new InvalidDataException("A chunk runs past the end.");
            }
            if (id.SequenceEqual("fmt "u8))
            {
                if (size < 16) throw new InvalidDataException("A short format chunk.");
                var tag = BinaryPrimitives.ReadUInt16LittleEndian(wav.Slice(body, 2));
                var channels = BinaryPrimitives.ReadUInt16LittleEndian(wav.Slice(body + 2, 2));
                var rate = (int)BinaryPrimitives.ReadUInt32LittleEndian(wav.Slice(body + 4, 4));
                var bits = BinaryPrimitives.ReadUInt16LittleEndian(wav.Slice(body + 14, 2));
                if (tag is not (1 or 0xFFFE) || channels is 0 or > 8 || rate is <= 0 or > 384_000 || bits is not (8 or 16 or 24 or 32))
                    throw new InvalidDataException("Not PCM samples.");
                format = (channels, rate, bits, tag);
            }
            else if (id.SequenceEqual("data"u8))
            {
                if (format is null) throw new InvalidDataException("Samples before their format.");
                return Info(format.Value, body, (int)size);
            }
            at = body + (int)size + (int)(size & 1); // chunks are padded to an even length
        }
        throw new InvalidDataException("No samples.");
    }

    private static WavInfo Info((int Channels, int Rate, int Bits, int Tag) f, int offset, int length) =>
        new(f.Channels, f.Rate, f.Bits, f.Tag, offset, length - length % Math.Max(1, f.Channels * f.Bits / 8));

    /// <summary>One WAV file of <paramref name="parts"/>' samples one after another, with a short silence between them.</summary>
    /// <exception cref="InvalidDataException">A part isn't a WAV file of PCM samples, or its format differs from the first's.</exception>
    /// <exception cref="WavTooLongException">The joined file would be past <see cref="MaxDataLength"/>.</exception>
    public static byte[] Join(IReadOnlyList<byte[]> parts, TimeSpan pause = default)
    {
        if (parts.Count == 0) throw new ArgumentException("Nothing to join.", nameof(parts));
        var infos = parts.Select(p => Read(p)).ToList();
        var first = infos[0];
        if (infos.Any(i => i.Channels != first.Channels || i.SampleRate != first.SampleRate || i.BitsPerSample != first.BitsPerSample))
            throw new InvalidDataException("The parts' formats differ.");
        var frame = first.Channels * first.BitsPerSample / 8;
        var pauseBytes = SilenceLength(first, pause);
        var total = infos.Sum(i => (long)i.DataLength) + pauseBytes * (parts.Count - 1);
        if (total > MaxDataLength) throw new WavTooLongException();
        var silence = parts.Count > 1 ? (int)pauseBytes : 0; // within MaxDataLength once there are two parts
        var output = new byte[44 + total];
        var span = output.AsSpan();
        "RIFF"u8.CopyTo(span);
        BinaryPrimitives.WriteUInt32LittleEndian(span[4..], (uint)(36 + total));
        "WAVEfmt "u8.CopyTo(span[8..]);
        BinaryPrimitives.WriteUInt32LittleEndian(span[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(span[20..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(span[22..], (ushort)first.Channels);
        BinaryPrimitives.WriteUInt32LittleEndian(span[24..], (uint)first.SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(span[28..], (uint)(first.SampleRate * frame));
        BinaryPrimitives.WriteUInt16LittleEndian(span[32..], (ushort)frame);
        BinaryPrimitives.WriteUInt16LittleEndian(span[34..], (ushort)first.BitsPerSample);
        "data"u8.CopyTo(span[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(span[40..], (uint)total);
        var at = 44;
        var silent = (byte)(first.BitsPerSample == 8 ? 0x80 : 0); // 8-bit samples are unsigned: their silence is the middle
        for (var i = 0; i < parts.Count; i++)
        {
            if (i > 0)
            {
                span.Slice(at, silence).Fill(silent);
                at += silence;
            }
            parts[i].AsSpan(infos[i].DataOffset, infos[i].DataLength).CopyTo(span[at..]);
            at += infos[i].DataLength;
        }
        return output;
    }

    /// <summary>The bytes of <paramref name="pause"/>'s silence in <paramref name="format"/>'s samples (whole frames, never negative).</summary>
    internal static long SilenceLength(WavInfo format, TimeSpan pause) =>
        (long)Math.Clamp(pause.TotalSeconds * format.SampleRate, 0, MaxDataLength) * (format.Channels * format.BitsPerSample / 8);
}

/// <summary>The recording would be past what one WAV file holds (<see cref="WavFile.MaxDataLength"/>); its message says so plainly.</summary>
public sealed class WavTooLongException() : Exception(PdfStrings.Speech_TooLong);

/// <summary>
/// The parts of a recording as they are made, their total kept as each comes: one that would take the joined file past
/// <see cref="WavFile.MaxDataLength"/> stops it there (<see cref="WavTooLongException"/>), before the rest are made and
/// kept in memory, rather than at <see cref="WavFile.Join"/> with them all held.
/// </summary>
public sealed class WavParts(TimeSpan pause)
{
    private readonly List<byte[]> _parts = [];

    /// <summary>The joined file's samples so far, silences between parts included.</summary>
    public long DataLength { get; private set; }

    public int Count => _parts.Count;

    /// <summary>Adds the next part.</summary>
    /// <exception cref="InvalidDataException">It isn't a WAV file of PCM samples.</exception>
    /// <exception cref="WavTooLongException">The joined file would be too long.</exception>
    public void Add(byte[] part)
    {
        var info = WavFile.Read(part);
        var silence = _parts.Count == 0 ? 0 : WavFile.SilenceLength(info, pause);
        var total = DataLength + silence + info.DataLength;
        if (total > WavFile.MaxDataLength) throw new WavTooLongException();
        _parts.Add(part);
        DataLength = total;
    }

    /// <summary>The parts as one WAV file (<see cref="WavFile.Join"/>).</summary>
    public byte[] Join() => WavFile.Join(_parts, pause);
}
