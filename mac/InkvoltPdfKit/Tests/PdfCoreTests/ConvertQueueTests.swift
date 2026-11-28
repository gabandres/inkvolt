import Foundation
import Testing
@testable import PdfCore

private func word(_ files: String...) -> ConvertCommand.Request { ConvertCommand.Request(.word, files) }
private func word(_ files: [String]) -> ConvertCommand.Request { ConvertCommand.Request(.word, files) }
private func saved(_ pdf: String) -> ConvertOutcome { .saved((pdf as NSString).deletingPathExtension + ".docx", inDocuments: false, notes: nil) }

/// A value the conversions change and the test reads.
@MainActor
private final class Ref<T> {
    var v: T
    init(_ v: T) { self.v = v }
}

/// Released by a test: a conversion waits on it.
@MainActor
private final class Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for w in waiters { w.resume() }
        waiters = []
    }
}

/// Windows' `ConvertQueueTests`: the conversions Finder asks for, one after another in one copy of the app: each file
/// once, a failure kept to its own file, the rest going on.
@MainActor
struct ConvertQueueTests {
    @Test func EachFileIsConvertedOnceInOrder() async {
        let order = Ref<[String]>([])
        let queue = ConvertQueue { job, _ in
            order.v.append(job.pdf)
            return saved(job.pdf)
        }
        queue.add(word("/a.pdf", "/b.pdf", "/c.pdf"))
        await queue.idle()
        #expect(order.v == ["/a.pdf", "/b.pdf", "/c.pdf"])
        #expect(queue.jobs.allSatisfy { $0.outcome?.result == .saved && $0.state == .done })
    }

    @Test func OneRunsAtATime() async {
        let running = Ref(0), most = Ref(0)
        let queue = ConvertQueue { job, _ in
            running.v += 1
            most.v = max(most.v, running.v)
            try await Task.sleep(nanoseconds: 5_000_000)
            running.v -= 1
            return saved(job.pdf)
        }
        queue.add(word("/a.pdf", "/b.pdf"))
        queue.add(word("/c.pdf")) // another request while the first ones run
        await queue.idle()
        #expect(most.v == 1)
        #expect(queue.jobs.count == 3)
    }

    @Test func AFailureStaysWithItsFileAndTheRestGoOn() async {
        struct Damaged: Error, LocalizedError { var errorDescription: String? { "cannot find startxref" } }
        let queue = ConvertQueue { job, _ in
            switch job.pdf {
            case "/damaged.pdf": throw Damaged()
            case "/locked.pdf": return .failed(.notOpened, "a password is needed")
            default: return saved(job.pdf)
            }
        }
        queue.add(word("/damaged.pdf", "/locked.pdf", "/fine.pdf"))
        await queue.idle()
        let j = queue.jobs
        #expect(j[0].outcome?.result == .failed)
        #expect(j[0].outcome?.message == "cannot find startxref")
        #expect(j[1].outcome?.result == .notOpened)
        #expect(j[2].outcome?.result == .saved)
    }

    @Test func AFileAlreadyWaitingIsNotAddedTwice() async {
        let gate = Gate()
        let seen = Ref<[String]>([])
        let queue = ConvertQueue { job, _ in
            seen.v.append(job.pdf)
            await gate.wait()
            return saved(job.pdf)
        }
        let first = queue.add(word("/a.pdf", "/b.pdf"))
        let again = queue.add(word("/A.pdf", "/b.pdf", "/c.pdf")) // a second call of the service on the same selection
        #expect(first.count == 2)
        #expect(again.map(\.pdf) == ["/c.pdf"])
        gate.release()
        await queue.idle()
        #expect(seen.v == ["/a.pdf", "/b.pdf", "/c.pdf"])

        // Done, it can be converted again (a second copy, "name (2).docx").
        #expect(queue.add(word("/a.pdf")).count == 1)
        await queue.idle()
        #expect(seen.v.count == 4)
    }

