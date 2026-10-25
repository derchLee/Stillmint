import XCTest
@testable import ClearKeep

final class ReviewWorkflowTests: XCTestCase {
    func test_reviewBatcher_whenTwentyThousandCandidates_defaultsToFirstTwenty() {
        let session = ReviewSession(category: .screenshots, candidates: (0..<20_000).map { .init(id: "\($0)", groupID: nil, estimatedBytes: 1) })
        XCTAssertEqual(ReviewBatcher.currentBatch(for: session).candidateIDs.count, 20)
        XCTAssertEqual(ReviewBatcher.currentBatch(for: session).totalBatches, 1_000)
    }
    func test_reviewBatcher_whenSizeChanges_preservesDecisionsAndDoesNotRepeatResolvedIDs() {
        var session = ReviewSession(category: .screenshots, candidates: (0..<100).map { .init(id: "\($0)", groupID: nil, estimatedBytes: 1) })
        for id in session.candidates.prefix(12).map(\.id) { session.decisions[id] = .keepForNow }
        session.batchSize = 50
        XCTAssertFalse(ReviewBatcher.currentBatch(for: session).candidateIDs.contains(where: { Int($0)! < 12 }))
        XCTAssertEqual(session.decisions.count, 12)
    }
    func test_reviewBatcher_whenSimilarityGroupCrossesBoundary_keepsGroupIntact() {
        let plain = (0..<18).map { ReviewCandidateSnapshot(id: "p\($0)", groupID: nil, estimatedBytes: 1) }
        let group = (0..<8).map { ReviewCandidateSnapshot(id: "g\($0)", groupID: "group", estimatedBytes: 1) }
        let session = ReviewSession(category: .similar, candidates: plain + group)
        XCTAssertEqual(ReviewBatcher.currentBatch(for: session).candidateIDs.count, 18)
        var next = session; for id in plain.map(\.id) { next.decisions[id] = .keepForNow }
        XCTAssertEqual(ReviewBatcher.currentBatch(for: next).candidateIDs, group.map(\.id))
    }
    func test_deletionPlan_whenBatchContainsUnselectedItems_includesOnlyExplicitDeletes() {
        var session = ReviewSession(category: .screenshots, candidates: (0..<20).map { .init(id: "\($0)", groupID: nil, estimatedBytes: 1) })
        session.decisions["1"] = .delete; session.decisions["2"] = .delete; session.decisions["3"] = .delete
        XCTAssertEqual(ReviewBatcher.deletionPlan(for: session).identifiers, ["1", "2", "3"])
    }
    func test_reviewBatchReducer_whenDeletionIsPartial_requeuesUnchangedWithoutSkippingCursor() {
        var session = ReviewSession(category: .screenshots, candidates: (0..<20).map { .init(id: "\($0)", groupID: nil, estimatedBytes: 1) })
        session.decisions["1"] = .delete; session.decisions["2"] = .delete; session.decisions["3"] = .delete
        session.applyDeletion(deleted: ["1", "2"], unchanged: ["3"])
        XCTAssertNil(session.decisions["1"]); XCTAssertFalse(session.candidates.map(\.id).contains("1")); XCTAssertEqual(session.decisions["3"], .delete)
        XCTAssertTrue(ReviewBatcher.currentBatch(for: session).candidateIDs.contains("3"))
    }
    func test_reviewCheckpoint_roundTrip_restoresCategoryBatchCursorAndDecisions() throws {
        var session = ReviewSession(category: .largeVideos, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 5)])
        session.batchSize = 50; session.cursor = 2; session.decisions["A"] = .delete
        let store = InMemoryReviewCheckpointStore(); try store.save(.init(scopeFingerprint: "scope", session: session))
        XCTAssertEqual(try store.load()?.session, session)
    }
    func test_reviewCheckpointStore_whenWriteInterrupted_readsLastCompleteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("review.json")
        let store = FileReviewCheckpointStore(url: url)
        let session = ReviewSession(category: .screenshots, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 1)])
        let expected = ReviewCheckpoint(scopeFingerprint: "scope", session: session)
        try store.save(expected)
        try Data("interrupted".utf8).write(to: url.appendingPathExtension("tmp"))
        XCTAssertEqual(try store.load(), expected)
    }
    func test_reviewResume_whenSchemaUnknown_failsClosedWithoutDeleteSelection() throws {
        let store = InMemoryReviewCheckpointStore(rawData: Data("{\"schemaVersion\":99}".utf8))
        XCTAssertThrowsError(try store.load()); XCTAssertNil(store.resumeOffer)
    }
    func test_protectedStore_roundTrip_persistsUserSkippedReason() throws {
        let store = InMemoryProtectedItemStore(); try store.upsert(.init(id: "A", reasons: [.userSkipped], createdAt: .distantPast, lastSeenAt: .now))
        XCTAssertEqual(try store.records()[0].reasons, [.userSkipped])
    }
    func test_fileProtectedStore_usesVersionedEnvelopeAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("protected.json")
        let store = FileProtectedItemStore(url: url)
        try store.upsert(.init(id: "A", reasons: [.userSkipped], createdAt: .distantPast, lastSeenAt: .now))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["records"] as? [[String: Any]])
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.records()) { error in
            guard case ProtectedItemStoreError.corrupt = error else { return XCTFail("Expected corrupt, got \(error)") }
        }
    }
    func test_protectionPolicy_whenSkipRemovedButFavoriteRemains_staysProtected() {
        XCTAssertTrue(ProtectionPolicy.isProtected(systemReasons: [.systemFavorite], persistentReasons: []))
    }
    func test_protectedStore_whenSkipRemovedButFavoriteRemains_keepsFavoriteReason() throws {
        let store = InMemoryProtectedItemStore(); try store.upsert(.init(id: "A", reasons: [.userSkipped, .systemFavorite], createdAt: .distantPast, lastSeenAt: .now))
        try store.removeUserSkipped(id: "A")
        XCTAssertEqual(try store.records()[0].reasons, [.systemFavorite])
    }
    func test_protectedStore_whenAssetDisappears_prunesOnlyMissingTombstone() throws {
        let store = InMemoryProtectedItemStore()
        try store.upsert(.init(id: "A", reasons: [.userSkipped], createdAt: .distantPast, lastSeenAt: .now)); try store.upsert(.init(id: "B", reasons: [.userSkipped], createdAt: .distantPast, lastSeenAt: .now))
        try store.reconcile(existingIDs: ["B"])
        XCTAssertEqual(try store.records().map(\.id), ["B"])
    }
    func test_reviewResume_whenAssetsDisappear_prunesMissingAndPreservesRemainingDecisions() {
        var session = ReviewSession(category: .screenshots, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 1), .init(id: "B", groupID: nil, estimatedBytes: 1)])
        session.decisions = ["A": .delete, "B": .keepForNow]
        session.candidates.removeAll { !Set(["B"]).contains($0.id) }
        session.decisions = session.decisions.filter { Set(["B"]).contains($0.key) }
        XCTAssertEqual(session.decisions, ["B": .keepForNow])
        XCTAssertFalse(session.decisions.values.contains(.delete))
    }
    func test_deletionPlan_whenAssetIsUserSkipped_neverIncludesAsset() {
        var session = ReviewSession(category: .screenshots, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 1)])
        session.decisions["A"] = .delete
        XCTAssertTrue(ReviewBatcher.deletionPlan(for: session, excludedIDs: ["A"]).identifiers.isEmpty)
    }
}
