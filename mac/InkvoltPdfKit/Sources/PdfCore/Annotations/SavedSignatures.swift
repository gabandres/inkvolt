import Foundation

/// A saved handwritten signature or initials: a transparent PNG in the library's folder (the Windows app's
/// `SavedSignature`).
public struct SavedSignature: Equatable, Sendable {
    public let path: String
    public let initials: Bool

    public init(path: String, initials: Bool) {
        self.path = path
        self.initials = initials
    }

    /// "Initials", or "Signature 1" from signature1.png.
    public var name: String {
        if initials { return "Initials" }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "Signature " + stem.replacingOccurrences(of: "signature", with: "", options: .caseInsensitive)
    }

    public func load() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
}

/// Up to three saved signatures and one set of initials, as PNG files in one folder (the Windows app's
/// `SignatureLibrary`, which keeps them under its data folder's "signatures"). The pictures stay PNG bytes here; the
/// app turns them into and out of `StampImage`s.
public struct SavedSignatures: Sendable {
    public static let maxSignatures = 3
    public let folder: String

    public init(folder: String) { self.folder = folder }

    /// Signatures first (by file name), then the initials; other files in the folder are left out.
    public func list() -> [SavedSignature] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let all: [SavedSignature] = names.compactMap { name in
            let lower = name.lowercased()
            guard lower.hasSuffix(".png") else { return nil }
            let initials = lower.hasPrefix("initials")
            guard initials || lower.hasPrefix("signature") else { return nil }
            return SavedSignature(path: (folder as NSString).appendingPathComponent(name), initials: initials)
        }
        return all.sorted { a, b in
            if a.initials != b.initials { return !a.initials }
            return a.path.lowercased() < b.path.lowercased()
        }
    }

    /// Saves a new signature in the first free slot, or replaces the initials; nil when all signature slots are taken.
    /// Written to a temporary file first, then moved into place, so a half-written file is never listed.
    @discardableResult
    public func save(_ png: Data, initials: Bool) throws -> SavedSignature? {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var path: String? = initials ? (folder as NSString).appendingPathComponent("initials.png") : nil
        var i = 1
        while path == nil && i <= Self.maxSignatures {
            let p = (folder as NSString).appendingPathComponent("signature\(i).png")
            if !FileManager.default.fileExists(atPath: p) { path = p }
            i += 1
        }
        guard let path else { return nil }
        let temp = path + ".tmp"
        try png.write(to: URL(fileURLWithPath: temp))
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
        } else {
            try FileManager.default.moveItem(atPath: temp, toPath: path)
        }
        return SavedSignature(path: path, initials: initials)
    }

    public func delete(_ signature: SavedSignature) throws {
        if FileManager.default.fileExists(atPath: signature.path) { try FileManager.default.removeItem(atPath: signature.path) }
    }

    /// The number of signatures (not initials) saved.
    public var signatureCount: Int { list().filter { !$0.initials }.count }
}
