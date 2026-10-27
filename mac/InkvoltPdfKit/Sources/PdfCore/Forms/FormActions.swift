import Foundation

extension FormEditor {
    /// Runs the actions a user event triggers on a widget (identified by field name, page and its index in the page's
    /// /Annots): /AA /D, /U (+ /A), /E, /X, /Fo, /Bl, with their /Next chains. JavaScript runs in the sandbox;
    /// ResetForm, Hide and ImportData change the form; SubmitForm, URI, Launch, GoToR, Named and mail go through `host`.
    /// A document whose permissions password isn't known runs read-only: navigation and outward actions still work,
    /// field changes are dropped (`needsPermission`).
    public static func runAction(_ data: [UInt8], _ password: String?, _ fieldName: String, _ pageIndex: Int, _ annotIndex: Int,
                                 _ trigger: FormTrigger, _ host: FormActionHost) throws -> FormActionResult {
        let doc: MuDoc
        var readOnly = false
        do {
            doc = try PdfEdit.open(data, password, failure: "This PDF's form can't be read")
        } catch is OwnerPasswordRequired {
            doc = try PdfEdit.openToRead(data, password)
            readOnly = true
        }
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)
        guard let field = fields.first(where: { $0.name == fieldName }) else {
            return FormActionResult(data: nil, label: "", alerts: [], log: ["Form action: no field \(fieldName)"], focusField: nil, needsPermission: false)
        }
        var widget = field.widgets.first ?? field.dict
        if pageIndex >= 0, pageIndex < (try doc.pageCount()), let annots = doc.page(pageIndex).array("Annots"), annotIndex >= 0,
           annotIndex < annots.count, let a = annots[annotIndex], a.isDict, field.widgets.contains(where: { $0.identity == a.identity }) {
            widget = a
        }

        // Hovering isn't a decision: pointer enter and exit only run scripts and harmless actions (no dialogs, nothing
        // outward).
        let runner = FormActionRunner(doc, acro, fields, host, data, password: password, xmp: Xmp.read(doc), readOnly: readOnly,
                                      hover: trigger == .enter || trigger == .exit)
        func additional(_ key: String) -> PObj? { widget.dict("AA")?[key] ?? field.dict.dict("AA")?[key] }
        func step(_ key: String, _ name: String) {
            runner.execute(additional(key), field, name)
            if key == "U" { runner.execute(widget["A"], field, name) }
        }
        switch trigger {
        case .down: step("D", "Mouse Down")
        case .up: step("U", "Mouse Up")
        case .click:
            step("D", "Mouse Down")
            step("U", "Mouse Up")
        case .enter: step("E", "Mouse Enter")
        case .exit: step("X", "Mouse Exit")
        case .focus: step("Fo", "Focus")
        case .blur: step("Bl", "Blur")
        }
        return try runner.finish()
    }
}

enum FormActions {
    /// Which triggers a widget has actions for.
    static func triggersOf(_ f: FormField, _ widget: PObj) -> FormTriggers {
        var t: FormTriggers = []
        if let a = widget["A"], a.isDict || a.isArray { t.insert(.up) }
        for holder in [widget, f.dict] {
            guard let aa = holder.dict("AA") else { continue }
            for (key, bit) in [("D", FormTriggers.down), ("U", .up), ("E", .enter), ("X", .exit), ("Fo", .focus), ("Bl", .blur)] where aa.has(key) {
                t.insert(bit)
            }
            if aa.dict("K")?.name("S") == "JavaScript" { t.insert(.keystroke) }
        }
        return t
    }

    /// Writes a choice field's options: plain strings, or [export display] pairs where they differ.
    static func writeOptions(_ f: FormField, _ exports: [String], _ labels: [String]) {
        let doc = f.dict.doc
        let opt = doc.array(exports.indices.map { i in
            exports[i] == labels[i] ? doc.text(exports[i]) : doc.array([doc.text(exports[i]), doc.text(labels[i])])
        })
        // The options may be inherited: written where they live, so the field's kids keep sharing them.
        var holder = f.dict
        var d: PObj? = f.dict
        var seen = Set<UInt>()
        while let cur = d, seen.count < 64, seen.insert(cur.identity).inserted {
            if cur.has("Opt") {
                holder = cur
                break
            }
            d = cur.dict("Parent")
        }
        holder.set("Opt", opt)
        // A selection index past the new list would point at the wrong option.
        if let sel = FormEditor.inherited(f.dict, "I"), sel.isArray, sel.elements.contains(where: { ($0.int ?? -1) >= exports.count }) {
            f.dict.remove("I")
        }
    }
}

