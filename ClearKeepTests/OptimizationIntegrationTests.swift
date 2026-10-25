import XCTest
@testable import ClearKeep

@MainActor final class OptimizationIntegrationTests: XCTestCase {
    private func makeModel(library: FakePhotoLibrary, ledger: FakeQuotaLedger = FakeQuotaLedger(), rules: ProtectionRules = .init(), snapshot: AlbumSnapshot = .init(fullAccess: true), compression: VideoCompressionService? = nil, history: ActivityStoring? = nil) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rulesStore = FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json"))
        try! rulesStore.save(rules)
        return AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: StoreService(ledger: ledger, liveEntitlements: false), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: InMemoryProtectedItemStore(), rulesStore: rulesStore, activityStore: history ?? FileActivityStore(url: directory.appendingPathComponent("activity.json")), albumSnapshotProvider: { snapshot }, compressionService: compression)
    }

    func testProtectedAlbumUnknownBlocksProductionDeletionAndRecommendation() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let library = FakePhotoLibrary(items: [item], access: .limited)
        let model = makeModel(library: library, rules: .init(protectedAlbumIDs: ["album"]), snapshot: .init(fullAccess: false))
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertTrue(model.deletionPlanIdentifiers.isEmpty)
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testProductionDeletionWritesRealHistoryAndClearingHistoryDoesNotResetQuota() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let ledger = FakeQuotaLedger()
        let model = makeModel(library: FakePhotoLibrary(items: [item]), ledger: ledger)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        await model.deleteSelected()
        XCTAssertEqual(model.activityEntries.count, 1)
        XCTAssertEqual(model.activityEntries.first?.confirmedCount, 1)
        XCTAssertEqual(ledger.quota.items, 1)
        model.clearActivity()
        XCTAssertTrue(model.activityEntries.isEmpty)
        XCTAssertEqual(ledger.quota.items, 1)
    }

    func testRecommendedReviewStaysStableAndStartsWithNoDeleteDecisions() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .largeVideos)
        let model = makeModel(library: FakePhotoLibrary(items: [item]))
        model.startScan(); await wait { model.scanState == .complete }
        model.beginRecommendedReview()
        let session = model.reviewSession
        XCTAssertEqual(session?.candidates.map(\.id), ["A"])
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertTrue(model.deletionPlanIdentifiers.isEmpty)
        model.beginRecommendedReview()
        XCTAssertEqual(model.reviewSession, session)
    }

    func testMixedPartialDeletionChargesOnlyConfirmedOrdinaryIDs() async throws {
        let source = FakePhotoLibrary.makeItem(id: "Z-source", category: .largeVideos)
        let ordinary = FakePhotoLibrary.makeItem(id: "A-ordinary", category: .largeVideos)
        let exporter = IntegrationExporter(), writer = IntegrationCompressionLibrary()
        let compression = VideoCompressionService(exporter: exporter, library: writer, operations: FileCompressionOperationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), quota: IntegrationCompressionQuota())
        _ = try await compression.compress(sourceID: source.id, profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let ledger = FakeQuotaLedger(); ledger.quota = .init(items: 99, bytes: 0)
        let library = FakePhotoLibrary(items: [source, ordinary], deleteBehavior: .partial)
        let model = makeModel(library: library, ledger: ledger, compression: compression)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .largeVideos); model.toggle(identifier: source.id); model.toggle(identifier: ordinary.id)
        await model.deleteSelected()
        XCTAssertEqual(model.deleteOutcome.deleted, [ordinary.id])
        XCTAssertEqual(ledger.quota.items, 100)
        await model.deleteSelected()
        XCTAssertEqual(model.deleteOutcome.deleted, [source.id])
        XCTAssertEqual(ledger.quota.items, 100)
    }

    func testMissingCompressionOutputDoesNotExemptOriginalAtExhaustedQuota() async throws {
        let source = FakePhotoLibrary.makeItem(id: "source", category: .largeVideos)
        let writer = IntegrationCompressionLibrary()
        let compression = VideoCompressionService(exporter: IntegrationExporter(), library: writer, operations: FileCompressionOperationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), quota: IntegrationCompressionQuota())
        _ = try await compression.compress(sourceID: source.id, profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        writer.outputExists = false
        let ledger = FakeQuotaLedger(); ledger.quota = .init(items: 100, bytes: 0)
        let library = FakePhotoLibrary(items: [source])
        let model = makeModel(library: library, ledger: ledger, compression: compression)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .largeVideos); model.toggle(identifier: source.id)
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
        XCTAssertEqual(ledger.quota.items, 100)
        XCTAssertNotNil(model.optimizationMessage)
    }

    func testRuleChangeClearsSelectionsAndCannotUnlockAlbumProtection() async {
        let source = FakePhotoLibrary.makeItem(id: "source", category: .largeVideos)
        let library = FakePhotoLibrary(items: [source])
        let model = makeModel(library: library, snapshot: .init(fullAccess: true, membersByAlbumID: ["album": [source.id]]))
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .largeVideos); model.toggle(identifier: source.id)
        model.updateProtectionRules(.init(protectedAlbumIDs: ["album"]))
        model.unlockedIdentifiers.insert(source.id)
        model.toggle(identifier: source.id)
        await model.deleteSelected()
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testLiveFavoriteChangeClearsOldDeletionIntentBeforePhotosRequest() async {
        let item = FakePhotoLibrary.makeItem(id: "source", category: .screenshots)
        let library = FakePhotoLibrary(items: [item])
        let model = makeModel(library: library)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: item.id)
        library.liveProtectionItems = [FakePhotoLibrary.makeItem(id: item.id, category: .screenshots, favorite: true)]
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertNil(model.reviewSession)
    }

    func testScopeChangeDoesNotResurrectDeletionIntentWhenFullAccessReturns() async {
        let item = FakePhotoLibrary.makeItem(id: "source", category: .screenshots)
        let library = FakePhotoLibrary(items: [item])
        let model = makeModel(library: library)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: item.id)
        library.access = .limited; await model.requestPhotoAccess()
        library.access = .full; await model.requestPhotoAccess()
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertNil(model.resumeReviewOffer)
    }

    func testRecentRuleCutoffIsFrozenInPersistedReviewSession() async throws {
        let old = FakePhotoLibrary.makeItem(id: "old", category: .screenshots, createdAt: .distantPast)
        let model = makeModel(library: FakePhotoLibrary(items: [old]), rules: .init(recentDays: 7))
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .screenshots)
        let cutoff = try XCTUnwrap(model.reviewSession?.resolvedRecentCutoff)
        model.refreshProtection(); model.flushReviewCheckpoint()
        XCTAssertEqual(model.reviewSession?.resolvedRecentCutoff, cutoff)
        let saved = try XCTUnwrap(model.resumeReviewOffer)
        let decoded = try JSONDecoder().decode(ReviewCheckpoint.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.session.resolvedRecentCutoff, cutoff)
    }

    func testPendingCheckpointCannotResumeOldDeletesWithUnknownAlbumBoundary() throws {
        let checkpoint = InMemoryReviewCheckpointStore()
        var session = ReviewSession(category: .screenshots, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 10)])
        session.decisions["A"] = .delete
        try checkpoint.save(.init(scopeFingerprint: "full", session: session))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rules = FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json"))
        try rules.save(.init(protectedAlbumIDs: ["album"]))
        let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "A", category: .screenshots)], access: .limited)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: StoreService(ledger: FakeQuotaLedger(), liveEntitlements: false), reviewCheckpointStore: checkpoint, protectedItemStore: InMemoryProtectedItemStore(), rulesStore: rules, activityStore: FileActivityStore(url: directory.appendingPathComponent("history.json")), albumSnapshotProvider: { .init(fullAccess: false) })
        model.resumeReview()
        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertNil(try checkpoint.load())
    }

    func testSelectionChangeDuringCompressionProofCannotExecuteCapturedDeletion() async throws {
        let source = FakePhotoLibrary.makeItem(id: "source", category: .largeVideos)
        let writer = IntegrationCompressionLibrary()
        let compression = VideoCompressionService(exporter: IntegrationExporter(), library: writer, operations: FileCompressionOperationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), quota: IntegrationCompressionQuota())
        _ = try await compression.compress(sourceID: source.id, profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let library = FakePhotoLibrary(items: [source])
        let model = makeModel(library: library, compression: compression)
        model.startScan(); await wait { model.scanState == .complete }
        model.beginReview(category: .largeVideos); model.toggle(identifier: source.id)
        writer.onVerify = { model.setDecision(.undecided, for: source.id) }
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
        XCTAssertEqual(model.result, .changedLibrary)
    }

    func testEditedMetadataInvalidatesOldExactHashButUnchangedIdentityRetainsIt() {
        var checkpoint = ScanCheckpoint()
        XCTAssertTrue(checkpoint.needsAnalysis(identifier: "photo", modificationIdentity: "v1"))
        checkpoint.fingerprints["photo"] = "old-hash"
        XCTAssertFalse(checkpoint.needsAnalysis(identifier: "photo", modificationIdentity: "v1"))
        XCTAssertEqual(checkpoint.fingerprints["photo"], "old-hash")
        XCTAssertTrue(checkpoint.needsAnalysis(identifier: "photo", modificationIdentity: "v2"))
        XCTAssertNil(checkpoint.fingerprints["photo"])
        checkpoint.fingerprints["photo"] = "new-hash"
        XCTAssertTrue(checkpoint.needsAnalysis(identifier: "photo", modificationIdentity: nil))
        XCTAssertNil(checkpoint.fingerprints["photo"])
    }

    func testCompletedCompressionReplaysActivityOnceAndClearDoesNotResurrectIt() async throws {
        let writer = IntegrationCompressionLibrary(), quota = IntegrationCompressionQuota()
        let compression = VideoCompressionService(exporter: IntegrationExporter(), library: writer, operations: FileCompressionOperationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), quota: quota)
        let op = try await compression.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let history = FileActivityStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json"))
        let first = makeModel(library: FakePhotoLibrary(items: []), compression: compression, history: history)
        XCTAssertEqual(first.activityEntries.map(\.operationID), [op.id])
        XCTAssertTrue(try compression.uncommittedCompletedOperations().isEmpty)
        first.clearActivity()
        let relaunched = makeModel(library: FakePhotoLibrary(items: []), compression: compression, history: history)
        XCTAssertTrue(relaunched.activityEntries.isEmpty)
        XCTAssertEqual(try quota.read().consumedCount, 1)
        XCTAssertEqual(writer.saveCount, 1)
    }

    func testActivityWriteFailureLeavesCompressionUnacknowledgedAndExplicitClearDiscardsOutbox() async throws {
        let compression = VideoCompressionService(exporter: IntegrationExporter(), library: IntegrationCompressionLibrary(), operations: FileCompressionOperationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), quota: IntegrationCompressionQuota())
        let op = try await compression.compress(sourceID: "source", profile: .balanced, isLifetime: false, protectionAllowsExport: true)
        let model = makeModel(library: FakePhotoLibrary(items: []), compression: compression, history: FailingIntegrationActivityStore())
        XCTAssertEqual(try compression.uncommittedCompletedOperations().map(\.id), [op.id])
        XCTAssertNotNil(model.optimizationMessage)
        model.clearActivity()
        XCTAssertTrue(try compression.uncommittedCompletedOperations().isEmpty)
    }

    private func wait(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        XCTAssertTrue(predicate())
    }
}

