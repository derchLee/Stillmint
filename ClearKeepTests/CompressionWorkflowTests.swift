import XCTest
@testable import ClearKeep

@MainActor
final class CompressionWorkflowTests: XCTestCase {
    func testPreviewIsAtMostTenSecondsAndNeverSavesOrConsumesQuota() async throws {
        let harness = CompressionHarness()
        let sample = try await harness.service.preview(sourceID: "source", profile: .balanced)
        XCTAssertEqual(sample.duration, 10)
        XCTAssertEqual(harness.exporter.sampleDurations, [10])
        XCTAssertEqual(harness.library.saveCount, 0)
        XCTAssertEqual(try harness.quota.read().consumedCount, 0)
    }

    func testVerifiedSaveConsumesOneIndependentExportAndKeepsBoth() async throws {
        let h = CompressionHarness()
        let operation = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertEqual(operation.state, .completed)
        XCTAssertEqual(operation.outputID, "output")
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
        XCTAssertEqual(h.library.saveCount, 1)
        XCTAssertTrue(operation.keepsOriginal)
        XCTAssertEqual(operation.receipt?.potentialSavingsBytes, 500)
    }

    func testPendingVerificationRetryNeverResavesAndChargesOnlyOnce() async throws {
        let h = CompressionHarness(); h.library.verified = false
        let pending = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertEqual(pending.state, .pendingVerification)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
        h.library.verified = true
        let done = try await h.service.retryVerification(operationID: pending.id, isLifetime: false)
        _ = try await h.service.retryVerification(operationID: pending.id, isLifetime: false)
        XCTAssertEqual(done.state, .completed)
        XCTAssertEqual(h.library.saveCount, 1)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
    }

    func testUnresolvedSavedOutputBlocksAnotherExportWithoutConsumingAllowance() async throws {
        let h = CompressionHarness(); h.library.verified = false
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        do { _ = try await h.service.compress(sourceID: "another-source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Unresolved save must block another export") }
        catch { }
        XCTAssertEqual(h.library.saveCount, 1)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
    }

    func testCleanupProofRejectsSourceOrOutputThatChangedAfterVerification() async throws {
        let h = CompressionHarness(); h.library.requiresModificationIdentity = true
        h.exporter.source.modificationIdentity = "source-v1"
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        h.library.identities["source"] = "source-v2"
        let sourceChanged = try await h.service.cleanupProof(sourceID: "source", protected: false)
        XCTAssertNil(sourceChanged)
        h.library.identities["source"] = "source-v1"; h.library.identities["output"] = "output-v2"
        let outputChanged = try await h.service.cleanupProof(sourceID: "source", protected: false)
        XCTAssertNil(outputChanged)
    }

    func testCleanupProofRechecksIdentityAfterAsyncVerification() async throws {
        let h = CompressionHarness(); h.library.requiresModificationIdentity = true
        h.exporter.source.modificationIdentity = "source-v1"
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        h.library.onVerify = { h.library.identities["source"] = "source-v2" }
        let proof = try await h.service.cleanupProof(sourceID: "source", protected: false)
        XCTAssertNil(proof)
    }

    func testPlaceholderPersistenceFailureLeavesAmbiguousSaveAndBlocksNewExport() async throws {
        let h = CompressionHarness(); h.operations.failPlaceholderPersistence = true
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected durable mapping failure") }
        catch { }
        XCTAssertEqual(h.service.activeOperation?.state, .pendingVerification)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
        do { _ = try await h.service.compress(sourceID: "another-source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Ambiguous save must block new export") }
        catch { }
        XCTAssertEqual(h.library.saveCount, 1)
    }

    func testExplicitFailureBeforeVideoResourceRegistrationAllowsNewJobWithoutQuotaUse() async throws {
        let h = CompressionHarness(); h.library.saveFailure = .saveIntentFailed
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected pre-resource intent failure") }
        catch { }
        XCTAssertEqual(h.service.activeOperation?.state, .failed)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
        h.library.saveFailure = nil
        let next = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertEqual(next.state, .completed)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
    }

    func testFailureCancellationAndSaveFailureNeverConsume() async throws {
        for failure in [CompressionFailure.exportFailed, .cancelled, .saveFailed, .invalidOutput] {
            let h = CompressionHarness()
            if failure == .saveFailed { h.library.saveFailure = failure }
            else if failure == .invalidOutput { h.exporter.validationFailure = failure }
            else { h.exporter.exportFailure = failure }
            do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected failure") }
            catch { }
            XCTAssertEqual(try h.quota.read().consumedCount, 0)
            XCTAssertEqual(h.exporter.cleaned.count, 1)
        }
    }

