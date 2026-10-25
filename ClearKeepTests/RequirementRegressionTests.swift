import XCTest
@testable import ClearKeep

@MainActor
final class RequirementRegressionTests: XCTestCase {
    func testCompressionRejectsUnknownAlgorithmWithoutDamagingKnownOperation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCompressionOperationStore(directory: directory)
        let known = CompressionOperation(sourceID: "known", profile: .balanced)
        try store.save(known)
        var future = CompressionOperation(sourceID: "future", profile: .balanced)
        future.algorithmVersion = 999
        XCTAssertThrowsError(try store.save(future))
        XCTAssertEqual(try store.all().map(\.id), [known.id])

        let url = directory.appendingPathComponent("operations.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var operations = try XCTUnwrap(envelope["operations"] as? [[String: Any]])
        operations[0]["algorithmVersion"] = 999
        envelope["operations"] = operations
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertThrowsError(try store.all())
    }

    func testCancelledAndFailedActivityCannotBeDowngradedByDelayedPendingReplay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActivityStore(url: directory.appendingPathComponent("activity.json"))
        for terminal in [ActivityStatus.cancelled, .failed] {
            let id = UUID()
            try store.upsert(.init(operationID: id, kind: .compression, status: terminal, requestedCount: 1))
            try store.upsert(.init(operationID: id, kind: .compression, status: .pendingVerification, requestedCount: 1))
            XCTAssertEqual(try store.load().first { $0.operationID == id }?.status, terminal)
        }
    }

    func testQuotaCommitLostAcknowledgementRecoversOnceAfterRelaunch() async throws {
        let h = RegressionCompressionHarness()
        h.quota.throwAfterNextDurableCommit = true
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected lost quota acknowledgement") }
        catch { }
        let pending = try XCTUnwrap(h.service.activeOperation)
        XCTAssertEqual(pending.state, .pendingVerification)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
        let relaunched = h.newService()
        let complete = try await relaunched.retryVerification(operationID: pending.id, isLifetime: false)
        XCTAssertEqual(complete.state, .completed)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
        XCTAssertEqual(h.library.saveCount, 1)
    }

    func testCompletedOperationWriteFailureRecoversWithoutAnotherSaveOrCharge() async throws {
        let h = RegressionCompressionHarness(); h.operations.failNextCompletedWrite = true
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected completion persistence failure") }
        catch { }
        let pending = try XCTUnwrap(h.service.activeOperation)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
        let completed = try await h.newService().retryVerification(operationID: pending.id, isLifetime: false)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
        XCTAssertEqual(h.library.saveCount, 1)
    }

    func testOutboxAcknowledgementWriteFailureRemainsReplayableWithoutMediaSideEffects() async throws {
        let h = RegressionCompressionHarness()
        let completed = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        h.operations.failNextActivityAcknowledgement = true
        XCTAssertThrowsError(try h.service.acknowledgeActivity(operationID: completed.id))
        let relaunched = h.newService()
        XCTAssertEqual(try relaunched.uncommittedCompletedOperations().map(\.id), [completed.id])
        try relaunched.acknowledgeActivity(operationID: completed.id)
        XCTAssertTrue(try relaunched.uncommittedCompletedOperations().isEmpty)
        XCTAssertEqual(h.library.saveCount, 1)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
    }

    func testActivityRetentionIncludesExactTwelveMonthBoundaryAndExcludesOlderRecord() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cutoff = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -12, to: now))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActivityStore(url: directory.appendingPathComponent("history.json"), now: { now })
        let older = UUID(), exact = UUID(), newer = UUID()
        for (id, date) in [(older, cutoff.addingTimeInterval(-0.001)), (exact, cutoff), (newer, cutoff.addingTimeInterval(0.001))] {
            try store.upsert(.init(operationID: id, date: date, kind: .deletion, status: .success, confirmedCount: 1))
        }
        XCTAssertEqual(Set(try store.load().map(\.operationID)), [exact, newer])
    }

    func testPendingExportRetainsOriginalFreeOrLifetimeOwnershipAcrossEntitlementChanges() async throws {
        for startedWithLifetime in [false, true] {
            let h = RegressionCompressionHarness()
            for _ in 0..<9 { try h.quota.commit(operationID: UUID()) }
            h.library.verificationAllowed = false
            let pending = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: startedWithLifetime, protectionAllowsExport: true)
            XCTAssertEqual(pending.state, .pendingVerification)
            XCTAssertEqual(try h.quota.read().consumedCount, 9)
            h.library.verificationAllowed = true
            let completed = try await h.newService().retryVerification(operationID: pending.id, isLifetime: !startedWithLifetime)
            XCTAssertEqual(completed.state, .completed)
            XCTAssertEqual(try h.quota.read().consumedCount, startedWithLifetime ? 9 : 10)
            XCTAssertEqual(h.library.saveCount, 1)
        }
    }

    func testSuspendedExportRejectsConcurrentWorkAndExplicitCancellationConsumesNothing() async throws {
        let exporter = SuspendedRegressionExporter(), operations = RegressionOperationStore(), quota = RegressionQuotaLedger(), library = RegressionCompressionLibrary()
        let service = VideoCompressionService(exporter: exporter, library: library, operations: operations, quota: quota)
        let task = Task { try await service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true) }
        await exporter.waitUntilExportStarted()
        XCTAssertTrue(service.isBusy)
        do { _ = try await service.preview(sourceID: "source", profile: .balanced); XCTFail("Concurrent preview must not start") }
        catch { XCTAssertEqual(error as? CompressionFailure, .busy) }
        service.cancel()
        do { _ = try await task.value; XCTFail("Export must cancel") }
        catch { XCTAssertEqual(error as? CompressionFailure, .cancelled) }
        XCTAssertFalse(service.isBusy)
        XCTAssertEqual(service.activeOperation?.state, .cancelled)
        XCTAssertEqual(try quota.read().consumedCount, 0)
        XCTAssertEqual(library.saveCount, 0)
        XCTAssertEqual(exporter.cleanedIDs.count, 1)
    }

    func testProductionBatchCompletionAfterSizeChangesResolvesExactlyTwentyOfOneHundredFive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = FakePhotoLibrary(items: (0..<105).map { FakePhotoLibrary.makeItem(id: "screen-\($0)", category: .screenshots) })
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: StoreService(ledger: FakeQuotaLedger(), liveEntitlements: false), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: InMemoryProtectedItemStore(), rulesStore: FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json")), activityStore: FileActivityStore(url: directory.appendingPathComponent("history.json")), albumSnapshotProvider: { .init(fullAccess: true) }, compressionService: RegressionCompressionHarness().newService())
        model.startScan()
        for _ in 0..<1000 { if model.scanState == .complete { break }; await Task.yield() }
        XCTAssertEqual(model.scanState, .complete)
        model.beginReview(category: .screenshots)
        for size in [50, 100, 20] { model.setBatchSize(size) }
        XCTAssertEqual(model.currentReviewBatch?.totalBatches, 6)
        model.completeCurrentBatch()
        let session = try XCTUnwrap(model.reviewSession)
        XCTAssertEqual(session.decisions.values.filter { $0 == .keepForNow }.count, 20)
        XCTAssertEqual(session.candidates.count - session.decisions.values.filter { $0 == .keepForNow }.count, 85)
        XCTAssertEqual(model.currentReviewBatch?.completedCount, 20)
        XCTAssertEqual(model.currentReviewBatch?.number, 1)
        XCTAssertEqual(model.currentReviewBatch?.totalBatches, 5)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertTrue(model.deletionPlanIdentifiers.isEmpty)
    }

    func testStartingAnotherCategoryClearsPriorSelectionsAndProtectionUnlocks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = FakePhotoLibrary.makeItem(id: "protected-screen", category: .screenshots, favorite: true)
        let similar = FakePhotoLibrary.makeItem(id: "similar", category: .similar)
        let library = FakePhotoLibrary(items: [screen, similar])
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: StoreService(ledger: FakeQuotaLedger(), liveEntitlements: false), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: InMemoryProtectedItemStore(), rulesStore: FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json")), activityStore: FileActivityStore(url: directory.appendingPathComponent("history.json")), albumSnapshotProvider: { .init(fullAccess: true) }, compressionService: RegressionCompressionHarness().newService())
        model.startScan()
        for _ in 0..<1000 { if model.scanState == .complete { break }; await Task.yield() }
        XCTAssertEqual(model.scanState, .complete)
        model.beginReview(category: .screenshots)
        model.unlockedIdentifiers.insert(screen.id)
        model.refreshProtection()
        model.toggle(identifier: screen.id)
        XCTAssertEqual(model.selectedIdentifiers, [screen.id])
        model.beginReview(category: .similar)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertTrue(model.unlockedIdentifiers.isEmpty)
        XCTAssertTrue(model.deletionPlanIdentifiers.isEmpty)
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("RequirementRegression-" + UUID().uuidString) }
}