    @Test func CancellingStopsTheRunningOneAndThoseWaiting() async {
        let started = Ref(false)
        let queue = ConvertQueue { job, cancel in
            started.v = true
            while !cancel.isCancelled { try await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        }
        queue.add(word("/a.pdf", "/b.pdf"))
        while !started.v { await Task.yield() }
        queue.cancelAll()
        await queue.idle()
        #expect(queue.jobs.allSatisfy { $0.outcome?.result == .cancelled })
    }

    @Test func EveryChangeIsReported() async {
        let changes = Ref<[String]>([])
        let queue = ConvertQueue { job, _ in saved(job.pdf) }
        queue.changed = { changes.v.append("\($0.pdf) \($0.state)") }
        queue.add(word("/a.pdf"))
        await queue.idle()
        #expect(changes.v == ["/a.pdf waiting", "/a.pdf converting", "/a.pdf done"])
    }

    @Test func TheLastOneDoneLeavesTheQueueIdleAlready() async {
        // The conversions window turns Cancel into Close when the last one ends: busy must be false by then.
        let busyAtEnd = Ref<[Bool]>([])
        let queue = ConvertQueue { job, _ in
            await Task.yield()
            return saved(job.pdf)
        }
        queue.changed = { if $0.state == .done { busyAtEnd.v.append(queue.isBusy) } }
        queue.add(word("/a.pdf", "/b.pdf"))
        await queue.idle()
        #expect(busyAtEnd.v == [true, false])
    }

    @Test func TheListIsBounded() async {
        let queue = ConvertQueue { job, _ in saved(job.pdf) }
        for round in 0..<3 {
            queue.add(word((0..<ConvertCommand.maxFiles).map { "/r\(round)/\($0).pdf" }))
            await queue.idle()
        }
        #expect(queue.jobs.count <= ConvertQueue.maxListed, "\(queue.jobs.count) listed")
        #expect(queue.jobs.last?.pdf == "/r2/\(ConvertCommand.maxFiles - 1).pdf") // the oldest finished ones go first
    }

    @Test func IdleIsDoneWithNothingQueued() async {
        let queue = ConvertQueue { job, _ in saved(job.pdf) }
        await queue.idle()
        #expect(!queue.isBusy)
    }

    @Test func AnAnswerHoldsForItsSelectionOnly() async {
        // 500 protected files ask once (ConvertAnswers); another selection, even one queued while these run, asks again.
        let asked = Ref(0)
        let gate = Gate()
        let queue = ConvertQueue { job, _ in
            await gate.wait()
            if job.answers.exportProtected == nil {
                asked.v += 1
                job.answers.exportProtected = true
            }
            return saved(job.pdf)
        }
        let first = queue.add(word("/a.pdf", "/b.pdf"))
        let second = queue.add(word("/c.pdf"))
        #expect(first[0].answers === first[1].answers)
        #expect(first[0].answers !== second[0].answers)
        gate.release()
        await queue.idle()
        #expect(asked.v == 2)
    }

    @Test func NoMoreThanMaxWaitingFilesWait() async {
        let gate = Gate() // the first never ends while the test looks
        let queue = ConvertQueue { job, _ in
            await gate.wait()
            return saved(job.pdf)
        }
        #expect(queue.room == ConvertQueue.maxWaiting)
        queue.add(word((0..<400).map { "/\($0).pdf" }))
        #expect(queue.room == ConvertQueue.maxWaiting - 400)
        for b in 1..<(ConvertQueue.maxWaiting / 400 + 2) {
            queue.add(queue.fit(word((0..<400).map { "/\(b)-\($0).pdf" })).taken)
        }
        #expect(queue.room == 0)
        // Files already waiting aren't cut (add skips them); new ones are, and counted.
        var (taken, cut) = queue.fit(word((0..<400).map { "/\($0).pdf" } + ["/new.pdf"]))
        #expect(taken.files.count == 0 && cut == 1)
        #expect(queue.add(taken).isEmpty)
        (taken, cut) = queue.fit(word("/new.pdf", "/new2.pdf"))
        #expect(taken.files.count == 0 && cut == 2)
        queue.cancelAll()
        gate.release()
        await queue.idle()
    }
}

/// Windows' `LaunchHandoffTests`: how a command-line launch reaches the running copy: a conversion launch waits for it
/// rather than converting alongside.
struct LaunchHandoffTests {
    private final class Slot: LaunchSlot {
        var released = false
        func release() { released = true }
    }

    private func run(_ convert: Bool, owns: Bool, _ forwardsOn: (Int) -> Bool, slot: Bool, waiter: Slot? = nil,
                     waiterFree: Bool = true) -> (way: LaunchHandoff.Way, forwards: Int, waited: TimeInterval) {
        var forwards = 0
        var clock: TimeInterval = 0
        let way = LaunchHandoff.find(convert: convert, own: { owns }, forward: { forwards += 1; return forwardsOn(forwards) },
                                     waiterSlot: { waiterFree ? waiter ?? Slot() : nil }, standaloneSlot: { slot },
                                     elapsed: { clock }, wait: { clock += $0 + 10 })
        return (way, forwards, clock)
    }