    func testTenthAllowedEleventhBlockedButPreviewRemainsFree() async throws {
        let h = CompressionHarness()
        h.quota.snapshot = CompressionQuotaSnapshot(consumedOperationIDs: Set((0..<9).map { _ in UUID() }))
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected allowance exhausted") }
        catch { XCTAssertEqual(error as? CompressionFailure, .purchaseRequired) }
        _ = try await h.service.preview(sourceID: "source", profile: .balanced)
        XCTAssertEqual(try h.quota.read().consumedCount, 10)
        XCTAssertEqual(h.library.saveCount, 1)
    }

    func testLifetimeDoesNotResetConsumedFreeCountAndDistinctJobsCountSeparately() async throws {
        let h = CompressionHarness()
        _ = try await h.service.compress(sourceID: "source", profile: .smaller, isLifetime: false, protectionAllowsExport: true)
        _ = try await h.service.compress(sourceID: "source", profile: .higherQuality, isLifetime: false, protectionAllowsExport: true)
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: true, protectionAllowsExport: true)
        XCTAssertEqual(try h.quota.read().consumedCount, 2)
    }

    func testDiskSpaceFailsBeforeExportWithoutCommercialSizeOrDurationLimit() async throws {
        let h = CompressionHarness(); h.exporter.availableBytes = 1
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true); XCTFail("Expected low space") }
        catch { XCTAssertEqual(error as? CompressionFailure, .insufficientDiskSpace) }
        XCTAssertEqual(h.exporter.exports, 0)
        h.exporter.availableBytes = Int64.max
        h.exporter.source.duration = 20_000
        h.exporter.source.bytes = 40_000_000_000
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertEqual(h.exporter.exports, 1)
    }

    func testProtectionBlocksFullExportButAllowsPreviewAndProofRequiresAccessibleOutput() async throws {
        let h = CompressionHarness()
        do { _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: false); XCTFail("Expected protected") }
        catch { XCTAssertEqual(error as? CompressionFailure, .protectedSource) }
        _ = try await h.service.preview(sourceID: "source", profile: .balanced)
        _ = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let valid = try await h.service.cleanupProof(sourceID: "source", protected: false)
        XCTAssertNotNil(valid)
        let protected = try await h.service.cleanupProof(sourceID: "source", protected: true)
        XCTAssertNil(protected)
        h.library.verified = false
        let absent = try await h.service.cleanupProof(sourceID: "source", protected: false)
        XCTAssertNil(absent)
    }

    func testNoSavingsIsClampedAndReceiptHasNoAssetIdentifiers() async throws {
        let h = CompressionHarness(); h.exporter.outputBytes = 2_000
        let op = try await h.service.compress(sourceID: "sensitive-source-id", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertEqual(op.receipt?.potentialSavingsBytes, 0)
        let data = try JSONEncoder().encode(try XCTUnwrap(op.receipt))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("sensitive-source-id")); XCTAssertFalse(json.contains("output" + "ID"))
    }

    func testUnknownSaveStateAfterCrashNeverExportsOrSavesAgain() async throws {
        let h = CompressionHarness()
        var op = CompressionOperation(sourceID: "source", profile: .balanced)
        op.state = .saving
        try h.operations.save(op)
        let pending = try await h.service.retryVerification(operationID: op.id, isLifetime: false)
        XCTAssertEqual(pending.state, .pendingVerification)
        XCTAssertEqual(h.exporter.exports, 0); XCTAssertEqual(h.library.saveCount, 0)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
    }

    func testFullScopeConfirmedMissingPendingOutputResolvesFailedAndAllowsNewJob() async throws {
        let h = CompressionHarness(); h.library.verified = false
        let pending = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        h.library.confirmedMissing = true
        let failed = try await h.service.retryVerification(operationID: pending.id, isLifetime: false)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(try h.quota.read().consumedCount, 0)
        h.library.verified = true; h.library.confirmedMissing = false
        let newJob = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        XCTAssertNotEqual(newJob.id, pending.id)
        XCTAssertEqual(newJob.state, .completed)
        XCTAssertEqual(h.library.saveCount, 2)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
    }

    func testCompletedReceiptOutboxReplaysUntilAcknowledgedWithoutSavingOrChargingAgain() async throws {
        let h = CompressionHarness()
        let job = try await h.service.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let relaunched = VideoCompressionService(exporter: h.exporter, library: h.library, operations: h.operations, quota: h.quota)
        XCTAssertEqual(try relaunched.uncommittedCompletedOperations().map(\.id), [job.id])
        XCTAssertEqual(try relaunched.uncommittedCompletedOperations().map(\.id), [job.id])
        try relaunched.acknowledgeActivity(operationID: job.id)
        try relaunched.acknowledgeActivity(operationID: job.id)
        XCTAssertTrue(try relaunched.uncommittedCompletedOperations().isEmpty)
        XCTAssertEqual(try h.operations.load(id: job.id)?.activityCommitted, true)
        _ = try await relaunched.retryVerification(operationID: job.id, isLifetime: false)
        XCTAssertEqual(h.library.saveCount, 1)
        XCTAssertEqual(try h.quota.read().consumedCount, 1)
    }

    func testOperationAndQuotaStoresRejectCorruptionAndReplayIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileCompressionOperationStore(directory: directory)
        let op = CompressionOperation(sourceID: "s", profile: .balanced)
        try store.save(op); XCTAssertEqual(try store.load(id: op.id)?.id, op.id)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("operations.json"))
        XCTAssertThrowsError(try store.all())
        let q = MemoryCompressionQuotaLedger()
        try q.commit(operationID: op.id); try q.commit(operationID: op.id)
        XCTAssertEqual(try q.read().consumedCount, 1)
    }
}

