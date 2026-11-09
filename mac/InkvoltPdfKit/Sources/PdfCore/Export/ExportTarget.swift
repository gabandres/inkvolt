import Foundation
import PrintCore

/// Where a one-click conversion (the command bar's Convert › Word, Excel…) writes, as Windows' `ExportTarget`: next to
/// the PDF, so it is found where the PDF is; in Documents when the PDF has no folder yet (a new, unsaved one) or its
/// folder refuses the file (a read-only volume, a locked folder). The name is reserved by creating the file (an empty
/// one, which the export then replaces) with an exclusive create, so two conversions at once never pick the same name and
/// nothing is ever written over. A name Windows opens as a device (CON, COM¹, CONIN$…: `ReservedFileNames`) is refused,
/// so the conversion asks where instead. Call it off the main thread: a network volume can be slow.
public enum ExportTarget {
    /// The reserved file, and whether it is in Documents rather than next to the PDF.
    public struct Reserved: Equatable, Sendable {
        public let path: String
        public let inDocuments: Bool

        public init(path: String, inDocuments: Bool) {
            self.path = path
            self.inDocuments = inDocuments
        }
    }

    /// What creating a file found: made it, a file of that name is there, or the folder refused it.
    public enum CreateResult: Sendable { case created, exists, refused }

    /// What a reservation came to: the file, or why there is none, so the app says the right reason.
    public enum Reservation: Equatable, Sendable {
        case reserved(Reserved)
        /// The name opens a device on Windows (a PDF named CON.pdf): the save panel asks, offering `allowedName`.
        case deviceName
        /// No folder took it: the PDF's refused (or it isn't saved) and Documents refused too (`documentsTried`), or there
        /// is no Documents folder to try.
        case refused(documentsTried: Bool)
    }

    /// `reservation`'s file, or nil when there is none.
    public static func reserve(pdfPath: String?, fileName: String, documents: String?,
                               uniquePath: (String, String) throws -> String = defaultUniquePath,
                               create: (String) -> CreateResult = tryCreate) -> Reserved? {
        if case .reserved(let r) = reservation(pdfPath: pdfPath, fileName: fileName, documents: documents, uniquePath: uniquePath, create: create) {
            return r
        }
        return nil
    }

    /// `fileName` as a name every Windows takes: a device name gets "_" after its stem ("CON.docx" → "CON_.docx",
    /// Inkvolt Print's rule); anything else as it is.
    public static func allowedName(_ fileName: String) -> String {
        guard ReservedFileNames.isDevice(fileName) else { return fileName }
        guard let dot = fileName.firstIndex(of: ".") else { return fileName + "_" }
        return String(fileName[..<dot]) + "_" + String(fileName[dot...])
    }

    /// Reserves `fileName` (made unique by `uniquePath`) next to `pdfPath`, else in `documents`.
    /// - Parameters:
    ///   - pdfPath: The PDF's file, or nil while it isn't saved.
    ///   - documents: The user's Documents folder; nil or empty when there is none.
    ///   - uniquePath: A free path for the name in a folder ("name (2).docx" when taken).
    ///   - create: Creates the file if nothing is there (`tryCreate`; a seam for tests).
    public static func reservation(pdfPath: String?, fileName: String, documents: String?,
                                   uniquePath: (String, String) throws -> String = defaultUniquePath,
                                   create: (String) -> CreateResult = tryCreate) -> Reservation {
        guard !ReservedFileNames.isDevice(fileName) else { return .deviceName }
        let own = pdfPath.flatMap { $0.isEmpty ? nil : ($0 as NSString).deletingLastPathComponent }
        var folders: [(folder: String, inDocuments: Bool)] = []
        if let own, !own.isEmpty { folders.append((own, false)) }
        if let documents, !documents.trimmingCharacters(in: .whitespaces).isEmpty,
           own.map({ $0.compare(documents, options: .caseInsensitive) != .orderedSame }) ?? true {
            folders.append((documents, true))
        }
        for (folder, inDocuments) in folders {
            // A few tries: another conversion may take the free name between choosing it and creating it.
            for _ in 0..<8 {
                guard let path = try? uniquePath(folder, fileName) else { break } // no name fits there
                switch create(path) {
                case .created: return .reserved(Reserved(path: path, inDocuments: inDocuments))
                case .exists: continue
                case .refused: break
                }
                break
            }
        }
        // Documents was tried when it is there, as the fallback or as the PDF's own folder.
        return .refused(documentsTried: !(documents ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// "name.docx" in `folder`, else "name (2).docx", "name (3).docx"… (`SplitFiles.uniquePath`'s rule).
    public static func defaultUniquePath(_ folder: String, _ fileName: String) -> String {
        var none = Set<String>()
        return SplitFiles.uniquePath(folder, fileName, &none)
    }

    /// Creates an empty regular file at `path` only if nothing is there (O_CREAT | O_EXCL, never through a symbolic link).
    public static func tryCreate(_ path: String) -> CreateResult {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0 { return errno == EEXIST ? .exists : .refused }
        var info = stat()
        let regular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        if !regular {
            unlink(path)
            return .refused
        }
        return .created
    }

    /// Deletes the reserved file of a conversion that wrote nothing (cancelled, failed, nothing to export): only while it
    /// is still empty, so a file the export wrote is never removed.
    @discardableResult
    public static func deleteIfEmpty(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == 0 else { return false }
        return unlink(path) == 0
    }
}
