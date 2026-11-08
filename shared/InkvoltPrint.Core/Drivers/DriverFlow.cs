using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>An Authenticode signature as Windows reads it (<c>WinVerifyTrust</c>), and the signing certificate's organization.</summary>
public enum SignatureState
{
    /// <summary>Signed, the file unchanged since, the certificate chaining to a root Windows trusts.</summary>
    Valid,
    NotSigned,

    /// <summary>A signature that doesn't match the file (changed or cut short), or a malformed one.</summary>
    Invalid,

    /// <summary>A signature whose certificate doesn't chain to a trusted root, or is revoked, expired without a timestamp, or not for code.</summary>
    Untrusted,
}

public sealed record SignatureFacts(SignatureState State, string? Organization);

/// <summary>Reads a file's Authenticode signature (the seam: <c>WindowsSignatures</c>, the tests' fake).</summary>
public interface ISignatureCheck
{
    SignatureFacts Check(string path);
}

/// <summary>What this PC does with a checked installer (the seam: the Windows one, demo mode's and the tests').</summary>
public interface IDriverPc
{
    /// <summary>Runs the installer (it asks for an administrator itself) and waits for it to end.</summary>
    Task<InstallerExit> RunInstallerAsync(string path, CancellationToken ct);

    /// <summary>Asks Windows to look for new devices as the user (<c>CM_Reenumerate_DevNode</c>); false when it can't.</summary>
    Task<bool> RescanAsUserAsync(CancellationToken ct);

    /// <summary>The same, elevated (<c>pnputil /scan-devices</c>, one prompt); false when declined or failed.</summary>
    Task<bool> RescanElevatedAsync(CancellationToken ct);
}

public enum InstallerEnd { Exited, Declined, TimedOut }

public sealed record InstallerExit(InstallerEnd End, int Code = 0)
{
    /// <summary>Done: 0, or done and Windows wants a restart (3010, 1641).</summary>
    public bool Succeeded => End == InstallerEnd.Exited && Code is 0 or 3010 or 1641;
}

/// <summary>Why a download wasn't kept: said in words, the file deleted.</summary>
public enum Refusal { Fetch, NotAnInstaller, NotSigned, BadSignature, Untrusted, WrongSigner, NotLookedUp }

/// <summary>A downloaded installer that passed every check, ready for the user's click.</summary>
public sealed record DriverReady(DriverOffer Offer, string Maker, string Path, long Bytes, string Signer);

public sealed record DriverDownload(DriverReady? Ready, Refusal? Why = null, FetchProblem? Problem = null, string? Signer = null);

public enum InstallOutcome
{
    /// <summary>Installed, and Windows has the device now (WIA lists the scanner; the printer no longer needs its driver).</summary>
    Done,

    /// <summary>The installer finished but Windows doesn't show the device yet: unplug it and plug it back in.</summary>
    NotSeen,

    /// <summary>The installer wasn't allowed to run (its prompt was declined).</summary>
    Declined,
    Failed,
    TimedOut,
}

public sealed record InstallResult(InstallOutcome Outcome, int? ExitCode = null, bool Rescanned = false, bool Elevated = false);

/// <summary>The steps "Get the driver" takes, each run by a click; demo mode's version downloads and runs nothing.</summary>
public interface IDriverGetter
{
    bool LooksUp(NeedsDriverPrinter device);

    Task<DriverLookup> FindAsync(NeedsDriverPrinter device, CancellationToken ct);

    Task<DriverDownload> DownloadAsync(DriverOffer offer, NeedsDriverPrinter device, IProgress<long>? progress, CancellationToken ct);

    /// <param name="isThere">Whether Windows has the device now (asked after the installer, and after each rescan).</param>
    Task<InstallResult> InstallAsync(DriverReady ready, Func<CancellationToken, Task<bool>> isThere, CancellationToken ct);

    /// <summary>A download not installed after all: deleted.</summary>
    void Discard(DriverReady ready);
}

