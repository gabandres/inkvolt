using System.IO;
using InkvoltPdf.Core;
using Windows.Media.MediaProperties;
using Windows.Media.SpeechSynthesis;
using Windows.Media.Transcoding;
using Windows.Storage.Streams;

namespace InkvoltPdf.App;

/// <summary>What a spoken recording came to: where it was written, how long it is, and whether an MP3 asked for became a WAV.</summary>
internal sealed record SpeechFileResult(string Path, TimeSpan Duration, bool Mp3Refused);

/// <summary>
/// A summary read aloud to a file (roadmap 4.24, free): the answer's paragraphs (<see cref="AiAnswerSpeech"/>) spoken by
/// Read Aloud's Windows voice and speed, each synthesized on its own and joined (<see cref="WavFile.Join"/>), written as a WAV
/// file, or as an MP3 through Windows' own encoder (Media Foundation's, no package) when the name ends in .mp3. Where
/// Windows can't encode MP3 (an N edition without the Media Feature Pack) the WAV is written beside it instead and said.
/// </summary>
internal static class SpeechFile
{
    public static async Task<SpeechFileResult> SaveAsync(IReadOnlyList<string> paragraphs, string path, IProgress<(int Done, int Total)>? progress, CancellationToken cancel)
    {
        using var synth = new SpeechSynthesizer();
        if (ReadAloud.ChosenVoiceId is { } id && SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == id) is { } voice) synth.Voice = voice;
        synth.Options.SpeakingRate = ReadAloud.ChosenSpeed;
        // Counted as each paragraph comes: past one WAV file's 2 GB it stops there (WavTooLongException), not once all are in memory.
        var parts = new WavParts(TimeSpan.FromMilliseconds(350));
        for (var i = 0; i < paragraphs.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            using var stream = await synth.SynthesizeTextToStreamAsync(paragraphs[i]).AsTask(cancel);
            parts.Add(await ReadAll(stream, cancel));
            progress?.Report((i + 1, paragraphs.Count));
        }
        var wav = parts.Join();
        var duration = WavFile.Read(wav).Duration;
        if (!path.EndsWith(".mp3", StringComparison.OrdinalIgnoreCase))
        {
            await Task.Run(() => AtomicFile.WriteAllBytes(path, wav), cancel);
            return new SpeechFileResult(path, duration, false);
        }
        if (await ToMp3(wav, cancel) is { } mp3)
        {
            await Task.Run(() => AtomicFile.WriteAllBytes(path, mp3), cancel);
            return new SpeechFileResult(path, duration, false);
        }
        // Beside the MP3 asked for, never over a file already there.
        var instead = PdfFiles.UniquePath(Path.GetDirectoryName(Path.GetFullPath(path))!, Path.GetFileNameWithoutExtension(path) + ".wav");
        await Task.Run(() => AtomicFile.WriteAllBytes(instead, wav), cancel);
        return new SpeechFileResult(instead, duration, true);
    }

    /// <summary>The WAV as an MP3 by Windows' own encoder; null when Windows has none (or it refuses this format).</summary>
    private static async Task<byte[]?> ToMp3(byte[] wav, CancellationToken cancel)
    {
        try
        {
            using var source = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(source.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(wav);
                await writer.StoreAsync().AsTask(cancel);
                await writer.FlushAsync().AsTask(cancel);
                writer.DetachStream();
            }
            source.Seek(0);
            using var target = new InMemoryRandomAccessStream();
            var transcoder = new MediaTranscoder();
            var prepared = await transcoder.PrepareStreamTranscodeAsync(source, target, MediaEncodingProfile.CreateMp3(AudioEncodingQuality.Medium)).AsTask(cancel);
            if (!prepared.CanTranscode)
            {
                Log.Write($"MP3: Windows can't encode it ({prepared.FailureReason})");
                return null;
            }
            await prepared.TranscodeAsync().AsTask(cancel);
            target.Seek(0);
            return await ReadAll(target, cancel);
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            Log.Write($"MP3: Windows' encoder failed: {ex.GetType().Name} 0x{ex.HResult:X8}");
            return null;
        }
    }

    private static async Task<byte[]> ReadAll(IRandomAccessStream stream, CancellationToken cancel)
    {
        if (stream.Size > 512UL << 20) throw new InvalidDataException("A recording too long.");
        var size = (uint)stream.Size;
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync(size).AsTask(cancel);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);
        return bytes;
    }
}
