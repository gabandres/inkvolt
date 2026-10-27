import Foundation

/// What a field script did with one event: the resulting event.value and event.rc, the app.alert texts it raised (when
/// no UI host showed them), the text color it set (format scripts drawing negatives red), the keystroke change and
/// selection it left (live keystrokes), and how many dialogs the host showed for it.
struct JsEventResult {
    var value: String?
    var rc: Bool
    var alerts: [String]
    var textColor: [Double]?
    var change = ""
    var selStart = 0
    var selEnd = 0
    var shown = 0
}

/// A clock that runs only while started (.NET's `Stopwatch`).
final class RunClock {
    private var total: TimeInterval = 0
    private var since: TimeInterval?

    var isRunning: Bool { since != nil }
    var elapsed: TimeInterval { total + (since.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0) }

    func start() { if since == nil { since = ProcessInfo.processInfo.systemUptime } }

    func stop() {
        if let s = since { total += ProcessInfo.processInfo.systemUptime - s }
        since = nil
    }

    func reset() {
        total = 0
        since = nil
    }

    func restart() {
        total = 0
        since = ProcessInfo.processInfo.systemUptime
    }
}

/// Runs a form's Acrobat JavaScript (field /AA actions, button actions and document-level scripts) in a sandbox, the
/// Windows app's `JsFormHost` over a `FormScriptEngine` (JavaScriptCore) instead of Jint: no file, network or system
/// access exists in the engine; a time budget per script and per run, array and string caps (the prelude), and only a
/// small Acrobat object model (event, getField, field objects, app/util/console and the AF* built-ins). Everything that
/// leaves the document (launchURL, submitForm, mailDoc, print, imports) goes through a `FormActionRunner` and its
/// `FormActionHost`, which asks the user first; without a runner (reading a form, live keystrokes) those calls do
/// nothing, and document-level scripts can never reach them; outward calls are capped per run and per document per
/// minute, and one the user declines ends the script. Hovering (Mouse Enter/Exit) runs scripts without dialogs, printing
/// or outward calls, and setFocus is ignored while focus moves (Focus/Blur). Modal dialogs (app.alert, app.response) are
/// limited per event and per run, and the time they are open doesn't count against the script's budget. A script that
/// fails, times out or exceeds a limit returns nil so callers fall back to the parsed fast paths in `FormScripts`;
/// errors never escape.
final class JsFormHost {
    private static let scriptTimeout: TimeInterval = 0.5
    /// Setting up the engine (the prelude, the host functions) is our own code: its own, longer limit, not charged to
    /// the scripts' budget.
    private static let setupTimeout: TimeInterval = 10
    private static let totalBudget: TimeInterval = 2 // all scripts of one fill or read together: past it, scripting turns off
    private static let maxScriptLength = 256 * 1024
    static let maxDialogsPerEvent = 3
    private static let maxDialogsPerRun = 10

    private let doc: MuDoc
    private let fields: [FormField]
    private let readOnly: Bool
    private weak var runner: FormActionRunner?
    private let hasRunner: Bool
    private let makeEngine: () -> FormScriptEngine
    private let spent = RunClock()
    /// The running script's clock (paused while the host shows a dialog or sends something) and its limit.
    private let clock = RunClock()
    private var limit = scriptTimeout
    private var paused = 0
    private var props: [String: [String: ScriptValue]] = [:]
    private var engine: FormScriptEngine?
    private var failed = false
    private var inDocumentScripts = false
    private var eventAlerts: [String]?
    private var eventColor: [Double]?
    private var eventTarget: String?
    private var eventName: String?
    private var eventDialogs = 0, runDialogs = 0, prints = 0
    /// An outward step was declined or capped: the running script ends (its host calls do nothing more).
    private var stopping = false
    private var stopReason = ""
    private var timedOut = false

    /// `readOnly`: scripts may read fields but their writes are ignored (reading a form for display). `runner` carries
    /// out document actions (reset, submit, navigation...); nil = none reachable.
    init(_ doc: MuDoc, _ fields: [FormField], readOnly: Bool = false, runner: FormActionRunner? = nil,
         engine: @escaping () -> FormScriptEngine = { JavaScriptCoreEngine() }) {
        self.doc = doc
        self.fields = fields
        self.readOnly = readOnly
        self.runner = runner
        hasRunner = runner != nil
        makeEngine = engine
    }

    /// The engine is running (prelude and document scripts done).
    var started: Bool { engine != nil }

    /// console.println output and script errors, for the app log.
    var log: [String] = []

    /// Fields whose value, look or visibility a script changed (they need saving and fresh appearances).
    private(set) var touched = Set<FormField>()
    private(set) var touchedInOrder: [FormField] = []

