#if DEBUG
import AVKit
import UIKit

/// First-party synthetic content for reproducible UI review. Never built into Release.
@MainActor enum DebugReviewFixture {
    static func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clearkeep-ui-" + UUID().uuidString)
        let history = FileActivityStore(url: directory.appendingPathComponent("history.json"))
        try? history.upsert(.init(operationID: UUID(), kind: .deletion, status: .partial, requestedCount: 5, confirmedCount: 4, unchangedCount: 1, estimatedDeletedSize: .init(bytes: 230_000_000, provenance: .estimated)))
        let model = AppModel(deletionJournalStore: FileDeletionJournalStore(url: directory.appendingPathComponent("deletion-journal.json")), photoLibrary: DebugFixtureLibrary(), store: StoreService(defaults: UserDefaults(suiteName: "ClearKeep.UIFixture." + UUID().uuidString)!, durableQuota: false, liveEntitlements: false), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: InMemoryProtectedItemStore(), rulesStore: FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json")), activityStore: history, albumSnapshotProvider: { .init(fullAccess: true, membersByAlbumID: ["family": [], "travel": []], titlesByAlbumID: ["family": "Family", "travel": "Travel"]) }, compressionService: VideoCompressionService(operations: FileCompressionOperationStore(directory: directory.appendingPathComponent("compression")), quota: DebugCompressionQuotaLedger()))
        model.finishedOnboarding = true
        model.startScan()
        Task {
            while model.isScanning { await Task.yield() }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--fixture-compare") { model.beginReview(category: .similar); model.path = [.review(.similar), .compare("photo-a", "photo-b")] }
            if args.contains("--fixture-compression") { model.path = [.compression("video")] }
            if args.contains("--fixture-rules") { model.path = [.protectionRules] }
            if args.contains("--fixture-activity") { model.path = [.activity] }
            if args.contains("--fixture-screenshots") { model.beginReview(category: .screenshots); model.path = [.review(.screenshots)] }
            if args.contains("--fixture-large-videos") { model.beginReview(category: .largeVideos); model.path = [.review(.largeVideos)] }
            if args.contains("--fixture-similar") { model.beginReview(category: .similar); model.path = [.review(.similar)] }
        }
        return model
    }

    static func preparedModel(page: String) async -> AppModel {
        let model = makeModel()
        while model.isScanning { await Task.yield() }
        if let category = DebugLayoutGallery.reviewCategory(page) { model.beginReview(category: category) }
        if page == "compare" { model.beginReview(category: .similar) }
        if page == "summary" || page == "result-partial" {
            model.beginReview(category: .screenshots)
            for item in model.items(in: .screenshots) { model.toggle(identifier: item.id) }
        }
        if page == "result-partial" { (model.photoLibrary as? DebugFixtureLibrary)?.partialDeletion = true; await model.deleteSelected() }
        if page == "protected" { model.skipAndProtect(identifier: "screen") }
        if page == "purchase-unavailable" { await model.store.load() }
        return model
    }
}

@MainActor private final class DebugCompressionQuotaLedger: CompressionQuotaLedger {
    private var snapshot = CompressionQuotaSnapshot()
    func read() throws -> CompressionQuotaSnapshot { snapshot }
    func commit(operationID: UUID) throws { snapshot.consumedOperationIDs.insert(operationID) }
}

