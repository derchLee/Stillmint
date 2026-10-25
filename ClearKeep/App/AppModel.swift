import Combine
import CryptoKit
import Foundation
import Photos

enum AppRoute: Hashable {
    case permission, scan, map, summary, purchase, result
    case review(MediaCategory)
    case preview(String)
    case videos, compression(String), compare(String, String), protectionRules, activity
}
enum ScanState: Equatable { case idle, running, paused, failed, complete }
enum ResultState: Equatable { case success, partial, cancelled, failed, changedLibrary, noChanges }

struct DeleteOutcome: Equatable {
    var requested = Set<String>()
    var deleted = Set<String>()
    var unchanged = Set<String>()
    var estimatedDeletedBytes: Int64 = 0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var finishedOnboarding = false
    @Published var path: [AppRoute] = []
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var libraryItems: [LibraryItem] = []
    @Published var selectedIdentifiers = Set<String>()
    @Published var unlockedIdentifiers = Set<String>() { didSet { refreshEffectiveExclusions() } }
    @Published private(set) var scanAnalyzed = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var access: LibraryAccess
    @Published var libraryChanged = false
    @Published private(set) var result: ResultState = .cancelled
    @Published private(set) var deleteOutcome = DeleteOutcome()
    @Published private(set) var deleteError: String?
    @Published private(set) var isDeleting = false
    @Published private(set) var deletionRecoveryPending = false
    private let deletionJournalStore: DeletionJournalStoring
    @Published private(set) var isVerifyingDeletion = false
    @Published private(set) var canCloseUnverifiedDeletion = false
    func closeUnverifiedDeletion() {
        guard canCloseUnverifiedDeletion, !isDeleting, !isVerifyingDeletion else { return }
        do {
            for var entry in try deletionJournalStore.load() where entry.phase == .executing {
                // Only an unknown outcome may be closed. A durable confirmation must
                // still settle its original allowance, even after entitlement changes.
                entry.phase = .confirmed; entry.status = .failed
                entry.confirmedDeleted = []; entry.unchanged = []
                entry.closureReason = "Unverified cleanup closed by you. Some media may have been deleted, but the result could not be proven. No deletion was repeated and no allowance was added or reset."
                try deletionJournalStore.save(entry)
                try finishDeletionJournal(entry)
            }
            clearReviewLifecycle(message: "The unverified cleanup was closed. Start a fresh review; no deletion choices were carried over.")
            retryPendingDeletionVerification()
        } catch { pauseForDeletionRecovery() }
    }
    func retryPendingDeletionVerification() {
        guard !isDeleting, !isVerifyingDeletion else { return }
        isVerifyingDeletion = true
        defer { isVerifyingDeletion = false }
        do {
            for var entry in try deletionJournalStore.load() where entry.phase != .completed {
                if entry.phase == .prepared {
                    entry.unchanged = entry.requested; entry.status = .cancelled; entry.phase = .confirmed
                    try deletionJournalStore.save(entry)
                } else if entry.phase == .executing {
                    // Even Full-scope absence cannot attribute a deletion to this app:
                    // the process may have stopped before Photos was called.
                    throw DeletionRecoveryError.scopeUnknown
                }
                try finishDeletionJournal(entry)
            }
            deletionRecoveryPending = false
            canCloseUnverifiedDeletion = false
        } catch { pauseForDeletionRecovery() }
    }
    private enum DeletionRecoveryError: Error { case scopeUnknown, historyUnavailable }
    private func pauseForDeletionRecovery() {
        deletionRecoveryPending = true
        canCloseUnverifiedDeletion = ((try? deletionJournalStore.load()) ?? []).contains { $0.phase == .executing }
        optimizationMessage = "Cleanup verification is pending. No deletion will be repeated. Retry for free. If the result cannot be proven, you may explicitly close it as unverified without changing your allowance."
    }
    private func finishDeletionJournal(_ original: DeletionJournalEntry) throws {
        var entry = original
        if !entry.quotaCommitted {
            try store.commitJournalDeletion(operationID: entry.id, items: entry.confirmedDeleted.subtracting(entry.exempt).count, bytes: entry.estimatedBytes, consumesFreeAllowance: entry.consumesFreeAllowance)
            entry.quotaCommitted = true; try deletionJournalStore.save(entry)
        }
        if !entry.activityCommitted {
            guard recordActivity(entry.receipt) else { throw DeletionRecoveryError.historyUnavailable }
            entry.activityCommitted = true; try deletionJournalStore.save(entry)
        }
        entry.phase = .completed; try deletionJournalStore.save(entry)
    }
    @Published private(set) var isRequestingPhotoAccess = false
    @Published private(set) var reviewSession: ReviewSession?
    @Published private(set) var resumeReviewOffer: ReviewCheckpoint?
    @Published private(set) var protectedRecords: [ProtectedItemRecord] = []
    @Published var reviewPersistenceMessage: String?
    @Published private(set) var reviewLifecycleMessage: String?
    @Published private(set) var protectionRules = ProtectionRules()
    @Published private(set) var activityEntries: [ActivityReceipt] = []
    @Published var optimizationMessage: String?
    @Published private(set) var compressionOperations: [CompressionOperation] = []
    @Published private(set) var cachedVideos: [LibraryItem] = []
    @Published private(set) var cleanupExemptions = Set<String>()
    let compressionService: VideoCompressionService
    private let rulesStore: FileProtectionRulesStore
    private let activityStore: ActivityStoring
    private let albumSnapshotProvider: () -> AlbumSnapshot
    private var rulesAreHealthy = true
    private var historyIsHealthy = true
    private var cachedAlbums = AlbumSnapshot(fullAccess: false)
    private var evaluatedProtection = ProtectionEvaluation(excludedIDs: [], reasonCodes: [:], unknownBoundary: false, cutoff: nil)
    private var hasInitializedProtection = false
    private(set) var effectiveExcludedIDs = Set<String>()
    let photoLibrary: PhotoLibraryServing
    let store: StoreService
    let reviewCheckpointStore: ReviewCheckpointStoring
    let protectedItemStore: ProtectedItemStoring
    private var scanTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var reviewCheckpointIsHealthy = true
    private var protectedStoreIsHealthy = true

