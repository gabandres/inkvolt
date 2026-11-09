using System.ComponentModel;
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

/// <summary>An installer started: its process id, and its exit code once it ends.</summary>
public sealed record InstallerProcess(int Id, Task<int> Exited);

/// <summary>One process running on the PC: its id and its parent's (what a snapshot of the processes gives).</summary>
public readonly record struct ProcessLink(int Id, int Parent);

/// <summary>What this PC does with a checked installer (the seam: the Windows one and the tests').</summary>
public interface IDriverPc
{
    /// <summary>
    /// Starts the installer through the shell (it asks for an administrator itself). Null: its prompt was declined. Throws when
    /// Windows doesn't let it start (SmartScreen, an antivirus holding the file, a policy).
    /// </summary>
    Task<InstallerProcess?> StartInstallerAsync(string path, CancellationToken ct);

    /// <summary>Every process running now, with its parent: how the installer's own processes are followed after it exits.</summary>
    IReadOnlyList<ProcessLink> Processes();

    /// <summary>Asks Windows to look for new devices as the user (<c>CM_Reenumerate_DevNode</c>); false when it can't.</summary>
    Task<bool> RescanAsUserAsync(CancellationToken ct);

    /// <summary>The same, elevated (<c>pnputil /scan-devices</c>, one prompt); false when declined or failed.</summary>
    Task<bool> RescanElevatedAsync(CancellationToken ct);
}

/// <summary>
/// What "Get the driver" may do in this copy of the app. A Store (packaged) copy never downloads or runs anything itself: it finds
/// the download and opens the maker's own link in the browser, then watches for the device (print/packaging/README.md, Store policy
/// 10.1.5). Unpackaged copies, and a package built for sideloading with the flow kept, install it for you.
/// </summary>
public enum DriverMode { InstallForYou, OpenLink }

public static class DriverModes
{
    public static DriverMode For(bool packaged, bool installKeptInPackage) => !packaged || installKeptInPackage ? DriverMode.InstallForYou : DriverMode.OpenLink;
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

    /// <summary>Windows didn't let the installer start (SmartScreen, an antivirus, a policy), or the file was gone or changed.</summary>
    CouldntStart,
    Failed,

    /// <summary>The installer (or a process it started) was still running at the limit: its folder is left for the next start-up's sweep.</summary>
    TimedOut,
}

public sealed record InstallResult(InstallOutcome Outcome, int? ExitCode = null, bool Rescanned = false, bool Elevated = false);

/// <summary>How long the steps may take: overridable for the tests.</summary>
/// <param name="Wait">How long Windows is given to show the device after the installer, and again after a rescan.</param>
/// <param name="InstallerLimit">How long the installer and every process it starts may run.</param>
/// <param name="Poll">How often the installer's processes are looked at.</param>
public sealed record DriverTiming(TimeSpan Wait, TimeSpan InstallerLimit, TimeSpan Poll)
{
    public static DriverTiming Default { get; } = new(TimeSpan.FromSeconds(20), TimeSpan.FromMinutes(45), TimeSpan.FromSeconds(1));
}

/// <summary>The steps "Get the driver" takes, each run by a click; demo mode's version downloads and runs nothing.</summary>
public interface IDriverGetter
{
    DriverMode Mode { get; }

    bool LooksUp(NeedsDriverPrinter device);

    Task<DriverLookup> FindAsync(NeedsDriverPrinter device, CancellationToken ct);

    /// <summary>The maker's own download link to open in the browser (<see cref="DriverMode.OpenLink"/>); null when it isn't on the maker's hosts.</summary>
    Uri? LinkFor(DriverOffer offer, NeedsDriverPrinter device);

    Task<DriverDownload> DownloadAsync(DriverOffer offer, NeedsDriverPrinter device, IProgress<long>? progress, CancellationToken ct);

    /// <param name="isThere">Whether Windows has the device now (asked after the installer, and after each rescan).</param>
    Task<InstallResult> InstallAsync(DriverReady ready, Func<CancellationToken, Task<bool>> isThere, CancellationToken ct);

    /// <summary>"Look again" after the user ran the installer themselves: asks, else asks Windows to look as the user and asks again.</summary>
    Task<bool> LookAgainAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct);

    /// <summary>A download not installed after all: deleted.</summary>
    void Discard(DriverReady ready);
}

