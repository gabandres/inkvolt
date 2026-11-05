import Foundation

/// The features Inkvolt Pro unlocks in Inkvolt Print (print/ROADMAP.md, "Free and Pro"; the Windows Core's `ProFeature`).
public enum ProFeature: CaseIterable, Sendable {
    /// 1.1: one CSV of the supply history across all printers (the chart and days left stay free).
    case supplyHistoryExport
    /// 2.4: saved batch-print lists, a dropped folder printed as it fills, the command line, the results as CSV.
    case batchPrintAutomation
    /// 2.6: the fleet page's CSV and JSON, `status --all`, Fix all.
    case fleetExport
    /// 3.1: a scanner shared on the network over eSCL.
    case scannerSharing
    /// 3.2: SNMPv3 (a community per printer stays free).
    case snmpV3
}

/// The Pro entitlement check for Inkvolt Print: the one place a Pro feature asks whether it may run (`allows`), nowhere
/// else. Behind it is the suite's `ProCheck` for the "print" product: the key format, its verification (the app sets
/// PrintMac's CryptoKit verifier), the gate (`ProCheck.enforced`, off while the apps launch) and the store, so one key
/// listing both products licenses both apps. Removing it never takes away a result already made.
public enum Pro {
    /// The one switch, shared with Inkvolt PDF.
    public static var enforced: Bool {
        get { ProCheck.enforced }
        set { ProCheck.enforced = newValue }
    }

    public static let product = ProKeys.productPrint

    private static let check = ProCheck(product)

    /// Where the key is kept. Setting it forgets what was read from the previous store.
    public static var store: ProStore {
        get { check.store }
        set { check.store = newValue }
    }

    /// What checks a key's signature: PrintMac's CryptoKit verifier in the app, a stand-in in the tests.
    public static var verifier: ProSignatureVerifier {
        get { check.verifier }
        set { check.verifier = newValue }
    }

    /// The installed licence, or nil (none, or the stored key doesn't count: `problem`).
    public static var licence: ProLicence? { check.licence }

    /// Why the stored key doesn't count, when there is one and it doesn't; nil otherwise.
    public static var problem: String? { check.problem }

    /// True when `feature` may run: always while `enforced` is off, else with a licence.
    public static func allows(_ feature: ProFeature) -> Bool { check.allowed }

    /// Checks `key`, keeps it in the store and returns its licence; refuses with a reason.
    @discardableResult
    public static func install(_ key: String) throws -> ProLicence { try check.install(key) }

    /// Forgets the key. What the Pro features made stays.
    public static func remove() { check.remove() }

    /// The feature's name as the window shows it.
    public static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .supplyHistoryExport: "Supply history export"
        case .batchPrintAutomation: "Batch print automation"
        case .fleetExport: "Fleet export and command line"
        case .scannerSharing: "Scanner sharing"
        case .snmpV3: "SNMPv3"
        }
    }

    /// What the feature does, for a person who hasn't unlocked it.
    public static func describe(_ feature: ProFeature) -> String {
        switch feature {
        case .supplyHistoryExport: "Export one CSV of every printer's ink and toner levels over time, with the pages each cartridge printed."
        case .batchPrintAutomation: "Save a batch-print list, print a folder as files land in it, run a list from the command line, and keep the results as CSV."
        case .fleetExport: "Export the fleet page as CSV or JSON, read every printer from a script with status --all, and fix every queue at once."
        case .scannerSharing: "Share a USB or driver-only scanner on the network, so phones, Macs and PCs scan from it."
        case .snmpV3: "Read printers whose SNMP needs a user name and keys (SNMPv3) instead of a community."
        }
    }

    /// What a person is told when a feature isn't unlocked.
    public static func locked(_ feature: ProFeature) -> String {
        switch feature {
        case .supplyHistoryExport: "Exporting the supply history is part of Inkvolt Pro."
        case .batchPrintAutomation: "Batch print lists, folders and the command line are part of Inkvolt Pro."
        case .fleetExport: "Fleet export, status --all and Fix all are part of Inkvolt Pro."
        case .scannerSharing: "Scanner sharing is part of Inkvolt Pro."
        case .snmpV3: "SNMPv3 is part of Inkvolt Pro."
        }
    }

    /// Where a key is entered (after `locked` on the command line). Mac difference (PLAN.md P12 1.6): Inkvolt Print for Mac is
    /// the App Store's, so no refusal names a price or a shop (guidelines 3.1.1(a), 3.1.3(b)), as the Pro window names none.
    public static var howToGet: String {
        "Help › Inkvolt Pro… in Inkvolt Print enters an Inkvolt Pro key, and a key entered in Inkvolt PDF counts here too."
    }
}
