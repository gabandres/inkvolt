namespace InkvoltPrint.Core;

/// <summary>
/// Whether Windows maps a file name to a device instead of a file: CON, PRN, AUX, NUL, COM0–COM9, LPT0–LPT9, COM¹ COM²
/// COM³ LPT¹ LPT² LPT³ (Latin-1's superscript digits) and the console handles CONIN$ and CONOUT$. The one rule both
/// apps use (Inkvolt PDF's file names, batch names and redaction sets; Inkvolt Print's scan names and batch lists); each
/// caller decides what a reserved name becomes.
/// </summary>
/// <remarks>
/// Matched as Windows 10 matches them, the strictest: any case, with any extension (<c>nul.txt</c>,
/// <c>COM1.backup.pdf</c>), after the trailing dots and spaces Windows trims (<c>"CON "</c>, <c>"nul."</c>,
/// <c>"PRN .txt"</c>), and before a colon (<c>"COM1:"</c>). Windows 11 (checked on 10.0.26300, 2026-11-09) maps only the
/// bare names: <c>nul.txt</c>, <c>COM¹.txt</c> and <c>LPT²</c> are files there, <c>nul</c> is <c>\\.\nul</c>.
/// COM0 and LPT0: Microsoft's naming page lists them, but neither Windows 10 (its check takes the digits 1–9 and ¹ ² ³)
/// nor Windows 11 (COM0, LPT0, COM0.txt, LPT0.pdf all made real files on 10.0.26300) maps them. They are reserved here
/// anyway: a name that is a device on any Windows a file may be copied to is never made, and nothing is lost but a
/// "_".
/// </remarks>
public static class DeviceNames
{
    private static readonly HashSet<string> Names = Build();

    private static HashSet<string> Build()
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
        foreach (var d in "0123456789¹²³")
        {
            names.Add("COM" + d);
            names.Add("LPT" + d);
        }
        return names;
    }

    /// <summary>
    /// True when <paramref name="fileName"/> (one name, not a path) opens a device on Windows rather than a file.
    /// </summary>
    public static bool IsReserved(string? fileName)
    {
        if (string.IsNullOrEmpty(fileName)) return false;
        var name = fileName.TrimEnd('.', ' ');
        var end = name.AsSpan().IndexOfAny('.', ':');
        var stem = (end < 0 ? name : name[..end]).TrimEnd(' ');
        // OrdinalIgnoreCase: "com¹" matches "COM¹"; "COM⁴" or a full-width "ＣＯＮ" doesn't, as in Windows.
        return Names.Contains(stem);
    }
}
