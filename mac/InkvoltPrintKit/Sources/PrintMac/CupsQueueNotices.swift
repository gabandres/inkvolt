import CCups
import Foundation
import PrintCore
import Synchronization

/// Queue change notices (Windows: the spooler's change notifications, `SpoolerChanges`), all on a thread of its own (libcups
/// keeps a connection per thread, so the app's other libcups calls never wait on it). First CUPS's own: a subscription to
/// cupsd's printer-added, printer-deleted and printer-modified events, pulled with Get-Notifications (RFC 3996's `ippget`;
/// nothing is pushed to a sandboxed app). macOS's cupsd has no subscriptions (27.1: Create-Printer-Subscriptions is
/// 0x501, not supported), so there the list is polled instead: CUPS-Get-Printers' names, device URIs and models every
/// `pull`, a change from the last read a notice. Each notice goes to the app's `QueueChangeNotices`, which reads the queues
/// once a burst is over. A subscription is cancelled on `stop`, and its lease (`lease`) lets cupsd drop it if the app ends
/// without that.
public final class CupsQueueNotices: Sendable {
    /// How often the notices are pulled.
    public static let pull: Duration = .seconds(2)

    /// The subscription's lease in seconds (another is taken when it ends).
    public static let lease: Int32 = 3600

    /// How changes are followed: being set up, CUPS's subscription, or polling the list (with cupsd's words for the refusal).
    public enum Subscription: Sendable, Equatable {
        case asking, taken, polling(String)
    }

    private struct State {
        var running = true
        var subscription = Subscription.asking
        var events = 0
        var listed: Int?
    }

    private let notice: @Sendable () -> Void
    private let state = Mutex(State())

    /// Subscribes and starts pulling on a thread of its own; `notice` is called on that thread for each pull that brought events.
    public init(notice: @escaping @Sendable () -> Void) {
        self.notice = notice
        OwnThread.run("CUPS queue notices") { [weak self] in self?.loop() }
    }

    /// The subscription as it stands now (the report).
    public var subscription: Subscription { state.withLock { $0.subscription } }

    /// Polling: how many queues the last read of the list found (nil before one answered; the report).
    public var listedQueues: Int? { state.withLock { $0.listed } }

    /// How many events were pulled (the report).
    public var events: Int { state.withLock { $0.events } }

    /// Stops pulling; the subscription is cancelled by the loop as it ends.
    public func stop() { state.withLock { $0.running = false } }

    deinit { state.withLock { $0.running = false } }