/// <summary>
/// "Get the driver": the maker's own download for the model and this PC (<see cref="IDriverCatalog"/>), fetched from the maker's
/// hosts only (<see cref="BoundedHttp"/>, at most <see cref="MaxBytes"/> in <see cref="DownloadLimit"/>), into a folder of its own,
/// then kept only when it is a Windows program with a valid Authenticode signature chaining to a trusted root and signed by one of
/// the maker's own organizations (<see cref="MakerSource"/>); anything else is deleted and said why. Running it is a separate
/// step, on the user's click: the installer asks for an administrator itself; once it ends, Windows is asked to look for the
/// device again (as the user, else with one elevated pnputil), and whether Windows has it now is checked.
/// </summary>
public sealed class DriverFlow(IDriverCatalog catalog, BoundedHttp http, ISignatureCheck signatures, IDriverPc pc, string folder, PcArch arch, PcWindows windows,
    TimeSpan? wait = null) : IDriverGetter
{
    public const long MaxBytes = 500L << 20;
    public static readonly TimeSpan DownloadLimit = TimeSpan.FromMinutes(15);

    /// <summary>How long Windows is given to show the device after the installer, and again after a rescan.</summary>
    private readonly TimeSpan _wait = wait ?? TimeSpan.FromSeconds(20);

    public bool LooksUp(NeedsDriverPrinter device) => !device.IsMadeUp && catalog.LooksUp(device.Maker) && MakerSource.For(device.Maker) is not null;

    public Task<DriverLookup> FindAsync(NeedsDriverPrinter device, CancellationToken ct) =>
        LooksUp(device) ? catalog.FindAsync(DriverQuery.For(device, arch, windows), ct) : Task.FromResult(DriverLookup.None(NoOffer.MakerNotLookedUp));

    public async Task<DriverDownload> DownloadAsync(DriverOffer offer, NeedsDriverPrinter device, IProgress<long>? progress, CancellationToken ct)
    {
        if (MakerSource.For(device.Maker) is not { } source) return new DriverDownload(null, Refusal.NotLookedUp);
        var dir = Path.Combine(folder, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, Path.GetFileName(offer.FileName));
        try
        {
            await http.DownloadAsync(offer.Download, source.DownloadHosts, MaxBytes, DownloadLimit, path, progress, ct).ConfigureAwait(false);
        }
        catch (FetchException ex)
        {
            Remove(dir);
            return new DriverDownload(null, Refusal.Fetch, ex.Problem);
        }
        catch
        {
            Remove(dir);
            throw;
        }
        var refusal = Check(path, source, out var signer);
        if (refusal is not null)
        {
            Remove(dir);
            return new DriverDownload(null, refusal, Signer: signer);
        }
        return new DriverDownload(new DriverReady(offer, source.Maker, path, new FileInfo(path).Length, signer!));
    }

    /// <summary>A Windows program ("MZ"), its signature valid and trusted, signed by the maker; null when every check passes.</summary>
    private Refusal? Check(string path, MakerSource source, out string? signer)
    {
        signer = null;
        if (!IsProgram(path)) return Refusal.NotAnInstaller;
        var facts = signatures.Check(path);
        signer = facts.Organization is { Length: > 0 } o ? (o.Length > 80 ? o[..80] + "…" : o) : null;
        return facts.State switch
        {
            SignatureState.NotSigned => Refusal.NotSigned,
            SignatureState.Invalid => Refusal.BadSignature,
            SignatureState.Untrusted => Refusal.Untrusted,
            _ when !source.IsSigner(facts.Organization) => Refusal.WrongSigner,
            _ => null,
        };
    }

    private static bool IsProgram(string path)
    {
        try
        {
            using var f = File.OpenRead(path);
            Span<byte> head = stackalloc byte[2];
            return f.Read(head) == 2 && head[0] == (byte)'M' && head[1] == (byte)'Z';
        }
        catch (IOException)
        {
            return false;
        }
    }

    public async Task<InstallResult> InstallAsync(DriverReady ready, Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        InstallerExit exit;
        try
        {
            // Checked again just before it runs, the file held open against writes until it has run: it sits in the user's own
            // folder and could have been swapped since.
            if (!File.Exists(ready.Path) || MakerSource.For(ready.Maker) is not { } source) return new InstallResult(InstallOutcome.Failed);
            using var held = new FileStream(ready.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (Check(ready.Path, source, out var signer) is not null || signer != ready.Signer) return new InstallResult(InstallOutcome.Failed);
            exit = await pc.RunInstallerAsync(ready.Path, ct).ConfigureAwait(false);
        }
        finally
        {
            Discard(ready);
        }
        switch (exit.End)
        {
            case InstallerEnd.Declined: return new InstallResult(InstallOutcome.Declined);
            case InstallerEnd.TimedOut: return new InstallResult(InstallOutcome.TimedOut);
        }
        if (!exit.Succeeded) return new InstallResult(InstallOutcome.Failed, exit.Code);
        if (await isThere(ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, exit.Code);
        // The device node can be gone until Windows looks again (a driver installed while it was plugged in).
        var asUser = await pc.RescanAsUserAsync(ct).ConfigureAwait(false);
        if (asUser && await WaitForAsync(isThere, ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, exit.Code, Rescanned: true);
        var elevated = await pc.RescanElevatedAsync(ct).ConfigureAwait(false);
        if (elevated && await WaitForAsync(isThere, ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, exit.Code, true, true);
        return new InstallResult(InstallOutcome.NotSeen, exit.Code, asUser || elevated, elevated);
    }

    private async Task<bool> WaitForAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        var until = DateTime.UtcNow + _wait;
        var step = TimeSpan.FromMilliseconds(Math.Clamp(_wait.TotalMilliseconds / 10, 1, 2000));
        while (true)
        {
            if (await isThere(ct).ConfigureAwait(false)) return true;
            if (DateTime.UtcNow >= until) return false;
            await Task.Delay(step, ct).ConfigureAwait(false);
        }
    }

    public void Discard(DriverReady ready)
    {
        if (Path.GetDirectoryName(ready.Path) is { } dir && Path.GetFullPath(dir).StartsWith(Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase))
            Remove(dir);
    }

    private static void Remove(string dir)
    {
        try { Directory.Delete(dir, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Trace.WriteLine($"driver download: {ex.Message}"); }
    }
}
