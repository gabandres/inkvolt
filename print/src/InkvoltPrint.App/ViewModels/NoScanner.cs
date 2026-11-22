using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The scanner of the phone and camera page (roadmap 4.6, 4.12), which has none: it's never asked to scan there (that page shows no Scan
/// button), and says so in plain words if it ever is.
/// </summary>
internal sealed class NoScanner : IScanner
{
    public Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default) => Task.FromResult(new ScannerStatus("Idle", null, []));

    public async IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, [EnumeratorCancellation] CancellationToken ct = default)
    {
        await Task.CompletedTask;
        throw new ScanException(Strings.Capture_NoScanner);
#pragma warning disable CS0162 // an iterator needs a yield to be one
        yield break;
#pragma warning restore CS0162
    }
}
