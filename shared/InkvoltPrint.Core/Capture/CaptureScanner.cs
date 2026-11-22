using System.Runtime.CompilerServices;
using System.Threading.Channels;
using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Core.Capture;

/// <summary>
/// One photo from a capture source: a file's bytes as sent (a phone's JPEG or PNG, checked by <see cref="PhotoInput"/> before it's
/// decoded), or a camera's frame already as pixels (<paramref name="Frame"/>, upright).
/// </summary>
public sealed record CapturedPhoto(byte[]? Data = null, Picture? Frame = null);

/// <summary>
/// A capture source as a scanner (roadmap 4.6, 4.12): each photo that comes in is made into a page (<see cref="PhotoPage"/>) at the
/// scan's resolution and color, and handed to the scan review like a scanner's page, so the review, the cleanup, OCR and the
/// presets are the scanner's own. One scan job lasts until the source is done (the phone's Done, the camera window closed): the
/// photos' channel completes. A photo that isn't one (or doesn't decode) is left out and <paramref name="leftOut"/> told why, in
/// plain words; nothing it holds reaches the log.
/// </summary>
public sealed class CaptureScanner(ChannelReader<CapturedPhoto> photos, IPhotoCodec codec, Action<string>? leftOut = null) : IScanner
{
    /// <summary>What a capture source offers: a "glass" of up to Legal size, color, grey or black and white, <see cref="PhotoPage.Resolutions"/>.</summary>
    public static ScannerCapabilities Capabilities(string name) => new("Capture", name, null,
        new InputCaps(300, (int)(8.5 * 300), 300, 14 * 300, ["RGB24", "Grayscale8", "BlackAndWhite1"], ["image/jpeg"], PhotoPage.Resolutions, ["Document", "Photo"]),
        null, false);

    /// <summary>Pages made so far, and photos left out.</summary>
    public int Made { get; private set; }

    public int LeftOut { get; private set; }

    public Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default) => Task.FromResult(new ScannerStatus("Idle", null, []));

    public async IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var gray = request.Color != ScanColor.Color;
        await foreach (var photo in photos.ReadAllAsync(ct).ConfigureAwait(false))
        {
            byte[]? jpeg;
            try
            {
                jpeg = await Task.Run(() => Make(photo, request.Resolution, gray, ct), ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception) // a photo that doesn't decode: left out, the scan goes on
            {
                jpeg = null;
            }
            if (jpeg is null)
            {
                LeftOut++;
                leftOut?.Invoke(CoreStrings.Capture_NotAPhoto);
                continue;
            }
            Made++;
            yield return jpeg;
        }
    }

    private byte[]? Make(CapturedPhoto photo, int dpi, bool gray, CancellationToken ct)
    {
        Picture picture;
        var orientation = 1;
        if (photo.Frame is { } frame)
        {
            if (frame.Width < PhotoInput.MinSide || frame.Height < PhotoInput.MinSide || frame.Width > PhotoInput.MaxSide || frame.Height > PhotoInput.MaxSide
                || (long)frame.Width * frame.Height > PhotoInput.MaxPixels) return null;
            picture = frame;
        }
        else if (photo.Data is { } data && PhotoInput.Inspect(data) is { } header)
        {
            picture = codec.Decode(data, header);
            // The decoder's size must be the header's: anything else is a file that says one thing and holds another.
            if (picture.Width != header.Width || picture.Height != header.Height) return null;
            orientation = header.Orientation;
        }
        else return null;
        var page = PhotoPage.Make(picture, orientation, dpi, gray, cancel: ct);
        return codec.EncodeJpeg(page.Image, page.Dpi);
    }
}
