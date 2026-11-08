using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using InkvoltPrint.Core.Drivers;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// "Get the driver" on this PC (<see cref="DriverFlow"/>): Epson's site through <see cref="BoundedHttp"/>, Authenticode through
/// <c>WinVerifyTrust</c>, the installer run with the shell (it raises its own prompt), Windows asked to look for devices again. The
/// downloads go to their own folder under the app's data and are deleted once run or refused.
/// </summary>
public static class WindowsDrivers
{
    public static PcArch Arch => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? PcArch.Arm64 : PcArch.X64;

    public static PcWindows Windows => Environment.OSVersion.Version.Build >= 22000 ? PcWindows.Windows11 : PcWindows.Windows10;

    public static string DownloadFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InkvoltPrint", "Driver downloads");

    private static readonly Lazy<BoundedHttp> Http = new(() => new BoundedHttp(BoundedHttp.CreateHandler()));

    public static DriverFlow Create(TimeSpan? wait = null) =>
        new(new MakerCatalogs(new EpsonDrivers(Http.Value)), Http.Value, new WindowsSignatures(), new WindowsDriverPc(), DownloadFolder, Arch, Windows, wait);
}

/// <summary>A file's Authenticode signature (<c>WinVerifyTrust</c>, chain and revocation checked, no UI) and its signer's organization.</summary>
public sealed class WindowsSignatures : ISignatureCheck
{
    private static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    public SignatureFacts Check(string path)
    {
        var pathPtr = Marshal.StringToHGlobalUni(path);
        var fileInfo = new FileInfoStruct { Size = (uint)Marshal.SizeOf<FileInfoStruct>(), FilePath = pathPtr };
        var filePtr = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfoStruct>());
        Marshal.StructureToPtr(fileInfo, filePtr, false);
        var data = new TrustData
        {
            Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2 /* none */, RevocationChecks = 1 /* whole chain */, UnionChoice = 1 /* file */,
            File = filePtr, StateAction = 1 /* verify */, ProvFlags = 0x80 /* revocation: chain, root excluded */,
        };
        var action = GenericVerifyV2;
        try
        {
            var result = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            var state = result switch
            {
                0 => SignatureState.Valid,
                unchecked((int)0x800B0100) or unchecked((int)0x800B0003) or unchecked((int)0x800B0001) => SignatureState.NotSigned,
                unchecked((int)0x800B0109) or unchecked((int)0x800B010A) or unchecked((int)0x800B0101) or unchecked((int)0x800B010C)
                    or unchecked((int)0x800B0111) or unchecked((int)0x800B0004) or unchecked((int)0x800B010E) or unchecked((int)0x800B0110)
                    or unchecked((int)0x800B010F) => SignatureState.Untrusted,
                _ => SignatureState.Invalid,
            };
            Trace.WriteLine($"signature: 0x{result:X8}");
            return new SignatureFacts(state, Organization(data.StateData));
        }
        finally
        {
            data.StateAction = 2; // close
            WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            Marshal.FreeHGlobal(filePtr);
            Marshal.FreeHGlobal(pathPtr);
        }
    }

    /// <summary>The O= of the certificate that signed it, as WinVerifyTrust read it (null when it has none).</summary>
    private static string? Organization(IntPtr stateData)
    {
        if (stateData == IntPtr.Zero) return null;
        var prov = WTHelperProvDataFromStateData(stateData);
        if (prov == IntPtr.Zero) return null;
        var signer = WTHelperGetProvSignerFromChain(prov, 0, false, 0);
        if (signer == IntPtr.Zero) return null;
        // CRYPT_PROVIDER_SGNR: cbStruct, sftVerifyAsOf (FILETIME), csCertChain, then pasCertChain (pointer-aligned).
        var count = Marshal.ReadInt32(signer, 12);
        var chain = Marshal.ReadIntPtr(signer, 16);
        if (count < 1 || chain == IntPtr.Zero) return null;
        // CRYPT_PROVIDER_CERT: cbStruct, then pCert (pointer-aligned).
        var context = Marshal.ReadIntPtr(chain, IntPtr.Size);
        if (context == IntPtr.Zero) return null;
        using var cert = new X509Certificate2(context);
        foreach (var rdn in cert.SubjectName.EnumerateRelativeDistinguishedNames())
            if (rdn.GetSingleElementType().Value == "2.5.4.10" && rdn.GetSingleElementValue() is { Length: > 0 } o) return o;
        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfoStruct
    {
        public uint Size;
        public IntPtr FilePath, File, KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size;
        public IntPtr PolicyCallbackData, SipClientData;
        public uint UiChoice, RevocationChecks, UnionChoice;
        public IntPtr File;
        public uint StateAction;
        public IntPtr StateData, UrlReference;
        public uint ProvFlags, UiContext;
        public IntPtr SignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = false)]
    private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref TrustData data);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperProvDataFromStateData(IntPtr stateData);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provData, uint signerIndex, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterSignerIndex);
}

/// <summary>The installer run as the user asked (its own prompt), and Windows asked to look for devices again.</summary>
public sealed class WindowsDriverPc : IDriverPc
{
    private static readonly TimeSpan InstallerLimit = TimeSpan.FromMinutes(45);

    public async Task<InstallerExit> RunInstallerAsync(string path, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path) };
        Process? p;
        try
        {
            p = await Task.Run(() => Process.Start(psi), CancellationToken.None).ConfigureAwait(false); // returns once its prompt is answered
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return new InstallerExit(InstallerEnd.Declined);
        }
        if (p is null) return new InstallerExit(InstallerEnd.Exited, -1);
        using (p)
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
            limit.CancelAfter(InstallerLimit);
            try
            {
                await p.WaitForExitAsync(limit.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                return new InstallerExit(InstallerEnd.TimedOut);
            }
            return new InstallerExit(InstallerEnd.Exited, p.ExitCode);
        }
    }

    public Task<bool> RescanAsUserAsync(CancellationToken ct) => Task.Run(() =>
    {
        var located = CM_Locate_DevNodeW(out var root, null, 0);
        if (located != 0) return false;
        var done = CM_Reenumerate_DevNode(root, 1 /* synchronous */);
        Trace.WriteLine($"rescan as the user: CR {done}");
        return done == 0;
    }, ct);

    public async Task<bool> RescanElevatedAsync(CancellationToken ct)
    {
        var code = await Elevated.RunAsync("& (Join-Path $env:SystemRoot 'System32\\pnputil.exe') /scan-devices | Out-Null; exit $LASTEXITCODE", [],
            TimeSpan.FromMinutes(2), ct).ConfigureAwait(false);
        Trace.WriteLine($"rescan elevated: {code}");
        return code == 0;
    }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int CM_Locate_DevNodeW(out uint devInst, string? deviceId, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    private static extern int CM_Reenumerate_DevNode(uint devInst, uint flags);
}
