import Foundation

/// What is handed to Inkvolt Print from outside (the Windows app's `App.FirstPdf`, `Pictures`, `QueueArg`, `PresetArg` and
/// `ScanPresetLibrary.Find`): files opened from Finder, dropped on the window or named on the command line, and the
/// `--queue <name>` and `--preset <id>` that come with them. A PDF goes to Print a PDF, pictures to Print Photos; the first
/// PDF wins over pictures, as on Windows.
public enum HandedFiles {
    public enum What: Equatable, Sendable {
        case pdf(String)
        case pictures([String])
        case nothing
    }

    /// The first PDF among `paths`, else the pictures, of those that exist.
    public static func choose(_ paths: [String], exists: (String) -> Bool) -> What {
        if let pdf = paths.first(where: { ClipboardPrint.isPdf($0) && exists($0) }) { return .pdf(pdf) }
        let pictures = paths.filter { ClipboardPrint.isPicture($0) && exists($0) }
        return pictures.isEmpty ? .nothing : .pictures(pictures)
    }

    /// The command line's files: each argument that isn't an option (`-…`) or an option's value (the argument after an
    /// option: AppKit's `-NSSomething YES` too), so a file comes before the options, as `Inkvolt Print file.pdf --queue Office`.
    public static func files(in args: [String]) -> [String] {
        args.enumerated().compactMap { i, a in
            if a.isEmpty || a.hasPrefix("-") { return nil }
            if i > 0 && args[i - 1].hasPrefix("-") { return nil }
            return a
        }
    }

    /// The value after `option` (`--queue`, `--preset`), when there is one that isn't another option.
    public static func value(_ option: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: option), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        let v = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// A preset asked for from outside: by its id, else by its name (any case).
    public static func preset(_ idOrName: String, in presets: [ScanPreset]) -> ScanPreset? {
        presets.first { $0.id == idOrName } ?? presets.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    /// The printer something handed in goes to (Windows' `MainViewModel.Printer`): the one meant (`--queue`'s) when it
    /// prints, else the selected one when it prints, else the first that prints; nil when none does.
    public static func target<T>(_ printers: [T], selected: T?, meant: T? = nil, prints: (T) -> Bool) -> T? {
        if let meant, prints(meant) { return meant }
        if let selected, prints(selected) { return selected }
        return printers.first(where: prints)
    }
}
