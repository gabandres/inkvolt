import Foundation

/// The Pro entitlement check behind each app's `Pro` (the Windows suite's `ProCheck`): one instance per app, for its
/// product. The licence is a key (`ProKeys`) signed with our private key and checked here against the public key: no
/// server is asked, nothing is sent, the key works offline and survives reinstalling. It is kept where both apps find it
/// (`ProKeyFile`) and in the app's own settings, so a key entered in one app licenses the other when it lists both
/// products. Removing it never takes away a result already made.
public final class ProCheck: @unchecked Sendable {
    /// The one switch, for both apps. While it is false, everything is free: `allowed` says yes to everyone (a key is
    /// still verified and shown in Help › Inkvolt Pro). It flips to true in a release noted in each app's WHATS-NEW; tests
    /// set it either way.
    public static var enforced: Bool {
        get { enforcedLock.withLock { enforcedValue } }
        set { enforcedLock.withLock { enforcedValue = newValue } }
    }
    nonisolated(unsafe) private static var enforcedValue = false
    private static let enforcedLock = NSLock()

    public static let priceText = "$19"
    public static let buyUrl = "https://bermudezsystems.com/products/inkvolt/pro"

    private let lock = NSLock()
    private var storeValue: ProStore = MemoryProStore()
    private var verifierValue: ProSignatureVerifier
    private var licenceValue: ProLicence?
    private var problemValue: String?
    private var loaded = false

    /// "pdf" or "print" (`ProKeys.knownProducts`): what a key must list to count here.
    public let product: String

    public init(_ product: String, verifier: ProSignatureVerifier = NoProSignatureVerifier()) {
        self.product = product
        verifierValue = verifier
    }

    /// The app, as the refusals name it.
    public var productName: String { ProKeys.productName(product) }

    /// Where the key is kept. Setting it forgets what was read from the previous store.
    public var store: ProStore {
        get { lock.withLock { storeValue } }
        set {
            lock.withLock {
                storeValue = newValue
                loaded = false
            }
        }
    }

    /// What checks a key's signature (PrintMac's CryptoKit one in the app). Setting it forgets what was read.
    public var verifier: ProSignatureVerifier {
        get { lock.withLock { verifierValue } }
        set {
            lock.withLock {
                verifierValue = newValue
                loaded = false
            }
        }
    }

    /// The installed licence, or nil (none, or the stored key doesn't count: `problem`).
    public var licence: ProLicence? { lock.withLock { load(); return licenceValue } }

    /// Why the stored key doesn't count, when there is one and it doesn't; nil otherwise.
    public var problem: String? { lock.withLock { load(); return problemValue } }

    /// True when a Pro feature may run: always while `enforced` is off, else with a licence.
    public var allowed: Bool { !Self.enforced || licence != nil }

    /// Checks `key`, keeps it in the store and returns its licence; refuses with a reason.
    @discardableResult
    public func install(_ key: String) throws -> ProLicence {
        let licence = try ProKeys.parse(key, verifier: verifier)
        if !licence.covers(product) {
            throw ProKeyError(loc("This key is for {0}, not {1}. A key for {2} lists it.", Self.names(licence), productName, productName))
        }
        lock.withLock {
            storeValue.write(ProKeys.format(key))
            licenceValue = licence
            problemValue = nil
            loaded = true
        }
        return licence
    }

    /// Forgets the key. What the Pro features made stays.
    public func remove() {
        lock.withLock {
            storeValue.write(nil)
            licenceValue = nil
            problemValue = nil
            loaded = true
        }
    }

    /// Under the lock.
    private func load() {
        if loaded { return }
        loaded = true
        licenceValue = nil
        problemValue = nil
        guard let stored = storeValue.read(), !stored.isEmpty else { return }
        do {
            let licence = try ProKeys.parse(stored, verifier: verifierValue)
            if licence.covers(product) {
                licenceValue = licence
            } else {
                problemValue = loc("The saved key is for {0}, not {1}.", Self.names(licence), productName)
            }
        } catch let e as ProKeyError {
            problemValue = loc("The saved key no longer checks out: {0}", e.message)
        } catch {
            problemValue = loc("The saved key no longer checks out.")
        }
    }

    private static func names(_ licence: ProLicence) -> String { MaintenanceCatalog.and(licence.products.map(ProKeys.productName)) }
}

/// The licence key where both apps find it: `<root>/Inkvolt/pro-key.txt`, one line, the key as it is shown. On the Mac the
/// root is the app group container both apps share (PrintMac and the apps pass it); on Windows it is %LOCALAPPDATA%, whose
/// Store-package redirection has no Mac counterpart, so the Mac reads one place. Pure path and file logic, testable with
/// any folder as the root.
public enum ProKeyFile {
    public static let fileName = "pro-key.txt"

    /// Where a key is written.
    public static func pathUnder(_ root: String) -> String {
        ((root as NSString).appendingPathComponent("Inkvolt") as NSString).appendingPathComponent(fileName)
    }

    /// Every copy that exists (the Mac has the one place).
    public static func candidates(_ root: String) -> [String] {
        let plain = pathUnder(root)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: plain, isDirectory: &isDirectory) && !isDirectory.boolValue ? [plain] : []
    }

    /// The key, or nil (none, empty, or unreadable).
    public static func read(_ root: String) -> String? {
        for file in candidates(root) {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { return key }
            }
        }
        return nil
    }

    /// Writes the key (making the folder), or with nil deletes it. False when the file system refused.
    @discardableResult
    public static func write(_ root: String, _ key: String?) -> Bool {
        if let key, !key.isEmpty {
            let path = pathUnder(root)
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data((key + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                return true
            } catch {
                return false
            }
        }
        var ok = true
        for file in candidates(root) {
            do { try FileManager.default.removeItem(atPath: file) } catch { ok = false }
        }
        return ok
    }
}

/// An app's key store: the shared file (`ProKeyFile`) is the key's home; the app's own settings (`own`) hold a key only
/// from before the file existed (Inkvolt PDF for Mac keeps it in its settings today) or when the file couldn't be written.
/// Such a key is moved into the file on the first read, so the other app finds it and removing it in either app removes it
/// for both. Installing writes the file (the settings only if that fails); removing clears both.
public final class SharedProStore: ProStore, @unchecked Sendable {
    private let own: ProStore
    private let root: String

    public init(_ own: ProStore, _ root: String) {
        self.own = own
        self.root = root
    }

    public func read() -> String? {
        if let shared = ProKeyFile.read(root) { return shared }
        guard let mine = own.read(), !mine.isEmpty else { return nil }
        if ProKeyFile.write(root, mine) { own.write(nil) }
        return mine
    }

    public func write(_ key: String?) {
        let written = ProKeyFile.write(root, key)
        if key == nil || !written {
            own.write(key)
        } else if own.read() != nil {
            own.write(nil)
        }
    }
}
