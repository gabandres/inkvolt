using InkvoltPrint.Core;
using Windows.Devices.Enumeration;

namespace InkvoltPrint.Windows.Queues;

public enum InstallOutcome { Installed, AlreadyInstalled, NotAvailable, Failed }

public sealed record InstallResult(InstallOutcome Outcome, string Message);

/// <summary>
/// Installs Windows print/scan queues the same way Settings → "Add device" does: by pairing the printer's
/// association endpoint. Windows then creates an IPP Class Driver queue (no HP driver, no admin prompt)
/// and, for the eSCL endpoint, a WIA scanner.
/// </summary>
public static class QueueInstaller
{
    /// <summary>Printer installs take ~30 s (driver staging + queue creation); give them headroom, not forever.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(120);

    public static async Task<InstallResult> InstallAsync(string endpointId, CancellationToken ct = default, TimeSpan? timeout = null)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? DefaultTimeout);
        try
        {
            return await PairAsync(endpointId, cts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new(InstallOutcome.Failed, CoreStrings.Win_SetupTimedOut);
        }
    }

    private static async Task<InstallResult> PairAsync(string endpointId, CancellationToken ct)
    {
        DeviceInformation device;
        try
        {
            device = await DeviceInformation.CreateFromIdAsync(endpointId, [], DeviceInformationKind.AssociationEndpoint).AsTask(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return new(InstallOutcome.NotAvailable, CoreStrings.Win_NoLongerSeen);
        }

        if (device.Pairing.IsPaired) return new(InstallOutcome.AlreadyInstalled, CoreStrings.Win_AlreadyInstalled);
        if (!device.Pairing.CanPair) return new(InstallOutcome.NotAvailable, CoreStrings.Win_CannotInstallAuto);

        var custom = device.Pairing.Custom;
        void Accept(DeviceInformationCustomPairing _, DevicePairingRequestedEventArgs args) => args.Accept();
        custom.PairingRequested += Accept;
        try
        {
            var result = await custom.PairAsync(DevicePairingKinds.ConfirmOnly).AsTask(ct);
            return result.Status switch
            {
                DevicePairingResultStatus.Paired => new(InstallOutcome.Installed, CoreStrings.Win_Installed),
                DevicePairingResultStatus.AlreadyPaired => new(InstallOutcome.AlreadyInstalled, CoreStrings.Win_AlreadyInstalled),
                DevicePairingResultStatus.OperationAlreadyInProgress => new(InstallOutcome.Failed, CoreStrings.Win_AlreadySettingUp),
                _ => new(InstallOutcome.Failed, string.Format(CoreStrings.Win_InstallFailed, Describe(result.Status))),
            };
        }
        finally
        {
            custom.PairingRequested -= Accept;
        }
    }

    public static async Task<bool> UninstallAsync(string endpointId, CancellationToken ct = default)
    {
        var device = await DeviceInformation.CreateFromIdAsync(endpointId, [], DeviceInformationKind.AssociationEndpoint).AsTask(ct);
        if (!device.Pairing.IsPaired) return true;
        var r = await device.Pairing.UnpairAsync().AsTask(ct);
        return r.Status is DeviceUnpairingResultStatus.Unpaired or DeviceUnpairingResultStatus.AlreadyUnpaired;
    }

    private static string Describe(DevicePairingResultStatus s) => s switch
    {
        DevicePairingResultStatus.NotReadyToPair => CoreStrings.Win_PairNotReady,
        DevicePairingResultStatus.ConnectionRejected => CoreStrings.Win_PairRejected,
        DevicePairingResultStatus.AccessDenied => CoreStrings.Win_PairAccessDenied,
        DevicePairingResultStatus.Failed => CoreStrings.Win_PairFailed,
        DevicePairingResultStatus.RequiredHandlerNotRegistered or DevicePairingResultStatus.PairingCanceled => CoreStrings.Win_PairNeedsConfirmation,
        _ => s.ToString(),
    };
}
