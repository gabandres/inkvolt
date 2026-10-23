using System.Runtime.InteropServices;
using System.Text;

namespace PrintDesk.Windows;

/// <summary>
/// How the running app was installed: as an MSIX package (Microsoft Store or sideloaded) or unpackaged (the Desk
/// installer, a published exe, or a build folder). Packaged copies get their "Open with" entry, Start menu entry and
/// app execution alias from the package manifest, never from the registry; Windows keeps their %LOCALAPPDATA% writes in
/// the package's own folder; the Store updates them. Same check as PdfDesk's AppEnvironment.
/// </summary>
public static class AppPackage
{
    private const int AppModelErrorNoPackage = 15700;
    private const int ErrorInsufficientBuffer = 122;

    /// <summary>True when running with package identity (MSIX). One Win32 call, cached.</summary>
    public static bool IsPackaged => FamilyName is not null;

    /// <summary>The package family name (Name_PublisherHash) when packaged, else null.</summary>
    public static string? FamilyName { get; } = QueryFamilyName();

    private static string? QueryFamilyName()
    {
        try
        {
            var length = 0;
            var rc = GetCurrentPackageFamilyName(ref length, null);
            if (rc == AppModelErrorNoPackage || rc != ErrorInsufficientBuffer || length <= 0) return null;
            var buffer = new StringBuilder(length);
            return GetCurrentPackageFamilyName(ref length, buffer) == 0 ? buffer.ToString() : null;
        }
        catch (Exception ex) when (ex is EntryPointNotFoundException or DllNotFoundException)
        {
            return null;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFamilyName(ref int packageFamilyNameLength, StringBuilder? packageFamilyName);
}