/// Outward steps per host in the last minute (the Windows app's ConditionalWeakTable of hosts).
private final class OutwardLog: @unchecked Sendable {
    private struct Entry {
        weak var host: AnyObject?
        var times: [TimeInterval]
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Takes one step for `host` if fewer than `max` happened in the last minute.
    func take(_ host: AnyObject, max: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { $0.value.host != nil }
        let id = ObjectIdentifier(host)
        var entry = entries[id].flatMap { $0.host === host ? $0 : nil } ?? Entry(host: host, times: [])
        entry.times.removeAll { now - $0 > 60 }
        guard entry.times.count < max else {
            entries[id] = entry
            return false
        }
        entry.times.append(now)
        entries[id] = entry
        return true
    }
}

/// Carries out a run's actions on one open document (the Windows app's `FormActionRunner`): the JavaScript host,
/// ResetForm, SubmitForm, Hide, ImportData, navigation and the outward calls (through `host`). Fill uses one too, so
/// field scripts can reset or submit. Actions that need the finished document (submit as PDF, mailDoc) wait for
/// `runDeferred`.
final class FormActionRunner {
    private static let maxActions = 64, maxDepth = 32
    /// Outward steps (open a link, send, mail, open a file, import) one run may take: past it the run stops.
    static let maxOutwardPerRun = 3
    /// Outward steps one document (one host) may take per minute, across runs.
    static let maxOutwardPerMinute = 6
    private static let recentOutward = OutwardLog()

    private let doc: MuDoc
    private let acro: PObj?
    private let fields: [FormField]
    private let source: [UInt8]
    private let password: String?
    private let xmp: XMLDocument?
    private var deferred: [([UInt8]) -> Void] = []
    private var ran = Set<UInt>()
    private var alerts: [String] = []
    private var actions = 0, outward = 0

    let host: FormActionHost?
    private(set) var js: JsFormHost!
    let readOnly: Bool
    /// The run comes from the pointer entering or leaving a widget: scripts run without dialogs, and only harmless
    /// actions (show or hide fields, go to a page) are carried out; nothing outward, no printing.
    let hover: Bool
    /// Fields changed outside the script's own writes (reset, import, hide).
    private(set) var changed = false
    /// A change was dropped because the document is read-only here.
    private(set) var wantedChange = false
    var focusField: String?
    private(set) var label = "Form action"
    /// An outward step was declined, refused, or went over the caps: the running script is stopped and the rest of this
    /// run's actions are skipped.
    private(set) var stopped = false
    /// Messages for the user about this run (shown as toasts), e.g. that it was stopped.
    private(set) var notices: [String] = []

    init(_ doc: MuDoc, _ acro: PObj?, _ fields: [FormField], _ host: FormActionHost?, _ source: [UInt8], password: String?,
         xmp: XMLDocument?, readOnly: Bool = false, hover: Bool = false) {
        self.doc = doc
        self.acro = acro
        self.fields = fields
        self.host = host
        self.source = source
        self.password = password
        self.xmp = xmp
        self.readOnly = readOnly
        self.hover = hover
        js = JsFormHost(doc, fields, readOnly: readOnly, runner: self)
    }

    private func log(_ line: String) { js.log.append(line) }

    /// Runs an action (dictionary or array of them) and its /Next chain; each action runs once per run.
    func execute(_ item: PObj?, _ target: FormField, _ eventName: String, depth: Int = 0) {
        guard depth <= Self.maxDepth, !stopped, let item else { return }
        if item.isArray {
            for e in item.elements { execute(e, target, eventName, depth: depth + 1) }
            return
        }
        guard item.isDict, ran.insert(item.identity).inserted else { return }
        actions += 1
        if actions > Self.maxActions {
            if actions == Self.maxActions + 1 { log("Form actions: too many in one go; the rest were skipped") }
            return
        }
        perform(item, target, eventName)
        execute(item["Next"], target, eventName, depth: depth + 1)
    }

