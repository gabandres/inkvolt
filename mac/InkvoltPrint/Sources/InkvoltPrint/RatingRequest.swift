import AppKit
import PrintCore
import StoreKit

/// The one App Store rating request (the Windows app's `RatingRequest`, there the Microsoft Store's): each saved scan and
/// each print sent counts, and once `RatingProgress` says so, macOS's own rating prompt (`AppStore.requestReview`) is asked
/// for a moment later over the main window (a job done while the window is closed counts but doesn't ask). Never again
/// after that, whatever the person chose or whether macOS showed it. Only in a copy from the App Store or TestFlight (one
/// with a receipt), never in demo mode.
@MainActor
enum RatingRequest {
    static let delay: Duration = .seconds(3)

    /// A copy the App Store or TestFlight installed: it has a receipt in its bundle (a development build has none). Read
    /// where the App Store puts it, not through `AppTransaction`, which can ask a development copy to sign in to the store.
    static var isStoreCopy: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }

    /// Counts a success in `store` and says whether to ask now (then recorded as asked).
    static func note(_ store: StateStore, now: Date, windowShows: Bool) -> Bool {
        store.change { s in
            let progress = (s.rating ?? RatingProgress()).record(now)
            let ask = windowShows && progress.shouldAsk(now)
            s.rating = ask ? progress.markAsked(now) : progress
            return ask
        }
    }

    /// Call after the app did its job.
    static func noteSuccess(_ app: AppModel) {
        guard isStoreCopy, !app.isDemo else { return }
        let window = mainWindow
        guard note(app.store, now: Date(), windowShows: window != nil), let controller = window?.contentViewController else { return }
        Task {
            try? await Task.sleep(for: delay) // after the "Saved" or "Sent" message, not over it
            AppStore.requestReview(in: controller)
        }
    }

    /// The main window when it shows (not the demo's, not a panel).
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.isVisible && !$0.isMiniaturized }
    }
}

extension AppModel {
    /// A scan saved or a print sent (`RatingRequest`).
    func noteSuccess() {
        guard self === AppModel.shared else { return }
        RatingRequest.noteSuccess(self)
    }
}