    @Test func OnlyAFewConversionLaunchesWaitTheRestGiveUpAtOnce() {
        let r = run(true, owns: false, { _ in false }, slot: true, waiterFree: false)
        #expect(r.way == .dropped && r.forwards == 1 && r.waited == 0)
        let waiter = Slot()
        #expect(run(true, owns: false, { $0 == 2 }, slot: true, waiter: waiter).way == .forwarded)
        #expect(waiter.released)
    }

    @Test func TheFirstLaunchOwnsTheSession() {
        #expect(run(true, owns: true, { _ in false }, slot: true).way == .owner)
    }

    @Test func AnOrdinaryLaunchOpensOnItsOwnWhenTheOwnerDoesntAnswer() {
        let r = run(false, owns: false, { _ in false }, slot: false)
        #expect(r.way == .standalone && r.forwards == 1)
    }

    @Test func AConversionLaunchTriesAgainUntilTheOwnerAnswers() {
        let r = run(true, owns: false, { $0 == 3 }, slot: true)
        #expect(r.way == .forwarded && r.forwards == 3)
    }

    @Test func AConversionLaunchConvertsAloneOnlyAfterAMinuteAndOnlyOneAtATime() {
        let alone = run(true, owns: false, { _ in false }, slot: true)
        #expect(alone.way == .standalone)
        #expect(alone.waited >= LaunchHandoff.convertPatience)
        #expect(run(true, owns: false, { _ in false }, slot: false).way == .dropped)
    }
}

/// Windows' `ConvertLaunchTests`: requests that come together are one batch, a result opens only for a batch of one
/// file, and the app stays up while conversions are left.
struct ConvertLaunchTests {
    private static let t0 = Date(timeIntervalSince1970: 1_794_042_000)

    // ── The options before the command, the files after it ──

    @Test func OptionsAreReadOnlyBeforeTheCommand() {
        let (options, command) = ConvertCommand.splitOptions(["--lang", "es", "--convert-to", "word", "--lang", "--report", "/a.pdf"])
        #expect(options == ["--lang", "es"])
        #expect(command == ["--convert-to", "word", "--lang", "--report", "/a.pdf"])
        let r = ConvertCommand.tryParse(command, folder: "/work").request
        #expect(r?.files.count == 3) // "--lang" and "--report" after the format are files (relative names, made full)
    }

    @Test func WithoutTheCommandEverythingIsOptionsAndFiles() {
        var (options, command) = ConvertCommand.splitOptions(["--lang", "es", "/a.pdf"])
        #expect(options == ["--lang", "es", "/a.pdf"])
        #expect(command.isEmpty)
        (options, command) = ConvertCommand.splitOptions(["--convert-to=word", "/a.pdf"])
        #expect(options.isEmpty)
        #expect(command.count == 2)
    }

    @Test func WhatALaunchLeftOutReachesTheRunningCopy() {
        let launch = ConvertCommand.Request(.word, ["/a.pdf"], overLimit: 3, refused: 1)
        let forwarded = ConvertCommand.toArguments(launch)
        #expect(forwarded[0] == "--convert-to=word:3:1")
        let back = ConvertCommand.tryParse(forwarded).request
        #expect(back?.overLimit == 3 && back?.refused == 1)
        #expect(ConvertCommand.tryParse(["--convert-to=word:-1:0", "/a.pdf"]).error == .unknownFormat)
        #expect(ConvertCommand.tryParse(["--convert-to=word:9", "/a.pdf"]).error == .unknownFormat)
        #expect(ConvertCommand.tryParse(["--convert-to=word:99999999999:0", "/a.pdf"]).error == .unknownFormat)
    }

    // ── Requests gathered into one batch ──

    @Test func LaunchesThatComeTogetherAreOneBatch() {
        var gather = ConvertGather()
        gather.add(word("/a.pdf"), Self.t0)
        gather.add(word("/b.pdf"), Self.t0 + 0.15)
        gather.add(word("/c.pdf"), Self.t0 + 0.3)
        #expect(!gather.isDue(Self.t0 + 0.5))
        #expect(gather.isDue(Self.t0 + 0.3 + ConvertGather.quiet))
        let batch = gather.take()
        #expect(batch.count == 1)
        #expect(batch.first?.files == ["/a.pdf", "/b.pdf", "/c.pdf"])
        #expect(gather.isEmpty)
    }

    @Test func AStreamOfLaunchesIsCutAtTheLongestWait() {
        var gather = ConvertGather()
        for i in 0..<40 { gather.add(word("/\(i).pdf"), Self.t0 + 0.2 * Double(i)) }
        #expect(gather.isDue(Self.t0 + ConvertGather.longest))
        #expect(gather.dueAt == Self.t0 + ConvertGather.longest)
    }

