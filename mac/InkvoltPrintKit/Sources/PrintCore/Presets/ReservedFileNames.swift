import Foundation

/// The names Windows opens as a device instead of a file: CON, PRN, AUX, NUL, COM0 to COM9, LPT0 to LPT9, the superscript
/// forms COM¹ COM² COM³ LPT¹ LPT² LPT³ (Latin-1's ¹ ² ³) and the console handles CONIN$ and CONOUT$. Windows'
/// `DeviceNames.IsReserved` (shared/InkvoltPrint.Core/DeviceNames.cs) on the Mac, same list and same matching: any case,
/// any extension, after the trailing dots and spaces Windows trims, and before a colon ("COM1:"). COM0 and LPT0 map to
/// nothing on today's Windows but Microsoft lists them, so they are reserved too. A Mac's file can sync or be copied to
/// a PC, so every name the Mac apps make (Batch's results, Inkvolt Print's scans, a one-click conversion) goes through it.
public enum ReservedFileNames {
    /// Lowercase, as compared.
    public static let devices: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul", "conin$", "conout$"]
        for d in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"] {
            names.insert("com" + d)
            names.insert("lpt" + d)
        }
        return names
    }()

    /// Whether `name` (one file name, not a path) opens a device on Windows rather than a file. "nul.tar.gz", "CON ",
    /// "nul. . " and "aux:stream" do; "console.txt", " CON" (Windows keeps a leading space) and "COM⁴" don't.
    public static func isDevice(_ name: String) -> Bool {
        var trimmed = Substring(name)
        while let last = trimmed.last, last == "." || last == " " { trimmed.removeLast() }
        var stem = trimmed.firstIndex(where: { $0 == "." || $0 == ":" }).map { trimmed[..<$0] } ?? trimmed
        while stem.last == " " { stem.removeLast() }
        return devices.contains(stem.lowercased())
    }
}
