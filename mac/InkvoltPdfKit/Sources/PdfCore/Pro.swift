import Foundation
import PrintCore

/// The features Inkvolt Pro unlocks (pdf/ROADMAP.md, "Free and Pro").
public enum ProFeature: CaseIterable, Sendable {
    /// Saving, importing and exporting batch presets (Batch itself stays free).
    case batchPresets
    /// Watched folders, in the app and from the command line.
    case watchedFolders
    /// `--batch` and `--watch` on the command line.
    case commandLine
    /// Make Accessible: tagging a PDF from its layout, in the app and in Batch (viewing tags and alt text stays free).
    case autoTagging
    /// The Reading Order pane's fixes: moving pieces and applying the edited tags.
    case readingOrder
    /// Save as PDF/A-2a (tagged, PDF/UA identifier kept), in the app and in Batch.
    case accessibleOutput
}

/// The Pro entitlement check for Inkvolt PDF (the Windows Core's `Pro`): the one place that decides whether a Pro feature
/// runs. Every Pro feature asks `allows` and nowhere else. Behind it is the suite's `ProCheck` (PrintCore) for the "pdf"
/// product: the key format, its verification (the app sets PrintMac's CryptoKit verifier), the gate (`ProCheck.enforced`,
/// shared with Inkvolt Print) and the store, so one key listing both products licenses both apps, from whichever it was
/// entered in (the app's store is the file both share, `ProKeyFile`). No server is asked, nothing is sent, the key works
/// offline and survives reinstalling. Removing it never takes away a result already made: presets saved, files a watched
/// folder or the command line produced and their logs stay where they are.
public enum Pro {
    /// The one switch, shared with Inkvolt Print. While it is false, everything is free: `allows` says yes to everyone (a
    /// key is still verified and shown in Help › Inkvolt Pro, and the purchase is a way to support the project or to get a
    /// licence a business can invoice). It flips to true, in a release noted in WHATS-NEW, once Inkvolt PDF has a few
    /// thousand installs or about 50 Store ratings; from then on the Pro features ask for a key. Tests set it either way.
    public static var enforced: Bool {
        get { ProCheck.enforced }
        set { ProCheck.enforced = newValue }
    }

    public static let product = ProKeys.productPdf
    public static let priceText = ProCheck.priceText
    public static let buyUrl = ProCheck.buyUrl

    private static let check = ProCheck(product)

    /// Where the key is kept. Setting it forgets what was read from the previous store.
    public static var store: ProStore {
        get { check.store }
        set { check.store = newValue }
    }

    /// What checks a key's signature: PrintMac's `CryptoKitProVerifier` in the app and the tests. None set: no key counts.
    public static var verifier: ProSignatureVerifier {
        get { check.verifier }
        set { check.verifier = newValue }
    }

    /// The installed licence, or nil (none, or the stored key no longer checks out: `problem`).
    public static var licence: ProLicence? { check.licence }

    /// Why the stored key doesn't count, when there is one and it doesn't; nil otherwise.
    public static var problem: String? { check.problem }

    /// True when `feature` may run: always while `enforced` is off, else with a licence.
    public static func allows(_ feature: ProFeature) -> Bool { check.allowed }

    /// Checks `key`, keeps it in the `store` and returns its licence; refuses with a reason.
    @discardableResult
    public static func install(_ key: String) throws -> ProLicence { try check.install(key) }

    /// Forgets the key. What the Pro features made stays.
    public static func remove() { check.remove() }

    /// The feature's name as the window shows it.
    public static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets: loc("Batch presets")
        case .watchedFolders: loc("Watched folders")
        case .commandLine: loc("Command line")
        case .autoTagging: loc("Make Accessible")
        case .readingOrder: loc("Reading order")
        case .accessibleOutput: loc("Accessible PDF/A-2a")
        }
    }

    /// What the feature does, for a person who hasn't unlocked it.
    public static func describe(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets:
            loc("Save the list of Batch actions with their settings under a name and pick it next time; export a preset to share it or for the command line, import one from someone else.")
        case .watchedFolders:
            loc("Drop PDFs or images into a folder and Inkvolt PDF runs a preset on each one once it has finished copying, moves the original to \"done\" or \"failed\" and logs a line for it.")
        case .commandLine:
            loc("inkvoltpdf --batch runs a preset on files or folders without a window; inkvoltpdf --watch watches a folder from a terminal or a scheduled task.")
        case .autoTagging:
            loc("Tag a PDF for screen readers on this Mac, nothing sent anywhere: headings, paragraphs, lists, tables and pictures read from the pages, running headers and page numbers set aside, the title and language set; in Batch over many files too.")
        case .readingOrder:
            loc("See the order a screen reader follows as numbered boxes on the page, move pieces up, down or to another page, and write the tags again.")
        case .accessibleOutput:
            loc("Save a tagged PDF as PDF/A-2a, the archival format that keeps the tags and says it is accessible (PDF/UA); in Batch too.")
        }
    }

    /// What a person is told when a feature isn't unlocked.
    public static func locked(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets: loc("Saved batch presets are part of Inkvolt Pro.")
        case .watchedFolders: loc("Watched folders are part of Inkvolt Pro.")
        case .commandLine: loc("The command line is part of Inkvolt Pro.")
        case .autoTagging: loc("Make Accessible is part of Inkvolt Pro.")
        case .readingOrder: loc("Fixing the reading order is part of Inkvolt Pro.")
        case .accessibleOutput: loc("Saving accessible PDF/A-2a files is part of Inkvolt Pro.")
        }
    }

    /// Where to get a key and where to enter it (after `locked` on the command line).
    public static var howToGet: String {
        loc("Inkvolt Pro is a one-time purchase ({0}) at {1}; Help › Inkvolt Pro… in Inkvolt PDF enters the key.", priceText, buyUrl)
    }
}
