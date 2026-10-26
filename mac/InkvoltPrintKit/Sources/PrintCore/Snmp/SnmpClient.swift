import Synchronization

/// One row of a walked table column: the arcs after the column's prefix, and the value.
public struct SnmpRow: Equatable, Sendable {
    public let index: [UInt32]
    public let value: SnmpValue
}

/// A read-only SNMPv1/v2c manager for one agent: Get, GetNext and (v2c) GetBulk, and table walks built on them. It has no
/// way to send a Set. Each request waits `timeout` and is sent again `retries` times (UDP may drop it); no reply at all is
/// an `SnmpTimeoutError` (the printer is off or has no agent), an error the client can't work around an `SnmpErrorStatus`.
/// A reply that isn't SNMP counts as no reply.
public final class SnmpClient: Sendable {
    /// The read community nearly every printer ships with.
    public static let defaultCommunity = "public"

    public let host: String
    public let version: SnmpVersion
    public let timeout: Duration
    public let retries: Int

    /// Rows a walk reads at most per column (a printer's alert or supply table is far shorter).
    public let maxRows: Int

    private let transport: any SnmpTransport
    private let community: String
    private let lastRequestId: Mutex<Int>

    public init(transport: any SnmpTransport, host: String, version: SnmpVersion, community: String = SnmpClient.defaultCommunity,
                timeout: Duration = .seconds(1), retries: Int = 1, maxRows: Int = 64) {
        self.transport = transport
        self.host = host
        self.version = version
        self.community = community
        self.timeout = timeout
        self.retries = retries
        self.maxRows = maxRows
        lastRequestId = Mutex(Int.random(in: 1..<Int(Int32.max / 2)))
    }

    /// The values of `names`, in order. An object the agent doesn't have comes back as an exception value (SNMPv2's
    /// noSuchObject / noSuchInstance; for v1, whose noSuchName fails the whole request, the request is sent again without
    /// that object).
    public func get(_ names: [Oid]) async throws -> [SnmpVarBind] {
        try await perObject(.getRequest, names, missing: .noSuchObject)
    }

    /// The object after each of `names`; past the last object, endOfMibView (also for v1's noSuchName).
    public func getNext(_ names: [Oid]) async throws -> [SnmpVarBind] {
        try await perObject(.getNextRequest, names, missing: .endOfMibView)
    }

    private func perObject(_ type: SnmpPduType, _ names: [Oid], missing: SnmpValue) async throws -> [SnmpVarBind] {
        var result = [SnmpVarBind?](repeating: nil, count: names.count)
        var pending = Array(names.indices)
        while !pending.isEmpty {
            let reply = try await send(type, 0, 0, pending.map { names[$0] })
            if reply.errorStatus == SnmpMessage.noSuchName && reply.errorIndex >= 1 && reply.errorIndex <= pending.count {
                // v1: that object isn't there (or nothing follows it); ask for the others.
                let i = pending.remove(at: reply.errorIndex - 1)
                result[i] = SnmpVarBind(names[i], missing)
                continue
            }
            try throwOnError(reply)
            guard reply.varBinds.count == pending.count else {
                throw SnmpFormatError("SNMP: the reply doesn't answer every object asked for.")
            }
            for (k, i) in pending.enumerated() { result[i] = reply.varBinds[k] }
            break
        }
        return result.map { $0! }
    }

    /// RFC 3416 §4.2.3 GetBulk (v2c only): `nonRepeaters` objects once, then up to `maxRepetitions` successors of the rest.
    public func getBulk(nonRepeaters: Int, maxRepetitions: Int, _ names: [Oid]) async throws -> [SnmpVarBind] {
        precondition(version == .v2c, "GetBulk is SNMPv2 only.")
        let reply = try await send(.getBulkRequest, nonRepeaters, maxRepetitions, names)
        try throwOnError(reply)
        return reply.varBinds
    }

    /// Walks table columns side by side (GetBulk on v2c, GetNext on v1): for each prefix in `columns`, every object under
    /// it, as (arcs after the prefix, value), in order. A column ends when the agent moves past it, reports the end of its
    /// MIB, or doesn't move forward (a broken agent never loops the walk). When GetBulk fails with an error the walk goes on
    /// with GetNext; an error on GetNext ends the column it names (all of them when it names none), so a table the agent
    /// can't read is empty rather than the whole read failing. No reply at all is still an `SnmpTimeoutError`.
    public func walk(_ columns: [Oid]) async throws -> [[SnmpRow]] {
        var rows = [[SnmpRow]](repeating: [], count: columns.count)
        var at = columns
        var done = [Bool](repeating: false, count: columns.count)
        var repetitions = 16
        var bulk = version == .v2c
        var request = 0
        while request < maxRows * 2 && done.contains(false) {
            request += 1
            let active = columns.indices.filter { !done[$0] }
            let names = active.map { at[$0] }
            let reply: [SnmpVarBind]
            if bulk {
                let r = try await send(.getBulkRequest, 0, repetitions, names)
                if r.errorStatus == SnmpMessage.tooBig && repetitions > 1 {
                    repetitions /= 2 // the reply wouldn't fit a datagram: fewer rows per request
                    continue
                }
                if r.errorStatus != SnmpMessage.noError {
                    bulk = false // some agents fail GetBulk on a table they answer GetNext for
                    continue
                }
                reply = r.varBinds
                if reply.isEmpty { break }
            } else {
                do {
                    reply = try await getNext(names)
                } catch let error as SnmpErrorStatus {
                    if error.index >= 1 && error.index <= active.count {
                        done[active[error.index - 1]] = true
                    } else {
                        for i in active { done[i] = true }
                    }
                    continue
                }
            }
            // Replies come row by row: the successors of every active column, then theirs, and so on (RFC 3416 §4.2.3).
            for (k, binding) in reply.enumerated() {
                let column = active[k % active.count]
                if done[column] { continue }
                guard !binding.value.isException, let index = binding.name.after(columns[column]), binding.name > at[column],
                      rows[column].count < maxRows else {
                    done[column] = true
                    continue
                }
                rows[column].append(SnmpRow(index: index, value: binding.value))
                at[column] = binding.name
            }
        }
        return rows
    }

    private func throwOnError(_ reply: SnmpMessage) throws {
        if reply.errorStatus != SnmpMessage.noError { throw SnmpErrorStatus(status: reply.errorStatus, index: reply.errorIndex) }
    }

    /// Sends a request and waits for its Response (same request-id), trying again on silence. Never anything but a read.
    private func send(_ type: SnmpPduType, _ a: Int, _ b: Int, _ names: [Oid]) async throws -> SnmpMessage {
        precondition([.getRequest, .getNextRequest, .getBulkRequest].contains(type), "Inkvolt Print only reads over SNMP.")
        let id = lastRequestId.withLock { id in
            id = (id + 1) & Int(Int32.max)
            return id
        }
        let request = SnmpMessage(version, community, type, requestId: id, errorStatus: a, errorIndex: b,
                                  varBinds: names.map { SnmpVarBind($0, .null) }).encode()
        for _ in 0...retries {
            guard let bytes = try await transport.send(request, to: host, timeout: timeout) else { continue }
            // Not an SNMP message (garbage, or something else on the port): no answer.
            guard let reply = try? SnmpMessage.decode(bytes) else { continue }
            // Another reply on this socket (a duplicate, or someone else's): not an answer to this request.
            if reply.type != .response || reply.requestId != id || reply.version != version { continue }
            return reply
        }
        throw SnmpTimeoutError(host: host)
    }
}