    init(deletionJournalStore: DeletionJournalStoring = FileDeletionJournalStore(), photoLibrary: PhotoLibraryServing? = nil, store: StoreService = StoreService(), reviewCheckpointStore: ReviewCheckpointStoring = FileReviewCheckpointStore(), protectedItemStore: ProtectedItemStoring = FileProtectedItemStore(), rulesStore: FileProtectionRulesStore? = nil, activityStore: ActivityStoring? = nil, albumSnapshotProvider: @escaping () -> AlbumSnapshot = PhotoAlbumAdapter.snapshot, compressionService: VideoCompressionService? = nil) {
        self.deletionJournalStore = deletionJournalStore
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rulesStore = rulesStore ?? FileProtectionRulesStore(url: support.appendingPathComponent("clearkeep-rules-v1.json"))
        self.activityStore = activityStore ?? FileActivityStore(url: support.appendingPathComponent("clearkeep-history-v1.json"))
        self.albumSnapshotProvider = albumSnapshotProvider
        self.compressionService = compressionService ?? VideoCompressionService()
        self.photoLibrary = photoLibrary ?? PhotoLibraryService()
        self.store = store
        self.reviewCheckpointStore = reviewCheckpointStore
        self.protectedItemStore = protectedItemStore
        self.access = self.photoLibrary.access
        do { protectionRules = try self.rulesStore.load() } catch { rulesAreHealthy = false; optimizationMessage = "Protection rules could not be loaded. Cleanup is paused to keep your media safe." }
        do { activityEntries = try self.activityStore.load() } catch { historyIsHealthy = false; optimizationMessage = "Activity could not be read. Clear the unreadable history explicitly before new operations." }
        do { try self.compressionService.recoverInterruptedExports() } catch { optimizationMessage = "Interrupted compression records could not be recovered safely." }
        refreshCompressionOperations()
        replayCompressionActivity()
        self.compressionService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        do { resumeReviewOffer = try reviewCheckpointStore.load() }
        catch { reviewCheckpointIsHealthy = false; resumeReviewOffer = nil; selectedIdentifiers.removeAll(); reviewPersistenceMessage = "Review progress couldn’t be restored. Deletion is disabled until a new review starts." }
        do { protectedRecords = try protectedItemStore.records() }
        catch { protectedStoreIsHealthy = false; protectedRecords = []; selectedIdentifiers.removeAll(); reviewPersistenceMessage = "Protected items couldn’t be loaded. Deletion is disabled to keep them safe." }
        if access == .denied { clearReviewLifecycle(message: "Photo access is off, so saved review progress was cleared.") }
        refreshProtection()
        retryPendingDeletionVerification()
        if let observable = self.photoLibrary as? PhotoLibraryService {
            observable.$access.sink { [weak self] in self?.handleAccessChange($0) }.store(in: &cancellables)
            observable.$changeToken.dropFirst().sink { [weak self] _ in self?.refreshProtection() }.store(in: &cancellables)
        }
    }

