import AppKit
import Sparkle

/// Updates through Sparkle 2: the standard updater, started at launch, with Check for Updates… in the app menu.
/// Info.plist holds the feed (SUFeedURL), the EdDSA public key (SUPublicEDKey) and SUEnableSystemProfiling = NO;
/// SUEnableAutomaticChecks is left out, so Sparkle asks on the second launch (automatic checks ticked) and keeps the
/// user's answer. No system profile is ever sent: the privacy rule.
///
/// The update self-test, for checking a build over SSH where nobody sees the screen:
///   open -n "Inkvolt PDF.app" --args --update-test /tmp/update.txt [--install]
/// checks the feed without any window and writes what Sparkle found to the report (version, length, URL). With
/// `--install` it lets Sparkle download, verify (EdDSA and Apple signature), extract and install the update at once, then
/// relaunch; that turns on automatic checks and downloads in the app's defaults, so a test restores them afterwards.
@MainActor
final class Updates {
    private let delegate: UpdaterDelegate
    let controller: SPUStandardUpdaterController

    init() {
        let args = CommandLine.arguments
        let report = args.firstIndex(of: "--update-test").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        delegate = UpdaterDelegate(report: report, install: args.contains("--install"))
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    var isTesting: Bool { delegate.report != nil }

    /// Runs the update self-test when the app was launched with `--update-test`.
    func startTestIfAsked() {
        guard isTesting else { return }
        let updater = controller.updater
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        delegate.write("# Inkvolt PDF update self-test, \(Date())")
        delegate.write("RUNNING version=\(version) feed=\(updater.feedURL?.absoluteString ?? "none") profile=\(updater.sendsSystemProfile)")
        if delegate.install {
            // Sparkle downloads by itself only with automatic checks on too.
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        } else {
            updater.checkForUpdateInformation()
        }
        // A feed that never answers: say so rather than hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            MainActor.assumeIsolated {
                self.delegate.write("TIMEOUT")
                NSApp.terminate(nil)
            }
        }
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}

/// Keeps the system profile empty and, in the self-test, reports each step of Sparkle's update cycle.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let report: String?
    let install: Bool

    init(report: String?, install: Bool) {
        self.report = report
        self.install = install
    }

    func write(_ text: String) {
        guard let report, let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: report) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: report, contents: data)
        }
    }

    private func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] { [] }

    /// The self-test shows no window, the permission prompt included.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { report == nil }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let url = item.fileURL?.absoluteString ?? "none"
        write("FOUND version=\(item.versionString) display=\(item.displayVersionString) length=\(item.contentLength) url=\(url)")
        if !install { finish() }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        write("NOT FOUND \(describe(error))")
        finish()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { write("DOWNLOADED \(item.versionString)") }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        write("DOWNLOAD FAILED \(describe(error))")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { write("EXTRACTED \(item.versionString)") }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { write("INSTALLING \(item.versionString)") }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard report != nil, install else { return false }
        write("READY \(item.versionString): installing now")
        immediateInstallHandler()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { write("RELAUNCHING") }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        write("ABORTED \(describe(error))")
        finish()
    }

    private func finish() {
        guard report != nil else { return }
        write("DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}
