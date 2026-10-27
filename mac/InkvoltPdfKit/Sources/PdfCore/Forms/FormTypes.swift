import CryptoKit
import Foundation

public enum FormFieldKind: Sendable { case text, checkBox, radio, choice, pushButton, signature }

/// Which actions a form widget carries (its /A and the /AA entries of the widget and its field).
public struct FormTriggers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Mouse down (/AA /D).
    public static let down = FormTriggers(rawValue: 1)
    /// Mouse up or activation (/AA /U, /A).
    public static let up = FormTriggers(rawValue: 2)
    /// The pointer enters the widget (/AA /E).
    public static let enter = FormTriggers(rawValue: 4)
    /// The pointer leaves the widget (/AA /X).
    public static let exit = FormTriggers(rawValue: 8)
    /// The field gets the input focus (/AA /Fo).
    public static let focus = FormTriggers(rawValue: 16)
    /// The field loses the input focus (/AA /Bl).
    public static let blur = FormTriggers(rawValue: 32)
    /// A keystroke script checks typing (/AA /K, JavaScript).
    public static let keystroke = FormTriggers(rawValue: 64)
}

/// The user event that runs a widget's actions.
public enum FormTrigger: Sendable {
    case down, up
    /// Down then up at once (keyboard activation, taps).
    case click
    case enter, exit, focus, blur
}

/// One clickable widget of a form field, positioned in page space (points, top-left origin, rotation applied).
/// `options`: choice fields' export values (what goes into the value); `optionLabels` their display text when it
/// differs. `tabOrder`: the widget's position in fill order (0-based, across the document); `FormEditor.read` sorts by
/// it. `multiSelect`: a list box whose value is the selected export values joined by "\n". `noToggleToOff`: a radio
/// group that can't go back to "nothing selected". `displayValue`: the value as the field's format script shows it
/// ("$1,234.50"), nil without one. `calculated`: computed from other fields. `signed`: a signature field whose /V holds
/// a signature. `annotIndex`: the widget's position in its page's /Annots (for `FormEditor.runAction`).
public struct FormWidget: Equatable, Sendable {
    public var fieldName: String
    public var kind: FormFieldKind
    public var pageIndex: Int
    public var rect: RectD
    public var onState: String?
    public var multiline: Bool
    public var readOnly: Bool
    public var editable: Bool
    public var maxLength: Int
    public var options: [String]
    public var value: String
    public var tabOrder: Int
    public var optionLabels: [String]?
    public var multiSelect = false
    public var noToggleToOff = false
    public var password = false
    public var displayValue: String?
    public var calculated = false
    public var signed = false
    public var triggers: FormTriggers = []
    public var annotIndex = -1
}

/// A value a field's keystroke or validate script refused, and the message it gave (or a generic one).
public struct FieldRejection: Equatable, Sendable {
    public var fieldName: String
    public var message: String
}

/// What `FormEditor.fill` did: the new document, the values the form's scripts refused (those fields kept their old
/// value), app.alert messages raised by the scripts, script log lines (console.println, errors), and the field a script
/// asked to move the focus to (field.setFocus).
public struct FormFillResult: Sendable {
    public var data: [UInt8]
    public var rejected: [FieldRejection]
    public var alerts: [String]
    public var log: [String]
    public var focusField: String?
}

public enum SubmitFormat: String, Sendable { case html, fdf, xfdf, pdf }

/// Form data a SubmitForm action (or this.submitForm) wants to send. `method`: "POST" or "GET" (for GET the data is in
/// `url` and `body` is empty). `fieldCount`, `fields`: the fields whose values the data carries.
public struct FormSubmission: Equatable, Sendable {
    public var url: String
    public var method: String
    public var contentType: String
    public var body: [UInt8]
    public var format: SubmitFormat
    public var fieldCount: Int
    public var fields: [String]?

    public init(url: String, method: String, contentType: String, body: [UInt8], format: SubmitFormat, fieldCount: Int, fields: [String]? = nil) {
        self.url = url
        self.method = method
        self.contentType = contentType
        self.body = body
        self.format = format
        self.fieldCount = fieldCount
        self.fields = fields
    }
}

/// An email the form wants to send (mailDoc, mailForm, app.mailMsg, or a mailto: submit). `attachment`: the document or
/// its form data, nil for a plain message; `fields`: for form data, the fields it carries.
public struct FormMail: Equatable, Sendable {
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var message: String
    public var attachment: [UInt8]?
    public var attachmentName: String?
    public var fields: [String]?

    public init(to: String, cc: String, bcc: String, subject: String, message: String, attachment: [UInt8]?, attachmentName: String?,
                fields: [String]? = nil) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.message = message
        self.attachment = attachment
        self.attachmentName = attachmentName
        self.fields = fields
    }
}

