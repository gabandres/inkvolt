using PrintDesk.Windows;

namespace PrintDesk.App;

/// <summary>Features that differ between the unpackaged app and the MSIX package (packaging/README.md).</summary>
public static class Features
{
    /// <summary>
    /// HP clean-up: finds and removes HP Smart, HP's Print Support App and the services it leaves behind. Removing other
    /// publishers' apps and services may not pass Microsoft Store review, so packaged copies leave it out unless the
    /// package was built with <c>pack-msix.ps1 -IncludeHpCleanup</c> (sideloading, outside the Store). Unpackaged copies
    /// always have it.
    /// </summary>
    public static bool HpCleanup { get; } =
#if HP_CLEANUP_IN_PACKAGE
        true;
#else
        !AppPackage.IsPackaged;
#endif

    /// <summary>
    /// Printers added by IP address: unpackaged copies create the Windows queue themselves with one UAC prompt
    /// (elevated PowerShell). Store policy rejects apps that elevate or start PowerShell, so packaged copies copy the
    /// printer's address and open Windows Settings, where the user adds it with Windows' own "Add manually".
    /// </summary>
    public static bool ElevatedQueueSetup { get; } = !AppPackage.IsPackaged;
}
