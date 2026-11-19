using System.Security.Cryptography;

namespace InkvoltPdf.Core;

/// <summary>A file Inkvolt takes out of the Tesseract installer: its place in the decompressed stream, size and SHA-256.</summary>
public sealed record EngineFile(string Name, long Offset, long Size, string Sha256);

/// <summary>One of Tesseract's languages: its code ("hin"), BCP-47 tag ("hi"), English name, and its data file's size and SHA-256.</summary>
public sealed record TesseractLanguage(string Code, string Tag, string EnglishName, long Size, string Sha256)
{
    /// <summary>tessdata_fast's file at the pinned commit.</summary>
    public Uri Url => new($"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{TesseractCatalog.LanguageCommit}/{Code}.traineddata");
}

/// <summary>
/// Tesseract's pinned files (<c>TesseractCatalog.cs</c>, written by <c>pdf/tools/tesseract-pin</c>) and the languages it
/// reads, matched to a BCP-47 tag.
/// </summary>
public static partial class TesseractCatalog
{
    /// <summary>The disk the engine takes once taken out of the installer.</summary>
    public static long EngineBytes => EngineFiles.Sum(f => f.Size);

    public static TesseractLanguage? ByCode(string code) => Languages.FirstOrDefault(l => l.Code == code);

    /// <summary>
    /// The language that reads <paramref name="tag"/> ("en-US" → eng, "zh-Hant-TW" → chi_tra, "sr-Latn-RS" → srp_latn):
    /// the same language, and the same script when either says one (Chinese without one: Traditional for Taiwan, Hong
    /// Kong and Macao). Null when Tesseract hasn't the language.
    /// </summary>
    public static TesseractLanguage? ForTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var (language, script, region) = Split(tag);
        if (language == "zh" && script is null) script = region is "TW" or "HK" or "MO" ? "Hant" : "Hans";
        if (language == "no" || language == "nn") language = "nb"; // Tesseract's Norwegian is one model
        TesseractLanguage? first = null;
        foreach (var l in Languages)
        {
            var (lang, s, _) = Split(l.Tag);
            if (!string.Equals(lang, language, StringComparison.OrdinalIgnoreCase)) continue;
            if (script is null || s is null || string.Equals(s, script, StringComparison.OrdinalIgnoreCase))
            {
                if (script is not null && s is not null) return l; // the script named matches: the one
                first ??= l;
            }
        }
        return first;
    }

    /// <summary>A tag's language, script (four letters) and region (two letters or three digits), any of the last two null.</summary>
    internal static (string Language, string? Script, string? Region) Split(string tag)
    {
        var parts = tag.Trim().Replace('_', '-').Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return ("", null, null);
        string? script = null, region = null;
        foreach (var p in parts.Skip(1))
        {
            if (p.Length == 4 && p.All(char.IsAsciiLetter) && script is null && region is null) script = char.ToUpperInvariant(p[0]) + p[1..].ToLowerInvariant();
            else if ((p.Length == 2 && p.All(char.IsAsciiLetter)) || (p.Length == 3 && p.All(char.IsAsciiDigit))) region ??= p.ToUpperInvariant();
        }
        return (parts[0].ToLowerInvariant(), script, region);
    }
}

/// <summary>
/// The Tesseract engine and its languages on this PC, in a folder of the app's own data (<c>tesseract</c> in Inkvolt
/// PDF's data folder: writable in the Store package too). Nothing is there until the person asks: the engine is taken
/// out of the Tesseract project's own Windows installer, downloaded from its pinned GitHub release and checked
/// (<see cref="PinnedDownload"/>), without running it: its LZMA stream is decoded here (<see cref="Lzma"/>) and only
/// tesseract.exe, the DLLs it loads and the licence are kept, each checked against its pinned SHA-256; the installer is
/// then deleted. A language is its tessdata_fast file, downloaded and checked the same way. Before first use in a run,
/// every file is checked again (<see cref="Verify"/>), so a file changed since isn't run.
/// </summary>
public sealed class TesseractStore(string root)
{
    private readonly Lock _gate = new();
    private readonly HashSet<string> _verified = [];