    @Test func NothingGatheredIsNeverDue() {
        var gather = ConvertGather()
        #expect(gather.dueAt == nil)
        #expect(!gather.isDue(Self.t0 + 3600))
        #expect(gather.take().isEmpty)
    }

    @Test func MergingKeepsOrderEachFileOnceAndTheCountsApart() {
        let merged = ConvertCommand.merge([
            ConvertCommand.Request(.word, ["/a.pdf", "/b.pdf"], overLimit: 1, refused: 2),
            ConvertCommand.Request(.excel, ["/x.pdf"]),
            ConvertCommand.Request(.word, ["/B.pdf", "/c.pdf"], refused: 1),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].format == .word)
        #expect(merged[0].files == ["/a.pdf", "/b.pdf", "/c.pdf"])
        #expect(merged[0].overLimit == 1 && merged[0].refused == 3)
        #expect(merged[1].files == ["/x.pdf"])
    }

    @Test func MergedLaunchesStillStopAtTheLimit() {
        let merged = ConvertCommand.merge((0..<(ConvertCommand.maxFiles + 3)).map { word("/\($0).pdf") })
        #expect(merged.count == 1)
        #expect(merged.first?.files.count == ConvertCommand.maxFiles)
        #expect(merged.first?.overLimit == 3)
    }

    @Test func NineLaunchesWithTheWindowIdleShowOneList() {
        var gather = ConvertGather()
        for i in 0..<9 { gather.add(word("/\(i).pdf"), Self.t0 + 0.02 * Double(i)) }
        let batch = gather.take()
        #expect(batch.count == 1)
        #expect(!ConvertCommand.showsNotice(windowReady: true, listOpen: false, busy: false, files: batch.first?.files.count ?? 0))
    }

    @Test func LaunchesHaveSettledOnlyALongWhileAfterTheLast() {
        var gather = ConvertGather()
        #expect(gather.settled(Self.t0)) // nothing ever came
        gather.add(word("/a.pdf"), Self.t0)
        _ = gather.take()
        #expect(!gather.settled(Self.t0 + ConvertGather.quiet))
        #expect(!gather.settled(Self.t0 + ConvertGather.settle - 0.001))
        #expect(gather.settled(Self.t0 + ConvertGather.settle))
        #expect(gather.settledAt == Self.t0 + ConvertGather.settle)
        gather.add(word("/b.pdf"), Self.t0 + 2) // a late request starts the wait again
        #expect(!gather.settled(Self.t0 + ConvertGather.settle))
        #expect(ConvertGather.settle > ConvertGather.longest)
    }

    @MainActor
    @Test func AResultFoldedIntoTheListIsNotOpened() async {
        let gate = Gate()
        let openAtEnd = Ref<Bool?>(nil)
        let queue = ConvertQueue { job, _ in
            await gate.wait()
            openAtEnd.v = job.open // read when written, as the app does
            return .saved(job.pdf + ".docx", inDocuments: false, notes: nil)
        }
        let noticed = queue.add(word("/a.pdf"), open: true)[0]
        #expect(noticed.open)
        noticed.stopOpening() // a second request came: the notice joins the list
        gate.release()
        await queue.idle()
        #expect(openAtEnd.v == false)
    }

    // ── Opening the result ──

    @MainActor
    @Test func OnlyANoticedSingleFileIsOpened() async {
        let queue = ConvertQueue { job, _ in .saved(job.pdf + ".docx", inDocuments: false, notes: nil) }
        let one = queue.add(word("/a.pdf"), open: true)
        let listed = queue.add(word("/b.pdf"))
        let many = queue.add(word("/c.pdf", "/d.pdf"), open: true)
        await queue.idle()
        #expect(one[0].open)
        #expect(!listed[0].open)
        #expect(many.allSatisfy { !$0.open })
    }

    // ── Staying up for conversions ──

    @Test(arguments: [
        (false, false, false, 0, true),
        (true, false, false, 0, false), // a document window is open
        (false, true, false, 0, false), // the conversions window is open
        (false, false, true, 0, false), // conversions left (gathering or queued): they finish, then it quits
        (false, false, false, 1, false), // a launch's files read but not handled yet
    ])
    func TheAppExitsOnlyWithNothingLeft(_ c: (Bool, Bool, Bool, Int, Bool)) {
        #expect(ConvertCommand.mayExit(mainOpen: c.0, listOpen: c.1, converting: c.2, forwards: c.3) == c.4)
    }
}
