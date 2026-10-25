import XCTest
#if canImport(ClearKeep)
@testable import ClearKeep
#endif

final class OptimizationCoreTests: XCTestCase {
    func test_visualDistanceFailureDoesNotGroupAndMatchingAnchorsAreBounded() {
        let candidates = (0..<4000).map { CKMediaCandidate(id: "\($0)", kind: .photo, createdAt: Date(timeIntervalSince1970: 0)) }
        var calls = 0
        let groups = SimilarityEngine.group(candidates: candidates, threshold: 0.2) { _, _ in calls += 1; return 1 }
        XCTAssertTrue(groups.isEmpty)
        XCTAssertLessThanOrEqual(calls, candidates.count * 8)
    }
    func test_keeperReasonsAreStableAndCompareDoesNotMutateDeletion() {
        let a = CKMediaCandidate(id: "a", kind: .photo, pixelWidth: 4000, pixelHeight: 3000)
        let b = CKMediaCandidate(id: "b", kind: .photo, pixelWidth: 100, pixelHeight: 100)
        XCTAssertEqual(KeeperPolicy.suggest([a,b]), KeeperPolicy.suggest([b,a]))
        XCTAssertEqual(KeeperPolicy.suggest([a,b])?.reasons, [.higherResolution])
        var compare = ComparisonState(firstID: "a", secondID: "b", keeperID: "a")
        compare.chooseKeeper("b")
        XCTAssertEqual(compare.keeperID, "b")
    }
    func test_rulesUnionAndLimitedUnknownFailClosedAndDateBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let rules = ProtectionRules(protectedAlbumIDs: ["album"], recentDays: 7)
        let c = CKMediaCandidate(id: "a", kind: .photo, createdAt: nil, isFavorite: true)
        let unknown = rules.evaluate(candidates: [c], albumSnapshot: .init(fullAccess: false), now: now)
        XCTAssertTrue(unknown.unknownBoundary)
        XCTAssertTrue(unknown.excludedIDs.contains("a"))
        let known = rules.evaluate(candidates: [c], albumSnapshot: .init(fullAccess: true, membersByAlbumID: ["album": ["a"]]), now: now)
        XCTAssertEqual(known.reasonCodes["a"], ["favorite","album","recent"])
        XCTAssertFalse(known.unknownBoundary)
    }
    func test_recommendationExcludesProtectedAndKeepsGroupsIntact() {
        let candidates = [CKMediaCandidate(id: "protected",kind: .video,estimatedBytes: 1000), CKMediaCandidate(id: "v",kind: .video,estimatedBytes: 600,previewAvailable: true), CKMediaCandidate(id: "g1",groupID: "g",kind: .exactDuplicate,estimatedBytes: 200), CKMediaCandidate(id: "g2",groupID: "g",kind: .exactDuplicate,estimatedBytes: 200)]
        let result = RecommendationPolicy.rank(candidates: candidates, excludedIDs: ["protected"], unknownBoundary: false, limit: 2)
        XCTAssertEqual(result.first?.candidateIDs, ["v"])
        XCTAssertFalse(result.flatMap(\.candidateIDs).contains("protected"))
        XCTAssertTrue(RecommendationPolicy.rank(candidates: candidates, excludedIDs: [], unknownBoundary: true, limit: 20).isEmpty)
    }
    func test_activityStoreIsIdempotentPrivateAndClearIsIndependent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let store = FileActivityStore(url: url)
        let receipt = ActivityReceipt(operationID: UUID(), kind: .deletion, status: .partial, requestedCount: 10, confirmedCount: 8, unchangedCount: 2, estimatedDeletedSize: .init(bytes: 300, provenance: .estimated))
        try store.upsert(receipt); try store.upsert(receipt)
        XCTAssertEqual(try store.load().count, 1)
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(json.contains("assetID")); XCTAssertFalse(json.contains("album"))
        try store.clear(); XCTAssertEqual(try store.load().count, 0)
    }
    func test_activityRetentionAndEstimatedCompressionNeverClaimsFreed() throws {
        let r = ActivityReceipt(operationID: UUID(), kind: .compression, status: .success, sourceSize: .init(bytes: 100, provenance: .estimated), outputSize: .init(bytes: 50, provenance: .measured))
        XCTAssertEqual(r.comparison?.provenance, .estimated)
        XCTAssertEqual(r.comparison?.bytes, 50)
        XCTAssertFalse(r.comparisonLabel.contains("freed"))
    }
    func test_recentCutoffBoundaryAndSavedCutoffRemainStable() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let candidate = CKMediaCandidate(id: "edge", kind: .photo, createdAt: cutoff)
        let rules = ProtectionRules(recentDays: 7)
        let initial = rules.evaluate(candidates: [candidate], albumSnapshot: .init(fullAccess: true), now: now)
        let restored = rules.evaluate(candidates: [candidate], albumSnapshot: .init(fullAccess: true), now: now.addingTimeInterval(86400), resolvedCutoff: initial.cutoff)
        XCTAssertTrue(initial.excludedIDs.contains("edge")); XCTAssertEqual(initial, restored)
    }
    func test_removedAlbumReasonDoesNotRemoveFavoriteOrOtherAlbumProtection() {
        let c = CKMediaCandidate(id: "a", kind: .photo, isFavorite: true)
        let snapshot = AlbumSnapshot(fullAccess: true, membersByAlbumID: ["one": ["a"], "two": ["a"]])
        XCTAssertEqual(ProtectionRules(protectedAlbumIDs: ["two"]).evaluate(candidates: [c], albumSnapshot: snapshot).reasonCodes["a"], ["favorite","album"])
    }
    func test_similarityDoesNotTransitivelyMergeDissimilarAnchorMembers() {
        let c = ["a","b","c"].map { CKMediaCandidate(id: $0, kind: .photo, createdAt: .distantPast) }
        let result = SimilarityEngine.group(candidates: c, threshold: 0.2) { a,b in a == "a" && b == "c" ? 1 : 0.1 }
        XCTAssertEqual(result.first?.memberIDs, ["a","b"])
    }
    func test_activityRetentionKeepsOnlyNewestTwoHundred() throws {
        let now = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let store = FileActivityStore(url: url, now: { now })
        for i in 0..<205 { try store.upsert(.init(operationID: UUID(), date: now.addingTimeInterval(Double(i)), kind: .deletion, status: .success, confirmedCount: 1)) }
        XCTAssertEqual(try store.load().count, 200)
        XCTAssertEqual(try store.load().last?.date, now.addingTimeInterval(5))
    }
    func test_activityCorruptionDoesNotSilentlyResetHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try FileActivityStore(url: url).load())
    }
    func test_activityTerminalResultCannotBeDowngradedByPendingReplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileActivityStore(url: url), id = UUID()
        try store.upsert(.init(operationID: id,kind: .compression,status: .success))
        try store.upsert(.init(operationID: id,kind: .compression,status: .pendingVerification))
        XCTAssertEqual(try store.load().first?.status, .success)
    }
}