    deinit { scanTask?.cancel() }

    func requestPhotoAccess() async {
        guard !isRequestingPhotoAccess else { return }
        isRequestingPhotoAccess = true
        defer { isRequestingPhotoAccess = false }
        handleAccessChange(await photoLibrary.requestAccess())
    }
    func managePhotoAccess() { photoLibrary.manageAccess() }

    func startScan() {
        guard scanTask == nil else { return }
        refreshProtection()
        photoLibrary.setScanProtection(rules: protectionRules, manuallyProtectedIDs: userSkippedIDs)
        scanState = .running
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await photoLibrary.scanIncrementally { [weak self] analyzed, total in
                    self?.scanAnalyzed = analyzed; self?.scanTotal = total
                }
                guard !Task.isCancelled else { scanState = .paused; scanTask = nil; return }
                libraryItems = items
                refreshProtection()
                if protectedStoreIsHealthy {
                    do { try protectedItemStore.reconcile(existingIDs: Set(items.map(\.id))); protectedRecords = try protectedItemStore.records() }
                    catch { protectedStoreIsHealthy = false; selectedIdentifiers.removeAll(); reviewPersistenceMessage = "Protected items couldn’t be reconciled. Deletion is disabled to keep them safe." }
                }
                scanState = .complete; scanTask = nil
            } catch is CancellationError { scanState = .paused; scanTask = nil }
            catch { scanState = .failed; scanTask = nil }
        }
    }

    func pauseScan() { guard scanTask != nil else { return }; scanTask?.cancel() }
    var isScanning: Bool { scanTask != nil }
    var unavailableAssetCount: Int { photoLibrary.unavailableAssetCount }
    var visualUnavailableCount: Int { photoLibrary.visualUnavailableCount }

    func items(in category: MediaCategory) -> [LibraryItem] { protectionUnknown ? [] : libraryItems.filter { (category == .recommended || $0.category == category) && !effectiveExcludedIDs.contains($0.id) } }
    func item(identifier: String) -> LibraryItem? { libraryItems.first { $0.id == identifier } ?? cachedVideos.first { $0.id == identifier } }
    func toggle(identifier: String) {
        guard let item = item(identifier: identifier), !protectionUnknown, !effectiveExcludedIDs.contains(identifier), !item.isProtected || unlockedIdentifiers.contains(identifier) else { return }
        if selectedIdentifiers.contains(identifier) { selectedIdentifiers.remove(identifier) } else { selectedIdentifiers.insert(identifier) }
        setDecision(selectedIdentifiers.contains(identifier) ? .delete : .undecided, for: identifier)
    }

    var userSkippedIDs: Set<String> { Set(protectedRecords.filter { $0.reasons.contains(.userSkipped) }.map(\.id)) }
    var albumSnapshot: AlbumSnapshot { cachedAlbums }
    var protectionEvaluation: ProtectionEvaluation { evaluatedProtection }
    var protectionUnknown: Bool { !rulesAreHealthy || protectionEvaluation.unknownBoundary }
    func refreshProtection() {
        let previous = evaluatedProtection
        let previousAlbums = cachedAlbums
        cachedAlbums = albumSnapshotProvider()
        libraryItems = photoLibrary.refreshedProtectionItems(libraryItems)
        let knownIDs = Set(libraryItems.map(\.id))
        cachedVideos = photoLibrary.refreshedProtectionItems(photoLibrary.allVideos.isEmpty ? libraryItems.filter(\.isVideo) : photoLibrary.allVideos)
        let videos = cachedVideos.filter { !knownIDs.contains($0.id) }
        evaluatedProtection = protectionRules.evaluate(candidates: (libraryItems + videos).map(\.optimizationCandidate), albumSnapshot: cachedAlbums, resolvedCutoff: reviewSession?.resolvedRecentCutoff ?? resumeReviewOffer?.session.resolvedRecentCutoff, manuallyProtectedIDs: userSkippedIDs)
        refreshEffectiveExclusions()
        let changedAlbums = protectionRules.protectedAlbumIDs.contains { previousAlbums.membersByAlbumID[$0] != cachedAlbums.membersByAlbumID[$0] }
        if let active = compressionService.activeOperation, compressionService.isBusy, protectionUnknown || effectiveExcludedIDs.contains(active.sourceID) { compressionService.cancel() }
        let activeProtectionChanged = reviewSession != nil && previous.reasonCodes != evaluatedProtection.reasonCodes
        let savedBoundaryChanged = (reviewSession != nil || resumeReviewOffer != nil) && (previous.unknownBoundary != evaluatedProtection.unknownBoundary || changedAlbums)
        if hasInitializedProtection && (activeProtectionChanged || savedBoundaryChanged) {
            clearReviewLifecycle(message: "Protection changed. Start a fresh review; no deletion choices were carried over.")
            cleanupExemptions.removeAll()
        }
        hasInitializedProtection = true
    }
    private func refreshEffectiveExclusions() {
        effectiveExcludedIDs = Set(evaluatedProtection.reasonCodes.compactMap { id, reasons in
            !reasons.isDisjoint(with: ["album", "recent", "userSkipped"]) || !unlockedIdentifiers.contains(id) ? id : nil
        }).union(userSkippedIDs)
    }
    var recommendations: [RecommendationOpportunity] { RecommendationPolicy.rank(candidates: libraryItems.map(\.optimizationCandidate), excludedIDs: effectiveExcludedIDs, unknownBoundary: protectionUnknown) }
    private var currentProtectionFingerprint: String {
        var components = [String(protectionRules.recentDays ?? 0)]
        for id in protectionRules.protectedAlbumIDs.sorted() { components.append(id); components.append((cachedAlbums.membersByAlbumID[id] ?? []).sorted().joined(separator: "|")) }
        return Data(SHA256.hash(data: Data(components.joined(separator: "\n").utf8))).base64EncodedString()
    }
    var videos: [LibraryItem] { cachedVideos }
    func beginRecommendedReview() {
        guard reviewSession == nil, !protectionUnknown else { return }
        let ids = recommendations.flatMap(\.candidateIDs)
        let byID = Dictionary(uniqueKeysWithValues: libraryItems.map { ($0.id, $0) })
        let snapshots = ids.compactMap { byID[$0] }.map { ReviewCandidateSnapshot(id: $0.id, groupID: $0.duplicateGroup, estimatedBytes: $0.estimatedBytes) }
        guard !snapshots.isEmpty else { return }
        reviewSession = ReviewSession(category: .recommended, candidates: snapshots)
        reviewSession?.resolvedRecentCutoff = evaluatedProtection.cutoff
        reviewSession?.protectionFingerprint = currentProtectionFingerprint
        selectedIdentifiers.removeAll(); persistReview()
        path.append(.review(.recommended))
    }
    func updateProtectionRules(_ value: ProtectionRules) {
        do { try rulesStore.save(value); protectionRules = value; rulesAreHealthy = true; refreshProtection(); cleanupExemptions.removeAll(); selectedIdentifiers.removeAll(); clearReviewLifecycle(message: "Protection rules changed. Start a new review to use the updated rules.") }
        catch { rulesAreHealthy = false; optimizationMessage = "Protection rules could not be saved. Cleanup is paused." }
    }
    func keeperID(for group: SimilarityGroup) -> String? { reviewSession?.keeperOverrides?[group.id] ?? photoLibrary.similarityClusters.first(where: { $0.id == group.id })?.keeper?.id ?? group.items.first(where: \.isSuggestedKeeper)?.id }
    func chooseKeeper(_ id: String, groupID: String) { reviewSession?.keeperOverrides = reviewSession?.keeperOverrides ?? [:]; reviewSession?.keeperOverrides?[groupID] = id; persistReview() }
    func keeperReason(for groupID: String) -> String {
        if reviewSession?.keeperOverrides?[groupID] != nil { return "Your preferred keeper. Deletion choices are unchanged." }
        let reasons = photoLibrary.similarityClusters.first(where: { $0.id == groupID })?.keeper?.reasons ?? []
        return reasons.isEmpty ? "No reliable quality preference. Compare before deciding." : reasons.map { $0 == .higherResolution ? "Higher resolution" : $0 == .sharper ? "Sharper image" : $0 == .favorite ? "You favorited this photo" : "You edited this photo" }.joined(separator: " · ")
    }
    func clearActivity() {
        do {
            for op in try compressionService.uncommittedCompletedOperations() { try compressionService.acknowledgeActivity(operationID: op.id) }
            for var entry in try deletionJournalStore.load() where entry.phase == .confirmed {
                if !entry.quotaCommitted {
                    try store.commitJournalDeletion(operationID: entry.id, items: entry.confirmedDeleted.subtracting(entry.exempt).count, bytes: entry.estimatedBytes, consumesFreeAllowance: entry.consumesFreeAllowance)
                    entry.quotaCommitted = true
                }
                entry.activityCommitted = true; entry.phase = .completed; try deletionJournalStore.save(entry)
            }
            try activityStore.clear(); activityEntries = []; historyIsHealthy = true
        } catch { optimizationMessage = "Activity could not be cleared safely. Please try again." }
    }
    @discardableResult private func recordActivity(_ receipt: ActivityReceipt) -> Bool {
        do { try activityStore.upsert(receipt); activityEntries = try activityStore.load(); historyIsHealthy = true; return true }
        catch { historyIsHealthy = false; optimizationMessage = "Your result is shown, but Activity could not be saved. Further operations are paused until history is repaired."; return false }
    }
    private func replayCompressionActivity() {
        guard historyIsHealthy else { return }
        do { for op in try compressionService.uncommittedCompletedOperations() { recordCompressionActivity(op); if !historyIsHealthy { break } }; refreshCompressionOperations() }
        catch { optimizationMessage = "Completed compression results could not be restored to Activity. Your saved copies and originals are unchanged." }
    }
    var hasUnlimitedAccess: Bool {
        switch store.entitlement { case .lifetime: true; case .legacy(let expiry): expiry > Date(); case .none: false }
    }
    func refreshCompressionOperations() { do { compressionOperations = try compressionService.history(); cleanupExemptions = Set(compressionOperations.filter { $0.state == .completed }.map(\.sourceID)) } catch { cleanupExemptions.removeAll(); optimizationMessage = "Compression records could not be read safely." } }
    func compressVideo(_ id: String, profile: CompressionProfile) async {
        guard historyIsHealthy else { optimizationMessage = "Activity must be readable before starting a new operation."; return }
        await store.refreshEntitlements()
        refreshProtection()
        do {
            let op = try await compressionService.compress(sourceID: id, profile: profile, isLifetime: hasUnlimitedAccess, protectionAllowsExport: !protectionUnknown && !effectiveExcludedIDs.contains(id))
            recordCompressionActivity(op); refreshCompressionOperations()
        } catch {
            optimizationMessage = error.localizedDescription
            refreshCompressionOperations()
            if let op = compressionService.activeOperation { recordCompressionActivity(op) }
        }
    }
    func retryCompression(_ id: UUID) async {
        do { let op = try await compressionService.retryVerification(operationID: id, isLifetime: hasUnlimitedAccess); recordCompressionActivity(op); refreshCompressionOperations() }
        catch { optimizationMessage = error.localizedDescription }
    }
    private func recordCompressionActivity(_ op: CompressionOperation) {
        let status: ActivityStatus = op.state == .completed ? .success : op.state == .cancelled ? .cancelled : op.state == .pendingVerification || op.state == .saving ? .pendingVerification : .failed
        var receipt = ActivityReceipt(operationID: op.id, kind: .compression, status: status, requestedCount: 1, confirmedCount: op.state == .completed ? 1 : 0, sourceSize: op.source.map { .init(bytes: $0.bytes, provenance: $0.bytesAreMeasured ? .measured : .estimated) }, outputSize: op.output.map { .init(bytes: $0.bytes, provenance: .measured) })
        receipt.date = op.createdAt
        if recordActivity(receipt), op.state == .completed {
            do { try compressionService.acknowledgeActivity(operationID: op.id) }
            catch { optimizationMessage = "The compression result is in Activity; its delivery acknowledgement will be retried on restart." }
        }
    }
    func prepareOriginalCleanup(_ sourceID: String) async {
        refreshProtection()
        guard !protectionUnknown, !effectiveExcludedIDs.contains(sourceID), let video = item(identifier: sourceID) else { optimizationMessage = "This original is protected or unavailable."; return }
        do {
            guard try await compressionService.cleanupProof(sourceID: sourceID, protected: false) != nil else { optimizationMessage = "The saved copy could not be verified. Original cleanup allowance is unavailable."; return }
            refreshProtection()
            guard !protectionUnknown, !effectiveExcludedIDs.contains(sourceID), photoLibrary.existingIdentifiers([sourceID]).contains(sourceID) else { optimizationMessage = "Protection or access changed. Review the original again."; return }
            if !libraryItems.contains(where: { $0.id == sourceID }) { libraryItems.append(video) }
            reviewSession = ReviewSession(category: .recommended, candidates: [.init(id: sourceID, groupID: nil, estimatedBytes: video.estimatedBytes)])
            reviewSession?.resolvedRecentCutoff = evaluatedProtection.cutoff
            reviewSession?.protectionFingerprint = currentProtectionFingerprint
            reviewSession?.decisions[sourceID] = .delete
            selectedIdentifiers = [sourceID]; cleanupExemptions = [sourceID]; persistReview(); path.append(.summary)
        } catch { optimizationMessage = error.localizedDescription }
    }
    func beginReview(category: MediaCategory) {
        guard !protectionUnknown else { optimizationMessage = "Protection rules must be verified before starting a new batch."; return }
        // A new review is a new intent, not a continuation of another category's choices.
        selectedIdentifiers.removeAll()
        unlockedIdentifiers.removeAll()
        cleanupExemptions.removeAll()
        reviewCheckpointIsHealthy = true
        let snapshots = items(in: category).filter { !userSkippedIDs.contains($0.id) }.map { ReviewCandidateSnapshot(id: $0.id, groupID: $0.duplicateGroup, estimatedBytes: $0.estimatedBytes) }
        reviewSession = ReviewSession(category: category, candidates: snapshots)
        reviewSession?.resolvedRecentCutoff = evaluatedProtection.cutoff
        reviewSession?.protectionFingerprint = currentProtectionFingerprint
        persistReview()
    }
    var currentReviewBatch: ReviewBatch? { reviewSession.map { ReviewBatcher.currentBatch(for: $0, excludedIDs: effectiveExcludedIDs) } }
    func setBatchSize(_ size: Int) { guard [20, 50, 100].contains(size), reviewSession != nil else { return }; reviewSession?.batchSize = size; reviewSession?.cursor = 0; persistReview() }
    func setDecision(_ decision: ReviewDecision, for id: String) { guard reviewSession?.candidates.contains(where: { $0.id == id }) == true else { return }; reviewSession?.decisions[id] = decision; persistReview() }
    func completeCurrentBatch() { guard var session = reviewSession else { return }; for id in currentReviewBatch?.candidateIDs ?? [] where session.decisions[id] == nil { session.decisions[id] = .keepForNow }; session.cursor = 0; reviewSession = session; if reviewIsComplete { clearReviewLifecycle() } else { persistReview() } }
    func resumeReview() {
        guard var checkpoint = resumeReviewOffer else { return }
        refreshProtection()
        guard resumeReviewOffer != nil else { return }
        guard !protectionUnknown else { clearReviewLifecycle(message: "Protection rules could not be verified. Start a new review after resolving them."); return }
        guard access == .full || access == .limited else { clearReviewLifecycle(message: "Photo access is off, so saved review progress was cleared."); return }
        let currentScope = access == .limited ? "limited" : "full"
        let originalScope = checkpoint.scopeFingerprint
        let originalIDs = Set(checkpoint.session.candidates.map(\.id))
        let existing = photoLibrary.existingIdentifiers(Set(checkpoint.session.candidates.map(\.id)))
        checkpoint.session.candidates.removeAll { !existing.contains($0.id) }
        checkpoint.session.decisions = checkpoint.session.decisions.filter { existing.contains($0.key) && ($0.value != .delete || !effectiveExcludedIDs.contains($0.key)) }
        checkpoint.session.unlockedIDs.subtract(effectiveExcludedIDs)
        let legacyRulesUnverified = checkpoint.session.protectionFingerprint == nil && (!protectionRules.protectedAlbumIDs.isEmpty || protectionRules.recentDays != nil)
        if originalScope != currentScope || legacyRulesUnverified || (checkpoint.session.protectionFingerprint != nil && checkpoint.session.protectionFingerprint != currentProtectionFingerprint) {
            checkpoint.session.decisions = checkpoint.session.decisions.filter { $0.value != .delete }
            checkpoint.session.unlockedIDs.removeAll()
            checkpoint.session.protectionFingerprint = currentProtectionFingerprint
        }
        checkpoint = ReviewCheckpoint(scopeFingerprint: currentScope, session: checkpoint.session)
        guard !checkpoint.session.candidates.isEmpty else { clearReviewLifecycle(message: "Your photo library changed, and none of the saved review items are still available."); return }
        do {
            try reviewCheckpointStore.save(checkpoint)
            reviewSession = checkpoint.session
            resumeReviewOffer = checkpoint
            selectedIdentifiers = Set(checkpoint.session.decisions.compactMap { $0.value == .delete ? $0.key : nil }).subtracting(effectiveExcludedIDs)
            reviewCheckpointIsHealthy = true
            if originalIDs != existing || originalScope != currentScope { reviewLifecycleMessage = "Your photo library changed. The saved review was updated to include only items that are still available." }
            path.append(.review(checkpoint.session.category))
        } catch {
            reviewCheckpointIsHealthy = false; reviewSession = nil; selectedIdentifiers.removeAll(); reviewPersistenceMessage = "Updated review progress couldn’t be saved. Deletion is disabled."
        }
    }
    func dismissReviewLifecycleMessage() { reviewLifecycleMessage = nil }
    func startOverReview() { clearReviewLifecycle() }
    func flushReviewCheckpoint() { persistReview() }
    private func persistReview() { guard let session = reviewSession else { return }; do { let value = ReviewCheckpoint(scopeFingerprint: access == .limited ? "limited" : "full", session: session); try reviewCheckpointStore.save(value); resumeReviewOffer = value; reviewCheckpointIsHealthy = true; if protectedStoreIsHealthy { reviewPersistenceMessage = nil } } catch { reviewCheckpointIsHealthy = false; selectedIdentifiers.removeAll(); reviewPersistenceMessage = "Review progress couldn’t be saved. Deletion is disabled." } }
    func skipAndProtect(identifier: String) {
        let now = Date(); let record = ProtectedItemRecord(id: identifier, reasons: [.userSkipped], createdAt: now, lastSeenAt: now)
        do { try protectedItemStore.upsert(record); protectedRecords = try protectedItemStore.records(); refreshProtection(); selectedIdentifiers.remove(identifier); setDecision(.skip, for: identifier); reviewPersistenceMessage = nil }
        catch { reviewPersistenceMessage = "Protection couldn’t be saved. This item was not skipped." }
    }
    func removeUserProtection(identifier: String) {
        do { try protectedItemStore.removeUserSkipped(id: identifier); protectedRecords = try protectedItemStore.records(); refreshProtection(); reviewSession?.decisions[identifier] = .undecided; selectedIdentifiers.remove(identifier); persistReview() }
        catch { reviewPersistenceMessage = "Protection couldn’t be removed." }
    }

    var selectedItems: [LibraryItem] { libraryItems.filter { selectedIdentifiers.contains($0.id) && !effectiveExcludedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.estimatedBytes } }
    func validateSelection() -> Bool {
        let existing = photoLibrary.existingIdentifiers(selectedIdentifiers)
        libraryChanged = existing != selectedIdentifiers
        if libraryChanged { selectedIdentifiers = existing }
        return !libraryChanged
    }

    var deletionPlanIdentifiers: Set<String> {
        guard reviewCheckpointIsHealthy, protectedStoreIsHealthy, !protectionUnknown, let reviewSession else { return [] }
        let explicit = ReviewBatcher.deletionPlan(for: reviewSession, excludedIDs: effectiveExcludedIDs).identifiers
        return explicit.intersection(photoLibrary.existingIdentifiers(explicit)).subtracting(effectiveExcludedIDs)
    }

    private var deletionPlanBytes: Int64 { libraryItems.filter { deletionPlanIdentifiers.contains($0.id) }.reduce(0) { $0 + $1.estimatedBytes } }
    private var potentialCompressionSources: Set<String> { Set(compressionOperations.filter { $0.state == .completed }.map(\.sourceID)) }
    var deletionGate: DeletionGate {
        guard reviewCheckpointIsHealthy, protectedStoreIsHealthy, !protectionUnknown, historyIsHealthy, !deletionRecoveryPending else { return .unavailable }
        return store.deletionGate(itemCount: deletionPlanIdentifiers.subtracting(potentialCompressionSources).count, bytes: deletionPlanBytes)
    }

    func deleteSelected() async {
        guard !isDeleting, !deletionRecoveryPending else { return }
        refreshProtection()
        isDeleting = true
        defer { isDeleting = false }
        guard reviewCheckpointIsHealthy, protectedStoreIsHealthy, !protectionUnknown, historyIsHealthy else { selectedIdentifiers.removeAll(); result = .noChanges; return }
        guard let session = reviewSession else { selectedIdentifiers.removeAll(); result = .noChanges; return }
        let intended = ReviewBatcher.deletionPlan(for: session, excludedIDs: effectiveExcludedIDs).identifiers.subtracting(effectiveExcludedIDs)
        let snapshot = intended.intersection(photoLibrary.existingIdentifiers(intended))
        let byteByID = Dictionary(uniqueKeysWithValues: libraryItems.filter { snapshot.contains($0.id) }.map { ($0.id, $0.estimatedBytes) })
        guard !snapshot.isEmpty else { selectedIdentifiers.formIntersection(snapshot); result = intended.isEmpty ? .noChanges : .changedLibrary; return }
        guard snapshot == intended else { selectedIdentifiers.formIntersection(snapshot); libraryChanged = true; result = .changedLibrary; return }
        let plannedBytes = byteByID.values.reduce(0, +)
        var verifiedExemptions = Set<String>()
        for id in snapshot.intersection(potentialCompressionSources) {
            if (try? await compressionService.cleanupProof(sourceID: id, protected: effectiveExcludedIDs.contains(id))) != nil { verifiedExemptions.insert(id) }
        }
        cleanupExemptions = verifiedExemptions
        refreshProtection()
        guard reviewSession == session, !protectionUnknown, snapshot.isDisjoint(with: effectiveExcludedIDs) else { result = .changedLibrary; return }
        guard await store.deletionGateRefreshing(itemCount: snapshot.subtracting(verifiedExemptions).count, bytes: plannedBytes) == .allowed else { optimizationMessage = "This selection needs ordinary deletion allowance because a compressed copy could not be verified, or your free allowance is exhausted."; return }
        refreshProtection()
        guard reviewSession == session, !protectionUnknown, snapshot.isDisjoint(with: effectiveExcludedIDs), photoLibrary.existingIdentifiers(snapshot) == snapshot else { result = .changedLibrary; return }
        var journal = DeletionJournalEntry(requested: snapshot, exempt: verifiedExemptions, bytesByID: byteByID, consumesFreeAllowance: store.usesFreeDeletionAllowance)
        do {
            try deletionJournalStore.save(journal)
            journal.phase = .executing; try deletionJournalStore.save(journal)
        } catch { pauseForDeletionRecovery(); result = .noChanges; return }
        var deletionError: Error?
        do { try await photoLibrary.delete(identifiers: snapshot); deleteError = nil }
        catch { deletionError = error; deleteError = error.localizedDescription }
        let remaining = photoLibrary.existingIdentifiers(snapshot)
        let deleted = snapshot.subtracting(remaining)
        // A successful live Photos completion confirms this exact request. After an
        // error or relaunch, even Full-scope absence cannot establish attribution.
        guard deleted.isEmpty || deletionError == nil else {
            pauseForDeletionRecovery(); result = .changedLibrary; return
        }
        deleteOutcome = DeleteOutcome(requested: snapshot, deleted: deleted, unchanged: remaining, estimatedDeletedBytes: deleted.reduce(0) { $0 + (byteByID[$1] ?? 0) })
        selectedIdentifiers = remaining
        if !deleted.isEmpty {
            reviewSession?.applyDeletion(deleted: deleted, unchanged: remaining)
            if reviewIsComplete { clearReviewLifecycle() } else { persistReview() }
        }
        if deleted.count == snapshot.count { result = .success }
        else if !deleted.isEmpty { result = .partial }
        else if let error = deletionError as NSError? {
            if error.domain == PHPhotosErrorDomain && error.code == 3072 { result = .cancelled }
            else if deletionError is PhotoLibraryService.LibraryError { result = .changedLibrary }
            else { result = .failed }
        } else { result = .noChanges }
        let status: ActivityStatus = result == .success ? .success : result == .partial ? .partial : result == .cancelled ? .cancelled : .failed
        journal.confirmedDeleted = deleted; journal.unchanged = remaining; journal.status = status; journal.phase = .confirmed
        do { try deletionJournalStore.save(journal); try finishDeletionJournal(journal) }
        catch { pauseForDeletionRecovery() }
    }

    func finishResult() {
        if reviewIsComplete { clearReviewLifecycle() }
        path.removeAll()
        libraryChanged = false
    }

    func reviewUnchangedItems() {
        selectedIdentifiers = deleteOutcome.unchanged.intersection(Set(libraryItems.map(\.id)))
        libraryChanged = false
        path = selectedIdentifiers.isEmpty ? [] : [.summary]
    }

    private var reviewIsComplete: Bool {
        guard let session = reviewSession else { return false }
        return session.candidates.allSatisfy { candidate in
            let decision = session.decisions[candidate.id] ?? .undecided
            return decision == .keepForNow || decision == .skip
        }
    }

    private func handleAccessChange(_ newAccess: LibraryAccess) {
        let changed = access != newAccess
        access = newAccess
        refreshProtection()
        if changed && (reviewSession != nil || resumeReviewOffer != nil) { clearReviewLifecycle(message: "Photo access changed. Start a new review with the current scope.") }
        if newAccess == .denied { clearReviewLifecycle(message: "Photo access is off, so saved review progress was cleared.") }
    }

    private func clearReviewLifecycle(message: String? = nil) {
        reviewSession = nil
        resumeReviewOffer = nil
        selectedIdentifiers.removeAll()
        unlockedIdentifiers.removeAll()
        do { try reviewCheckpointStore.clear(); reviewCheckpointIsHealthy = true }
        catch { reviewCheckpointIsHealthy = false; reviewPersistenceMessage = "Saved review progress couldn’t be cleared. Deletion is disabled." }
        reviewLifecycleMessage = message
    }
}