@MainActor private final class RegressionCompressionHarness {
    let operations = RegressionOperationStore()
    let quota = RegressionQuotaLedger()
    let library = RegressionCompressionLibrary()
    lazy var service = newService()
    func newService() -> VideoCompressionService { VideoCompressionService(exporter: RegressionExporter(), library: library, operations: operations, quota: quota) }
}

private final class RegressionOperationStore: CompressionOperationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CompressionOperation] = [:]
    var failNextCompletedWrite = false
    var failNextActivityAcknowledgement = false
    func load(id: UUID) throws -> CompressionOperation? { lock.withLock { values[id] } }
    func all() throws -> [CompressionOperation] { lock.withLock { Array(values.values) } }
    func save(_ operation: CompressionOperation) throws {
        try lock.withLock {
            if operation.state == .completed && failNextCompletedWrite { failNextCompletedWrite = false; throw CompressionFailure.persistence }
            if operation.activityCommitted == true && failNextActivityAcknowledgement { failNextActivityAcknowledgement = false; throw CompressionFailure.persistence }
            values[operation.id] = operation
        }
    }
}

@MainActor private final class RegressionQuotaLedger: CompressionQuotaLedger {
    private var snapshot = CompressionQuotaSnapshot()
    var throwAfterNextDurableCommit = false
    func read() throws -> CompressionQuotaSnapshot { snapshot }
    func commit(operationID: UUID) throws {
        if snapshot.consumedOperationIDs.contains(operationID) { return }
        snapshot.consumedOperationIDs.insert(operationID)
        if throwAfterNextDurableCommit { throwAfterNextDurableCommit = false; throw CompressionFailure.persistence }
    }
}

