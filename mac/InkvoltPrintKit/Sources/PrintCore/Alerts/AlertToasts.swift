import Foundation

/// Inkvolt Print's printer alerts as macOS notifications, as the Windows app's toasts (`AlertToasts`): one notification per
/// printer, with Open Printer and Pause Alerts, its title and text, and the identifier that lets a newer alert for the same
/// printer replace the one still showing (Windows' tag). A job's notification is `JobNotices`'. The buttons themselves are the
/// app's notification category (macOS's actions, not Windows' XML and arguments).
public enum AlertToasts {
    /// Pause Alerts from a notification: an hour.
    public static let pauseFor: TimeInterval = 60 * 60

    /// The printers' problems as notifications, in the order the printers first appear (a printer's problems together; its
    /// uuid's case doesn't matter). Job notices are left out: `JobNotices.split` makes theirs.
    public static func perPrinter(_ notices: [AlertNotice]) -> [[AlertNotice]] {
        var order: [String] = []
        var byPrinter: [String: [AlertNotice]] = [:]
        for n in notices where n.jobKey == nil {
            let key = n.uuid.lowercased()
            if byPrinter[key] == nil { order.append(key) }
            byPrinter[key, default: []].append(n)
        }
        return order.compactMap { byPrinter[$0] }
    }

    /// One notification's title and text: one alert as it is; several, a count and a line per alert.
    public static func text(_ notices: [AlertNotice]) -> (title: String, text: String) {
        guard notices.count > 1 else { return (notices.first?.title ?? "", notices.first?.body ?? "") }
        return (loc("{0} alerts", notices.count), notices.map(\.title).joined(separator: "\n"))
    }

    /// The notification's identifier for a printer: a newer alert for the same printer replaces the one showing. Short,
    /// hex, the same whatever the uuid's case (Windows' 16-character tag).
    public static func tag(_ uuid: String) -> String {
        let digest = Digest.sha256(Array(uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
