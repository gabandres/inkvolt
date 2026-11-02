import Foundation

/// What leaves the Mac in a report, an export or a recording, made safe to share (the Windows app's `Diagnostics`; its
/// `Scrub` for now: the report itself, the log tail and the issue address come with Report a Problem).
public enum Diagnostics {
    /// The user's and the Mac's names, masked wherever they turn up.
    public struct Identity: Equatable, Sendable {
        public var userName: String?
        public var machineName: String?

        public init(_ userName: String?, _ machineName: String?) {
            self.userName = userName
            self.machineName = machineName
        }

        public static var current: Identity { Identity(NSUserName(), ProcessInfo.processInfo.hostName) }
    }

    /// Masks what identifies a person, a printer or a network in a line of text: IP and MAC addresses, host names (in URLs,
    /// .local and other dotted names, host:port, HP's NPI/HP+hex names), UUIDs, serial numbers and serial-like IDs, long hex
    /// strings (certificate pins), e-mail addresses, file paths (keeping the extension) and the user's and the computer's
    /// names. Leaves times, versions, models, firmware revisions, type names, file names and error codes.
    ///
    /// The patterns are Windows', in ICU's syntax: a look-behind can't repeat without a bound there, so `[\s=:]*` before a
    /// version and the spaces around "Firmware" take at most a few characters (more than any line writes).
    public static func scrub(_ text: String, _ who: Identity) -> String {
        var text = text
        if let pc = who.machineName, pc.count >= 3 { text = replace(text, word(pc), "[pc]") }
        if let user = who.userName, user.count >= 3 { text = replace(text, word(user), "[user]") }
        text = replace(text, email, "[email]")
        text = replacePaths(text)
        text = replace(text, urlHost, "$1[host]")
        text = replace(text, localHost, "[host].local")
        text = replace(text, uuid, "[uuid]")
        text = replace(text, mac, "[mac]")
        text = replace(text, mappedIpv4, "[ip]")
        text = replace(text, ipv6, "[ip]")
        text = replace(text, ipv4, "[ip]")
        text = replace(text, dottedHost, "[host]")
        text = replace(text, hostPort, "[host]")
        text = replace(text, hpHostName, "[host]")
        text = replace(text, serial, "$1$2[serial]")
        text = replace(text, longHex, "[hex]")
        text = replace(text, serialLike, "[id]")
        text = replace(text, bracketId, "[id]")
        return text
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are fixed and valid (the names are escaped).
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func word(_ name: String) -> NSRegularExpression {
        regex(#"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#, .caseInsensitive)
    }

    private static func replace(_ text: String, _ pattern: NSRegularExpression, _ template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// A drive or UNC path, "[path]" and its extension.
    private static func replacePaths(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        for match in windowsPath.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: match.range.location - at))
            let found = ns.substring(with: match.range)
            let ext = extensionPattern.firstMatch(in: found, range: NSRange(location: 0, length: (found as NSString).length))
                .map { (found as NSString).substring(with: $0.range) } ?? ""
            out += "[path]" + ext
            at = match.range.location + match.range.length
        }
        return out + ns.substring(from: at)
    }

