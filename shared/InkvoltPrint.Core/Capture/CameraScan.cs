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

/// <summary>A preview frame: BGRA, rows of <see cref="Width"/> × 4 bytes, in a buffer the feed reuses once <see cref="ICameraFeed.Shown"/> is called.</summary>
public sealed record CameraPreview(byte[] Bgra, int Width, int Height);

/// <summary>A frame taken in full for a page: upright BGR, and the camera's count of it (two captures of one frame have the same).</summary>
public sealed record CameraFrame(Picture Picture, long Number);

/// <summary>
/// A camera streaming. Only frames shown or taken are copied: a preview at most ten times a second, and none while the last one isn't
/// <see cref="Shown"/> yet; <see cref="CaptureAsync"/> copies the next frame in full. Disposing stops the camera (its light goes off).
/// </summary>
public interface ICameraFeed : IAsyncDisposable
{
    /// <summary>The frames' size (0 × 0 before the first).</summary>
    (int Width, int Height) Size { get; }

    /// <summary>A preview frame came (from the camera's thread). Its buffer is the feed's: copy it, then call <see cref="Shown"/>.</summary>
    event Action<CameraPreview>? Preview;

    /// <summary>The last preview was copied: the next may come, in the same buffer.</summary>
    void Shown();

    /// <summary>The next frame in full; null when none comes (the camera stopped, or <paramref name="ct"/> was cancelled first).</summary>
    Task<CameraFrame?> CaptureAsync(CancellationToken ct = default);
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
/// One camera scan (roadmap 4.12): each Capture takes the camera's next frame in full and hands it to the scan as a photo
/// (<see cref="CaptureScanner"/> makes it a page), one capture at a time, never the same frame twice, at most <see cref="Waiting"/>
/// frames held while the PC makes pages of earlier ones (Capture is off past that) and <see cref="MaxPages"/> in all; Done (or the
/// window closing) ends it.
/// </summary>
public sealed class CameraSession
{
    public const int MaxPages = 100;

    /// <summary>Full frames held before they're made pages (each tens of megabytes at 4K).</summary>
    public const int Waiting = 2;

    private readonly Channel<CapturedPhoto> _photos = Channel.CreateBounded<CapturedPhoto>(new BoundedChannelOptions(Waiting) { SingleReader = true });
    private readonly Lock _gate = new();
    private int _taken;
    private long _lastFrame = -1;
    private bool _finished, _capturing;

    public ChannelReader<CapturedPhoto> Photos => _photos.Reader;

    public int Taken
    {
        get { lock (_gate) return _taken; }
    }

    public bool IsFinished
    {
        get { lock (_gate) return _finished; }
    }

    /// <summary>
    /// A capture may start now: the scan is on, under <see cref="MaxPages"/>, no capture under way and fewer than <see cref="Waiting"/>
    /// frames waiting to be made pages.
    /// </summary>
    public bool CanCapture
    {
        get { lock (_gate) return !_finished && _taken < MaxPages && !_capturing && _photos.Reader.Count < Waiting; }
    }

    /// <summary>
    /// Takes <paramref name="feed"/>'s next frame as the next page. False when it can't now (<see cref="CanCapture"/>), no frame came, the
    /// frame is the one taken last, or the scan ended meanwhile.
    /// </summary>
    public async Task<bool> CaptureAsync(ICameraFeed? feed, CancellationToken ct = default)
    {
        if (feed is null) return false;
        lock (_gate)
        {
            if (_finished || _taken >= MaxPages || _capturing || _photos.Reader.Count >= Waiting) return false;
            _capturing = true;
        }
        CameraFrame? frame;
        try
        {
            frame = await feed.CaptureAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _capturing = false;
        }
        if (frame is null) return false;
        lock (_gate)
        {
            if (_finished || _taken >= MaxPages || frame.Number == _lastFrame) return false;
            // Counted only once it's in, under the lock, so Finish can't come between.
            if (!_photos.Writer.TryWrite(new CapturedPhoto(Frame: frame.Picture))) return false;
            _taken++;
            _lastFrame = frame.Number;
        }
        return true;
    }

    /// <summary>Done: the frames taken go on to be pages, nothing more is taken.</summary>
    public void Finish()
    {
        lock (_gate)
        {
            if (_finished) return;
            _finished = true;
            _photos.Writer.TryComplete();
        }
    }

    /// <summary>The line under the preview: how many pages were taken, when the PC is catching up, and when no more can be.</summary>
    public string StatusText()
    {
        int taken, waiting;
        lock (_gate) (taken, waiting) = (_taken, _photos.Reader.Count);
        return taken >= MaxPages ? CoreStrings.Camera_StatusFull
            : waiting >= Waiting ? CoreStrings.Camera_StatusBusy
            : taken == 0 ? CoreStrings.Camera_StatusNone
            : Plural.Of(taken, CoreStrings.Camera_StatusTaken_One, CoreStrings.Camera_StatusTaken_Many);
    }
}