@MainActor private final class CompressionHarness {
    let exporter = FakeCompressionExporter()
    let library = FakeCompressionLibrary()
    let operations = MemoryCompressionOperationStore()
    let quota = MemoryCompressionQuotaLedger()
    lazy var service = VideoCompressionService(exporter: exporter, library: library, operations: operations, quota: quota)
}

final class MemoryCompressionOperationStore: CompressionOperationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CompressionOperation] = [:]
    var failPlaceholderPersistence = false
    func all() throws -> [CompressionOperation] { lock.withLock { Array(values.values) } }
    func load(id: UUID) throws -> CompressionOperation? { lock.withLock { values[id] } }
    func save(_ operation: CompressionOperation) throws {
        try lock.withLock {
            if failPlaceholderPersistence && operation.state == .saving && operation.outputID != nil { throw CompressionFailure.persistence }
            values[operation.id] = operation
        }
    }
}
@MainActor final class MemoryCompressionQuotaLedger: CompressionQuotaLedger {
    var snapshot = CompressionQuotaSnapshot()
    func read() throws -> CompressionQuotaSnapshot { snapshot }
    func commit(operationID: UUID) throws { snapshot.consumedOperationIDs.insert(operationID) }
}

@MainActor private final class FakeCompressionExporter: VideoCompressionExporting {
    var source = CompressionSource(duration: 60, bytes: 1_000, bytesAreMeasured: true, hasAudio: true, displayWidth: 1920, displayHeight: 1080)
    var availableBytes: Int64 = Int64.max
    var outputBytes: Int64 = 500
    var exportFailure: CompressionFailure?
    var validationFailure: CompressionFailure?
    var exports = 0
    var sampleDurations: [Double] = []
    var cleaned: [UUID] = []
    func inspect(sourceID: String) async throws -> CompressionSource { source }
    func availableTemporaryBytes() throws -> Int64 { availableBytes }
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile {
        exports += 1
        if let sampleDuration { sampleDurations.append(sampleDuration) }
        if let exportFailure { throw exportFailure }
        return CompressionExportedFile(url: URL(fileURLWithPath: "/tmp/" + operationID.uuidString + ".mp4"), bytes: outputBytes)
    }
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput {
        if let validationFailure { throw validationFailure }
        return CompressionValidatedOutput(bytes: file.bytes, duration: expectedDuration, hasAudio: source.hasAudio, displayWidth: source.displayWidth, displayHeight: source.displayHeight)
    }
    func cleanup(operationID: UUID) throws { cleaned.append(operationID) }
}

@MainActor private final class FakeCompressionLibrary: CompressionPhotoLibraryWriting {
    var saveCount = 0
    var verified = true
    var confirmedMissing = false
    var saveFailure: CompressionFailure?
    var requiresModificationIdentity = false
    var identities = ["source": "source-v1", "output": "output-v1"]
    var onVerify: (() -> Void)?
    func identity(sourceID: String) -> String? { identities[sourceID] }
    func absenceIsConfirmed(outputID: String) -> Bool { confirmedMissing }
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        saveCount += 1
        if let saveFailure { throw saveFailure }
        try recordPlaceholder("output")
        return "output"
    }
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool { onVerify?(); return verified }
    func exists(sourceID: String) -> Bool { true }
}
