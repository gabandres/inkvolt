import Foundation

/// What the fixer can repair on the Mac. Resuming a queue and letting it accept jobs are tried from the app (cupsd allows
/// them for an administrator; a standard user may be refused); cancelling the user's own jobs always works. Everything
/// else is a hand-off: steps for System Settings › Printers & Scanners.
public enum RepairKind: CaseIterable, Equatable, Sendable {
    /// Resume-Printer: the queue is paused (printer-state 5).
    case resumeQueue
    /// CUPS-Accept-Jobs: the queue turns new jobs away.
    case acceptJobs
    /// Cancel-Job for the user's own stuck jobs.
    case cancelStuckJobs
    /// Other people's stuck jobs: only an administrator cancels them (hand-off).
    case cancelOthersJobs
    /// The queue's device URI points at the printer's old address: remove it and add it again at the new one (hand-off).
    case addAgainAt
    /// The printer answers at the queue's address, yet macOS shows it offline: remove it and add it again (hand-off).
    case addAgain
}

/// Something the fixer offers to repair, with the steps to do it by hand when Inkvolt Print can't.
public struct Repair: Equatable, Sendable {
    public var kind: RepairKind
    public var title: String
    public var detail: String
    /// The CUPS queue's name (`printer-name`), for the calls; titles and steps use the name people see.
    public var queue: String?
    /// `.addAgainAt`: the address or host name to add it at.
    public var target: String?
    /// `.addAgainAt`: the queue's device URI at `target` (scheme, port and path kept).
    public var targetUri: String?
    public var jobIds: [Int]
    /// Asked before doing it (cancelling jobs).
    public var question: String?
    /// Confirm-button wording for `question`.
    public var confirm: String
    /// Inkvolt Print doesn't do it itself; it only shows the steps.
    public var manualOnly: Bool
    /// Another way to fix the same thing (adding it with its network name instead of its address).
    public var isAlternative: Bool
    public var manualSteps: [String]

    public init(_ kind: RepairKind, _ title: String, _ detail: String, queue: String? = nil, target: String? = nil, targetUri: String? = nil,
                jobIds: [Int] = [], question: String? = nil, confirm: String = "Fix it", manualOnly: Bool = false, isAlternative: Bool = false,
                manualSteps: [String] = []) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.queue = queue
        self.target = target
        self.targetUri = targetUri
        self.jobIds = jobIds
        self.question = question
        self.confirm = confirm
        self.manualOnly = manualOnly
        self.isAlternative = isAlternative
        self.manualSteps = manualSteps
    }
}

/// The steps for each repair in macOS's wording (System Settings › Printers & Scanners), for hand-offs and anything
/// macOS refuses. `queue` is the name Printers & Scanners shows.
public enum ManualSteps {
    private static let printers = "Open System Settings › Printers & Scanners"

    public static func `for`(_ kind: RepairKind, queue: String? = nil, target: String? = nil, uri: String? = nil) -> [String] {
        let q = queue.map { "“\($0)”" } ?? "the printer"
        let openQueue = "\(printers), select \(q), then click Printer Queue…."
        let remove = "\(printers), select \(q) and click Remove Printer…."
        switch kind {
        case .resumeQueue:
            return [openQueue, "In the queue window, click Resume. macOS asks for an administrator's name and password when needed."]
        case .acceptJobs:
            return [remove, "Click Add Printer, Scanner, or Fax… and add it again: macOS accepts jobs for a printer it has just added."]
        case .cancelStuckJobs:
            return [openQueue, "Select each stuck job and click the ✕ beside it. Other people's jobs need an administrator."]
        case .cancelOthersJobs:
            return [openQueue, "Select each stuck job and click the ✕ beside it; macOS asks for an administrator's name and password."]
        case .addAgainAt:
            let (name, path) = protocolOf(uri)
            let queuePart = path.isEmpty ? "" : ", with \(path) as the queue"
            return [remove, "Click Add Printer, Scanner, or Fax…, then IP at the top of the window.",
                    "Enter \(target ?? "the printer's address") as the address and choose \(name) as the protocol\(queuePart), then click Add."]
        case .addAgain:
            return [remove, "Click Add Printer, Scanner, or Fax…, select the printer in the list (macOS finds it on the network), then click Add."]
        }
    }

    /// The Add Printer sheet's protocol for a device URI, and its queue (the URI's path).
    private static func protocolOf(_ uri: String?) -> (String, String) {
        let path = uri.flatMap { URLComponents(string: $0)?.path }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
        return switch CupsQueues.scheme(uri) {
        case "socket": ("HP Jetdirect - Socket", "")
        case "lpd": ("Line Printer Daemon - LPD", path)
        default: ("Internet Printing Protocol - IPP", path)
        }
    }
}

/// The queue operations cupsd protects (operator or admin), as PrintMac's libcups calls make them. Demo mode and tests
/// use fakes.
public protocol QueueControl: Sendable {
    /// IPP Resume-Printer (0x0011) through cupsd. Throws `QueueControlError`.
    func resume(_ queue: String) async throws

