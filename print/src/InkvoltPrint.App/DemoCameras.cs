using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Capture;

namespace InkvoltPrint.App;

/// <summary>
/// Demo mode's cameras (roadmap 4.12): one made-up document camera whose picture is <see cref="Demo.PhonePhoto"/> (a letter at an angle
/// on a desk), sent ten times a second until it's stopped. No real camera is listed or opened.
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

        public Feed()
        {
            var frame = new JpegBitmapDecoder(new MemoryStream(Demo.PhonePhoto()), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            var bgra = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
            Size = (bgra.PixelWidth, bgra.PixelHeight);
            _bgra = new byte[Size.Width * Size.Height * 4];
            bgra.CopyPixels(_bgra, Size.Width * 4, 0);
            _timer = new Timer(_ => Frame?.Invoke(_bgra, Size.Width, Size.Height), null, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100));
        }

        public (int Width, int Height) Size { get; }

        public event Action<byte[], int, int>? Frame;

        public Picture? Latest() => CameraFormats.Bgr(_bgra, Size.Width, Size.Height);

        public ValueTask DisposeAsync() => _timer.DisposeAsync();
    }
}
