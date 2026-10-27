import Foundation
import JavaScriptCore
import ScriptLimits

/// A value crossing between form scripts and their host: what host functions receive and return.
enum ScriptValue: Equatable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScriptValue])
    /// Anything else (an object, a function), as JavaScript's String() of it.
    case object(String)

    var isNullish: Bool { self == .undefined || self == .null }

    /// JavaScript's ToString.
    var string: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return ScriptValue.numberText(d)
        case .string(let s): return s
        case .array(let a): return a.map { $0.isNullish ? "" : $0.string }.joined(separator: ",")
        case .object(let s): return s
        }
    }

    /// JavaScript's ToNumber (for the values hosts take: numbers, numeric strings, booleans).
    var number: Double {
        switch self {
        case .undefined: return .nan
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let d): return d
        case .string(let s), .object(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            return t.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil ? Double(t) ?? .nan : .nan
        case .array(let a): return a.isEmpty ? 0 : a.count == 1 ? a[0].number : .nan
        }
    }

    /// JavaScript's ToBoolean.
    var truthy: Bool {
        switch self {
        case .undefined, .null: return false
        case .bool(let b): return b
        case .number(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// A number as JavaScript writes it ("3", "0.1", "1e+21", "1e-7").
    static func numberText(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }
        if d == d.rounded() && abs(d) < 1e21 { return String(format: "%.0f", d) }
        var s = "\(d)"
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var exp = String(s[s.index(after: e)...])
            let sign = exp.hasPrefix("-") ? "-" : "+"
            exp = String(exp.drop { $0 == "-" || $0 == "+" || $0 == "0" })
            s = String(s[..<e]) + "e" + sign + (exp.isEmpty ? "0" : exp)
        }
        return s
    }
}

/// Why a script didn't finish: it threw (`message` is the error), or it was stopped (`interrupted`: the host's
/// interrupt check said so, for its time limit or because an outward step was declined).
struct ScriptError: Error {
    var message: String
    var interrupted: Bool
}

/// A JavaScript engine for form scripts (JavaScriptCore in the app; a test may bring its own). One engine runs one
/// document's scripts, on one thread at a time. Scripts see only the standard built-ins and what the prelude defines
/// over the host functions; no file, network or system access exists in the engine.
protocol FormScriptEngine: AnyObject {
    /// Asked often while a script runs (on its thread); true ends the script at once, in a way script code can't catch.
    var interrupt: (() -> Bool)? { get set }

    /// Evaluates `prelude` (an expression for a function taking the host object), calls it with an object whose methods
    /// are `host`, and keeps what it returns (the event API). A host function that throws raises an exception in the
    /// script.
    func start(prelude: String, host: [String: ([ScriptValue]) throws -> ScriptValue]) throws

    /// Runs a script in the global scope.
    func run(_ script: String) throws

    /// Calls a function of the event API (`begin`, `end`).
    func call(_ name: String, _ args: [ScriptValue]) throws -> ScriptValue
}

/// Form scripts on JavaScriptCore (the Windows app runs them on Jint). Each engine has its own virtual machine. A
/// running script is stopped by JavaScriptCore's watchdog: every `tick` seconds of the script's CPU time it asks
/// `interrupt`, and ends the script (uncatchably) when that says so; the host keeps the time limits.
final class JavaScriptCoreEngine: FormScriptEngine {
    /// How often a running script is checked (seconds of its CPU time).
    static let tick = 0.02

    /// What the watchdog callback reaches (a C callback can't capture): the interrupt check and the context group.
    private final class Watch {
        var interrupt: (() -> Bool)?
        var group: JSContextGroupRef?
        var stopped = false
    }

    private let vm: JSVirtualMachine
    private let context: JSContext
    private let watch = Watch()
    private var api: JSValue?
    private var exception: JSValue?

    var interrupt: (() -> Bool)? {
        get { watch.interrupt }
        set { watch.interrupt = newValue }
    }