    public string Root => root;

    public string EngineFolder => Path.Combine(root, "engine", TesseractCatalog.Version);

    public string LanguageFolder => Path.Combine(root, "tessdata");

    public string Executable => Path.Combine(EngineFolder, "tesseract.exe");

    public string LanguageFile(TesseractLanguage language) => Path.Combine(LanguageFolder, language.Code + ".traineddata");

    /// <summary>Whether the engine's files are all there at their pinned sizes (cheap: no hashing).</summary>
    public bool HasEngine => TesseractCatalog.EngineFiles.All(f => SizeIs(Path.Combine(EngineFolder, f.Name), f.Size));

    /// <summary>Whether a language's data is there at its pinned size (cheap: no hashing).</summary>
    public bool HasLanguage(TesseractLanguage language) => SizeIs(LanguageFile(language), language.Size);

    /// <summary>
    /// Whether the engine and <paramref name="languages"/> are there and each file is the pinned one (SHA-256), checked
    /// once per run for each; a file that isn't is deleted, so it is downloaded again when asked.
    /// </summary>
    public bool Verify(IEnumerable<TesseractLanguage> languages, CancellationToken cancel = default)
    {
        lock (_gate)
        {
            if (!_verified.Contains(""))
            {
                foreach (var f in TesseractCatalog.EngineFiles)
                {
                    var path = Path.Combine(EngineFolder, f.Name);
                    if (PinnedDownload.Matches(path, f.Size, f.Sha256, cancel)) continue;
                    PinnedDownload.TryDelete(path);
                    return false;
                }
                _verified.Add("");
            }
            foreach (var l in languages)
            {
                if (_verified.Contains(l.Code)) continue;
                if (!PinnedDownload.Matches(LanguageFile(l), l.Size, l.Sha256, cancel))
                {
                    PinnedDownload.TryDelete(LanguageFile(l));
                    return false;
                }
                _verified.Add(l.Code);
            }
            return true;
        }
    }

    /// <summary>
    /// Downloads the installer, checks it, takes the engine's files out of it into <see cref="EngineFolder"/> (each
    /// checked) and deletes it. Progress: 0 to 1 (download then extraction). Nothing is left half-done: the files go to a
    /// folder beside it first and are moved into place only when all of them are right.
    /// </summary>
    public async Task InstallEngineAsync(HttpClient http, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        Directory.CreateDirectory(root);
        var installer = Path.Combine(root, "tesseract-setup.download");
        try
        {
            if (!PinnedDownload.Matches(installer, TesseractCatalog.InstallerSize, TesseractCatalog.InstallerSha256, cancel))
                await PinnedDownload.FetchAsync(http, TesseractCatalog.InstallerUrl, TesseractCatalog.InstallerSize, TesseractCatalog.InstallerSha256,
                    installer, progress is null ? null : new Fraction(progress, 0, 0.6, TesseractCatalog.InstallerSize), cancel).ConfigureAwait(false);
            await Task.Run(() => Extract(installer, TesseractCatalog.StreamOffset, TesseractCatalog.StreamProperties, TesseractCatalog.StreamDictionary,
                TesseractCatalog.EngineFiles, EngineFolder, progress is null ? null : new Fraction(progress, 0.6, 0.4, TesseractCatalog.EngineFiles.Max(f => f.Offset + f.Size)),
                cancel), cancel).ConfigureAwait(false);
            lock (_gate) _verified.Add("");
        }
        finally
        {
            PinnedDownload.TryDelete(installer);
        }
        progress?.Report(1);
    }

    /// <summary>Downloads a language's data into <see cref="LanguageFolder"/>, checked. Progress: 0 to 1.</summary>
    public async Task InstallLanguageAsync(HttpClient http, TesseractLanguage language, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        await PinnedDownload.FetchAsync(http, language.Url, language.Size, language.Sha256, LanguageFile(language),
            progress is null ? null : new Fraction(progress, 0, 1, language.Size), cancel).ConfigureAwait(false);
        lock (_gate) _verified.Add(language.Code);
    }