    private func loop() {
        cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil) // never a password prompt from this thread
        var id = subscribe()
        if id == nil {
            poll()
            return
        }
        var sequence: Int32 = 1
        while state.withLock({ $0.running }), let current = id {
            Thread.sleep(forTimeInterval: Double(Self.pull.components.seconds))
            guard state.withLock({ $0.running }) else { break }
            switch Self.pullEvents(current, from: sequence) {
            case .events(let count, let next):
                sequence = next
                if count > 0 {
                    state.withLock { $0.events += count }
                    notice()
                }
            case .gone:
                // The lease ended or cupsd restarted: subscribe again, and read the queues (events may have been missed).
                id = subscribe()
                sequence = 1
                notice()
            case .failed:
                continue // cupsd busy or restarting: the next pull asks again
            }
        }
        if let id { Self.cancel(id) }
    }

    /// No subscriptions: the queue list read every `pull`, a change from the last read a notice. A read that fails changes
    /// nothing (cupsd busy or restarting).
    private func poll() {
        var last = Self.listed()
        state.withLock { $0.listed = last?.count }
        while state.withLock({ $0.running }) {
            Thread.sleep(forTimeInterval: Double(Self.pull.components.seconds))
            guard state.withLock({ $0.running }), let now = Self.listed() else { continue }
            state.withLock { $0.listed = now.count }
            if let before = last, before != now {
                state.withLock { $0.events += 1 }
                notice()
            }
            last = now
        }
    }

    /// CUPS-Get-Printers, only what the printer list shows of a queue: its name, device URI and model, one line each,
    /// sorted. Nil when cupsd can't be asked.
    private static func listed() -> [String]? {
        guard let request = ippNewRequest(IPP_OP_CUPS_GET_PRINTERS) else { return nil }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        let names: [String] = ["printer-name", "device-uri", "printer-make-and-model"]
        let wanted = names.map { strdup($0) }
        defer { wanted.forEach { free($0) } }
        let values = wanted.map { UnsafePointer($0) }
        values.withUnsafeBufferPointer { list in
            _ = ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", Int32(list.count), nil, list.baseAddress)
        }
        guard let response = cupsDoRequest(nil, request, "/") else { return nil }
        defer { ippDelete(response) }
        let status = ippGetStatusCode(response)
        if status == IPP_STATUS_ERROR_NOT_FOUND { return [] } // no queue at all
        guard status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return nil }
        var lines: [String] = []
        var line = ""
        var attribute = ippFirstAttribute(response)
        while let a = attribute {
            if ippGetGroupTag(a) != IPP_TAG_PRINTER || ippGetName(a) == nil {
                if !line.isEmpty { lines.append(line) }
                line = ""
            } else if let value = ippGetString(a, 0, nil) {
                line += String(cString: ippGetName(a)) + "=" + String(cString: value) + "\n"
            }
            attribute = ippNextAttribute(response)
        }
        if !line.isEmpty { lines.append(line) }
        return lines.sorted()
    }

    /// Create-Printer-Subscriptions on the server (every queue): the events that change the list; its id, or nil (the
    /// reason kept in `subscription`).
    private func subscribe() -> Int32? {
        let result = Self.createSubscription()
        state.withLock {
            switch result {
            case .success: $0.subscription = .taken
            case .failure(let why): $0.subscription = .polling(why.text)
            }
        }
        return try? result.get()
    }

    private struct Refusal: Error {
        let text: String
    }

    private static func request(_ operation: ipp_op_t) -> OpaquePointer? {
        guard let request = ippNewRequest(operation) else { return nil }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/")
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        return request
    }

    private static func createSubscription() -> Result<Int32, Refusal> {
        guard let request = request(IPP_OP_CREATE_PRINTER_SUBSCRIPTIONS) else { return .failure(Refusal(text: "no request made")) }
        ippAddString(request, IPP_TAG_SUBSCRIPTION, IPP_TAG_KEYWORD, "notify-pull-method", nil, "ippget")
        let names: [String] = ["printer-added", "printer-deleted", "printer-modified"]
        let events = names.map { strdup($0) }
        defer { events.forEach { free($0) } }
        let values = events.map { UnsafePointer($0) }
        values.withUnsafeBufferPointer { list in
            _ = ippAddStrings(request, IPP_TAG_SUBSCRIPTION, IPP_TAG_KEYWORD, "notify-events", Int32(list.count), nil, list.baseAddress)
        }
        ippAddInteger(request, IPP_TAG_SUBSCRIPTION, IPP_TAG_INTEGER, "notify-lease-duration", lease)
        guard let response = cupsDoRequest(nil, request, "/") else { return .failure(Refusal(text: lastError())) }
        defer { ippDelete(response) }
        guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return .failure(Refusal(text: lastError())) }
        guard let id = ippFindAttribute(response, "notify-subscription-id", IPP_TAG_INTEGER) else {
            return .failure(Refusal(text: "no subscription id in the answer"))
        }
        return .success(ippGetInteger(id, 0))
    }

    private static func lastError() -> String {
        let message = cupsLastErrorString().map { String(cString: $0) } ?? ""
        return "\(String(cupsLastError().rawValue, radix: 16)) \(message)"
    }

    private enum Pulled {
        case events(count: Int, next: Int32)
        case gone
        case failed
    }

    /// Get-Notifications from `sequence` on: how many events came and the next sequence number to ask for.
    private static func pullEvents(_ id: Int32, from sequence: Int32) -> Pulled {
        guard let request = request(IPP_OP_GET_NOTIFICATIONS) else { return .failed }
        ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "notify-subscription-ids", id)
        ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "notify-sequence-numbers", sequence)
        guard let response = cupsDoRequest(nil, request, "/") else { return .failed }
        defer { ippDelete(response) }
        let status = ippGetStatusCode(response)
        if status == IPP_STATUS_ERROR_NOT_FOUND || status == IPP_STATUS_ERROR_NOT_POSSIBLE { return .gone }
        guard status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return .failed }
        var count = 0
        var next = sequence
        var attribute = ippFirstAttribute(response)
        while let a = attribute {
            if ippGetGroupTag(a) == IPP_TAG_EVENT_NOTIFICATION, let name = ippGetName(a), String(cString: name) == "notify-sequence-number" {
                count += 1
                next = max(next, ippGetInteger(a, 0) + 1)
            }
            attribute = ippNextAttribute(response)
        }
        return .events(count: count, next: next)
    }

    private static func cancel(_ id: Int32) {
        guard let request = request(IPP_OP_CANCEL_SUBSCRIPTION) else { return }
        ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "notify-subscription-id", id)
        if let response = cupsDoRequest(nil, request, "/") { ippDelete(response) }
    }
}
