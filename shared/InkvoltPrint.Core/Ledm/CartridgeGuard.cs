namespace InkvoltPrint.Core.Ledm;

/// <summary>How "Keep my cartridges working" turned out.</summary>
public enum CartridgeGuardOutcome
{
    /// <summary>Automatic updates were off already: nothing was written.</summary>
    AlreadyOff,

    /// <summary>Written, and the printer reads back Off.</summary>
    Done,

    /// <summary>Written, but the printer reads back another mode, or nothing.</summary>
    NotKept,

    /// <summary>The printer doesn't let apps change the setting: nothing was written.</summary>
    CantChange,
}

/// <summary>What was done, in plain words, and the mode the printer reads back (null when it said nothing).</summary>
public sealed record CartridgeGuardResult(CartridgeGuardOutcome Outcome, FirmwareUpdateMode? ReadBack, string Text);

/// <summary>
/// "Keep my cartridges working" (roadmap 1.5): one button on an HP printer's Firmware card that sets automatic firmware updates
/// Off, so an HP update with "dynamic security" (which stops cartridges with non-HP chips) never installs by itself, then reads
/// the setting back and says what it did. The write is the Firmware card's own Off write, byte for byte
/// (<see cref="FirmwareUpdateSettings.BuildPut"/> to <see cref="FirmwareUpdateSettings.ConfigPath"/>). Off rather than "check,
/// don't install": some printers install when only the check is on (the LaserJet MFP M234dw does).
/// </summary>
public static class CartridgeGuard
{
    /// <param name="settings">As read just before (<see cref="LedmClient.GetFirmwareUpdateAsync"/>).</param>
    /// <param name="withAuth">Runs the write, asking for the admin password when the printer wants it (the settings' own way).</param>
    public static async Task<CartridgeGuardResult> KeepCartridgesWorkingAsync(LedmClient ledm, FirmwareUpdateSettings settings,
        Func<Func<Task>, Task> withAuth, CancellationToken ct = default)
    {
        if (settings.Mode == FirmwareUpdateMode.Off)
            return new(CartridgeGuardOutcome.AlreadyOff, FirmwareUpdateMode.Off,
                CoreStrings.Ledm_GuardAlreadyOff);
        if (!settings.CanChange || !settings.Choices.Contains(FirmwareUpdateMode.Off) || settings.ConfigPath is not { } path)
            return new(CartridgeGuardOutcome.CantChange, settings.Mode,
                CoreStrings.Ledm_GuardCantChange);

        await withAuth(() => ledm.PutPathAsync(path, settings.BuildPut(FirmwareUpdateMode.Off), ct)).ConfigureAwait(false);
        var back = await ledm.GetFirmwareUpdateAsync(ct).ConfigureAwait(false);
        return back?.Mode switch
        {
            FirmwareUpdateMode.Off => new(CartridgeGuardOutcome.Done, FirmwareUpdateMode.Off,
                CoreStrings.Ledm_GuardDone),
            { } other => new(CartridgeGuardOutcome.NotKept, other,
                string.Format(CoreStrings.Ledm_GuardNotKept, Words(other))),
            null => new(CartridgeGuardOutcome.NotKept, null,
                CoreStrings.Ledm_GuardNoReadBack),
        };
    }

    private static string Words(FirmwareUpdateMode mode) => mode switch
    {
        FirmwareUpdateMode.Automatic => CoreStrings.Ledm_GuardModeAutomatic,
        FirmwareUpdateMode.Notify => CoreStrings.Ledm_GuardModeNotify,
        _ => CoreStrings.Ledm_GuardModeOff,
    };
}
