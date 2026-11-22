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

    private sealed class Feed : ICameraFeed
    {
        private readonly MediaCapture _capture;
        private readonly MediaFrameReader _reader;
        private readonly Lock _gate = new();
        private byte[]? _latest;
        private int _width, _height;
        private long _lastShown;
        private int _disposed;

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

        public event Action<byte[], int, int>? Frame;

        private void OnFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
        {
            try
            {
                using var reference = sender.TryAcquireLatestFrame();
                if (reference?.VideoMediaFrame?.SoftwareBitmap is not { } frame) return;
                using var bgra = frame.BitmapPixelFormat == BitmapPixelFormat.Bgra8 ? null : SoftwareBitmap.Convert(frame, BitmapPixelFormat.Bgra8);
                var bitmap = bgra ?? frame;
                var (w, h) = (bitmap.PixelWidth, bitmap.PixelHeight);
                if (w < 1 || h < 1 || (long)w * h > PhotoInput.MaxPixels) return;
                var bytes = new byte[w * h * 4];
                bitmap.CopyToBuffer(bytes.AsBuffer());
                lock (_gate) (_latest, _width, _height) = (bytes, w, h);
                // The preview: ten frames a second at most.
                var now = Environment.TickCount64;
                if (now - Interlocked.Read(ref _lastShown) < 100) return;
                Interlocked.Exchange(ref _lastShown, now);
                Frame?.Invoke(bytes, w, h);
            }
            catch (Exception)
            {
                // A frame that doesn't convert is skipped; the next one comes.
            }
        }

        public Picture? Latest()
        {
            byte[]? bgra;
            int w, h;
            lock (_gate) (bgra, w, h) = (_latest, _width, _height);
            return bgra is null ? null : CameraFormats.Bgr(bgra, w, h);
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
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
