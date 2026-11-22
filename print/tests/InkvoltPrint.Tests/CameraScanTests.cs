using System.Text;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Capture;
using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Tests;

/// <summary>A webcam or document camera as a scan source (roadmap 4.12): the format chosen, frames made pages, captures counted and bounded.</summary>
public class CameraScanTests
{
    [Fact]
    public void The_largest_format_that_still_moves_is_chosen()
    {
        CameraFormat Hd = new(1280, 720, 30, "NV12"), FullHd = new(1920, 1080, 30, "MJPG"), FullHdSlow = new(1920, 1080, 15, "YUY2"),
            Uhd = new(3840, 2160, 15, "MJPG"), Still = new(4208, 3120, 2, "MJPG"), Huge = new(13_000, 9_000, 30, "MJPG"), Tiny = new(160, 120, 30, "NV12");
        Assert.Equal(Uhd, CameraFormats.Choose([Hd, FullHdSlow, FullHd, Uhd, Still, Huge, Tiny]));
        Assert.Equal(FullHd, CameraFormats.Choose([FullHdSlow, FullHd, Hd]));
        // Nothing streams fast enough: the largest within the limits all the same.
        Assert.Equal(Still, CameraFormats.Choose([Still, new CameraFormat(1280, 720, 1, "MJPG")]));
        Assert.Null(CameraFormats.Choose([Huge, Tiny]));
        Assert.Null(CameraFormats.Choose([]));
        Assert.Null(CameraFormats.Choose([new CameraFormat(1920, 1080, double.NaN, "NV12")]));
    }

    [Fact]
    public void A_frame_is_its_pixels_without_alpha_and_only_at_its_size()
    {
        var bgra = new byte[300 * 200 * 4];
        for (var i = 0; i < bgra.Length; i++) bgra[i] = (byte)(i % 4 == 3 ? 255 : i % 251);
        var bgr = CameraFormats.Bgr(bgra, 300, 200)!;
        Assert.Equal((300, 200, 3), (bgr.Width, bgr.Height, bgr.Channels));
        Assert.Equal([bgra[4], bgra[5], bgra[6]], bgr.Pixels[3..6]);
        Assert.Null(CameraFormats.Bgr(bgra, 301, 200));
        Assert.Null(CameraFormats.Bgr([], 0, 0));
    }

    /// <summary>A camera whose every frame is <paramref name="picture"/>, numbered in turn (or always <paramref name="fixedNumber"/>).</summary>
    private sealed class FakeFeed(Picture? picture, long? fixedNumber = null) : ICameraFeed
    {
        private long _number;

        public (int Width, int Height) Size => (picture?.Width ?? 0, picture?.Height ?? 0);

        public event Action<CameraPreview>? Preview
        {
            add { }
            remove { }
        }

        public void Shown() { }

        public Task<CameraFrame?> CaptureAsync(CancellationToken ct = default) =>
            Task.FromResult(picture is null ? null : new CameraFrame(picture, fixedNumber ?? Interlocked.Increment(ref _number)));

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class SizeCodec : IPhotoCodec
    {
        public Picture Decode(byte[] data, PhotoHeader header) => throw new InvalidOperationException("Frames aren't decoded.");

        public byte[] EncodeJpeg(Picture page, int dpi) => Encoding.ASCII.GetBytes($"{page.Width}x{page.Height}@{dpi}");
    }

    private static Picture Gray(int w, int h) => new(Enumerable.Repeat((byte)230, w * h * 3).ToArray(), w, h, 3);

    [Fact]
    public async Task Each_capture_is_a_page_until_Done()
    {
        var session = new CameraSession();
        Assert.Equal(CoreStrings.Camera_StatusNone, session.StatusText());
        Assert.False(await session.CaptureAsync(null));
        Assert.False(await session.CaptureAsync(new FakeFeed(null))); // no frame came
        var frame = new FakeFeed(Gray(1920, 1080));
        Assert.True(await session.CaptureAsync(frame));
        var pages = new List<string>();
        var reading = Task.Run(async () =>
        {
            await foreach (var page in new CaptureScanner(session.Photos, new SizeCodec()).ScanAsync(new ScanRequest(ScanSource.Platen, ScanColor.Color, 200)))
                lock (pages) pages.Add(Encoding.ASCII.GetString(page));
        });
        for (var i = 0; i < 100 && session.Photos.Count > 0; i++) await Task.Delay(20);
        Assert.True(await session.CaptureAsync(frame));
        Assert.Equal(2, session.Taken);
        session.Finish();
        Assert.False(await session.CaptureAsync(frame));
        Assert.False(session.CanCapture);
        await reading;
        // A frame with no page found in it: 16:9 is the camera's, not a paper's, so a page 11 inches the long way at 200 dpi.
        Assert.Equal(["2200x1238@200", "2200x1238@200"], pages);
        Assert.Equal(new PaperGuess("Photo", 11), PhotoPage.Paper(1920, 1080, foundPage: false));
        Assert.Equal("Narrow", PhotoPage.Paper(1920, 1080).Name); // a page found that long and narrow is one
        Assert.Equal("A4", PhotoPage.Paper(1414, 1000, foundPage: false).Name);
    }

    [Fact]
    public async Task The_same_frame_is_never_taken_twice()
    {
        var session = new CameraSession();
        var still = new FakeFeed(Gray(640, 480), fixedNumber: 7); // a held key, or a camera that sent nothing new
        Assert.True(await session.CaptureAsync(still));
        Assert.False(await session.CaptureAsync(still));
        Assert.Equal(1, session.Taken);
    }

    [Fact]
    public async Task Frames_wait_at_most_two_and_Capture_is_off_till_the_PC_catches_up()
    {
        var session = new CameraSession();
        var feed = new FakeFeed(Gray(640, 480));
        for (var i = 0; i < CameraSession.Waiting; i++) Assert.True(await session.CaptureAsync(feed));
        Assert.False(session.CanCapture);
        Assert.Equal(CoreStrings.Camera_StatusBusy, session.StatusText());
        Assert.False(await session.CaptureAsync(feed)); // refused, and not counted
        Assert.Equal(CameraSession.Waiting, session.Taken);
        Assert.True(session.Photos.TryRead(out _));
        Assert.True(session.CanCapture);
        Assert.True(await session.CaptureAsync(feed));
        Assert.Equal(CameraSession.Waiting + 1, session.Taken);
    }

    [Fact]
    public async Task A_scan_takes_at_most_its_limit_of_pages()
    {
        var session = new CameraSession();
        var feed = new FakeFeed(new Picture(new byte[640 * 480 * 3], 640, 480, 3));
        for (var i = 0; i < CameraSession.MaxPages; i++)
        {
            Assert.True(await session.CaptureAsync(feed));
            Assert.True(session.Photos.TryRead(out _));
        }
        Assert.False(await session.CaptureAsync(feed));
        Assert.False(session.CanCapture);
        Assert.Equal(CoreStrings.Camera_StatusFull, session.StatusText());
    }
}
