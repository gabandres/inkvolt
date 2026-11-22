using System.Threading.Channels;

namespace InkvoltPrint.Core.Capture;

/// <summary>A camera Windows lists (a webcam, a document camera): its id and its name.</summary>
public sealed record CameraInfo(string Id, string Name);

/// <summary>One way a camera can stream: its frame size, frames a second and pixel format (as Windows names it: NV12, YUY2, MJPG…).</summary>
public sealed record CameraFormat(int Width, int Height, double FramesPerSecond, string Subtype);

/// <summary>This PC's cameras (Windows.Media.Capture in the app; a made-up one in demo mode).</summary>
public interface ICameras
{
    Task<IReadOnlyList<CameraInfo>> ListAsync(CancellationToken ct = default);

    /// <summary>Starts <paramref name="camera"/> at the format <see cref="CameraFormats.Choose"/> picks. Throws <see cref="CameraException"/> with words to show.</summary>
    Task<ICameraFeed> OpenAsync(CameraInfo camera, CancellationToken ct = default);
}

/// <summary>A camera streaming: its frames as they come, and the latest one in full. Disposing stops the camera (its light goes off).</summary>
public interface ICameraFeed : IAsyncDisposable
{
    /// <summary>The frames' size.</summary>
    (int Width, int Height) Size { get; }

    /// <summary>A new frame came (from the camera's thread, a few a second at most): BGRA, rows of width × 4 bytes. Copy what's kept.</summary>
    event Action<byte[], int, int>? Frame;

    /// <summary>The latest frame in full, upright, as BGR; null before the first one came.</summary>
    Picture? Latest();
}

/// <summary>A camera couldn't be started; <see cref="Exception.Message"/> says why in plain words.</summary>
public sealed class CameraException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Which of a camera's formats a scan uses (roadmap 4.12), and its frames as pictures.</summary>
public static class CameraFormats
{
    /// <summary>A frame of BGRA pixels (rows of <paramref name="width"/> × 4 bytes) as a BGR picture; null when it isn't that size.</summary>
    public static Picture? Bgr(byte[] bgra, int width, int height)
    {
        if (width < 1 || height < 1 || (long)width * height > PhotoInput.MaxPixels || bgra.LongLength != (long)width * height * 4) return null;
        var bgr = new byte[width * height * 3];
        Parallel.For(0, height, y =>
        {
            for (int x = 0, i = y * width * 4, o = y * width * 3; x < width; x++, i += 4, o += 3)
            {
                bgr[o] = bgra[i];
                bgr[o + 1] = bgra[i + 1];
                bgr[o + 2] = bgra[i + 2];
            }
        });
        return new Picture(bgr, width, height, 3);
    }

    /// <summary>A preview slower than this (frames a second) is too slow to aim the page by.</summary>
    public const double MinFramesPerSecond = 5;

    /// <summary>
    /// The format with the most pixels within <see cref="PhotoInput"/>'s limits that streams at least <see cref="MinFramesPerSecond"/>
    /// (a document camera's 4K at 15, not its 13 megapixels at 2), the faster of two the same size; none that fast: the largest within
    /// the limits. Null when there's none at all (every format larger than the limits, or under its smallest side).
    /// </summary>
    public static CameraFormat? Choose(IReadOnlyList<CameraFormat> formats)
    {
        var usable = formats.Where(f => f.Width >= PhotoInput.MinSide && f.Height >= PhotoInput.MinSide && f.Width <= PhotoInput.MaxSide
            && f.Height <= PhotoInput.MaxSide && (long)f.Width * f.Height <= PhotoInput.MaxPixels && double.IsFinite(f.FramesPerSecond)).ToList();
        var smooth = usable.Where(f => f.FramesPerSecond >= MinFramesPerSecond).ToList();
        return (smooth.Count > 0 ? smooth : usable)
            .OrderByDescending(f => (long)f.Width * f.Height).ThenByDescending(f => f.FramesPerSecond).FirstOrDefault();
    }
}

/// <summary>
/// One camera scan (roadmap 4.12): each Capture takes the camera's latest frame in full and hands it to the scan as a photo
/// (<see cref="CaptureScanner"/> makes it a page), at most <see cref="MaxPages"/>; Done (or the window closing) ends it.
/// </summary>
public sealed class CameraSession
{
    public const int MaxPages = 100;

    private readonly Channel<CapturedPhoto> _photos = Channel.CreateUnbounded<CapturedPhoto>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Lock _gate = new();
    private int _taken;
    private bool _finished;

    public ChannelReader<CapturedPhoto> Photos => _photos.Reader;

    public int Taken
    {
        get { lock (_gate) return _taken; }
    }

    public bool IsFinished
    {
        get { lock (_gate) return _finished; }
    }

    /// <summary>Takes <paramref name="feed"/>'s latest frame. False: there's none yet, the scan ended, or it holds <see cref="MaxPages"/>.</summary>
    public bool Capture(ICameraFeed? feed)
    {
        if (feed?.Latest() is not { } frame) return false;
        lock (_gate)
        {
            if (_finished || _taken >= MaxPages) return false;
            _taken++;
        }
        return _photos.Writer.TryWrite(new CapturedPhoto(Frame: frame));
    }

    public bool CanCapture
    {
        get { lock (_gate) return !_finished && _taken < MaxPages; }
    }

    /// <summary>Done: the frames taken go on to be pages, nothing more is taken.</summary>
    public void Finish()
    {
        lock (_gate)
        {
            if (_finished) return;
            _finished = true;
        }
        _photos.Writer.TryComplete();
    }

    /// <summary>The line under the preview: how many pages were taken, and when no more can be.</summary>
    public string StatusText() => Taken switch
    {
        0 => CoreStrings.Camera_StatusNone,
        >= MaxPages => CoreStrings.Camera_StatusFull,
        var n => Plural.Of(n, CoreStrings.Camera_StatusTaken_One, CoreStrings.Camera_StatusTaken_Many),
    };
}