/// What an "Always allow" answer covers: the destination together with what goes there, so allowing one kind of data
/// (or one set of fields) to an address doesn't silently allow another: the whole PDF, form data with another field
/// list, or an email to other recipients each ask again.
public enum FormConsent {
    /// The key for a submission: method, address (without the query), format and the fields it sends.
    public static func submitKey(_ s: FormSubmission) -> String {
        var address = s.url
        if var c = URLComponents(string: s.url), c.scheme != nil, c.host != nil {
            c.query = nil
            c.fragment = nil
            address = c.string ?? s.url
        }
        let payload = s.format == .pdf ? "pdf" : "\(s.format.rawValue):\(fieldsHash(s.fields))"
        return "submit\n\(s.method) \(address)\n\(payload)"
    }

    /// The key for an email: the recipients and what is attached (nothing, the whole PDF, or form data and its fields).
    public static func mailKey(_ m: FormMail) -> String {
        func list(_ s: String) -> String {
            s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }.sorted().joined(separator: ",")
        }
        let payload: String
        if m.attachment == nil {
            payload = "message"
        } else if let name = m.attachmentName, name.lowercased().hasSuffix(".pdf") {
            payload = "pdf"
        } else {
            let ext = (m.attachmentName ?? "").split(separator: ".", omittingEmptySubsequences: false).dropFirst().last.map { "." + $0.lowercased() } ?? ""
            payload = "data\(ext):\(fieldsHash(m.fields))"
        }
        return "mail\nto=\(list(m.to));cc=\(list(m.cc));bcc=\(list(m.bcc))\n\(payload)"
    }

    private static func fieldsHash(_ fields: [String]?) -> String {
        guard let fields else { return "?" }
        let joined = Array(Set(fields)).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return String(digest.map { String(format: "%02X", $0) }.joined().prefix(16))
    }
}

/// app.alert: `icon` 0 error, 1 warning, 2 question, 3 status; `buttons` 0 OK, 1 OK/Cancel, 2 Yes/No, 3 Yes/No/Cancel.
public struct FormAlert: Equatable, Sendable {
    public var message: String
    public var title: String
    public var icon: Int
    public var buttons: Int

    public init(_ message: String, _ title: String, _ icon: Int, _ buttons: Int) {
        self.message = message
        self.title = title
        self.icon = icon
        self.buttons = buttons
    }
}

/// app.response: a question with a text box.
public struct FormPrompt: Equatable, Sendable {
    public var question: String
    public var title: String
    public var defaultText: String
    public var password: Bool
    public var label: String
}

/// What a form's actions may do outside the document. The app implements it: every outward step (open a URL, send data,
/// open or launch a file, write an email, import data) must ask the user first, naming the destination. Calls come from
/// the thread the form runs on; modal ones block the script (its time limit is paused meanwhile). An outward step that
/// reports it didn't happen (refused, or the user said no) stops the script that asked for it.
public protocol FormActionHost: AnyObject {
    /// The page shown (0-based).
    var currentPage: Int { get }

    func goToPage(_ page: Int, _ y: Double?)

    /// app.launchURL and URI actions; false when nothing was opened (refused, or the user declined).
    func openUrl(_ url: String) -> Bool

    /// Asks, then sends (http and https only, in the background); false when nothing is sent (refused, or the user
    /// declined).
    func submit(_ submission: FormSubmission) -> Bool

    /// Asks, then starts the email; false when it didn't (refused, or the user declined).
    func mail(_ mail: FormMail) -> Bool

    /// Opens the print dialog (pages 0-based, nil = the user picks).
    func print(_ fromPage: Int?, _ toPage: Int?)

    /// Returns 1 OK, 2 Cancel, 3 No, 4 Yes.
    func alert(_ alert: FormAlert) -> Int

    /// The text entered, or nil when cancelled.
    func response(_ prompt: FormPrompt) -> String?

    /// A GoToR action: ask, then open that PDF (relative paths are from this document's folder); false when not opened.
    func openRemote(_ path: String, _ page: Int) -> Bool

    /// A Launch action: never runs programs; asks, then opens a document file; false when not opened.
    func launch(_ path: String) -> Bool

    /// Named actions the app carries out: Print, GoBack, GoForward, Find, FullScreen.
    func named(_ name: String)

    /// Asks, then lets the user pick an FDF/XFDF file (suggested by the form); its bytes, or nil.
    func importData(_ suggestedPath: String?) -> [UInt8]?

    /// app.beep: 0 error, 1 warning, 2 question, 3 status, 4 default.
    func beep(_ type: Int)
}

/// What running a widget's actions did: the new document when fields changed (nil = unchanged), an undo label, alert
/// texts no dialog showed, log lines, the field a script asked to focus, and whether a change was refused because the
/// document's permissions password is needed.
public struct FormActionResult: Sendable {
    public var data: [UInt8]?
    public var label: String
    public var alerts: [String]
    public var log: [String]
    public var focusField: String?
    public var needsPermission: Bool
}

/// A keystroke script's verdict on one edit: whether it is accepted, and the text that replaces the selection
/// [selStart, selEnd) (scripts may rewrite what was typed, e.g. to insert a phone number's separators), plus any alert
/// texts. Positions count UTF-16 units, as JavaScript does.
public struct KeystrokeResult: Equatable, Sendable {
    public var accepted: Bool
    public var change: String
    public var selStart: Int
    public var selEnd: Int
    public var alerts: [String]
}