    private func perform(_ a: PObj, _ target: FormField, _ eventName: String) {
        let type = a.name("S") ?? ""
        if hover && !["JavaScript", "Hide", "GoTo", "Named"].contains(type) {
            log("Form action \(type) ignored (not run when the pointer only passes over a field)")
            return
        }
        switch type {
        case "JavaScript":
            if let script = FormEditor.scriptText(a["JS"]), !script.isEmpty,
               let r = js.run(eventName, target, script, FormEditor.exportValueOf(target)) {
                alerts += r.alerts
            }
        case "ResetForm":
            reset(fieldNames(a["Fields"]), exclude: (a.int("Flags") ?? 0) & 1 != 0)
        case "SubmitForm":
            let flags = a.int("Flags") ?? 0
            let format = flags & 256 != 0 ? "PDF" : flags & 32 != 0 ? "XFDF" : flags & 4 != 0 ? "HTML" : "FDF"
            _ = submit(fileSpec(a["F"]) ?? "", format, flags & 2 != 0, fieldNames(a["Fields"]), exclude: flags & 1 != 0, get: flags & 8 != 0,
                       charset: "")
        case "URI":
            if let uri = a.text("URI"), !uri.isEmpty { _ = openUrl(uri) }
        case "Launch":
            if let path = fileSpec(a["F"]) ?? fileSpec(a.dict("Win")?["F"]), !path.isEmpty, let host, takeOutward("open a file") {
                _ = went(host.launch(path))
            }
        case "GoTo":
            if let dest = DocumentFeatures.resolveDestination(doc, a["D"]) { host?.goToPage(dest.pageIndex, dest.y) }
        case "GoToR":
            guard let file = fileSpec(a["F"]), !file.isEmpty else { break }
            let d = a["D"]
            let page = d?.isArray == true ? d?[0]?.int ?? 0 : d?.int ?? 0
            if let host, takeOutward("open another PDF") { _ = went(host.openRemote(file, max(0, page))) }
        case "Named":
            named(a.name("N") ?? "")
        case "Hide":
            let h = a["H"]
            hide(a["T"], !(h?.kind == .bool && h?.bool == false))
        case "ImportData":
            _ = importData(fileSpec(a["F"]) ?? "")
        default:
            log("Form action \(type) isn't supported")
        }
    }

    // ---------------- Navigation and outward calls ----------------

    func goToPage(_ page: Int) {
        guard let host, let count = try? doc.pageCount(), count > 0 else { return }
        host.goToPage(min(max(page, 0), count - 1), nil)
    }

    private func named(_ name: String) {
        guard let host else { return }
        if hover && !["NextPage", "PrevPage", "FirstPage", "LastPage", "GoBack", "GoForward"].contains(name) {
            log("Named action \(name) ignored (not run when the pointer only passes over a field)")
            return
        }
        switch name {
        case "NextPage": goToPage(host.currentPage + 1)
        case "PrevPage": goToPage(host.currentPage - 1)
        case "FirstPage": goToPage(0)
        case "LastPage": goToPage(((try? doc.pageCount()) ?? 1) - 1)
        case "Print", "GoBack", "GoForward", "Find", "FullScreen": host.named(name)
        default: log("Named action \(name) isn't supported")
        }
    }

    /// Whether one more outward step may go ahead: not while hovering, not after the run was stopped, at most
    /// `maxOutwardPerRun` per run and `maxOutwardPerMinute` per document per minute (counted whether or not the user then
    /// agrees, so a script can't keep a consent dialog coming back). Going over a cap stops the run, with one notice.
    private func takeOutward(_ what: String) -> Bool {
        guard let host, !stopped else { return false }
        if hover {
            log("Form action: \(what) ignored (not run when the pointer only passes over a field)")
            return false
        }
        if outward < Self.maxOutwardPerRun && Self.recentOutward.take(host, max: Self.maxOutwardPerMinute) {
            outward += 1
            return true
        }
        log("Form action: \(what) stopped (too many outward actions)")
        if !stopped { notices.append("This form kept trying to open, send or email things, so Inkvolt PDF stopped its script.") }
        stopped = true
        return false
    }

