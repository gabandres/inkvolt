import Foundation

/// The names Windows opens as a device instead of a file, whatever the extension: CON, PRN, AUX, NUL, COM1 to COM9,
/// LPT1 to LPT9, the superscript forms COM¹ COM² COM³ LPT¹ LPT² LPT³ (Latin-1's ¹ ² ³, which Windows maps to the
/// digits) and the console handles CONIN$ and CONOUT$. A Mac's file can sync or be copied to a PC, so every name the
/// Mac apps make (Batch's results, Inkvolt Print's scans, a one-click conversion) goes through this one rule.
public enum ReservedFileNames {
    /// Lowercase, as compared.
    public static let devices: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
        "com¹", "com²", "com³", "lpt¹", "lpt²", "lpt³",
        "conin$", "conout$",
    ]

    /// Whether `name` (a file name, its extension or extensions included) is a device on Windows: the part before its
    /// first dot, trailing spaces ignored, any case. "nul.tar.gz" and "COM¹ .docx" are; "console.txt" isn't.
    public static func isDevice(_ name: String) -> Bool {
        var stem = name.firstIndex(of: ".").map { String(name[..<$0]) } ?? name
        while stem.last == " " { stem.removeLast() }
        return devices.contains(stem.lowercased())
    }
}
