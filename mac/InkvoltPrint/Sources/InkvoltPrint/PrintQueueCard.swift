import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The printer's CUPS queue on its pane (the Windows app's `PrintJobsViewModel`): its jobs, read every few seconds only while
/// the card is on screen, with Cancel for the user's own jobs and Cancel My Jobs.
@MainActor @Observable
final class PrintJobsModel {
    static let interval: Duration = .seconds(3)

    private(set) var jobs: [QueueJob] = []
    private(set) var isLoaded = false
    /// The queue couldn't be read several times in a row; still retrying.
    private(set) var loadError: String?
    var message: String?
    private(set) var cancelling: Set<Int> = []

    let queue: String
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var gate = RefreshGate()

    init(queue: String, app: AppModel) {
        self.queue = queue
        self.app = app
    }

    var user: String { app.queues.user }
    func isMine(_ j: QueueJob) -> Bool { QueueJobText.isOwner(j.owner, user) }
    var offline: Bool { app.queueOffline(queue) }
    var mine: [QueueJob] { jobs.filter { isMine($0) && !cancelling.contains($0.id) && !QueueJobText.isDone($0.state) } }

    /// Reads until the card goes (its task is cancelled).
    func poll() async {
        repeat { await refresh() } while (try? await Task.sleep(for: Self.interval)) != nil
    }

    func refresh() async {
        let ticket = gate.begin()
        guard let read = await app.queues.jobs(queue) else {
            if gate.failed(ticket) {
                loadError = "macOS's printing system isn't answering about this queue. Trying again every few seconds."
                isLoaded = true
                jobs = []
            }
            return
        }
        guard gate.succeeded(ticket) else { return } // a newer read started meanwhile; its list wins
        loadError = nil
        isLoaded = true
        jobs = QueueJobText.order(read)
        cancelling.formIntersection(jobs.map(\.id))
    }

    func cancel(_ j: QueueJob) async {
        message = nil
        cancelling.insert(j.id)
        do {
            try await app.queues.cancel(queue, job: j.id)
        } catch let e as PrintJobCancelError {
            message = "\"\(j.name)\": \(e.message)"
            cancelling.remove(j.id)
        } catch {
            message = "\"\(j.name)\" couldn't be cancelled."
            cancelling.remove(j.id)
        }
        await refresh()
    }

    func cancelMine() async {
        let list = mine
        var failed = 0
        message = nil
        for j in list {
            cancelling.insert(j.id)
            do {
                try await app.queues.cancel(queue, job: j.id)
            } catch {
                failed += 1
                cancelling.remove(j.id)
            }
        }
        if failed > 0 { message = "\(failed) of \(list.count) jobs couldn't be cancelled. They may have just finished." }
        await refresh()
    }
}

struct PrintQueueCard: View {
    @State private var model: PrintJobsModel
    @State private var confirmMine = false

    init(queue: String, app: AppModel) { _model = State(initialValue: PrintJobsModel(queue: queue, app: app)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Print Queue").font(.headline)
                if model.isLoaded && model.loadError == nil {
                    Text(QueueJobText.summary(model.jobs)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.mine.isEmpty {
                    Button(model.mine.count == 1 ? "Cancel My Job…" : "Cancel My Jobs…") { confirmMine = true }
                }
                Button("Open Printers & Scanners") { NSWorkspace.shared.open(SystemSettings.printers) }
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.jobs) { j in JobRow(job: j, model: model) }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .task { await model.poll() }
        .confirmationDialog(confirmText, isPresented: $confirmMine) {
            Button(model.mine.count == 1 ? "Cancel Job" : "Cancel Jobs", role: .destructive) { Task { await model.cancelMine() } }
            Button("Keep", role: .cancel) {}
        }
    }

    private var confirmText: String {
        let mine = model.mine
        guard !mine.isEmpty else { return "" }
        var text = mine.count == 1 ? "Cancel \"\(mine[0].name)\"?" : "Cancel your \(mine.count) print jobs?"
        let others = model.jobs.count - mine.count
        if others > 0 { text += " \(others == 1 ? "1 job" : "\(others) jobs") from other people stay in the queue." }
        return text
    }
}

private struct JobRow: View {
    let job: QueueJob
    let model: PrintJobsModel

    var body: some View {
        let offline = model.offline
        let problem = QueueJobText.isProblem(job.state, printerOffline: offline)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: problem ? "exclamationmark.triangle.fill" : job.state == .processing ? "printer.fill" : "doc")
                .foregroundStyle(problem ? .orange : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                Text(details(offline)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.cancelling.contains(job.id) {
                Text("Cancelling…").font(.caption).foregroundStyle(.secondary)
            } else if model.isMine(job) {
                if !QueueJobText.isDone(job.state) {
                    Button("Cancel") { Task { await model.cancel(job) } }.accessibilityLabel("Cancel \(job.name)")
                }
            } else {
                Text("Only an administrator can cancel it").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func details(_ offline: Bool) -> String {
        var parts = [QueueJobText.status(job.state, printerOffline: offline)]
        let pages = QueueJobText.pages(job.pages, job.pagesPrinted, job.state)
        if !pages.isEmpty { parts.append(pages) }
        parts.append(QueueJobText.submitted(job.submitted, now: Date()))
        if !model.isMine(job) && !job.owner.isEmpty { parts.append(job.owner) }
        return parts.joined(separator: " · ")
    }
}