    /// Notes the host's answer to an outward step: when it didn't happen, the run stops.
    private func went(_ done: Bool) -> Bool {
        if !done {
            stopped = true
            log("Form action: not allowed, so the rest of the form's actions were skipped")
        }
        return done
    }

    /// A relative address resolved against the document's /URI /Base.
    private func absolute(_ url: String) -> String {
        if URL(string: url)?.scheme != nil { return url }
        guard let base = doc.catalog.dict("URI")?.text("Base"), let b = URL(string: base), b.scheme != nil,
              let full = URL(string: url, relativeTo: b) else { return url }
        return full.absoluteString
    }

    func openUrl(_ address: String) -> Bool {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, let host, takeOutward("open a link") else { return false }
        return went(host.openUrl(absolute(url)))
    }

    func print(_ from: Int, _ to: Int) {
        if hover { return }
        host?.print(from >= 0 ? from : nil, to >= 0 ? to : nil)
    }

    func mail(_ kind: String, _ to: String, _ cc: String, _ bcc: String, _ subject: String, _ message: String) -> Bool {
        guard let host, takeOutward("email") else { return false }
        switch kind {
        case "doc":
            deferred.append { bytes in
                _ = host.mail(FormMail(to: to, cc: cc, bcc: bcc, subject: subject, message: message, attachment: bytes, attachmentName: "form.pdf"))
            }
            return true
        case "form":
            let entries = self.entries(nil, exclude: false, includeEmpty: false)
            return went(host.mail(FormMail(to: to, cc: cc, bcc: bcc, subject: subject, message: message, attachment: FormData.fdf(entries, nil),
                                           attachmentName: "form.fdf", fields: entries.map(\.name))))
        default:
            return went(host.mail(FormMail(to: to, cc: cc, bcc: bcc, subject: subject, message: message, attachment: nil, attachmentName: nil)))
        }
    }

    /// Builds the data a submit sends and hands it to the host (which asks the user first).
    func submit(_ address: String, _ format: String, _ includeEmpty: Bool, _ names: [String]?, exclude: Bool, get: Bool, charset: String) -> Bool {
        guard let host else {
            log("submitForm: nothing to send it with")
            return false
        }
        if !takeOutward("send the form") { return false }
        let url = absolute(address.trimmingCharacters(in: .whitespacesAndNewlines))
        let kind: SubmitFormat
        switch format {
        case "HTML": kind = .html
        case "XFDF", "XML", "XDP": kind = .xfdf
        case "PDF": kind = .pdf
        default: kind = .fdf
        }
        let entries = self.entries(names, exclude: exclude, includeEmpty: includeEmpty)
        let fields = entries.map(\.name)

        if url.lowercased().hasPrefix("mailto:") {
            // An emailed submission: the data goes along as an attachment the user adds.
            let rest = String(url.dropFirst(7))
            let address = String(rest.split(separator: "?", omittingEmptySubsequences: false)[0]).removingPercentEncoding ?? ""
            if kind == .pdf {
                deferred.append { bytes in
                    _ = host.mail(FormMail(to: address, cc: "", bcc: "", subject: "Form", message: "", attachment: bytes, attachmentName: "form.pdf"))
                }
                return true
            }
            let (data, name): ([UInt8], String) = kind == .xfdf ? (FormData.xfdf(entries, nil), "form.xfdf")
                : kind == .html ? (Array(FormData.html(entries, .utf8).utf8), "form.txt") : (FormData.fdf(entries, nil), "form.fdf")
            return went(host.mail(FormMail(to: address, cc: "", bcc: "", subject: "Form", message: "", attachment: data, attachmentName: name,
                                           fields: fields)))
        }

        let sent: Bool
        switch kind {
        case .pdf:
            deferred.append { bytes in
                _ = host.submit(FormSubmission(url: url, method: "POST", contentType: "application/pdf", body: bytes, format: .pdf,
                                               fieldCount: entries.count, fields: fields))
            }
            return true
        case .html:
            var encoding = String.Encoding.utf8
            if !charset.isEmpty {
                let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
            }
            let query = FormData.html(entries, encoding)
            if get {
                let target = url.contains("?") ? url + "&" + query : url + "?" + query
                sent = host.submit(FormSubmission(url: target, method: "GET", contentType: "application/x-www-form-urlencoded", body: [], format: .html,
                                                  fieldCount: entries.count, fields: fields))
            } else {
                sent = host.submit(FormSubmission(url: url, method: "POST", contentType: "application/x-www-form-urlencoded", body: Array(query.utf8),
                                                  format: .html, fieldCount: entries.count, fields: fields))
            }
        case .xfdf:
            sent = host.submit(FormSubmission(url: url, method: "POST", contentType: "application/vnd.adobe.xfdf", body: FormData.xfdf(entries, nil),
                                              format: .xfdf, fieldCount: entries.count, fields: fields))
        case .fdf:
            sent = host.submit(FormSubmission(url: url, method: "POST", contentType: "application/vnd.fdf", body: FormData.fdf(entries, nil),
                                              format: .fdf, fieldCount: entries.count, fields: fields))
        }
        return went(sent)
    }

