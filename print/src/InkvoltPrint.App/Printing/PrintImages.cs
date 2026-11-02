using System.IO;
using System.Windows.Media.Imaging;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// JPEG pictures for one print job, each kept as a temporary file and loaded from its file URI. The XPS serializer copies
/// such a picture into the job byte for byte (image/jpeg) and tells pictures apart by that URI. Loaded from a stream
/// instead, every <see cref="BitmapFrame"/> has the same name (its decoder's type), so the serializer would put the first
/// picture on every page; and a <see cref="BitmapImage"/> it re-encodes as PNG, several times larger in the spool.
/// Dispose once the job is written: the files go.
/// </summary>
public sealed class PrintImages : IDisposable
{
    internal static readonly string Root = Path.Combine(Path.GetTempPath(), "Inkvolt Print jobs");
    private readonly string _folder;
    private int _next;

    public PrintImages()
    {
        RemoveLeftovers();
        _folder = Path.Combine(Root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_folder);
    }

    /// <summary>The JPEG as a frozen frame the serializer embeds unchanged.</summary>
    public BitmapFrame Jpeg(byte[] jpeg)
    {
        var path = Path.Combine(_folder, $"{++_next}.jpg");
        File.WriteAllBytes(path, jpeg);
        var frame = BitmapFrame.Create(new Uri(path), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        if (frame.CanFreeze) frame.Freeze();
        return frame;
    }

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Print images not removed: {ex.Message}"); // the next job removes them
        }
    }

    /// <summary>Folders of jobs that ended without cleaning up (the app was closed while spooling), a day or more old.</summary>
    private static void RemoveLeftovers()
    {
        try
        {
            if (!Directory.Exists(Root)) return;
            foreach (var dir in Directory.GetDirectories(Root))
                if (Directory.GetLastWriteTimeUtc(dir) < DateTime.UtcNow.AddDays(-1))
                    try { Directory.Delete(dir, recursive: true); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Print images clean-up: {ex.Message}");
        }
    }
}
