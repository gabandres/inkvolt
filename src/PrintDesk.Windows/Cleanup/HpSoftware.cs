using Windows.Management.Deployment;

namespace PrintDesk.Windows.Cleanup;

public sealed record InstalledApp(string FullName, string DisplayName, string Role)
{
    /// <summary>HP's Print Support App: Windows routes every job for HP IPP queues through it while installed.</summary>
    public bool IsPrintSupportApp => FullName.StartsWith("AD2F1837.HPPrinterDriver_", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Finds HP's Store apps that PrintDesk replaces: HP Smart itself, and HP's Print Support App, which Windows
/// attaches to HP IPP queues so every print job passes through HP code. Both are per-user Store packages, so
/// the current user can remove them without admin rights.
/// </summary>
public static class HpSoftware
{
    private static readonly (string Family, string Name, string Role)[] Known =
    [
        ("AD2F1837.HPPrinterControl_v10z8vjag6ke6", "HP Smart", "HP's printer app (replaced by PrintDesk)"),
        ("AD2F1837.HPPrinterDriver_v10z8vjag6ke6", "HP Smart Printing (Print Support App)", "Processes every print job sent to HP printers"),
    ];

    public static IReadOnlyList<InstalledApp> Find()
    {
        var pm = new PackageManager();
        var found = new List<InstalledApp>();
        foreach (var (family, name, role) in Known)
        {
            try
            {
                foreach (var p in pm.FindPackagesForUser(string.Empty, family))
                    found.Add(new InstalledApp(p.Id.FullName, name, role));
            }
            catch (Exception)
            {
                // Package query unavailable (policy, corrupted store): treat as not installed.
            }
        }
        return found;
    }

    public static async Task<string?> RemoveAsync(InstalledApp app)
    {
        try
        {
            var result = await new PackageManager().RemovePackageAsync(app.FullName);
            return result.ExtendedErrorCode is null ? null : result.ErrorText;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}