    func touch(_ f: FormField) {
        if touched.insert(f).inserted { touchedInOrder.append(f) }
    }

    /// Starts a fresh time budget (each live keystroke is its own short run).
    func resetBudget() {
        spent.reset()
        runDialogs = 0
    }

    /// Runs one field event: `name` is Format, Keystroke, Validate, Calculate, or a button event (Mouse Up, Mouse Down,
    /// Mouse Enter, Mouse Exit, Focus, Blur). Nil when the script couldn't run (error, limit, or scripting off), so the
    /// caller falls back.
    func run(_ name: String, _ target: FormField, _ script: String, _ value: String, willCommit: Bool = false, change: String = "",
             selStart: Int = 0, selEnd: Int = 0) -> JsEventResult? {
        if script.allSatisfy(\.isWhitespace) || script.utf16.count > Self.maxScriptLength { return nil }
        guard let engine = startEngine() else { return nil }
        eventAlerts = []
        eventColor = nil
        eventTarget = target.name
        eventName = name
        eventDialogs = 0
        stopping = false
        defer {
            eventAlerts = nil
            eventTarget = nil
            eventName = nil
        }
        do {
            _ = try guarded {
                try engine.call("begin", [.string(name), .string(target.name), .string(value), .bool(willCommit), .string(change),
                                          .number(Double(selStart)), .number(Double(selEnd))])
            }
            try guarded { try engine.run(script) }
            guard case .array(let arr) = try guarded({ try engine.call("end", []) }), arr.count >= 5 else { return nil }
            let text: String?
            switch arr[0] {
            case .number(let d): text = d.isFinite ? FormScripts.numberToValue(d) : nil
            case .string(let s): text = s
            case .bool(let b): text = b ? "true" : "false"
            default: text = ""
            }
            var newChange = change
            if case .string(let c) = arr[2] { newChange = c }
            func pos(_ p: ScriptValue, _ fallback: Int) -> Int {
                if case .number(let d) = p, d.isFinite { return Int(min(max(d, -1), 1e7)) }
                return fallback
            }
            let rc: Bool
            if case .bool(let b) = arr[1] { rc = b } else { rc = false }
            return JsEventResult(value: text, rc: rc, alerts: eventAlerts ?? [], textColor: eventColor, change: newChange,
                                 selStart: pos(arr[3], selStart), selEnd: pos(arr[4], selEnd), shown: eventDialogs)
        } catch {
            let stopped = stopping
            log.append("Form script (\(name) of \(target.name)) \(stopped ? "stopped" : "failed"): \(describe(error))")
            return nil
        }
    }

    /// Starts the engine now (prelude and document-level scripts), so the first event doesn't pay for it: call it off
    /// the UI thread before live keystrokes start. (JavaScriptCore compiles a script when it first runs.)
    func prewarm() { _ = startEngine() }

    private struct BudgetUsedUp: Error {}

    /// Thrown into a running script from a host function: the script stops (an outward step was declined or capped).
    private struct Stop: Error, CustomStringConvertible {
        var description: String { "an outward action was declined or the form tried too many" }
    }

    private func describe(_ error: Error) -> String {
        if error is BudgetUsedUp { return "form scripts used up their time budget" }
        if let e = error as? ScriptError {
            if e.interrupted { return stopping ? stopReason : "took too long" }
            return e.message
        }
        return "\(error)"
    }

