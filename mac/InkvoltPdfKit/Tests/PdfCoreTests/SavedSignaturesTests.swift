import Foundation
import Testing
@testable import PdfCore

/// `SavedSignatures`: Fill & Sign's library of handwritten signatures kept between launches. The Windows
/// `SignatureLibrary` lives in the app and has no tests, so these are a Mac addition following its rules: three
/// signature slots filled first-free, one set of initials replaced in place, other files ignored.
struct SavedSignaturesTests {
    private static func folder() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("saved-signatures-\(UUID().uuidString)")
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    @Test func SignaturesFillTheFirstFreeSlotUpToThree() throws {
        let library = SavedSignatures(folder: Self.folder())
        defer { try? FileManager.default.removeItem(atPath: library.folder) }
        #expect(library.list().isEmpty)
        let first = try #require(try library.save(Self.png, initials: false))
        let second = try #require(try library.save(Self.png, initials: false))
        let third = try #require(try library.save(Self.png, initials: false))
        #expect([first, second, third].map(\.name) == ["Signature 1", "Signature 2", "Signature 3"])
        #expect(try library.save(Self.png, initials: false) == nil)
        try library.delete(second)
        let again = try #require(try library.save(Data([9]), initials: false))
        #expect(try again.name == "Signature 2" && again.load() == Data([9]))
        #expect(library.signatureCount == 3)
    }

    @Test func InitialsAreReplacedInPlace() throws {
        let library = SavedSignatures(folder: Self.folder())
        defer { try? FileManager.default.removeItem(atPath: library.folder) }
        try library.save(Self.png, initials: true)
        let replaced = try #require(try library.save(Data([7]), initials: true))
        #expect(try replaced.name == "Initials" && replaced.load() == Data([7]))
        #expect(library.list().filter(\.initials).count == 1 && library.signatureCount == 0)
    }

    @Test func ListPutsSignaturesFirstAndSkipsOtherFiles() throws {
        let library = SavedSignatures(folder: Self.folder())
        defer { try? FileManager.default.removeItem(atPath: library.folder) }
        try library.save(Self.png, initials: true)
        try library.save(Self.png, initials: false)
        try library.save(Self.png, initials: false)
        for name in ["notes.txt", "other.png", "signature9.png.tmp"] {
            try Data([0]).write(to: URL(fileURLWithPath: (library.folder as NSString).appendingPathComponent(name)))
        }
        #expect(library.list().map(\.name) == ["Signature 1", "Signature 2", "Initials"])
    }

    @Test func KeptBetweenLaunches() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try SavedSignatures(folder: folder).save(Self.png, initials: false)
        // A new library over the same folder (the app's next launch) finds it.
        let later = SavedSignatures(folder: folder).list()
        #expect(try later.count == 1 && later[0].load() == Self.png)
    }

    @Test func DeletingAMissingFileIsQuiet() throws {
        let library = SavedSignatures(folder: Self.folder())
        try library.delete(SavedSignature(path: (library.folder as NSString).appendingPathComponent("signature1.png"), initials: false))
        #expect(library.list().isEmpty)
    }
}
