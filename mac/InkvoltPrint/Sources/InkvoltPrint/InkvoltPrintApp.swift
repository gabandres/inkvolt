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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Inkvolt Print") { About.show() }
            }
        }

        // "Try the Demo" (the app's own window is the demo when it was started with --demo).
        Window("Inkvolt Print — Demo", id: MainWindow.demoID) {
            MainWindow().environment(AppModel.demo)
        }
        .defaultSize(width: 920, height: 620)
        .defaultLaunchBehavior(.suppressed)

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
            #if DEBUG
            Snapshot.runIfAsked(AppModel.shared)
            #endif
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

/// The standard About panel (it shows the app icon, name, version and copyright), with what the app is and where its
/// source is, as the Windows app's About dialog says.
@MainActor
enum About {
    static func show() {
        let text = """
            Printer status, ink and toner for your network printers. No account, no cloud, no telemetry.

            Free and open source (MIT License): github.com/gabandres/inkvolt

            Inkvolt Print is an independent project, not affiliated with or endorsed by HP Inc. or any printer maker.
            """
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let range = text.range(of: "github.com/gabandres/inkvolt") {
            credits.addAttribute(.link, value: URL(string: "https://github.com/gabandres/inkvolt")!, range: NSRange(range, in: text))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
