import Foundation
import Testing
@testable import PdfCore

extension ProGated {
    /// Ported from BatchLongTermTests.cs: Batch's long-term action (roadmap 3.4, `BatchStep.addLongTerm`), Add Verification
    /// Information on each signed file through one client per run, against the local authority of `LtvTestPki`, nothing
    /// needing the internet. In the Pro suites: the command line asks the Pro check. Adapted: a run's cancel token stops it
    /// (Windows' CancellationToken); the stalled server waits with `LtvTestPki.pause`.
    @Suite final class BatchLongTermTests {
        private let root: String

        init() throws {
            root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-batch-ltv-\(NewIds.hex().prefix(8))")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        private func put(_ name: String, _ bytes: [UInt8]) throws -> String {
            let path = ((root as NSString).appendingPathComponent("in") as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            return path
        }

        private var out: String { (root as NSString).appendingPathComponent("out") }

        private func plan(_ steps: BatchStep...) -> BatchPlan { BatchPlan(steps: steps, outputFolder: out) }

        private static func signed(_ pki: LtvTestPki, _ pages: Int = 2) async throws -> [UInt8] {
            try await SigningTests.sign(TestPdf.make(pages), pki.signer.id) { $0.reason = "Approved" }
        }

        private static func run(_ paths: [String], _ plan: BatchPlan, _ host: BatchHost, cancel: CancelToken? = nil) async throws -> BatchSummary {
            try await BatchRunner.run(paths.map { BatchFile($0) }, plan, host, cancel: cancel)
        }

        private static func read(_ path: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path))) }

        private static func first(_ pdf: [UInt8], _ pki: LtvTestPki) throws -> SignatureInfo { try LtvTests.first(pdf, pki) }

        @Test func aMixedBatchSaysPerFileWhatHappenedAndAsksEachServerOnce() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            let one = try await Self.signed(pki, 1)
            let two = try await Self.signed(pki, 3)
            let already = try await Ltv.addVerification(try await Self.signed(pki, 2), nil, pki.client()).pdf
            let hitsBefore = pki.hits.count
            let paths = [try put("one.pdf", one), try put("two.pdf", two), try put("plain.pdf", TestPdf.make(1)), try put("already.pdf", already)]
            let originals = try paths.map(Self.read)

            let summary = try await Self.run(paths, plan(.addLongTerm(timestampUrl: nil)), BatchHost(longTermClient: { pki.client() }))

            #expect(plan(.addLongTerm(timestampUrl: nil)).isSequential)
            for (item, signed) in zip(summary.items.prefix(2), [one, two]) {
                #expect(item.state == .done, "\(item.message)")
                try #require(item.outputs.count == 1)
                let result = try Self.read(item.outputs[0])
                #expect(LtvTests.starts(result, with: signed), "an update after the signed bytes")
                let s = try Self.first(result, pki)
                #expect(s.status == .valid)
                #expect(s.longTerm?.dataComplete == true)
                #expect(item.notes.contains { $0.hasPrefix("Asked 127.0.0.1") }, "\(item.notes)")
            }
            #expect(summary.items[2].state == .skipped)
            #expect(summary.items[2].message.hasPrefix("No signature"))
            #expect(summary.items[3].state == .done)
            #expect(summary.items[3].outputs.isEmpty)
            #expect(summary.items[3].notes.contains { $0.hasPrefix("Already long-term") })
            // The originals as they were; the second file's chain was already known to the run: its servers weren't asked again.
            #expect(try paths.map(Self.read) == originals)
            let asked = pki.hits.dropFirst(hitsBefore)
            #expect(asked.filter { $0 == "/ocsp" }.count == 2) // the signer's and the intermediate's, once each: not again for the second file
        }

        @Test func aDocumentTimestampPerFileReachesBLta() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            let path = try put("a.pdf", try await Self.signed(pki))
            let summary = try await Self.run([path], plan(.addLongTerm(timestampUrl: pki.timestampUrl)), BatchHost(longTermClient: { pki.client() }))
            try #require(summary.items.count == 1)
            let item = summary.items[0]
            #expect(item.state == .done, "\(item.message)")
            #expect(try Self.first(try Self.read(item.outputs[0]), pki).longTerm?.level == .blta)
        }

        @Test func offlineAndUnreachableAreToldApartAndASilentServerIsntAskedAgain() async throws {
            let pki = try LtvTestPki()
            let paths = [try put("a.pdf", try await Self.signed(pki, 1)), try put("b.pdf", try await Self.signed(pki, 2))]
            let client: @Sendable () -> LtvClient = { pki.client(10) }
            pki.stop() // the "internet" is gone

            let offline = try await Self.run(paths, plan(.addLongTerm(timestampUrl: nil)), BatchHost(longTermClient: client, isOnline: { false }))
            for i in offline.items {
                #expect(i.state == .failed)
                #expect(i.message.hasPrefix("Offline"), "\(i.message)")
                #expect(i.outputs.isEmpty)
            }

            let started = Date()
            let unreachable = try await Self.run(paths, plan(.addLongTerm(timestampUrl: nil)), BatchHost(longTermClient: client, isOnline: { true }))
            for i in unreachable.items { #expect(i.message.hasPrefix("Couldn't reach the service"), "\(i.message)") }
            #expect(unreachable.items[0].message.contains("can't be reached"))
            #expect(unreachable.items[1].message.contains("wasn't asked again"), "\(unreachable.items[1].message)")
            #expect(Date().timeIntervalSince(started) < (ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 10 : 60))
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []).isEmpty)
        }

        @Test func withoutAClientNothingGoesOnline() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            let summary = try await Self.run([try put("a.pdf", try await Self.signed(pki))], plan(.addLongTerm(timestampUrl: nil)), BatchHost())
            #expect(summary.items[0].state == .failed)
            #expect(summary.items[0].message.contains("may not go online"))
            #expect(pki.hits.isEmpty)
        }

        /// A Mac addition (Windows' window works this out in the app, `BatchLongTermPlan`): what the window before the run
        /// lists, offline: each signed file's addresses once, the timestamp server for each file, and how many files count.
        @Test func theWindowBeforeTheRunListsTheSignedFilesAddressesOnce() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            let paths = [try put("a.pdf", try await Self.signed(pki, 1)), try put("b.pdf", try await Self.signed(pki, 2)),
                         try put("plain.pdf", TestPdf.make(1)), try put("locked.pdf", TestPdf.encrypted(1, "pw"))]
            let client = pki.client()
            let (plan, signed) = Ltv.plan(files: paths, client: client, timestampUrl: pki.timestampUrl, forEachFile: "each file")
            #expect(signed == 2)
            #expect(plan.addresses.first?.kind == .timestamp && plan.addresses.first?.forWhom == "each file")
            #expect(plan.addresses.filter { $0.url.hasSuffix("/ocsp") }.count == 1)
            #expect(plan.addresses.allSatisfy { $0.refusedBecause == nil }) // this client may reach the test's loopback
            #expect(!plan.complete)
            #expect(pki.hits.isEmpty)
            #expect(Ltv.plan(files: [paths[2]], client: client, timestampUrl: nil, forEachFile: "each file").signed == 0)
        }

        @Test func itGoesWithChecksAndExportsOnly() {
            #expect(plan(.addLongTerm(timestampUrl: nil), .reportContents, .export(.text, dpi: 150)).validate(ocrAvailable: false) == nil)
            #expect(plan(.rotate(90), .addLongTerm(timestampUrl: nil)).validate(ocrAvailable: false)?.contains("break their signatures") == true)
            #expect(plan(.addLongTerm(timestampUrl: nil), .addLongTerm(timestampUrl: nil)).validate(ocrAvailable: false)?.contains("twice") == true)
        }

        @Test func cancellingStopsAFileWaitingOnAServerAndSavesNothing() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            pki.override("/ocsp") { body in
                pki.pause(600) // `stop` ends it
                return LtvTestPki.http(200, (try? pki.ocspReply(body)) ?? [])
            }
            let paths = [try put("a.pdf", try await Self.signed(pki, 1)), try put("b.pdf", try await Self.signed(pki, 2))]
            let cancel = CancelToken()
            // A GCD timer, not a sleeping task: it fires while a loaded run keeps the cooperative pool busy.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { cancel.cancel() }
            let started = Date()
            let summary = try await Self.run(paths, plan(.addLongTerm(timestampUrl: nil)), BatchHost(longTermClient: { pki.client(15) }), cancel: cancel)
            #expect(Date().timeIntervalSince(started) < (ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 5 : 60))
            for i in summary.items {
                #expect(i.state == .cancelled, "\(i.message)")
                #expect(i.outputs.isEmpty)
            }
        }

        @Test(arguments: ["oversized", "garbage"])
        func aHostileReplyFailsTheFileAndStoresNothing(_ kind: String) async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            pki.override("/ocsp") { _ in
                LtvTestPki.http(200, kind == "oversized" ? [UInt8](repeating: 0, count: LtvClient.maxOcspReply + 1) : Array("<html>Sign in to the hotel Wi-Fi</html>".utf8))
            }
            for ca in [pki.intermediate!, pki.root!] { pki.override("/crl/\(ca.thumbprint).crl") { _ in LtvTestPki.http(404, []) } }
            let summary = try await Self.run([try put("a.pdf", try await Self.signed(pki))], plan(.addLongTerm(timestampUrl: nil)), BatchHost(longTermClient: { pki.client() }))
            try #require(summary.items.count == 1)
            let item = summary.items[0]
            #expect(item.state == .failed)
            #expect(item.message.hasPrefix("Couldn't reach the service"), "\(item.message)")
            #expect(item.message.contains("Nothing was changed"))
            #expect(item.outputs.isEmpty)
        }

        @Test func presetsKeepTheActionAndItsTimestampServer() throws {
            for step in [BatchStep.addLongTerm(timestampUrl: nil), .addLongTerm(timestampUrl: LtvPlan.suggestedTimestampServer)] {
                let json = BatchPresets.write(BatchPreset(name: "LTV", steps: [step]))
                #expect(try BatchPresets.read(json).steps == [step])
            }
            do {
                _ = try BatchPresets.read(#"{ "format": "Inkvolt PDF batch preset", "version": 1, "actions": [ { "action": "addLongTermData", "timestampServer": "http://127.0.0.1/tsa" } ] }"#)
                Issue.record("a timestamp server on this Mac: refused")
            } catch let e as BatchPresetError {
                #expect(e.message.contains("timestampServer"))
            }
        }

        @Test func theCommandLineRunsItOnlyWithOnline() async throws {
            let pki = try LtvTestPki()
            defer { pki.stop() }
            let input = try put("a.pdf", try await Self.signed(pki))
            let preset = (root as NSString).appendingPathComponent("ltv.json")
            try BatchPresets.save(BatchPreset(name: "LTV", steps: [.addLongTerm(timestampUrl: nil)]), preset)

            func cli(_ args: String...) async -> (code: Int, output: String, error: String) {
                let output = MemoryLines(), error = MemoryLines()
                let code = await BatchCommandLine.run(args, output: output, error: error, host: BatchHost(longTermClient: { pki.client() }), environment: { _ in nil })
                return (code, output.text, error.text)
            }

            let refused = await cli("--batch", preset, input, "--out", out)
            #expect(refused.code == BatchCommandLine.wrong)
            #expect(refused.error.contains("--online"))
            #expect(pki.hits.isEmpty)

            let ran = await cli("--batch", preset, input, "--out", out, "--online")
            #expect(ran.code == BatchCommandLine.done, "\(ran.error)")
            #expect(ran.output.contains("Asked 127.0.0.1"), "\(ran.output)")
            let made = try FileManager.default.contentsOfDirectory(atPath: out)
            try #require(made.count == 1)
            #expect(try Self.first(try Self.read((out as NSString).appendingPathComponent(made[0])), pki).longTerm?.dataComplete == true)
        }
    }
}