    /// CUPS-Accept-Jobs (0x4008) through cupsd. Throws `QueueControlError`.
    func acceptJobs(_ queue: String) async throws
}

public enum QueueControlError: Error, Equatable, Sendable {
    /// cupsd wants an administrator (HTTP 401/403, `IPP_STATUS_ERROR_FORBIDDEN` or `NOT_AUTHORIZED`).
    case refused
    /// Anything else, in plain words.
    case failed(String)
}

public enum RepairOutcomeKind: Equatable, Sendable { case fixed, manual, failed }

/// Result of `RepairRunner`; `steps` is set when the user has to do it by hand.
public struct RepairOutcome: Equatable, Sendable {
    public var kind: RepairOutcomeKind
    public var message: String
    public var steps: [String]

    public init(_ kind: RepairOutcomeKind, _ message: String, _ steps: [String] = []) {
        self.kind = kind
        self.message = message
        self.steps = steps
    }

    public static func fixed(_ message: String) -> RepairOutcome { RepairOutcome(.fixed, message) }
}

/// Carries out a repair: a hand-off shows its steps; the rest is tried once, as this Mac's user (there's no permission
/// prompt in the sandbox), and a refusal becomes the steps.
public enum RepairRunner {
    public static func run(_ repair: Repair, queues: any PrintQueues, control: any QueueControl) async -> RepairOutcome {
        if repair.manualOnly { return RepairOutcome(.manual, "Do this in System Settings:", repair.manualSteps) }
        guard let queue = repair.queue else { return RepairOutcome(.failed, "There's no printer to change.", repair.manualSteps) }
        switch repair.kind {
        case .resumeQueue, .acceptJobs:
            do {
                if repair.kind == .resumeQueue { try await control.resume(queue) } else { try await control.acceptJobs(queue) }
                return .fixed("Done.")
            } catch QueueControlError.refused {
                return RepairOutcome(.manual, "macOS lets only an administrator of this Mac do this from Inkvolt Print. Do it in System Settings, "
                    + "which asks for an administrator's name and password:", repair.manualSteps)
            } catch QueueControlError.failed(let message) {
                return RepairOutcome(.failed, message, repair.manualSteps)
            } catch {
                return RepairOutcome(.failed, String(describing: error), repair.manualSteps)
            }
        case .cancelStuckJobs:
            var done = 0
            var why: String?
            for id in repair.jobIds {
                do {
                    try await queues.cancel(queue, job: id)
                    done += 1
                } catch let e as PrintJobCancelError {
                    why = why ?? e.message
                } catch {
                    why = why ?? String(describing: error)
                }
            }
            guard let why else { return .fixed("Done.") }
            let left = repair.jobIds.count - done
            let message = done == 0 ? why : "\(jobs(done)) \(done == 1 ? "was" : "were") cancelled. The other \(jobs(left)) couldn't be: \(why)"
            return RepairOutcome(.failed, message, repair.manualSteps)
        case .cancelOthersJobs, .addAgainAt, .addAgain:
            return RepairOutcome(.manual, "Do this in System Settings:", repair.manualSteps)
        }
    }

    private static func jobs(_ n: Int) -> String { n == 1 ? "1 job" : "\(n) jobs" }
}
