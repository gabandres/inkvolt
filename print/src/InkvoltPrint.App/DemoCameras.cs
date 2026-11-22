using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Capture;

namespace InkvoltPrint.App;

/// <summary>
/// Demo mode's cameras (roadmap 4.12): one made-up document camera whose picture is <see cref="Demo.PhonePhoto"/> (a letter at an angle
/// on a desk), a frame every tenth of a second until it's stopped, shown and captured by the same rules as a real camera's. No real
/// camera is listed or opened.
/// </summary>
internal sealed class DemoCameras : ICameras
{
    public Task<IReadOnlyList<CameraInfo>> ListAsync(CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<CameraInfo>>([new CameraInfo("demo-camera", "Demo document camera")]);

    public Task<ICameraFeed> OpenAsync(CameraInfo camera, CancellationToken ct = default) => Task.FromResult<ICameraFeed>(new Feed());

    private sealed class Feed : ICameraFeed
    {
        private readonly byte[] _bgra;
        private readonly Timer _timer;
        private readonly Lock _gate = new();
        private TaskCompletionSource<CameraFrame?>? _wanted;
        private int _previewFree = 1;
        private long _number;
        private bool _disposed;

        public Feed()
        {
            var frame = new JpegBitmapDecoder(new MemoryStream(Demo.PhonePhoto()), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            var bgra = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
            Size = (bgra.PixelWidth, bgra.PixelHeight);
            _bgra = new byte[Size.Width * Size.Height * 4];
            bgra.CopyPixels(_bgra, Size.Width * 4, 0);
            _timer = new Timer(_ => Tick(), null, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100));
        }

        public (int Width, int Height) Size { get; }

        public event Action<CameraPreview>? Preview;

        public void Shown() => Volatile.Write(ref _previewFree, 1);

        private void Tick()
        {
            var number = Interlocked.Increment(ref _number);
            TaskCompletionSource<CameraFrame?>? wanted;
            lock (_gate) (wanted, _wanted) = (_wanted, null);
            wanted?.TrySetResult(CameraFormats.Bgr(_bgra, Size.Width, Size.Height) is { } picture ? new CameraFrame(picture, number) : null);
            if (Interlocked.CompareExchange(ref _previewFree, 0, 1) == 1) Preview?.Invoke(new CameraPreview(_bgra, Size.Width, Size.Height));
        }

        public async Task<CameraFrame?> CaptureAsync(CancellationToken ct = default)
        {
            var wanted = new TaskCompletionSource<CameraFrame?>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate)
            {
                if (_disposed) return null;
                _wanted?.TrySetResult(null);
                _wanted = wanted;
            }
            try
            {
                return await wanted.Task.WaitAsync(TimeSpan.FromSeconds(5), ct);
            }
            catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
            {
                return null;
            }
        }

        public async ValueTask DisposeAsync()
        {
            TaskCompletionSource<CameraFrame?>? wanted;
            lock (_gate)
            {
                _disposed = true;
                (wanted, _wanted) = (_wanted, null);
            }
            wanted?.TrySetResult(null);
            await _timer.DisposeAsync();
        }
    }
}