    init() {
        vm = JSVirtualMachine()
        context = JSContext(virtualMachine: vm)
        context.exceptionHandler = { [weak self] _, e in self?.exception = e }
        watch.group = JSContextGetGroup(context.jsGlobalContextRef)
        Self.arm(watch)
    }

    deinit { inkv_js_clear_time_limit(watch.group) }

    private static let check: inkv_js_should_stop = { _, p in
        guard let p else { return true }
        let watch = Unmanaged<Watch>.fromOpaque(p).takeUnretainedValue()
        if watch.interrupt?() == true {
            watch.stopped = true
            return true
        }
        // The watchdog asks once per time limit: armed again for the next tick.
        arm(watch)
        return false
    }

    private static func arm(_ watch: Watch) {
        inkv_js_set_time_limit(watch.group, tick, check, Unmanaged.passUnretained(watch).toOpaque())
    }

    func start(prelude: String, host: [String: ([ScriptValue]) throws -> ScriptValue]) throws {
        let factory = try guarded { context.evaluateScript(prelude) }
        let h = JSValue(newObjectIn: context)!
        for (name, body) in host {
            let fn: @convention(block) () -> JSValue? = { [weak self] in
                guard let ctx = JSContext.current() else { return nil }
                let args = (JSContext.currentArguments() as? [JSValue] ?? []).map { JavaScriptCoreEngine.value($0, depth: 0) }
                do {
                    return self?.js(try body(args)) ?? JSValue(undefinedIn: ctx)
                } catch {
                    ctx.exception = JSValue(newErrorFromMessage: "\(error)", in: ctx)
                    return JSValue(undefinedIn: ctx)
                }
            }
            h.setObject(unsafeBitCast(fn, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }
        api = try guarded { factory?.call(withArguments: [h]) }
    }

    func run(_ script: String) throws {
        _ = try guarded { context.evaluateScript(script) }
    }

    func call(_ name: String, _ args: [ScriptValue]) throws -> ScriptValue {
        guard let fn = api?.objectForKeyedSubscript(name), fn.isObject else { throw ScriptError(message: "no \(name)", interrupted: false) }
        let result = try guarded { fn.call(withArguments: args.map(js)) }
        return result.map { Self.value($0, depth: 0) } ?? .undefined
    }

    /// Runs JavaScript; its exception (or its stop) becomes a Swift error.
    private func guarded(_ body: () -> JSValue?) throws -> JSValue? {
        exception = nil
        watch.stopped = false
        let result = body()
        if watch.stopped { throw ScriptError(message: "stopped", interrupted: true) }
        if let e = exception {
            exception = nil
            throw ScriptError(message: e.toString() ?? "error", interrupted: false)
        }
        return result
    }

    private func js(_ v: ScriptValue) -> JSValue {
        switch v {
        case .undefined: return JSValue(undefinedIn: context)
        case .null: return JSValue(nullIn: context)
        case .bool(let b): return JSValue(bool: b, in: context)
        case .number(let d): return JSValue(double: d, in: context)
        case .string(let s), .object(let s): return JSValue(object: s, in: context)
        case .array(let items):
            let a = JSValue(newArrayIn: context)!
            for (i, item) in items.enumerated() { a.setValue(js(item), at: i) }
            return a
        }
    }

    /// A script value as the host sees it: arrays (up to 10,000 items, 4 levels) item by item, other objects as their
    /// String().
    private static func value(_ v: JSValue, depth: Int) -> ScriptValue {
        if v.isUndefined { return .undefined }
        if v.isNull { return .null }
        if v.isBoolean { return .bool(v.toBool()) }
        if v.isNumber { return .number(v.toDouble()) }
        if v.isString { return .string(v.toString() ?? "") }
        if v.isArray && depth < 4 {
            let n = min(Int(v.forProperty("length")?.toUInt32() ?? 0), 10_000)
            return .array((0..<n).map { value(v.atIndex($0), depth: depth + 1) })
        }
        return .object(v.toString() ?? "")
    }
}
