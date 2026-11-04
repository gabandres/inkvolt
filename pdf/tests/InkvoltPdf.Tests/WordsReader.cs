using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Stands in for the recognizer: whatever image it is handed, it reads the same words at the same places (pixels of that
/// image), and counts what it was handed.
/// </summary>
internal sealed class WordsReader(params (string Text, RectD Box)[] words) : ITextRecognizer
{
    private int _calls;
    private readonly List<int> _channels = [];

    public string Language => "en-US";

    public string LanguageName => "English";

    /// <summary>Runs on each read (before the words come back), with its token.</summary>
    public Action<CancellationToken>? OnRead { get; init; }

    public int Calls => _calls;

    /// <summary>The channels of each image read: 3 as rendered, 1 cleaned (grey).</summary>
    public IReadOnlyList<int> Channels
    {
        get
        {
            lock (_channels) return [.. _channels];
        }
    }

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        Interlocked.Increment(ref _calls);
        lock (_channels) _channels.Add(channels);
        OnRead?.Invoke(cancel);
        return [.. words.Select(w => new RecognizedWord(w.Text, w.Box.X, w.Box.Y, w.Box.Width, w.Box.Height, 0))];
    }

    /// <summary>A spell checker that knows only these words.</summary>
    internal sealed class Dictionary(params string[] known) : ISpelling
    {
        private readonly HashSet<string> _known = new(known, StringComparer.OrdinalIgnoreCase);

        public string Language => "en-US";

        public bool IsKnown(string word) => _known.Contains(word);

        public IReadOnlyList<string> Suggest(string word) => [];
    }
}