@MainActor private final class IntegrationExporter: VideoCompressionExporting {
    func inspect(sourceID: String) async throws -> CompressionSource { .init(duration: 20, bytes: 1000, bytesAreMeasured: true, hasAudio: false, displayWidth: 100, displayHeight: 100) }
    func availableTemporaryBytes() throws -> Int64 { Int64.max }
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile { .init(url: URL(fileURLWithPath: "/tmp/unused-integration-video"), bytes: 100) }
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput { .init(bytes: 100, duration: expectedDuration, hasAudio: false, displayWidth: 100, displayHeight: 100) }
    func cleanup(operationID: UUID) throws {}
}
@MainActor private final class IntegrationCompressionLibrary: CompressionPhotoLibraryWriting {
    var outputExists = true
    var saveCount = 0
    var onVerify: (() -> Void)?
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { saveCount += 1; try recordPlaceholder("output"); return "output" }
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool { onVerify?(); return outputExists }
    func exists(sourceID: String) -> Bool { sourceID == "output" ? outputExists : true }
}
private final class FailingIntegrationActivityStore: ActivityStoring {
    func load() throws -> [ActivityReceipt] { [] }
    func upsert(_ receipt: ActivityReceipt) throws { throw ActivityStoreError.corrupt }
    func clear() throws {}
}
@MainActor private final class IntegrationCompressionQuota: CompressionQuotaLedger {
    var snapshot = CompressionQuotaSnapshot()
    func read() throws -> CompressionQuotaSnapshot { snapshot }
    func commit(operationID: UUID) throws { snapshot.consumedOperationIDs.insert(operationID) }
}