    /// The fields a submit sends: exportable ones (no push buttons, signatures or NoExport), listed or not.
    private func entries(_ names: [String]?, exclude: Bool, includeEmpty: Bool) -> [FormData.Entry] {
        var list: [FormData.Entry] = []
        var seen = Set<String>()
        for f in pick(names, exclude) {
            if !["Tx", "Ch", "Btn"].contains(f.type) || (f.type == "Btn" && f.flags & FormEditor.ffPushButton != 0) { continue }
            if (FormEditor.inherited(f.dict, "Ff")?.int ?? 0) & FormEditor.ffNoExport != 0 { continue }
            if !seen.insert(f.name).inserted { continue }
            let hasValue = FormEditor.inherited(f.dict, "V") != nil
            let value = FormEditor.exportValueOf(f) // check boxes and radios with /Opt send their export value, not "0" / "1"
            if !hasValue || (f.type != "Btn" && value.isEmpty) {
                if includeEmpty { list.append(FormData.Entry(name: f.name, values: nil, isName: false)) }
                continue
            }
            let multi = f.type == "Ch" && f.flags & FormEditor.ffMultiSelect != 0
            list.append(FormData.Entry(name: f.name, values: multi ? value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : [value],
                                       isName: f.type == "Btn"))
        }
        return list
    }

    /// Terminal fields named in `names` (or under them), or all others with `exclude`; nil = all.
    private func pick(_ names: [String]?, _ exclude: Bool) -> [FormField] {
        guard let names else { return fields }
        return fields.filter { f in names.contains { f.name == $0 || f.name.hasPrefix($0 + ".") } != exclude }
    }

    /// The full names an action's /Fields lists (text strings, or field dictionaries).
    private func fieldNames(_ item: PObj?) -> [String]? {
        guard let item, item.isArray else { return nil }
        return item.elements.compactMap { e in
            if e.kind == .string { return e.text }
            if e.isDict, let n = fullName(e), !n.isEmpty { return n }
            return nil
        }
    }