    /// Runs script code under the per-script time limit, charged to the run's budget.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        if spent.elapsed > Self.totalBudget {
            failed = true
            throw BudgetUsedUp()
        }
        spent.start()
        arm(Self.scriptTimeout)
        defer { spent.stop() }
        return try body()
    }

    private func arm(_ seconds: TimeInterval) {
        limit = seconds
        paused = 0
        timedOut = false
        clock.restart()
    }

    /// Asked by the engine while a script runs.
    private func shouldInterrupt() -> Bool {
        if stopping { return true }
        if paused == 0 && clock.elapsed > limit {
            timedOut = true
            return true
        }
        return false
    }

    /// Runs host work (a dialog, a request) without charging its time to the script.
    private func outside<T>(_ body: () -> T) -> T {
        let running = spent.isRunning
        spent.stop()
        if paused == 0 { clock.stop() }
        paused += 1
        defer {
            paused -= 1
            if paused == 0 { clock.start() }
            if running { spent.start() }
        }
        return body()
    }

    private func startEngine() -> FormScriptEngine? {
        if failed { return nil }
        if let engine { return engine }
        let e = makeEngine()
        e.interrupt = { [weak self] in self?.shouldInterrupt() ?? true }
        do {
            arm(Self.setupTimeout)
            try e.start(prelude: JsPrelude.source, host: hostFunctions())
            engine = e
            runDocumentScripts(e)
            return failed ? nil : e
        } catch {
            log.append("Form scripting is unavailable: \(describe(error))")
            failed = true
            engine = nil
            return nil
        }
    }

    /// The document-level scripts (/Names /JavaScript), in name order: they mostly define helper functions.
    private func runDocumentScripts(_ e: FormScriptEngine) {
        for (key, item) in PdfStructure.nameTree(doc.catalog.dict("Names")?.dict("JavaScript")) {
            guard let action = item, action.isDict, let js = FormEditor.scriptText(action["JS"]), !js.isEmpty,
                  js.utf16.count <= Self.maxScriptLength else { continue }
            // Alerts while the document opens aren't the user's doing: dropped; and nothing may leave the document.
            eventAlerts = []
            inDocumentScripts = true
            defer {
                eventAlerts = nil
                inDocumentScripts = false
            }
            do {
                try guarded { try e.run(js) }
            } catch {
                log.append("Document script \(key) failed: \(describe(error))")
                if failed { return }
            }
        }
    }

    /// The runner, when this script may act on the document or the world: not while document-level scripts run, and on
    /// hover (pointer enter or exit) only for `navigation`.
    private func actor(_ what: String, navigation: Bool = false) -> FormActionRunner? {
        guard let runner else { return nil }
        if inDocumentScripts || eventAlerts == nil {
            log.append("Form script: \(what) ignored (not allowed outside a user event)")
            return nil
        }
        if runner.hover && !navigation {
            log.append("Form script: \(what) ignored (not run when the pointer only passes over a field)")
            return nil
        }
        return runner
    }

    /// The host of a run whose event may open dialogs (not document-level scripts, not hover).
    private var dialogHost: FormActionHost? {
        guard let runner, let host = runner.host, !runner.hover, !inDocumentScripts, eventAlerts != nil else { return nil }
        return host
    }

    /// Whether another modal dialog may open for this event; counts it.
    private func takeDialog(_ what: String) -> Bool {
        if eventDialogs >= Self.maxDialogsPerEvent || runDialogs >= Self.maxDialogsPerRun {
            log.append("Form script: \(what) suppressed (too many dialogs)")
            return false
        }
        eventDialogs += 1
        runDialogs += 1
        return true
    }

    /// Ends the running script when the runner was stopped (an outward step declined or capped).
    private func stopIfStopped(_ r: FormActionRunner) throws {
        if r.stopped {
            stopping = true
            stopReason = Stop().description
            throw Stop()
        }
    }

    // ---------------- Host functions (reachable only through the prelude's closure) ----------------

    private static func arg(_ a: [ScriptValue], _ i: Int) -> ScriptValue { i < a.count ? a[i] : .undefined }
    private static func s(_ a: [ScriptValue], _ i: Int) -> String { i < a.count && !a[i].isNullish ? a[i].string : "" }
    private static func b(_ a: [ScriptValue], _ i: Int) -> Bool { i < a.count && a[i].truthy }

    private static func int(_ a: [ScriptValue], _ i: Int, _ def: Int = 0) -> Int {
        guard i < a.count, !a[i].isNullish else { return def }
        let d = a[i].number
        return d.isFinite ? Int(min(max(d, -1e6), 1e6)) : def
    }

    private static func str(_ s: String?) -> ScriptValue { s.map { .string($0) } ?? .null }

    private static func names(_ v: ScriptValue) -> [String]? {
        guard case .array(let items) = v else { return nil }
        return items.prefix(10_000).filter { !$0.isNullish }.map(\.string)
    }

    private static func clip(_ s: String, _ max: Int) -> String { s.count > max ? String(s.prefix(max)) + "…" : s }

    private func hostFunctions() -> [String: ([ScriptValue]) throws -> ScriptValue] {
        typealias A = [ScriptValue]
        func S(_ a: A, _ i: Int) -> String { Self.s(a, i) }
        func I(_ a: A, _ i: Int, _ def: Int = 0) -> Int { Self.int(a, i, def) }
        func B(_ a: A, _ i: Int) -> Bool { Self.b(a, i) }
        func Arg(_ a: A, _ i: Int) -> ScriptValue { Self.arg(a, i) }
        var h: [String: (A) throws -> ScriptValue] = [:]
        func fn(_ name: String, _ body: @escaping (JsFormHost, A) throws -> ScriptValue) {
            h[name] = { [weak self] a in
                guard let self else { return .undefined }
                if self.stopping { throw Stop() }
                return try body(self, a)
            }
        }

        fn("exists") { me, a in .bool(!me.terminals(S(a, 0)).isEmpty) }
        fn("kids") { me, a in
            var names: [String] = []
            for f in me.terminals(S(a, 0)) where !names.contains(f.name) { names.append(f.name) }
            return .array(names.map { .string($0) })
        }
        fn("count") { me, _ in .number(Double(me.fields.count)) }
        fn("nth") { me, a in
            let i = I(a, 0, -1)
            return i >= 0 && i < me.fields.count ? .string(me.fields[i].name) : .null
        }
        fn("get") { me, a in me.get(S(a, 0), S(a, 1)) }
        fn("set") { me, a in
            me.set(S(a, 0), S(a, 1), Arg(a, 2))
            return .undefined
        }
        fn("item") { me, a in
            guard let f = me.find(S(a, 0)), f.type == "Ch" else { return .null }
            let (exports, labels) = FormEditor.readOptions(FormEditor.inherited(f.dict, "Opt"))
            let i = I(a, 1, -1)
            if i < 0 || i >= exports.count { return .null }
            return .string(Arg(a, 2).truthy ? exports[i] : labels[i])
        }
        fn("items") { me, a in
            me.items(a)
            return .undefined
        }
        fn("alert") { me, a in
            let text = S(a, 0)
            let type = min(max(I(a, 2), 0), 3)
            // Without a dialog the answer is the cautious one: OK for a notice, Cancel / No for a question.
            let fallback = type == 1 ? 2 : type >= 2 ? 3 : 1
            if me.runner?.hover == true {
                me.log.append("Form script: app.alert suppressed (the pointer only passed over a field)")
                return .number(Double(fallback))
            }
            if let host = me.dialogHost {
                if text.isEmpty || !me.takeDialog("app.alert") { return .number(Double(fallback)) }
                let alert = FormAlert(Self.clip(text, 4000), Self.clip(S(a, 3), 200), min(max(I(a, 1), 0), 3), type)
                let r = me.outside { host.alert(alert) }
                return .number(Double((1...4).contains(r) ? r : fallback))
            }
            if var list = me.eventAlerts, list.count < 20, !text.isEmpty {
                list.append(Self.clip(text, 2000))
                me.eventAlerts = list
            }
            return .number(Double(fallback))
        }
        fn("response") { me, a in
            guard let host = me.dialogHost, me.takeDialog("app.response") else { return .null }
            let prompt = FormPrompt(question: Self.clip(S(a, 0), 4000), title: Self.clip(S(a, 1), 200), defaultText: Self.clip(S(a, 2), 10_000),
                                    password: B(a, 3), label: Self.clip(S(a, 4), 200))
            return Self.str(me.outside { host.response(prompt) })
        }
        fn("log") { me, a in
            if me.log.count < 200 { me.log.append("console: " + S(a, 0)) }
            return .undefined
        }
        // Outward calls: each counts against the run's caps; when one is declined or capped the script ends here.
        fn("launchURL") { me, a in
            if let r = me.actor("app.launchURL") {
                _ = me.outside { r.openUrl(S(a, 0)) }
                try me.stopIfStopped(r)
            }
            return .undefined
        }
        fn("submit") { me, a in
            // url, format (FDF, XFDF, HTML, PDF...), include empty fields, field names, GET, charset
            if let r = me.actor("submitForm"), !me.readOnly {
                _ = me.outside { r.submit(S(a, 0), S(a, 1), B(a, 2), Self.names(Arg(a, 3)), exclude: false, get: B(a, 4), charset: S(a, 5)) }
                try me.stopIfStopped(r)
            }
            return .undefined
        }
        fn("reset") { me, a in
            if !me.readOnly && !me.inDocumentScripts, let r = me.actor("resetForm") { r.reset(Self.names(Arg(a, 0)), exclude: false) }
            return .undefined
        }
        fn("print") { me, a in
            if let r = me.actor("print") {
                me.prints += 1
                if me.prints == 1 { me.outside { r.print(I(a, 0, -1), I(a, 1, -1)) } }
            }
            return .undefined
        }
        fn("mail") { me, a in
            // kind (doc, form, msg), to, cc, bcc, subject, message
            if let r = me.actor("mail") {
                _ = me.outside {
                    r.mail(S(a, 0), Self.clip(S(a, 1), 2000), Self.clip(S(a, 2), 2000), Self.clip(S(a, 3), 2000), Self.clip(S(a, 4), 500),
                           Self.clip(S(a, 5), 10_000))
                }
                try me.stopIfStopped(r)
            }
            return .undefined
        }
        fn("importData") { me, a in
            if let r = me.actor("importAnFDF"), !me.readOnly {
                _ = me.outside { r.importData(S(a, 0)) }
                try me.stopIfStopped(r)
            }
            return .undefined
        }
        fn("beep") { me, a in
            if let r = me.actor("app.beep") { r.host?.beep(min(max(I(a, 0, 4), 0), 4)) }
            return .undefined
        }
        fn("pageNum") { me, _ in
            guard let host = me.runner?.host else { return .number(0) }
            return .number(Double(me.outside { host.currentPage }))
        }
        fn("setPageNum") { me, a in
            if let r = me.actor("pageNum", navigation: true) { me.outside { r.goToPage(I(a, 0, -1)) } }
            return .undefined
        }
        fn("numPages") { me, _ in .number(Double((try? me.doc.pageCount()) ?? 0)) }
        fn("info") { me, a in
            let keys = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"]
            let wanted = S(a, 0)
            guard let key = keys.first(where: { $0 == wanted || $0.lowercased() == wanted }) else { return .null }
            return Self.str(me.doc.trailer.dict("Info")?.text(key))
        }
        fn("focus") { me, a in
            // Moving the focus fires Focus and Blur again: a setFocus from those (or from hovering) would bounce the focus
            // between fields forever, so only other events may move it.
            if let event = me.eventName, ["Focus", "Blur", "Mouse Enter", "Mouse Exit"].contains(event) {
                me.log.append("Form script: setFocus ignored during \(event)")
                return .undefined
            }
            if let r = me.runner, !me.inDocumentScripts, me.find(S(a, 0)) != nil { r.focusField = S(a, 0) }
            return .undefined
        }
        fn("boxChecked") { me, a in
            guard let f = me.find(S(a, 0)), f.type == "Btn" else { return .bool(false) }
            let current = FormEditor.valueOf(f)
            if current == "Off" || current.isEmpty { return .bool(false) }
            let i = I(a, 1, -1)
            let states = f.widgets.map(FormEditor.onStateOf)
            if states.allSatisfy({ $0 == nil }) { return .bool(true) } // no on looks to tell the widgets apart
            return .bool(i >= 0 && i < states.count && (states[i] ?? String(i)) == current)
        }
        fn("checkBox") { me, a in
            // checkThisBox(widget, on): the widget's own state, so widgets sharing an export value stay apart.
            guard !me.readOnly, let f = me.find(S(a, 0)), f.isToggle else { return .undefined }
            let i = I(a, 1, -1)
            if i < 0 || i >= f.widgets.count { return .undefined }
            let state = FormEditor.onStateOf(f.widgets[i]) ?? String(i)
            let current = FormEditor.valueOf(f)
            if B(a, 2) {
                FormEditor.setButton(f, state)
            } else if current == state {
                FormEditor.setButton(f, "Off")
            }
            if FormEditor.valueOf(f) != current { me.touch(f) }
            return .undefined
        }
        fn("makeNumber") { _, a in FormScripts.toNumber(S(a, 0)).map { .number($0) } ?? .null }
        fn("fmtNumber") { _, a in
            guard FormScripts.toNumber(S(a, 0)) != nil else { return .null }
            var prepend = true
            if case .bool(let p) = Arg(a, 5) { prepend = p }
            let fmt = FieldFormat(.number, decimals: min(max(I(a, 1, 2), 0), 10), separatorStyle: I(a, 2), negativeStyle: I(a, 3),
                                  currency: S(a, 4), currencyPrepend: prepend)
            let (text, red) = FormScripts.format(fmt, S(a, 0))
            return .array([.string(text), .bool(red)])
        }
        fn("fmtPercent") { _, a in
            guard FormScripts.toNumber(S(a, 0)) != nil else { return .null }
            let fmt = FieldFormat(.percent, decimals: min(max(I(a, 1, 2), 0), 10), separatorStyle: I(a, 2), currencyPrepend: Arg(a, 3).truthy)
            return .string(FormScripts.format(fmt, S(a, 0)).text)
        }
        fn("fmtDate") { _, a in
            FormScripts.parseDate(S(a, 0), S(a, 1)).map { .string(FormScripts.formatDate($0, S(a, 1))) } ?? .null
        }
        fn("fmtSpecial") { _, a in .string(FormScripts.format(FieldFormat(.special, special: I(a, 1)), S(a, 0)).text) }
        fn("parseDate") { _, a in
            guard let d = FormScripts.parseDate(S(a, 0), S(a, 1)) else { return .null }
            return .array([d.year, d.month, d.day, d.hour, d.minute, d.second].map { .number(Double($0)) })
        }
        fn("printd") { _, a in
            let d = FormDate.from(I(a, 1, 2000), min(max(I(a, 2, 1), 1), 12), plusDays: I(a, 3, 1) - 1, hours: I(a, 4), minutes: I(a, 5),
                                  seconds: I(a, 6))
            return d.map { .string(FormScripts.formatDate($0, S(a, 0))) } ?? .null
        }
        fn("printf") { _, a in .string(Self.printf(a)) }
        return h
    }

    /// setItems / insertItemAt / deleteItemAt / clearItems: op, field, then the op's arguments.
    private func items(_ a: [ScriptValue]) {
        guard !readOnly, let f = find(Self.s(a, 1)), f.type == "Ch" else { return }
        var (exports, labels) = FormEditor.readOptions(FormEditor.inherited(f.dict, "Opt"))
        switch Self.s(a, 0) {
        case "set":
            exports.removeAll()
            labels.removeAll()
            if case .array(let list) = Self.arg(a, 2) {
                for item in list.prefix(10_000) {
                    if case .array(let pair) = item, !pair.isEmpty {
                        let label = pair[0].string
                        labels.append(label)
                        exports.append(pair.count > 1 ? pair[1].string : label)
                    } else if !item.isNullish {
                        labels.append(item.string)
                        exports.append(item.string)
                    }
                }
            }
        case "insert":
            let label = Self.s(a, 2)
            let export = Self.arg(a, 3).isNullish ? label : Self.s(a, 3)
            var at = Self.int(a, 4, 0)
            if at < 0 || at > exports.count { at = exports.count }
            labels.insert(label, at: at)
            exports.insert(export, at: at)
        case "delete":
            let at = Self.arg(a, 2) == .undefined ? exports.firstIndex(of: FormEditor.valueOf(f)) ?? -1 : Self.int(a, 2, -1)
            if at < 0 || at >= exports.count { return }
            labels.remove(at: at)
            exports.remove(at: at)
        case "clear":
            exports.removeAll()
            labels.removeAll()
        default:
            return
        }
        FormActions.writeOptions(f, exports, labels)
        touch(f)
    }

    private func terminals(_ name: String) -> [FormField] {
        name.isEmpty ? [] : fields.filter { $0.name == name || $0.name.hasPrefix(name + ".") }
    }

    private func find(_ name: String) -> FormField? { fields.first { $0.name == name } }

    private static func liveFlags(_ f: FormField) -> Int { FormEditor.inherited(f.dict, "Ff")?.int ?? 0 }

    private func get(_ name: String, _ prop: String) -> ScriptValue {
        let live = ["value", "valueAsString", "display", "hidden", "readonly", "required", "numItems"]
        if let v = props[name]?[prop], !live.contains(prop) { return v }
        guard let f = find(name) else {
            // A parent name (getField("group")) reads the first of its terminal fields.
            if let first = terminals(name).first, prop != "value" && prop != "valueAsString" { return get(first.name, prop) }
            return prop == "value" || prop == "valueAsString" ? .string("") : .undefined
        }
        switch prop {
        case "value":
            let raw = FormEditor.exportValueOf(f)
            if f.isTextOrChoice, !raw.isEmpty, raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
               raw.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
               let num = Double(raw), num.isFinite {
                return .number(num)
            }
            return .string(raw)
        case "valueAsString": return .string(FormEditor.exportValueOf(f))
        case "type":
            switch f.type {
            case "Tx": return .string("text")
            case "Ch": return .string(f.flags & FormEditor.ffCombo != 0 ? "combobox" : "listbox")
            case "Sig": return .string("signature")
            case "Btn" where f.flags & FormEditor.ffPushButton != 0: return .string("button")
            case "Btn" where f.flags & FormEditor.ffRadio != 0: return .string("radiobutton")
            default: return .string("checkbox")
            }
        case "readonly": return .bool(Self.liveFlags(f) & FormEditor.ffReadOnly != 0)
        case "required": return .bool(Self.liveFlags(f) & FormEditor.ffRequired != 0)
        case "multiline": return .bool(f.flags & FormEditor.ffMultiline != 0)
        case "password": return .bool(f.flags & FormEditor.ffPassword != 0)
        case "charLimit": return .number(Double(FormEditor.inherited(f.dict, "MaxLen")?.int ?? 0))
        case "display", "hidden":
            let flags = f.widgets.first?.int("F") ?? 0
            let display = flags & FormEditor.annotHidden != 0 ? 1 : flags & FormEditor.annotNoView != 0 ? 3
                : flags != 0 && flags & FormEditor.annotPrint == 0 ? 2 : 0
            return prop == "hidden" ? .bool(display == 1) : .number(Double(display))
        case "exportValues":
            let values: [String]
            if f.type == "Ch" {
                values = FormEditor.readOptions(FormEditor.inherited(f.dict, "Opt")).exports
            } else if f.type == "Btn", let opt = FormEditor.inherited(f.dict, "Opt"), opt.isArray, opt.count > 0 {
                values = opt.elements.map { $0.text ?? "" }
            } else {
                values = f.widgets.compactMap(FormEditor.onStateOf)
            }
            return .array(values.map { .string($0) })
        case "numItems": return .number(Double(f.type == "Ch" ? FormEditor.readOptions(FormEditor.inherited(f.dict, "Opt")).exports.count : 0))
        case "defaultValue":
            let dvObj = FormEditor.inherited(f.dict, "DV")
            let dv = dvObj?.kind == .string ? dvObj?.text ?? "" : dvObj?.kind == .name ? dvObj?.name ?? "" : ""
            return .string(f.type == "Btn" ? FormEditor.buttonExport(f, dv) : dv)
        case "fillColor", "borderColor", "strokeColor":
            let a = f.widgets.first?.dict("MK")?.array(prop == "fillColor" ? "BG" : "BC")
            return Self.colorArray(a.map { a in (0..<a.count).map { a.num($0) } } ?? [])
        case "textColor":
            let da = f.widgets.first?.text("DA") ?? FormEditor.inherited(f.dict, "DA")?.text
            return Self.colorArray(DefaultAppearance.parse(da).color.c)
        default: return .undefined
        }
    }

    private static func colorArray(_ c: [Double]) -> ScriptValue {
        switch c.count {
        case 1: return .array([.string("G"), .number(c[0])])
        case 3: return .array([.string("RGB")] + c.map { .number($0) })
        case 4: return .array([.string("CMYK")] + c.map { .number($0) })
        default: return .array([.string("T")])
        }
    }

    private func set(_ name: String, _ prop: String, _ v: ScriptValue) {
        switch prop {
        case "value":
            if readOnly { return }
            let text: String
            switch v {
            case .number(let d): text = d.isFinite ? FormScripts.numberToValue(d) : ""
            case .undefined, .null: text = ""
            default: text = v.string
            }
            for f in fields where f.name == name {
                switch f.type {
                case "Tx":
                    if FormEditor.valueOf(f) == text { continue }
                    f.dict.set("V", doc.text(text))
                    f.dict.remove("RV")
                case "Ch":
                    if FormEditor.valueOf(f) == text { continue }
                    FormEditor.setChoice(doc, f, text)
                case "Btn" where f.flags & FormEditor.ffPushButton == 0:
                    FormEditor.setButton(f, text)
                default:
                    continue
                }
                touch(f)
            }
        case "display", "hidden":
            if readOnly { return }
            let n = v.number
            let display = prop == "hidden" ? (v.truthy ? 1 : 0) : n.isFinite ? Int(n) : 0
            for f in terminals(name) {
                for w in f.widgets {
                    let flags = w.int("F") ?? 0
                    let updated: Int
                    switch display {
                    case 1: updated = (flags | FormEditor.annotHidden) & ~FormEditor.annotNoView
                    case 2: updated = flags & ~(FormEditor.annotHidden | FormEditor.annotNoView | FormEditor.annotPrint)
                    case 3: updated = (flags | FormEditor.annotNoView | FormEditor.annotPrint) & ~FormEditor.annotHidden
                    default: updated = (flags | FormEditor.annotPrint) & ~(FormEditor.annotHidden | FormEditor.annotNoView)
                    }
                    if updated == flags { continue }
                    w.set("F", doc.int(updated))
                    touch(f)
                }
            }
        case "readonly", "required":
            if readOnly { return }
            let bit = prop == "readonly" ? FormEditor.ffReadOnly : FormEditor.ffRequired
            for f in terminals(name) {
                let flags = Self.liveFlags(f)
                let updated = v.truthy ? flags | bit : flags & ~bit
                if updated == flags { continue }
                f.dict.set("Ff", doc.int(updated))
                touch(f)
            }
        case "textColor", "fillColor", "borderColor", "strokeColor":
            if prop == "textColor" && name == eventTarget { eventColor = Self.colorOf(v) }
            if readOnly { return } // (a format script's red negatives still apply through the event color)
            for f in terminals(name) where applyColor(f, prop, v) { touch(f) }
        default:
            // Fonts, alignment, ...: remembered for the script's own reads only.
            var stored = props[name] ?? [:]
            if stored.count < 64 || stored[prop] != nil { stored[prop] = v }
            props[name] = stored
        }
    }

    /// Writes a field color into its widgets: text color into /DA, fill and border into /MK /BG and /BC.
    private func applyColor(_ f: FormField, _ prop: String, _ v: ScriptValue) -> Bool {
        var transparent = false
        if case .array(let t) = v, let first = t.first, first.string == "T" { transparent = true }
        let c = Self.colorOf(v)
        if c == nil && !transparent { return false }
        var changed = false
        for w in f.widgets {
            if prop == "textColor" {
                guard let c else { continue }
                let da = DefaultAppearance.parse(w.text("DA") ?? FormEditor.inherited(f.dict, "DA")?.text ?? "/Helv 0 Tf 0 g")
                let op = c.count == 1 ? "g" : c.count == 3 ? "rg" : "k"
                w.set("DA", doc.text("\(da.fontName) \(PdfNum.f(da.size)) Tf \(c.map(PdfNum.f).joined(separator: " ")) \(op)"))
                changed = true
                continue
            }
            if w.dict("MK") == nil {
                if transparent { continue }
                w.set("MK", doc.dict())
            }
            guard let mk = w.dict("MK") else { continue }
            let key = prop == "fillColor" ? "BG" : "BC"
            if let c { mk.set(key, doc.realArray(c)) } else { mk.remove(key) }
            changed = true
        }
        return changed
    }

    /// An Acrobat color array (["RGB", 1, 0, 0], ["G", 0], ["CMYK", ...]) as PDF color components.
    private static func colorOf(_ v: ScriptValue) -> [Double]? {
        guard case .array(let arr) = v, let space = arr.first?.string else { return nil }
        let n = space == "G" ? 1 : space == "RGB" ? 3 : space == "CMYK" ? 4 : 0
        if n == 0 || arr.count < n + 1 { return nil }
        return (0..<n).map { i in
            if case .number(let d) = arr[i + 1], d.isFinite { return min(max(d, 0), 1) }
            return 0
        }
    }

    /// Acrobat's util.printf: %[,sep][flags][width][.precision](d|f|s|x), sep 0 = 1,234.56, 1 = 1234.56, 2 = 1.234,56,
    /// 3 = 1234,56 (default 1); flags + (sign), space, 0 (zero pad), # (ignored), - (left align).
    static func printf(_ a: [ScriptValue]) -> String {
        guard let first = a.first else { return "" }
        let fmt = Array(first.string)
        var sb = ""
        var next = 1
        var i = 0
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        while i < fmt.count && sb.utf16.count < 100_000 {
            defer { i += 1 }
            if fmt[i] != "%" || i + 1 >= fmt.count {
                sb.append(fmt[i])
                continue
            }
            if fmt[i + 1] == "%" {
                sb.append("%")
                i += 1
                continue
            }
            var j = i + 1
            var sep = 1
            if j + 1 < fmt.count && fmt[j] == "," && isDigit(fmt[j + 1]) {
                sep = Int(String(fmt[j + 1])) ?? 1
                j += 2
            }
            var plus = false, space = false, zero = false, left = false
            while j < fmt.count && "+ 0#-".contains(fmt[j]) {
                plus = plus || fmt[j] == "+"
                space = space || fmt[j] == " "
                zero = zero || fmt[j] == "0"
                left = left || fmt[j] == "-"
                j += 1
            }
            var width = 0
            while j < fmt.count && isDigit(fmt[j]) {
                width = min(width * 10 + (Int(String(fmt[j])) ?? 0), 1000)
                j += 1
            }
            var precision = -1
            if j < fmt.count && fmt[j] == "." {
                precision = 0
                j += 1
                while j < fmt.count && isDigit(fmt[j]) {
                    precision = min(precision * 10 + (Int(String(fmt[j])) ?? 0), 20)
                    j += 1
                }
            }
            guard j < fmt.count, "dfsx".contains(fmt[j]) else {
                sb += String(fmt[i..<min(j + 1, fmt.count)])
                i = j
                continue
            }
            let conv = fmt[j]
            let argument = next < a.count ? a[next] : .undefined
            next += 1
            var body: String
            var sign = ""
            if conv == "s" {
                body = argument == .undefined ? "" : argument.string
            } else {
                var d = argument.number
                if !d.isFinite { d = 0 }
                if conv == "x" {
                    let t = min(max(d.rounded(.towardZero), -9.2e18), 9.2e18)
                    let n = Int64(t)
                    body = n < 0 ? String(format: "%llX", UInt64(bitPattern: n)) : String(n, radix: 16, uppercase: true)
                } else {
                    let decimals = conv == "d" ? 0 : precision < 0 ? 6 : precision
                    if conv == "d" { d = d.rounded(.towardZero) }
                    let magnitude = FormScripts.numberToValue(abs(d))
                    body = FormScripts.format(FieldFormat(.number, decimals: decimals, separatorStyle: min(max(sep, 0), 4)), magnitude).text
                    if FormScripts.toNumber(magnitude) == nil { body = "0" }
                }
                sign = d < 0 && body.contains(where: { ("1"..."9").contains($0) }) ? "-" : plus ? "+" : space ? " " : ""
            }
            let len = sign.count + body.count
            if width > len {
                if left {
                    body += String(repeating: " ", count: width - len)
                } else if zero && conv != "s" {
                    body = String(repeating: "0", count: width - len) + body
                } else {
                    sign = String(repeating: " ", count: width - len) + sign
                }
            }
            sb += sign + body
            i = j
        }
        return sb
    }
}