/// <summary>
/// "Get the driver": the maker's own download for the model and this PC (<see cref="IDriverCatalog"/>), fetched from the maker's
/// hosts only (<see cref="BoundedHttp"/>, at most <see cref="MaxBytes"/> in <see cref="DownloadLimit"/>), into a folder of its own,
/// then kept only when it is a Windows program with a valid Authenticode signature chaining to a trusted root and signed by one of
/// the maker's own organizations (<see cref="MakerSource"/>); anything else is deleted and said why. Running it is a separate
/// step, on the user's click: the installer asks for an administrator itself, and is waited for with every process it starts (a
/// self-extractor exits as soon as its setup runs); its folder goes only then. Windows is then asked whether it has the device,
/// asked to look again (as the user, else with one elevated pnputil) if not. In <see cref="DriverMode.OpenLink"/> nothing is
/// downloaded or run: the user gets the maker's link.
/// </summary>
public sealed class DriverFlow(IDriverCatalog catalog, BoundedHttp http, ISignatureCheck signatures, IDriverPc pc, string folder, PcArch arch, PcWindows windows,
    DriverMode mode = DriverMode.InstallForYou, DriverTiming? timing = null) : IDriverGetter
{
    public const long MaxBytes = 500L << 20;
    public static readonly TimeSpan DownloadLimit = TimeSpan.FromMinutes(15);

    private readonly DriverTiming _timing = timing ?? DriverTiming.Default;

    public DriverMode Mode => mode;

    public bool LooksUp(NeedsDriverPrinter device) => !device.IsMadeUp && catalog.LooksUp(device.Maker) && MakerSource.For(device.Maker) is not null;

    public Task<DriverLookup> FindAsync(NeedsDriverPrinter device, CancellationToken ct) =>
        LooksUp(device) ? catalog.FindAsync(DriverQuery.For(device, arch, windows), ct) : Task.FromResult(DriverLookup.None(NoOffer.MakerNotLookedUp));

    public Uri? LinkFor(DriverOffer offer, NeedsDriverPrinter device) =>
        MakerSource.For(device.Maker) is { } source && BoundedHttp.IsAllowed(offer.Download, source.DownloadHosts) ? offer.Download : null;

    public async Task<DriverDownload> DownloadAsync(DriverOffer offer, NeedsDriverPrinter device, IProgress<long>? progress, CancellationToken ct)
    {
        if (mode != DriverMode.InstallForYou || MakerSource.For(device.Maker) is not { } source) return new DriverDownload(null, Refusal.NotLookedUp);
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
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>What Windows may throw when a program is started or a device read: said as "couldn't start" or "not there yet", never a crash.</summary>
    private static bool Expected(Exception ex) =>
        ex is IOException or UnauthorizedAccessException or Win32Exception or InvalidOperationException or System.Runtime.InteropServices.COMException;

    public async Task<InstallResult> InstallAsync(DriverReady ready, Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        if (mode != DriverMode.InstallForYou) return new InstallResult(InstallOutcome.CouldntStart);
        var keepFolder = false;
        int code;
        try
        {
            InstallerProcess? started;
            try
            {
                // Checked again just before it starts, the file held open against writes until it has: it sits in the user's own
                // folder and could have been swapped since.
                if (!File.Exists(ready.Path) || MakerSource.For(ready.Maker) is not { } source) return new InstallResult(InstallOutcome.CouldntStart);
                using var held = new FileStream(ready.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (Check(ready.Path, source, out var signer) is not null || signer != ready.Signer) return new InstallResult(InstallOutcome.CouldntStart);
                started = await pc.StartInstallerAsync(ready.Path, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (Expected(ex))
            {
                System.Diagnostics.Trace.WriteLine($"driver installer: {ex.Message}");
                return new InstallResult(InstallOutcome.CouldntStart);
            }
            if (started is null) return new InstallResult(InstallOutcome.Declined);
            var until = DateTime.UtcNow + _timing.InstallerLimit;
            var ended = await WaitForInstallerAsync(started, until, ct).ConfigureAwait(false);
            if (!ended)
            {
                keepFolder = true; // something it started may still be reading it
                return new InstallResult(InstallOutcome.TimedOut);
            }
            code = await started.Exited.ConfigureAwait(false);
        }
        finally
        {
            if (!keepFolder) Discard(ready);
        }
        if (code is not (0 or 3010 or 1641)) return new InstallResult(InstallOutcome.Failed, code);
        if (await IsThereAsync(isThere, ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, code);
        // The device node can be gone until Windows looks again (a driver installed while it was plugged in).
        var asUser = await RescanAsync(pc.RescanAsUserAsync, ct).ConfigureAwait(false);
        if (asUser && await WaitForAsync(isThere, ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, code, Rescanned: true);
        var elevated = await RescanAsync(pc.RescanElevatedAsync, ct).ConfigureAwait(false);
        if (elevated && await WaitForAsync(isThere, ct).ConfigureAwait(false)) return new InstallResult(InstallOutcome.Done, code, true, true);
        return new InstallResult(InstallOutcome.NotSeen, code, asUser || elevated, elevated);
    }

    /// <summary>
    /// Waits for the installer to exit and then for every process it started (and they started) to end, at most until
    /// <paramref name="until"/>: false when something is still running then. Followed by parent id from snapshots taken while it runs.
    /// </summary>
    private async Task<bool> WaitForInstallerAsync(InstallerProcess started, DateTime until, CancellationToken ct)
    {
        var tree = new HashSet<int> { started.Id };
        while (true)
        {
            IReadOnlyList<ProcessLink> now;
            try { now = pc.Processes(); }
            catch (Exception ex) when (Expected(ex)) { now = []; }
            bool grew;
            do
            {
                grew = false;
                foreach (var p in now)
                    if (p.Id != p.Parent && tree.Contains(p.Parent) && tree.Add(p.Id)) grew = true;
            } while (grew);
            var running = !started.Exited.IsCompleted || now.Any(p => p.Id != started.Id && tree.Contains(p.Id));
            if (!running) return true;
            if (DateTime.UtcNow >= until) return false;
            if (started.Exited.IsCompleted) await Task.Delay(_timing.Poll, ct).ConfigureAwait(false);
            else await Task.WhenAny(Task.Delay(_timing.Poll, ct), started.Exited).ConfigureAwait(false); // a look as soon as it exits
            ct.ThrowIfCancellationRequested();
        }
    }

    private static async Task<bool> IsThereAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        try
        {
            return await isThere(ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (Expected(ex))
        {
            System.Diagnostics.Trace.WriteLine($"driver check: {ex.Message}");
            return false;
        }
    }

    private static async Task<bool> RescanAsync(Func<CancellationToken, Task<bool>> rescan, CancellationToken ct)
    {
        try
        {
            return await rescan(ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (Expected(ex))
        {
            System.Diagnostics.Trace.WriteLine($"rescan: {ex.Message}");
            return false;
        }
    }

    private async Task<bool> WaitForAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        var until = DateTime.UtcNow + _timing.Wait;
        var step = TimeSpan.FromMilliseconds(Math.Clamp(_timing.Wait.TotalMilliseconds / 10, 1, 2000));
        while (true)
        {
            if (await IsThereAsync(isThere, ct).ConfigureAwait(false)) return true;
            if (DateTime.UtcNow >= until) return false;
            await Task.Delay(step, ct).ConfigureAwait(false);
        }
    }

    public async Task<bool> LookAgainAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct)
    {
        if (await IsThereAsync(isThere, ct).ConfigureAwait(false)) return true;
        return await RescanAsync(pc.RescanAsUserAsync, ct).ConfigureAwait(false) && await WaitForAsync(isThere, ct).ConfigureAwait(false);
    }

    public void Discard(DriverReady ready)
    {
        if (Path.GetDirectoryName(ready.Path) is { } dir && IsInside(dir, folder)) Remove(dir);
    }

    /// <summary><paramref name="path"/> is <paramref name="root"/>'s own subfolder (bounded by a separator: never a sibling such as "root-old").</summary>
    public static bool IsInside(string path, string root)
    {
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        var parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        return full.Length > parent.Length && full.StartsWith(parent, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Deletes downloads left behind (an installer that outlived its limit, the app closed mid-way): every folder in
    /// <paramref name="folder"/> not written to for <paramref name="olderThan"/> (so one the command line is using now stays).
    /// Run at start-up, off the UI thread. Returns how many went.
    /// </summary>
    public static int SweepLeftovers(string folder, TimeSpan olderThan, DateTime nowUtc)
    {
        if (!Directory.Exists(folder)) return 0;
        var gone = 0;
        foreach (var dir in Directory.EnumerateDirectories(folder).Take(1000))
        {
            try
            {
                var info = new DirectoryInfo(dir);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0 || nowUtc - info.LastWriteTimeUtc < olderThan) continue;
                if (Remove(dir)) gone++;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Trace.WriteLine($"driver downloads: {ex.Message}"); }
        }
        return gone;
    }

    private static bool Remove(string dir)
    {
        try
        {
            Directory.Delete(dir, recursive: true);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.WriteLine($"driver download: {ex.Message}");
            return false;
        }
    }
}