    private func fullName(_ d: PObj) -> String? {
        var parts: [String] = []
        var n: PObj? = d
        var guardCount = 0
        while let cur = n, guardCount < 64 {
            if let t = cur["T"], t.kind == .string, let s = t.text { parts.insert(s, at: 0) }
            n = cur.dict("Parent")
            guardCount += 1
        }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    /// A file specification's path or URL (string, or dictionary with /UF, /F).
    private func fileSpec(_ item: PObj?) -> String? {
        guard let item else { return nil }
        if item.kind == .string { return item.text }
        if item.isDict { return item.text("UF") ?? item.text("F") ?? item.text("DOS") }
        return nil
    }

    // ---------------- Changes to the form ----------------

    /// ResetForm and this.resetForm: listed fields (or all, or all but the listed) back to their defaults.
    func reset(_ names: [String]?, exclude: Bool) {
        if readOnly {
            wantedChange = true
            return
        }
        label = "Reset form"
        for f in pick(names, exclude) {
            if !["Tx", "Ch", "Btn"].contains(f.type) || (f.type == "Btn" && f.flags & FormEditor.ffPushButton != 0) { continue }
            let dv = FormEditor.inherited(f.dict, "DV")
            switch f.type {
            case "Tx":
                if let dv, dv.kind == .string { f.dict.set("V", doc.text(dv.text ?? "")) } else { f.dict.remove("V") }
                f.dict.remove("RV")
            case "Ch":
                let value: String
                if let dv, dv.kind == .string {
                    value = dv.text ?? ""
                } else if let dv, dv.isArray {
                    value = dv.elements.compactMap { $0.kind == .string ? $0.text : nil }.joined(separator: "\n")
                } else {
                    value = ""
                }
                FormEditor.setChoice(doc, f, value)
            default:
                let state = dv?.kind == .name ? dv?.name ?? "Off" : "Off"
                f.dict.set("V", doc.name(state))
                for w in f.widgets where w.has("AS") || w.has("AP") {
                    w.set("AS", doc.name(FormEditor.onStateOf(w) == state ? state : "Off"))
                }
            }
            js.touch(f)
            changed = true
        }
    }

    /// The Hide action: shows or hides the widgets of the named fields (or the given annotations).
    private func hide(_ targets: PObj?, _ hide: Bool) {
        var widgets: [PObj] = []
        func add(_ t: PObj?, _ depth: Int) {
            guard depth <= 8, let t else { return }
            if t.isArray {
                for e in t.elements { add(e, depth + 1) }
            } else if t.kind == .string {
                for f in pick([t.text ?? ""], false) { widgets += f.widgets }
            } else if t.isDict {
                if fields.contains(where: { f in f.widgets.contains { $0.identity == t.identity } }) || t.name("Subtype") != nil {
                    widgets.append(t)
                } else if let name = fullName(t) {
                    for f in pick([name], false) { widgets += f.widgets }
                }
            }
        }
        add(targets, 0)
        if widgets.isEmpty { return }
        if readOnly {
            wantedChange = true
            return
        }
        var done = Set<UInt>()
        for w in widgets where done.insert(w.identity).inserted {
            let flags = w.int("F") ?? 0
            let updated = hide ? flags | FormEditor.annotHidden : flags & ~(FormEditor.annotHidden | FormEditor.annotNoView)
            if updated == flags { continue }
            w.set("F", doc.int(updated))
            changed = true
        }
    }

    /// ImportData and this.importAnFDF: the user picks an FDF or XFDF file (the host asks first); its values fill the
    /// form.
    func importData(_ suggested: String) -> Bool {
        guard let host else { return false }
        if readOnly {
            wantedChange = true
            return true
        }
        if !takeOutward("import form data") { return false }
        guard let bytes = host.importData(suggested.isEmpty ? nil : suggested) else { return went(false) }
        guard let values = FormData.parse(bytes) else {
            log("Import: the file isn't FDF or XFDF form data")
            return true
        }
        label = "Import form data"
        for f in fields {
            guard let v = values[f.name], let first = v.first else { continue }
            switch f.type {
            case "Tx":
                f.dict.set("V", doc.text(first))
                f.dict.remove("RV")
            case "Ch":
                FormEditor.setChoice(doc, f, v.joined(separator: "\n"))
            case "Btn" where f.flags & FormEditor.ffPushButton == 0:
                FormEditor.setButton(f, first)
            default:
                continue
            }
            js.touch(f)
            changed = true
        }
        return true
    }

    // ---------------- Finishing ----------------

    /// After the run: when fields changed, the calculations run, changed fields get fresh appearances, and the document
    /// is saved; then actions waiting for the finished document (PDF submits, mailDoc) go out.
    func finish() throws -> FormActionResult {
        var saved: [UInt8]?
        if !readOnly && (!js.touched.isEmpty || changed) {
            var dirty = FormEditor.calculate(doc, acro, fields, js, &alerts)
            for f in js.touchedInOrder where !dirty.contains(f) { dirty.append(f) }
            acro?.remove("XFA") // the AcroForm is now the truth
            FormEditor.finishAppearances(doc, acro, fields, dirty, js)
            saved = try FormEditor.save(doc, source, password, xmp)
        }
        runDeferred(saved ?? source)
        let label = self.label == "Form action" && !js.touched.isEmpty ? "Form script" : self.label
        return FormActionResult(data: saved, label: label, alerts: notices + alerts, log: js.log, focusField: focusField,
                                needsPermission: wantedChange || (readOnly && !js.touched.isEmpty))
    }

    /// Sends what waited for the finished document (PDF submits, mailDoc).
    func runDeferred(_ document: [UInt8]) {
        for send in deferred { send(document) }
        deferred.removeAll()
    }
}

/// Runs a text field's keystroke script (/AA /K) on each edit while the user types (event.willCommit false), so
/// characters can be refused or transformed as typed. Opened once per editing session (off the main thread: it reads
/// the document and starts the script engine); each call then takes well under a millisecond for the usual AF*
/// scripts. Scripts here can read the form but not change it, and nothing outward is reachable.
public final class FieldKeystrokes: @unchecked Sendable {
    private let lock = NSLock()
    private let runBody: (String, String, Int, Int) -> KeystrokeResult?