    private static let email = regex(#"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#)

    // A drive or UNC path: folders may hold spaces (they end at a backslash). The last part runs, spaces included, to the
    // first extension that ends a word ("John Smith tax return.pdf"); one without an extension ends at a space, a closing
    // bracket, a comma or a semicolon (the text around it).
    private static let windowsPath = regex(#"(?:\b[A-Za-z]:|\\\\[^\\\s/:*?"<>|]+)\\(?:[^\\/:*?"<>|\r\n]+\\)*(?:[^\\/:*?"<>|\r\n]*?\.[A-Za-z0-9]{1,5}(?![\w.])|[^\\/:*?"<>|\s),;\]]*)"#)

    private static let extensionPattern = regex(#"\.[A-Za-z0-9]{1,5}$"#)

    private static let urlHost = regex(#"\b((?:https?|ipps?|wss?|socket)://)(?:\[[0-9A-Fa-f:.%\w]+\]|[^/\s:?#\[\]]+)"#)

    private static let localHost = regex(#"\b[\w-]+(?:\.[\w-]+)*\.local\b"#)

    // A dotted name ending in a lower-case label (lan, home, corp, com…): officeprinter.lan, OfficePrinter.home.arpa. Not type
    // names (their labels are capitalized: System.Text.Json), versions (the last label is a number) nor file names (the last
    // label is a known extension: settings.json, MainWindow.xaml.cs).
    private static let dottedHost = regex(#"(?<![\w.\-\[@/\\])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?!(?:pdf|jpe?g|png|tiff?|heic|heif|bmp|gif|webp|txt|log|json|xml|xaml|cs|dll|exe|msix|msixbundle|appx|msi|docx?|xlsx?|pptx?|rtf|odt|ods|odp|html?|csv|ini|config|md|zip|svg|ps|pcl|pwg|urf|xps|oxps|ico|tmp|dat|db|cfg|ttf|otf|lnk|bat|cmd|pri|winmd|js|css|eml|msg|vcf|pfx|cer)(?![\w-]))[a-z]{2,24}(?![\w-]|\.\w)"#)

    // A name before ":port" (port kept), any case, starting with a letter: "(officeprinter:9100)", "OFFICE.CORP:443". Not
    // times (12:34:56 starts with a digit; T10:00:00 follows a digit), "cs:line 12" (no number after the colon) or "0x8007".
    private static let hostPort = regex(#"(?<![\w.\-\[:/@])[A-Za-z][\w-]*(?:\.[\w-]+)*(?=:\d{1,5}(?!\w|:\d|\.\d))"#)

    // HP's default host names, NPI or HP and the MAC address's last six hex digits, in any case.
    private static let hpHostName = regex(#"\b(?:NPI|HP)[0-9A-F]{6}\b"#, .caseInsensitive)

    private static let uuid = regex(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)

    private static let mac = regex(#"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b"#)

    // An IPv6 address ending in an IPv4 one (::ffff:192.168.1.5), whole, before either pattern takes a part.
    private static let mappedIpv4 = regex(#"(?<![\w:.])(?=[0-9A-Fa-f:]*::)[0-9A-Fa-f:]*:(?:\d{1,3}\.){3}\d{1,3}(?!\d|\.\d)"#)

    // Has "::" or at least five groups, so times (12:34:56) are left alone.
    private static let ipv6 = regex(#"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){5})[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%\w+)?(?![\w:])"#)

    // A dotted quad is a version, kept, after "v", "ver" or "version" (Version=10.0.12.0) or when every part is one digit
    // (1.0.7.0); every other one is masked.
    private static let ipv4 = regex(#"(?<![\d.])(?<!\b(?i:v|ver|version)[\s=:]{0,8})(?!\d\.\d\.\d\.\d(?!\d))(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d|\.\d)"#)

    // Whole words only: not the "Serial" in System.Text.Json.Serialization.
    private static let serial = regex(#"\b(serial(?:\s*number)?|s/n)\b(\s*[:=#]?\s*)[A-Za-z0-9-]{4,}"#, .caseInsensitive)

    private static let longHex = regex(#"\b[0-9A-Fa-f]{16,}\b"#)

    // Capital letters and digits, both, eight or more: serial numbers and the IDs printers name themselves with. Kept: model
    // numbers after a maker's series prefix (the L8900CDW of MFC-L8900CDW) and the revision after "Firmware".
    private static let serialLike = regex(#"(?<!\b(?i:firmware(?:\s{1,4}(?:revision|version))?)\s{0,4}[:=]?\s{0,4})\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])(?!(?<=-)[A-Z]{1,3}\d{3,5}[A-Z]{0,4}\b)[A-Z0-9]{8,}\b"#)

    // HP's network names end in the last six digits of the printer's MAC address: "HP OfficeJet Pro 9010 series [A1B2C3]".
    private static let bracketId = regex(#"\[[0-9A-Fa-f]{6}\]"#)
}