    /// <summary>
    /// Takes <paramref name="files"/> out of the solid LZMA stream at <paramref name="offset"/> of <paramref name="archive"/>
    /// (an NSIS installer's), into <paramref name="destination"/>: each must have its size and SHA-256, else nothing is
    /// kept and <see cref="InvalidDataException"/> is thrown. The stream's properties must be the pinned ones.
    /// </summary>
    public static void Extract(string archive, long offset, byte properties, uint dictionary, IReadOnlyList<EngineFile> files, string destination,
        IProgress<long>? progress = null, CancellationToken cancel = default)
    {
        if (files.Count == 0 || files.Any(f => f.Offset < 0 || f.Size < 0 || f.Name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || f.Name is "." or ".."))
            throw new ArgumentException("Not a list of files to take.", nameof(files));
        var staging = destination + ".partial";
        if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        Directory.CreateDirectory(staging);
        try
        {
            using (var input = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            {
                if (offset + 5 > input.Length) throw new InvalidDataException("The installer is shorter than expected.");
                input.Position = offset;
                Span<byte> header = stackalloc byte[5];
                input.ReadExactly(header);
                if (header[0] != properties || BitConverter.ToUInt32(header[1..]) != dictionary)
                    throw new InvalidDataException("The installer's stream isn't the one expected.");
                input.Position = offset;
                var end = files.Max(f => f.Offset + f.Size);
                using var sink = new RangeSink(files, staging);
                Lzma.Decode(input, sink, maxOutput: end + (1 << 20), stopAfter: end, progress, cancel);
                sink.Finish();
            }
            if (Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            Directory.Move(staging, destination);
        }
        catch
        {
            try
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // written over next time
            }
            throw;
        }
    }

    private static bool SizeIs(string path, long size)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && info.Length == size;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>Byte counts as a part (<paramref name="share"/> from <paramref name="start"/>) of a 0-1 progress.</summary>
    private sealed class Fraction(IProgress<double> to, double start, double share, long total) : IProgress<long>
    {
        public void Report(long value) => to.Report(start + share * Math.Clamp((double)value / Math.Max(1, total), 0, 1));
    }

    /// <summary>
    /// The decompressed stream, written nowhere but into the files whose ranges it passes: each one hashed as it goes and
    /// checked at the end (<see cref="Finish"/>).
    /// </summary>
    private sealed class RangeSink : Stream
    {
        private readonly (EngineFile File, FileStream Out, IncrementalHash Hash)[] _files;
        private long _position;

        public RangeSink(IReadOnlyList<EngineFile> files, string folder) =>
            _files = [.. files.OrderBy(f => f.Offset).Select(f => (f, new FileStream(Path.Combine(folder, f.Name), FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16),
                IncrementalHash.CreateHash(HashAlgorithmName.SHA256)))];

        public override void Write(byte[] buffer, int offset, int count)
        {
            var (start, end) = (_position, _position + count);
            foreach (var (file, output, hash) in _files)
            {
                var (from, to) = (Math.Max(start, file.Offset), Math.Min(end, file.Offset + file.Size));
                if (from >= to) continue;
                var at = offset + (int)(from - start);
                var n = (int)(to - from);
                output.Write(buffer, at, n);
                hash.AppendData(buffer, at, n);
            }
            _position = end;
        }

        public void Finish()
        {
            foreach (var (file, output, hash) in _files)
            {
                if (output.Length != file.Size || !string.Equals(Convert.ToHexStringLower(hash.GetHashAndReset()), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"{file.Name} isn't the file expected.");
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
                foreach (var (_, output, hash) in _files)
                {
                    output.Dispose();
                    hash.Dispose();
                }
            base.Dispose(disposing);
        }

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => _position;
        public override long Position { get => _position; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
