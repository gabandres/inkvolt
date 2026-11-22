using System.Runtime.InteropServices.WindowsRuntime;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Capture;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace InkvoltPrint.Windows.Capture;

/// <summary>
/// This PC's cameras through Windows.Media.Capture (roadmap 4.12): the video capture devices Windows lists, each opened with a frame
/// reader on its color stream, at the format <see cref="CameraFormats.Choose"/> picks, its frames converted to BGRA. Nothing is
/// recorded or kept but the latest frame; disposing the feed stops the camera. Windows' camera privacy setting decides whether a
/// desktop app may use it (a Store copy asks once, by its webcam capability).
/// </summary>
public sealed class WindowsCameras : ICameras
{
    public static readonly WindowsCameras Instance = new();

    public async Task<IReadOnlyList<CameraInfo>> ListAsync(CancellationToken ct = default)
    {
        var found = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture).AsTask(ct).ConfigureAwait(false);
        return [.. found.Where(d => d.IsEnabled).Select(d => new CameraInfo(d.Id, string.IsNullOrWhiteSpace(d.Name) ? CoreStrings.Camera_Unnamed : d.Name.Trim()))];
    }

    public async Task<ICameraFeed> OpenAsync(CameraInfo camera, CancellationToken ct = default)
    {
        var capture = new MediaCapture();
        try
        {
            try
            {
                await capture.InitializeAsync(new MediaCaptureInitializationSettings
                {
                    VideoDeviceId = camera.Id,
                    StreamingCaptureMode = StreamingCaptureMode.Video,
                    MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                    SharingMode = MediaCaptureSharingMode.ExclusiveControl,
                }).AsTask(ct).ConfigureAwait(false);
            }
            catch (UnauthorizedAccessException ex)
            {
                throw new CameraException(CoreStrings.Camera_Blocked, ex);
            }
            catch (Exception ex) when (ex is not OperationCanceledException and not CameraException)
            {
                throw new CameraException(CoreStrings.Camera_InUse, ex);
            }
            var source = capture.FrameSources.Values
                .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
                .OrderBy(s => s.Info.MediaStreamType == MediaStreamType.VideoRecord ? 0 : s.Info.MediaStreamType == MediaStreamType.VideoPreview ? 1 : 2)
                .FirstOrDefault() ?? throw new CameraException(CoreStrings.Camera_NoPicture);
            var formats = source.SupportedFormats.Where(f => f.VideoFormat is not null).ToList();
            var chosen = CameraFormats.Choose([.. formats.Select(Describe)]);
            if (chosen is not null && formats.FirstOrDefault(f => Describe(f) == chosen) is { } format)
                await source.SetFormatAsync(format).AsTask(ct).ConfigureAwait(false);
            var reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8).AsTask(ct).ConfigureAwait(false);
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            var feed = new Feed(capture, reader);
            if (await reader.StartAsync().AsTask(ct).ConfigureAwait(false) != MediaFrameReaderStartStatus.Success)
            {
                await feed.DisposeAsync().ConfigureAwait(false);
                throw new CameraException(CoreStrings.Camera_InUse);
            }
            return feed;
        }
        catch
        {
            capture.Dispose();
            throw;
        }
    }

    private static CameraFormat Describe(MediaFrameFormat f) => new((int)f.VideoFormat.Width, (int)f.VideoFormat.Height,
        f.FrameRate is { Denominator: > 0 } r ? r.Numerator / (double)r.Denominator : 0, f.Subtype);

    /// <summary>
    /// The frames of one camera. Most are never copied: only a preview frame (ten a second at most, into one buffer reused, none while
    /// the last one isn't shown yet) and the frame a capture waits for (in full, its own copy).
    /// </summary>
    private sealed class Feed : ICameraFeed
    {
        /// <summary>A capture gives up after this long without a frame (the camera stalled or was unplugged).</summary>
        private static readonly TimeSpan CaptureWait = TimeSpan.FromSeconds(5);

        private readonly MediaCapture _capture;
        private readonly MediaFrameReader _reader;
        private readonly Lock _gate = new();
        private TaskCompletionSource<CameraFrame?>? _wanted;
        private byte[]? _preview;
        private int _width, _height, _previewFree = 1, _disposed;
        private long _lastShown, _number;

        public Feed(MediaCapture capture, MediaFrameReader reader)
        {
            _capture = capture;
            _reader = reader;
            reader.FrameArrived += OnFrame;
        }

        public (int Width, int Height) Size
        {
            get { lock (_gate) return (_width, _height); }
        }

        public event Action<CameraPreview>? Preview;

        public void Shown() => Volatile.Write(ref _previewFree, 1);

        private void OnFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
        {
            var number = Interlocked.Increment(ref _number);
            TaskCompletionSource<CameraFrame?>? wanted;
            lock (_gate) (wanted, _wanted) = (_wanted, null);
            var now = Environment.TickCount64;
            var previewDue = Preview is not null && Volatile.Read(ref _previewFree) == 1 && now - Interlocked.Read(ref _lastShown) >= 100;
            if (wanted is null && !previewDue) return; // the frame is let go uncopied
            try
            {
                using var reference = sender.TryAcquireLatestFrame();
                if (reference?.VideoMediaFrame?.SoftwareBitmap is not { } frame)
                {
                    lock (_gate) _wanted ??= wanted; // the next frame, then
                    return;
                }
                using var converted = frame.BitmapPixelFormat == BitmapPixelFormat.Bgra8 ? null : SoftwareBitmap.Convert(frame, BitmapPixelFormat.Bgra8);
                var bitmap = converted ?? frame;
                var (w, h) = (bitmap.PixelWidth, bitmap.PixelHeight);
                if (w < 1 || h < 1 || (long)w * h > PhotoInput.MaxPixels)
                {
                    wanted?.TrySetResult(null);
                    return;
                }
                lock (_gate) (_width, _height) = (w, h);
                if (wanted is not null)
                {
                    var full = new byte[w * h * 4];
                    bitmap.CopyToBuffer(full.AsBuffer());
                    wanted.TrySetResult(CameraFormats.Bgr(full, w, h) is { } picture ? new CameraFrame(picture, number) : null);
                }
                if (previewDue)
                {
                    if (_preview is null || _preview.Length != w * h * 4) _preview = new byte[w * h * 4];
                    bitmap.CopyToBuffer(_preview.AsBuffer());
                    Volatile.Write(ref _previewFree, 0);
                    Interlocked.Exchange(ref _lastShown, now);
                    Preview?.Invoke(new CameraPreview(_preview, w, h));
                }
            }
            catch (Exception)
            {
                // A frame that doesn't convert is skipped; a capture waiting for it gets nothing.
                wanted?.TrySetResult(null);
            }
        }

        public async Task<CameraFrame?> CaptureAsync(CancellationToken ct = default)
        {
            var wanted = new TaskCompletionSource<CameraFrame?>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate)
            {
                if (_disposed != 0) return null;
                _wanted?.TrySetResult(null);
                _wanted = wanted;
            }
            try
            {
                return await wanted.Task.WaitAsync(CaptureWait, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
            {
                lock (_gate)
                {
                    if (_wanted == wanted) _wanted = null;
                }
                return null;
            }
        }

        public async ValueTask DisposeAsync()
        {
            TaskCompletionSource<CameraFrame?>? wanted;
            lock (_gate)
            {
                if (_disposed != 0) return;
                _disposed = 1;
                (wanted, _wanted) = (_wanted, null);
            }
            wanted?.TrySetResult(null);
            _reader.FrameArrived -= OnFrame;
            try
            {
                await _reader.StopAsync();
            }
            catch (Exception)
            {
                // Already stopped (the camera unplugged): it's let go below all the same.
            }
            _reader.Dispose();
            _capture.Dispose();
        }
    }
}
