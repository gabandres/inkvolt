using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PrintDesk.Core.Net;

namespace PrintDesk.App;

/// <summary>
/// <c>PrintDesk.exe --demo</c>: one made-up printer for screenshots and trying the app without a printer. Its web
/// server is a <see cref="FixtureHandler"/> over the scrubbed test fixtures (embedded from
/// <c>tests/PrintDesk.Tests/Fixtures/m234dw</c>) at <see cref="FixtureHandler.DemoHost"/>. Demo mode makes no network
/// access: no discovery, no probes, no Windows print queue, no HP software check; state lives in memory only
/// (the remembered-printers file is neither read nor written). Scanning returns a generated blank-ish page.
/// </summary>
internal static class Demo
{
    private const string Uuid = "12345678-1234-4abc-8def-123456789abc"; // the fixtures' (fake) UUID
    private const string ResourcePrefix = "Demo.";

    public static AppState CreateState() => new()
    {
        IsInMemory = true,
        Printers = [new KnownPrinter(Uuid, "Demo printer", null, FixtureHandler.DemoHost, $"http://{FixtureHandler.DemoHost}/eSCL/")],
        SelectedUuid = Uuid,
    };

    public static HttpMessageHandler CreateTransport() => new FixtureHandler(Document, () => Page.Value);

    // WPF drawing needs the UI thread; the handler runs wherever the scan's awaits continue.
    private static readonly Lazy<byte[]> Page = new(() => Application.Current.Dispatcher.Invoke(ScanPage));

    private static byte[]? Document(string name)
    {
        using var s = typeof(Demo).Assembly.GetManifestResourceStream(ResourcePrefix + name);
        if (s is null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>A synthetic letter-size page at 300 dpi: a heading, grey text bars and a picture box. Never a real scan.</summary>
    private static byte[] ScanPage()
    {
        const int w = 1275, h = 1650; // drawn at 150 dpi, rendered at 300
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(2, 2));
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, w, h));
            var ink = new SolidColorBrush(Color.FromRgb(0x30, 0x34, 0x3A));
            var grey = new SolidColorBrush(Color.FromRgb(0xC4, 0xC8, 0xCE));
            dc.DrawRoundedRectangle(ink, null, new Rect(150, 160, 620, 46), 6, 6);
            dc.DrawRoundedRectangle(grey, null, new Rect(150, 230, 380, 22), 4, 4);
            var y = 330.0;
            for (var i = 0; i < 20; i++, y += 44)
            {
                if (i == 9) { dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xE3, 0xE8, 0xEF)), null, new Rect(150, y, 975, 300)); y += 340; }
                var len = i % 7 == 6 ? 520 : 975 - (i * 37 % 90);
                dc.DrawRoundedRectangle(grey, null, new Rect(150, y, len, 18), 4, 4);
            }
        }
        var bmp = new RenderTargetBitmap(w * 2, h * 2, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        var enc = new JpegBitmapEncoder { QualityLevel = 85 };
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var outStream = new MemoryStream();
        enc.Save(outStream);
        return outStream.ToArray();
    }
}