@MainActor private final class RegressionExporter: VideoCompressionExporting {
    func inspect(sourceID: String) async throws -> CompressionSource { .init(duration: 60, bytes: 1000, bytesAreMeasured: true, hasAudio: false, displayWidth: 100, displayHeight: 100) }
    func availableTemporaryBytes() throws -> Int64 { Int64.max }
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile { .init(url: URL(fileURLWithPath: "/tmp/requirement-regression-not-a-real-video"), bytes: 500) }
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput { .init(bytes: file.bytes, duration: expectedDuration, hasAudio: false, displayWidth: 100, displayHeight: 100) }
    func cleanup(operationID: UUID) throws {}
}

@MainActor private final class RegressionCompressionLibrary: CompressionPhotoLibraryWriting {
    var saveCount = 0
    var verificationAllowed = true
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        saveCount += 1
        let id = "regression-output-\(saveCount)"
        try recordPlaceholder(id)
        return id
    }
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool { verificationAllowed }
    func exists(sourceID: String) -> Bool { true }
}

@MainActor private final class SuspendedRegressionExporter: VideoCompressionExporting {
    private var exportContinuation: CheckedContinuation<CompressionExportedFile, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false
    var cleanedIDs: [UUID] = []
    func waitUntilExportStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func inspect(sourceID: String) async throws -> CompressionSource { .init(duration: 60, bytes: 1000, bytesAreMeasured: true, hasAudio: false, displayWidth: 100, displayHeight: 100) }
    func availableTemporaryBytes() throws -> Int64 { Int64.max }
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile {
        try await withCheckedThrowingContinuation { continuation in
            exportContinuation = continuation; didStart = true
            let waiting = startWaiters; startWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }
    func cancelCurrentExport() { let pending = exportContinuation; exportContinuation = nil; pending?.resume(throwing: CompressionFailure.cancelled) }
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput { throw CompressionFailure.invalidOutput }
    func cleanup(operationID: UUID) throws { cleanedIDs.append(operationID) }
}
