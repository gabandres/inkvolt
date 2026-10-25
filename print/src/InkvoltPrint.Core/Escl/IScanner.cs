namespace InkvoltPrint.Core.Escl;

/// <summary>
/// A scanner the Scan and Copy tabs can use: <see cref="EsclClient"/> over the network, or a scanner Windows has a driver for
/// (<see cref="Wia.WiaScanner"/>). Both describe themselves with <see cref="ScannerCapabilities"/> and hand over JPEG pages,
/// so the review, OCR, presets and saving don't depend on which it is.
/// </summary>
public interface IScanner
{
    /// <summary>Whether it can scan now; for feeder scans, whether pages are loaded (null <c>AdfState</c> when it can't tell).</summary>
    Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default);

    /// <summary>One scan job: JPEG pages as they come. Glass jobs give one page; feeder jobs give pages until the feeder is empty.</summary>
    IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, CancellationToken ct = default);
}
