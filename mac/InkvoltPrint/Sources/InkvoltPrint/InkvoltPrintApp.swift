import AppKit
import PrintCore
import SwiftUI
import UserNotifications

@main
struct InkvoltPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window(model.isDemo ? "Inkvolt Print — Demo" : "Inkvolt Print", id: MainWindow.id) {
            MainWindow().environment(model)
        }
        .defaultSize(width: 920, height: 620)

        MenuBarExtra {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
    }
}

/// Starts the app's work at launch, whether or not a window ever shows (a locked screen shows none), keeps it running in
/// the menu bar when the window closes, and opens the printer an alert was about.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Report.runIfAsked(AppModel.shared)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let printer = response.notification.request.content.userInfo[Notifier.printerKey] as? String
        await MainActor.run {
            let model = AppModel.shared
            if let printer, model.printers.contains(where: { $0.id == printer }) { model.selectedID = printer }
            MainWindow.bringForward()
        }
    }
}