@MainActor final class DebugFixtureLibrary: PhotoLibraryServing {
    var access: LibraryAccess = .full
    let unavailableAssetCount = 0
    var allVideos: [LibraryItem] { items.filter(\.isVideo) }
    var partialDeletion = false
    var successfulDeletion = false
    var persistence: UserDefaults?
    private var deletedIDs = Set<String>()
    var items: [LibraryItem] = [
        LibraryItem(id: "photo-a", category: .similar, createdAt: Date(timeIntervalSince1970: 1_700_000_000), pixelWidth: 4000, pixelHeight: 3000, duration: 0, estimatedBytes: 4_500_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: "visual-fixture", isSuggestedKeeper: true),
        LibraryItem(id: "photo-b", category: .similar, createdAt: Date(timeIntervalSince1970: 1_700_000_001), pixelWidth: 2000, pixelHeight: 1500, duration: 0, estimatedBytes: 2_500_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: "visual-fixture"),
        LibraryItem(id: "video", category: .largeVideos, createdAt: .distantPast, pixelWidth: 1920, pixelHeight: 1080, duration: 180, estimatedBytes: 850_000_000, isFavorite: false, isEdited: false, isVideo: true, duplicateGroup: nil),
        LibraryItem(id: "screen", category: .screenshots, createdAt: .distantPast, pixelWidth: 1170, pixelHeight: 2532, duration: 0, estimatedBytes: 3_200_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: nil),
        LibraryItem(id: "screen-2", category: .screenshots, createdAt: .distantPast, pixelWidth: 1170, pixelHeight: 2532, duration: 0, estimatedBytes: 2_200_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: nil),
        LibraryItem(id: "recording", category: .screenRecordings, createdAt: .distantPast, pixelWidth: 1170, pixelHeight: 2532, duration: 40, estimatedBytes: 30_200_000, isFavorite: false, isEdited: false, isVideo: true, duplicateGroup: nil),
        LibraryItem(id: "exact-a", category: .exactDuplicates, createdAt: .distantPast, pixelWidth: 2000, pixelHeight: 1500, duration: 0, estimatedBytes: 2_500_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: "exact-fixture"),
        LibraryItem(id: "exact-b", category: .exactDuplicates, createdAt: .distantPast, pixelWidth: 2000, pixelHeight: 1500, duration: 0, estimatedBytes: 2_500_000, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: "exact-fixture")
    ]
    func refreshAccess() {}
    func requestAccess() async -> LibraryAccess { access = .full; return access }
    func manageAccess() {}
    func scanIncrementally(progress: @escaping (Int, Int) -> Void) async throws -> [LibraryItem] { deletedIDs.formUnion(persistence?.stringArray(forKey: "deletedIDs") ?? []); let available = items.filter { !deletedIDs.contains($0.id) }; progress(available.count, available.count); return available }
    func thumbnail(identifier: String, targetSize: CGSize) async -> UIImage? { picture(identifier) }
    func image(identifier: String) async -> UIImage? { picture(identifier) }
    func playerItem(identifier: String) async -> AVPlayerItem? { guard let url = try? await DebugLayoutVideo.url() else { return nil }; return AVPlayerItem(url: url) }
    func existingIdentifiers(_ identifiers: Set<String>) -> Set<String> { identifiers.intersection(Set(items.map(\.id))).subtracting(deletedIDs) }
    func delete(identifiers: Set<String>) async throws { if let persistence { persistence.set(persistence.integer(forKey: "deleteCallCount") + 1, forKey: "deleteCallCount") }; guard partialDeletion || successfulDeletion else { if persistence != nil { throw NSError(domain: "PHPhotosErrorDomain", code: 3072) }; throw CancellationError() }; if successfulDeletion { deletedIDs.formUnion(identifiers) } else if let first = identifiers.sorted().first { deletedIDs.insert(first) }; persistence?.set(Array(deletedIDs), forKey: "deletedIDs") }
    private func picture(_ id: String) -> UIImage {
        UIGraphicsImageRenderer(size: .init(width: 600, height: 450)).image { context in
            UIColor(red: 0.79, green: 0.89, blue: 0.91, alpha: 1).setFill(); context.fill(.init(x: 0, y: 0, width: 600, height: 450))
            UIColor.systemTeal.setFill(); UIBezierPath(ovalIn: .init(x: id == "photo-a" ? 70 : 85, y: 90, width: 340, height: 340)).fill()
            UIColor.systemYellow.setFill(); UIBezierPath(ovalIn: .init(x: 420, y: 40, width: 90, height: 90)).fill()
        }
    }
}
#endif