    /// The script engine was started when this was opened (so the first keystroke doesn't wait for it).
    let warm: Bool

    private init(warm: Bool, _ run: @escaping (String, String, Int, Int) -> KeystrokeResult?) {
        self.warm = warm
        runBody = run
    }

    /// The smallest edit that turns `before` into `after`: replace [start, end) of `before` with `change` (UTF-16
    /// positions; surrogate pairs are never split).
    public static func diff(_ before: String, _ after: String) -> (start: Int, end: Int, change: String) {
        let b = Array(before.utf16), a = Array(after.utf16)
        let most = min(b.count, a.count)
        var prefix = 0
        while prefix < most && b[prefix] == a[prefix] { prefix += 1 }
        if prefix > 0 && prefix < b.count && UTF16.isLeadSurrogate(b[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < most - prefix && b[b.count - suffix - 1] == a[a.count - suffix - 1] { suffix += 1 }
        if suffix > 0 && suffix < b.count - prefix && UTF16.isTrailSurrogate(b[b.count - suffix]) { suffix -= 1 }
        return (prefix, b.count - suffix, String(decoding: a[prefix..<(a.count - suffix)], as: UTF16.self))
    }

    /// `text` cut so that replacing [start, end) of `value` with it stays within `maxLength` UTF-16 units (0 = no
    /// limit), without splitting a surrogate pair: a paste longer than the field's limit keeps what fits.
    public static func fit(_ value: String, _ start: Int, _ end: Int, _ text: String, _ maxLength: Int) -> String {
        if maxLength <= 0 { return text }
        let t = Array(text.utf16)
        var room = maxLength - (value.utf16.count - max(0, end - start))
        if t.count <= room { return text }
        if room <= 0 { return "" }
        if UTF16.isLeadSurrogate(t[room - 1]) { room -= 1 }
        return String(decoding: t[..<room], as: UTF16.self)
    }

    /// The field's keystroke check, or nil when it has no keystroke script (or the PDF can't be read).
    public static func open(_ data: [UInt8], _ password: String?, _ fieldName: String) -> FieldKeystrokes? {
        guard let doc = try? PdfEdit.openToRead(data, password), let fields = try? FormEditor.collect(doc, doc.catalog.dict("AcroForm")),
              let field = fields.first(where: { $0.name == fieldName }), field.isTextOrChoice,
              let script = FormEditor.actionScript(field, "K"), !script.isEmpty else { return nil }
        let js = JsFormHost(doc, fields, readOnly: true)
        js.prewarm() // the engine and document scripts now, off the main thread
        return FieldKeystrokes(warm: js.started) { value, change, selStart, selEnd in
            _ = doc // the document stays open with the keystroke check
            let n = value.utf16.count
            let start = min(max(selStart, 0), n)
            let end = min(max(selEnd, start), n)
            js.resetBudget()
            guard let r = js.run("Keystroke", field, script, value, willCommit: false, change: change, selStart: start, selEnd: end) else { return nil }
            let s = min(max(r.selStart, 0), n)
            return KeystrokeResult(accepted: r.rc, change: r.change, selStart: s, selEnd: min(max(r.selEnd, s), n), alerts: r.alerts)
        }
    }

    /// The script's verdict on replacing [selStart, selEnd) of `value` with `change` (empty for a deletion); nil when
    /// the script couldn't run (then the edit should simply go through: the commit check still runs later).
    public func run(_ value: String, _ change: String, _ selStart: Int, _ selEnd: Int) -> KeystrokeResult? {
        lock.lock()
        defer { lock.unlock() }
        return runBody(value, change, selStart, selEnd)
    }
}
