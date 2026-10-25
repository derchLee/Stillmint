import AVFoundation
import Photos
import UIKit
import XCTest
@testable import ClearKeep

@MainActor final class AppModelTests: XCTestCase {
    func testProductionModelHasNoMockFallback() {
        let library = FakePhotoLibrary(items: [], access: .notDetermined)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore())
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertEqual(library.requestAccessCalls, 0, "Fresh model initialization must not request Photos access")
    }

    func testExplicitPhotoAccessActionRequestsExactlyOnce() async {
        let library = FakePhotoLibrary(items: [], access: .notDetermined)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore())
        XCTAssertEqual(library.requestAccessCalls, 0)
        await model.requestPhotoAccess()
        XCTAssertEqual(library.requestAccessCalls, 1)
    }

    func testPhotoLibraryChangeCallbackBridgesFromBackgroundToMainActorOnce() async {
        let service = PhotoLibraryService()
        let initialToken = service.changeToken
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                service.enqueueLibraryChange()
                continuation.resume()
            }
        }
        await waitUntilAsync { service.changeToken == initialToken + 1 }
        XCTAssertEqual(service.changeToken, initialToken + 1)
    }

    func testContinuationBridgeResumesSafelyFromBackgroundExactlyOnce() async {
        let value: Int = await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.resume(returning: 42)
                box.resume(returning: 99)
            }
        }
        XCTAssertEqual(value, 42)
    }

    func testCategoryAndPreviewIdentityCannotSelectDifferentAsset() {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .largeVideos)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [a, b]), store: isolatedStore())
        model.startScan()
        waitUntil { model.scanState == .complete }
        XCTAssertEqual(model.items(in: .screenshots).map(\.id), ["A"])
        model.toggle(identifier: "A")
        XCTAssertEqual(model.selectedIdentifiers, ["A"])
        XCTAssertFalse(model.selectedIdentifiers.contains("B"))
    }

    func testProtectedRequiresExplicitUnlock() {
        let protected = FakePhotoLibrary.makeItem(id: "P", category: .screenshots, favorite: true)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [protected]), store: isolatedStore())
        model.startScan(); waitUntil { model.scanState == .complete }
        model.toggle(identifier: "P"); XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        model.unlockedIdentifiers.insert("P"); model.toggle(identifier: "P")
        XCTAssertEqual(model.selectedIdentifiers, ["P"])
    }

    func testDeleteReconcilesRealIdentifiers() async {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let fake = FakePhotoLibrary(items: [a]); let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: fake, store: isolatedStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A"); await model.deleteSelected()
        XCTAssertEqual(model.deleteOutcome.deleted, ["A"])
        XCTAssertTrue(model.deleteOutcome.unchanged.isEmpty)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertEqual(model.deleteOutcome.estimatedDeletedBytes, 10)
    }

    func testFreeQuotaAndPaidEntitlementGate() {
        let defaults = isolatedDefaults(); let freeStore = StoreService(defaults: defaults, durableQuota: false)
        XCTAssertEqual(freeStore.deletionGate(itemCount: 100, bytes: 1_024), .allowed)
        freeStore.recordFreeDeletion(items: 100, bytes: 1_024)
        XCTAssertEqual(freeStore.deletionGate(itemCount: 1, bytes: 1), .unavailable)
        let lifetime = StoreService(defaults: isolatedDefaults(), initialEntitlement: .lifetime, durableQuota: false)
        XCTAssertEqual(lifetime.deletionGate(itemCount: 1_000, bytes: Int64.max / 2), .allowed)
        let expired = StoreService(defaults: isolatedDefaults(), initialEntitlement: .legacy(expires: Date().addingTimeInterval(-1)), durableQuota: false)
        XCTAssertEqual(expired.deletionGate(itemCount: 101, bytes: 1), .unavailable)
        XCTAssertTrue(expired.recordFreeDeletion(items: 100, bytes: 1))
        XCTAssertEqual(expired.deletionGate(itemCount: 1, bytes: 1), .unavailable)
        let activeLegacy = StoreService(defaults: isolatedDefaults(), initialEntitlement: .legacy(expires: Date().addingTimeInterval(60)), durableQuota: false)
        XCTAssertEqual(activeLegacy.deletionGate(itemCount: 101, bytes: 1), .allowed)
    }

    func testSaleCatalogContainsOnlyConfiguredLifetimeIdentifier() {
        let store = StoreService(defaults: isolatedDefaults(), durableQuota: false, liveEntitlements: false, lifetimeProductID: "com.test.lifetime")
        XCTAssertEqual(store.saleIdentifiers, ["com.test.lifetime"])
        XCTAssertFalse(store.saleIdentifiers.contains(StoreService.legacyCleanupPassProductID))
        XCTAssertFalse(store.saleIdentifiers.contains(StoreService.legacyAnnualProductID))
    }

    func testFreeDeletionAllowsHundredthItemRegardlessOfLegacyByteUsage() {
        let ledger = FakeQuotaLedger()
        ledger.quota = FreeQuota(items: 99, bytes: 8_000_000_000)
        let store = StoreService(ledger: ledger, liveEntitlements: false)
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: 4_000_000_000), .allowed)
        XCTAssertTrue(store.recordFreeDeletion(items: 1, bytes: 4_000_000_000))
        XCTAssertEqual(ledger.quota.items, 100)
        XCTAssertNotEqual(store.deletionGate(itemCount: 1, bytes: 0), .allowed)
    }

    func testFreeDeletionAllowsSingleLargeVideoWithNoByteCap() {
        let store = isolatedStore()
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: 40_000_000_000), .allowed)
    }

    func testFreeDeletionRejectsInvalidOrOverflowingItemCounts() {
        let ledger = FakeQuotaLedger()
        ledger.quota = FreeQuota(items: 99, bytes: 0)
        let store = StoreService(ledger: ledger, liveEntitlements: false)
        XCTAssertNotEqual(store.deletionGate(itemCount: -1, bytes: 0), .allowed)
        // A large request must be rejected without overflowing the count addition.
        XCTAssertNotEqual(store.deletionGate(itemCount: Int.max - 99, bytes: 0), .allowed)
    }

    func testLegacyDefaultsQuotaRetainsItemUsageAcrossReloadWithoutByteGate() {
        let defaults = isolatedDefaults()
        defaults.set(98, forKey: "clearkeep.free.deletedItems")
        defaults.set(40_000_000_000 as Int64, forKey: "clearkeep.free.deletedBytes")
        let store = StoreService(defaults: defaults, durableQuota: false, liveEntitlements: false)
        XCTAssertEqual(store.deletionGate(itemCount: 2, bytes: 40_000_000_000), .allowed)
        XCTAssertTrue(store.recordFreeDeletion(items: 2, bytes: 40_000_000_000))
        let reloaded = StoreService(defaults: defaults, durableQuota: false, liveEntitlements: false)
        XCTAssertEqual(defaults.integer(forKey: "clearkeep.free.deletedItems"), 100)
        XCTAssertNotEqual(reloaded.deletionGate(itemCount: 1, bytes: 0), .allowed)
    }

    func testFailedCancelledAndUnchangedDeletionDoNotConsumeQuota() async {
        for behavior in [FakePhotoLibrary.DeleteBehavior.fail, .cancel, .noOp] {
            let ledger = FakeQuotaLedger()
            ledger.quota = FreeQuota(items: 99, bytes: 8_000_000_000)
            let item = FakePhotoLibrary.makeItem(id: "quota-item", category: .screenshots)
            let library = FakePhotoLibrary(items: [item], deleteBehavior: behavior)
            let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: StoreService(ledger: ledger, liveEntitlements: false))
            model.startScan(); await waitUntilAsync { model.scanState == .complete }
            model.beginReview(category: .screenshots); model.toggle(identifier: item.id)
            await model.deleteSelected()
            XCTAssertEqual(library.deleteRequests.count, 1)
            XCTAssertTrue(model.deleteOutcome.deleted.isEmpty)
            XCTAssertEqual(ledger.quota, FreeQuota(items: 99, bytes: 8_000_000_000))
        }
    }

    func testLifetimeEntitlementIsPermanentAcrossRefreshAndRestoreResolution() {
        let purchase = EntitlementRecord(productID: StoreService.defaultLifetimeProductID, purchaseDate: .distantPast, expirationDate: nil, isRevoked: false)
        XCTAssertEqual(StoreService.resolveEntitlement(records: [purchase], now: .distantFuture), .lifetime)
        XCTAssertEqual(StoreService.resolveEntitlement(records: [purchase], now: Date().addingTimeInterval(10_000_000)), .lifetime)
    }

    func testRevokedLifetimeDoesNotUnlock() {
        let revoked = EntitlementRecord(productID: StoreService.defaultLifetimeProductID, purchaseDate: .distantPast, expirationDate: nil, isRevoked: true)
        XCTAssertEqual(StoreService.resolveEntitlement(records: [revoked]), .none)
    }

    func testLegacyEntitlementsRemainExpiryBoundAndNeverEnterSaleCatalog() {
        let now = Date()
        let activePass = EntitlementRecord(productID: StoreService.legacyCleanupPassProductID, purchaseDate: now, expirationDate: nil, isRevoked: false)
        guard case .legacy(let expiry) = StoreService.resolveEntitlement(records: [activePass], now: now) else { return XCTFail("Expected active legacy entitlement") }
        XCTAssertEqual(expiry.timeIntervalSince1970, now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(StoreService.resolveEntitlement(records: [activePass], now: now.addingTimeInterval(31 * 24 * 60 * 60)), .none)
    }

    func testMissingLifetimeProductFailsCatalogClosed() {
        XCTAssertFalse(StoreService.catalogIsAvailable(loadedProductIDs: [], saleIdentifiers: [StoreService.defaultLifetimeProductID]))
        XCTAssertFalse(StoreService.catalogIsAvailable(loadedProductIDs: [StoreService.legacyAnnualProductID], saleIdentifiers: [StoreService.defaultLifetimeProductID]))
        XCTAssertTrue(StoreService.catalogIsAvailable(loadedProductIDs: [StoreService.defaultLifetimeProductID], saleIdentifiers: [StoreService.defaultLifetimeProductID]))
    }

    func testQuotaLedgerReadAndWriteErrorsFailClosed() {
        let readFailure = FakeQuotaLedger(readError: .corrupt)
        let store = StoreService(ledger: readFailure, liveEntitlements: false)
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: 1), .unavailable)
        let writeFailure = FakeQuotaLedger(writeError: .writeFailed(-50))
        let writeStore = StoreService(ledger: writeFailure, liveEntitlements: false)
        XCTAssertFalse(writeStore.recordFreeDeletion(items: 1, bytes: 1))
        XCTAssertEqual(writeStore.deletionGate(itemCount: 1, bytes: 1), .unavailable)
    }

    func testDeleteCancellationAndFailureAreDistinct() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let cancelled = FakePhotoLibrary(items: [item], deleteBehavior: .cancel)
        let cancelModel = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: cancelled, store: isolatedStore())
        cancelModel.startScan(); await waitUntilAsync { cancelModel.scanState == .complete }; cancelModel.beginReview(category: .screenshots); cancelModel.toggle(identifier: "A"); await cancelModel.deleteSelected()
        XCTAssertEqual(cancelModel.result, .cancelled); XCTAssertEqual(cancelModel.deleteOutcome.unchanged, ["A"])
        let failed = FakePhotoLibrary(items: [item], deleteBehavior: .fail)
        let failModel = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: failed, store: isolatedStore())
        failModel.startScan(); await waitUntilAsync { failModel.scanState == .complete }; failModel.beginReview(category: .screenshots); failModel.toggle(identifier: "A"); await failModel.deleteSelected()
        XCTAssertEqual(failModel.result, .failed); XCTAssertEqual(failModel.deleteOutcome.unchanged, ["A"])
    }

    func testPermissionUsesSingleServiceStateAndManageAction() {
        let fake = FakePhotoLibrary(items: [], access: .limited)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: fake, store: isolatedStore())
        XCTAssertEqual(model.access, .limited)
        model.managePhotoAccess(); XCTAssertEqual(fake.manageAccessCalls, 1)
    }

    func testPauseCancelsAndPreventsConcurrentScan() {
        let fake = FakePhotoLibrary(items: [], suspendsScan: true)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: fake, store: isolatedStore())
        model.startScan(); waitUntil { fake.scanCalls == 1 }; model.startScan(); XCTAssertEqual(fake.scanCalls, 1)
        model.pauseScan(); waitUntil { model.scanState == .paused }
        XCTAssertFalse(model.isScanning)
    }

    func testEmptyLibraryPrunesEntireCheckpoint() {
        var checkpoint = ScanCheckpoint(analyzedIdentifiers: ["old"], items: [FakePhotoLibrary.makeItem(id: "old", category: .screenshots)], fingerprints: ["old": "hash"])
        checkpoint.reconcile(currentIdentifiers: [])
        XCTAssertTrue(checkpoint.analyzedIdentifiers.isEmpty)
        XCTAssertTrue(checkpoint.items.isEmpty)
        XCTAssertTrue(checkpoint.fingerprints.isEmpty)
    }

    func testResultCanExitBackToStorageMap() {
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: []), store: isolatedStore())
        model.path = [.review(.screenshots), .summary, .result]
        model.libraryChanged = true
        model.finishResult()
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertFalse(model.libraryChanged)
    }

    func testUnavailableCloudCountIsTruthfullyExposed() {
        let fake = FakePhotoLibrary(items: [])
        fake.unavailableAssetCount = 3
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: fake, store: isolatedStore())
        XCTAssertEqual(model.unavailableAssetCount, 3)
    }

    func testReviewUnchangedItemsReturnsToSummaryWithOnlyRemainingSelection() async {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        let fake = FakePhotoLibrary(items: [a, b], deleteBehavior: .partial)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: fake, store: isolatedStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A"); model.toggle(identifier: "B")
        await model.deleteSelected()
        XCTAssertEqual(model.result, .partial)
        model.reviewUnchangedItems()
        XCTAssertEqual(model.selectedIdentifiers, ["B"])
        XCTAssertEqual(model.path, [.summary])
    }

    func testPartialDeleteReducesCheckpointAndRelaunchKeepsOnlyUnchangedReviewable() async throws {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let protectedStore = InMemoryProtectedItemStore()
        let library = FakePhotoLibrary(items: [a, b], deleteBehavior: .partial)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: protectedStore)
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots)
        model.toggle(identifier: "A"); model.toggle(identifier: "B")

        await model.deleteSelected()

        XCTAssertEqual(model.deleteOutcome.deleted, ["A"])
        XCTAssertEqual(model.reviewSession?.candidates.map(\.id), ["B"])
        XCTAssertEqual(model.reviewSession?.decisions["B"], .delete)
        XCTAssertNil(model.reviewSession?.decisions["A"])
        XCTAssertEqual(try checkpointStore.load()?.session, model.reviewSession)

        let relaunched = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: protectedStore)
        relaunched.resumeReview()
        XCTAssertEqual(relaunched.selectedIdentifiers, ["B"])
        XCTAssertEqual(relaunched.reviewSession?.candidates.map(\.id), ["B"])
    }

    func testCancelledDeletePreservesReviewSelectionCheckpointAndQuota() async throws {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let ledger = FakeQuotaLedger()
        let model = AppModel(
            deletionJournalStore: MemoryDeletionJournalStore(),
            photoLibrary: FakePhotoLibrary(items: [item], deleteBehavior: .cancel),
            store: StoreService(ledger: ledger, liveEntitlements: false),
            reviewCheckpointStore: checkpointStore,
            protectedItemStore: InMemoryProtectedItemStore()
        )
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        let checkpointBefore = try checkpointStore.load()

        await model.deleteSelected()

        XCTAssertEqual(model.result, .cancelled)
        XCTAssertEqual(model.selectedIdentifiers, ["A"])
        XCTAssertEqual(try checkpointStore.load(), checkpointBefore)
        XCTAssertEqual(ledger.quota, FreeQuota(items: 0, bytes: 0))
    }

    func testDeletePlanUsesOnlyCurrentBatchExplicitDeletesAndExistingNonSkippedIDs() async {
        let items = ["A", "B", "C"].map { FakePhotoLibrary.makeItem(id: $0, category: .screenshots) }
        let library = FakePhotoLibrary(items: items)
        let protectedStore = InMemoryProtectedItemStore()
        let now = Date()
        try? protectedStore.upsert(ProtectedItemRecord(id: "B", reasons: [.userSkipped], createdAt: now, lastSeenAt: now))
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: protectedStore)
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots)
        model.toggle(identifier: "A")
        model.selectedIdentifiers.formUnion(["B", "C"])
        library.existing.remove("C")

        await model.deleteSelected()

        XCTAssertEqual(library.deleteRequests, [["A"]])
    }

    func testCorruptProtectedStoreFailsClosedAndNeverCallsDeletionClient() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let library = FakePhotoLibrary(items: [item])
        let store = FailingProtectedItemStore(readError: TestStoreError.corrupt)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: store)
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")

        await model.deleteSelected()

        XCTAssertNotNil(model.reviewPersistenceMessage)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testProtectionWriteFailureDoesNotClaimItemIsProtected() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let store = FailingProtectedItemStore(writeError: TestStoreError.writeFailed)
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [item]), store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: store)
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")

        model.skipAndProtect(identifier: "A")

        XCTAssertFalse(model.userSkippedIDs.contains("A"))
        XCTAssertEqual(model.selectedIdentifiers, ["A"])
        XCTAssertEqual(model.reviewSession?.decisions["A"], .delete)
        XCTAssertNotNil(model.reviewPersistenceMessage)
    }

    func testUserSkippedItemsStayExcludedAfterRestartAndRescan() async {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        let protectionStore = InMemoryProtectedItemStore()
        let first = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [a, b]), store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: protectionStore)
        first.startScan(); await waitUntilAsync { first.scanState == .complete }
        first.beginReview(category: .screenshots); first.skipAndProtect(identifier: "A")
        XCTAssertEqual(first.items(in: .screenshots).map(\.id), ["B"])

        let relaunched = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [a, b]), store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: protectionStore)
        relaunched.startScan(); await waitUntilAsync { relaunched.scanState == .complete }
        XCTAssertEqual(relaunched.items(in: .screenshots).map(\.id), ["B"])
    }

    func testSelectedBytesAndGateExcludeUserSkippedItems() async {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        let protectionStore = InMemoryProtectedItemStore()
        let now = Date()
        try? protectionStore.upsert(ProtectedItemRecord(id: "A", reasons: [.userSkipped], createdAt: now, lastSeenAt: now))
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [a, b]), store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: protectionStore)
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.selectedIdentifiers = ["A", "B"]
        XCTAssertEqual(model.selectedBytes, 10)
    }

    func testCorruptCheckpointClearsSelectionAndBlocksDeletionClient() async {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let library = FakePhotoLibrary(items: [item])
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: InMemoryReviewCheckpointStore(rawData: Data("bad".utf8)), protectedItemStore: InMemoryProtectedItemStore())
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        model.selectedIdentifiers.insert("A")

        await model.deleteSelected()

        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testResumeReconcilesMissingAssetsSavesCheckpointAndShowsOneTimeLibraryChangedMessage() throws {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        var session = ReviewSession(category: .screenshots, candidates: [
            .init(id: "A", groupID: nil, estimatedBytes: 10),
            .init(id: "B", groupID: nil, estimatedBytes: 10)
        ])
        session.decisions = ["A": .delete, "B": .delete]
        let checkpointStore = InMemoryReviewCheckpointStore()
        try checkpointStore.save(.init(scopeFingerprint: "full", session: session))
        let library = FakePhotoLibrary(items: [a, b]); library.existing.remove("A")
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())

        model.resumeReview()

        XCTAssertEqual(model.reviewSession?.candidates.map(\.id), ["B"])
        XCTAssertEqual(try checkpointStore.load()?.session.candidates.map(\.id), ["B"])
        XCTAssertEqual(model.selectedIdentifiers, ["B"])
        XCTAssertNotNil(model.reviewLifecycleMessage)
        model.dismissReviewLifecycleMessage()
        XCTAssertNil(model.reviewLifecycleMessage)
    }

    func testResumeWhenEveryCandidateDisappearedClearsSessionOfferAndStore() throws {
        let session = ReviewSession(category: .screenshots, candidates: [.init(id: "A", groupID: nil, estimatedBytes: 10)])
        let checkpointStore = InMemoryReviewCheckpointStore()
        try checkpointStore.save(.init(scopeFingerprint: "full", session: session))
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: []), store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())

        model.resumeReview()

        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertNil(try checkpointStore.load())
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
    }

    func testCompletingAllBatchesClearsSessionOfferAndCheckpoint() async throws {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [item]), store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots)

        model.completeCurrentBatch()

        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertNil(try checkpointStore.load())
    }

    func testPartialAndCancelledResultsKeepReviewCheckpoint() async throws {
        for behavior in [FakePhotoLibrary.DeleteBehavior.partial, .cancel] {
            let items = ["A", "B"].map { FakePhotoLibrary.makeItem(id: $0, category: .screenshots) }
            let checkpointStore = InMemoryReviewCheckpointStore()
            let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: items, deleteBehavior: behavior), store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())
            model.startScan(); await waitUntilAsync { model.scanState == .complete }
            model.beginReview(category: .screenshots); model.toggle(identifier: "A"); model.toggle(identifier: "B")
            await model.deleteSelected()
            model.finishResult()
            XCTAssertNotNil(model.reviewSession)
            XCTAssertNotNil(model.resumeReviewOffer)
            XCTAssertNotNil(try checkpointStore.load())
        }
    }

    func testFinishResultClearsCheckpointOnlyWhenSessionIsActuallyComplete() async throws {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [item]), store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots)
        model.setDecision(.keepForNow, for: "A")

        model.finishResult()

        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertNil(try checkpointStore.load())
    }

    func testStartOverExplicitlyClearsReviewStateSelectionAndCheckpoint() async throws {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: FakePhotoLibrary(items: [item]), store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")

        model.startOverReview()

        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertNil(try checkpointStore.load())
    }

    func testRevokedPhotoAccessClearsReviewLifecycle() async throws {
        let item = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let library = FakePhotoLibrary(items: [item], access: .full)
        let checkpointStore = InMemoryReviewCheckpointStore()
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())
        model.startScan(); await waitUntilAsync { model.scanState == .complete }
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        library.access = .denied

        await model.requestPhotoAccess()

        XCTAssertEqual(model.access, .denied)
        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.resumeReviewOffer)
        XCTAssertTrue(model.selectedIdentifiers.isEmpty)
        XCTAssertNil(try checkpointStore.load())
    }

    func testLimitedScopeTransitionReconcilesInsteadOfBlindlyClearing() throws {
        let a = FakePhotoLibrary.makeItem(id: "A", category: .screenshots)
        let b = FakePhotoLibrary.makeItem(id: "B", category: .screenshots)
        let session = ReviewSession(category: .screenshots, candidates: [
            .init(id: "A", groupID: nil, estimatedBytes: 10),
            .init(id: "B", groupID: nil, estimatedBytes: 10)
        ], decisions: ["A": .delete, "B": .delete])
        let checkpointStore = InMemoryReviewCheckpointStore()
        try checkpointStore.save(.init(scopeFingerprint: "full", session: session))
        let library = FakePhotoLibrary(items: [a, b], access: .limited); library.existing.remove("A")
        let model = AppModel(deletionJournalStore: MemoryDeletionJournalStore(), photoLibrary: library, store: isolatedStore(), reviewCheckpointStore: checkpointStore, protectedItemStore: InMemoryProtectedItemStore())

        model.resumeReview()

        XCTAssertEqual(model.reviewSession?.candidates.map(\.id), ["B"])
        XCTAssertEqual(try checkpointStore.load()?.scopeFingerprint, "limited")
        XCTAssertTrue(model.selectedIdentifiers.isEmpty, "A scope change must not restore old deletion intent")
        XCTAssertFalse(model.reviewSession?.decisions.values.contains(.delete) ?? true)
        XCTAssertNotNil(model.reviewLifecycleMessage)
    }

    func testCandidateFinalizationScalesAndPreservesGroupsAndKeeperIdentity() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        var paired: [ClearKeep.LibraryItem] = []
        for group in 0..<2_000 {
            let date = base.addingTimeInterval(TimeInterval(group * 6))
            paired.append(FakePhotoLibrary.makeItem(id: "keeper-\(group)", category: .exactDuplicates, createdAt: date))
            paired.append(FakePhotoLibrary.makeItem(id: "candidate-\(group)", category: .exactDuplicates, createdAt: date.addingTimeInterval(1)))
        }
        // A repeated identifier must never be emitted twice.
        paired.append(paired[0])
        let pairedResult = PhotoLibraryService.finalizePhotoCandidates(paired, fingerprints: [:])
        XCTAssertEqual(Set(pairedResult.items.map { $0.id }).count, pairedResult.items.count)
        XCTAssertLessThanOrEqual(pairedResult.operationCount, paired.count * 6)
        let firstKeeper = pairedResult.items.first { $0.id == "keeper-0" }
        let firstCandidate = pairedResult.items.first { $0.id == "candidate-0" }
        XCTAssertEqual(firstKeeper?.duplicateGroup, firstCandidate?.duplicateGroup)
        XCTAssertEqual(firstKeeper?.isSuggestedKeeper, true)
        XCTAssertEqual(firstCandidate?.isSuggestedKeeper, false)

        let burst = (0..<4_000).map { index in
            FakePhotoLibrary.makeItem(id: "burst-\(index)", category: .exactDuplicates, createdAt: base.addingTimeInterval(1))
        }
        let burstResult = PhotoLibraryService.finalizePhotoCandidates(burst, fingerprints: [:])
        XCTAssertEqual(burstResult.items.count, burst.count)
        XCTAssertEqual(burstResult.items.filter(\.isSuggestedKeeper).map(\.id), ["burst-0"])
        XCTAssertEqual(Set(burstResult.items.compactMap(\.duplicateGroup)).count, 1)
        XCTAssertLessThanOrEqual(burstResult.operationCount, burst.count * 6)
    }

    private func waitUntil(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(1)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate())
    }
    private func waitUntilAsync(_ predicate: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate() && clock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate())
    }
    private func isolatedDefaults() -> UserDefaults { let name = "ClearKeepTests.\(UUID())"; return UserDefaults(suiteName: name)! }
    private func isolatedStore() -> StoreService { StoreService(defaults: isolatedDefaults(), durableQuota: false, liveEntitlements: false) }
}

@MainActor final class FakeQuotaLedger: QuotaLedger {
    var quota = FreeQuota(items: 0, bytes: 0)
    let readError: QuotaLedgerError?; let writeError: QuotaLedgerError?
    init(readError: QuotaLedgerError? = nil, writeError: QuotaLedgerError? = nil) { self.readError = readError; self.writeError = writeError }
    func read() throws -> FreeQuota { if let readError { throw readError }; return quota }
    func write(_ quota: FreeQuota) throws { if let writeError { throw writeError }; self.quota = quota }
}

@MainActor final class FakePhotoLibrary: PhotoLibraryServing {
    var access: LibraryAccess
    var unavailableAssetCount = 0
    var items: [ClearKeep.LibraryItem]
    var existing: Set<String>
    var manageAccessCalls = 0
    var requestAccessCalls = 0
    var scanCalls = 0
    var deleteRequests: [Set<String>] = []
    var liveProtectionItems: [ClearKeep.LibraryItem]?
    let suspendsScan: Bool
    enum DeleteBehavior { case succeed, partial, cancel, fail, noOp, cancelAfterExternalRemoval, failAfterExternalRemoval }
    let deleteBehavior: DeleteBehavior
    init(items: [ClearKeep.LibraryItem], access: LibraryAccess = .full, suspendsScan: Bool = false, deleteBehavior: DeleteBehavior = .succeed) {
        self.items = items; self.existing = Set(items.map(\.id)); self.access = access; self.suspendsScan = suspendsScan; self.deleteBehavior = deleteBehavior
    }
    static func makeItem(id: String, category: MediaCategory, favorite: Bool = false, createdAt: Date? = nil) -> ClearKeep.LibraryItem {
        ClearKeep.LibraryItem(id: id, category: category, createdAt: createdAt, pixelWidth: 100, pixelHeight: 100, duration: 0, estimatedBytes: 10, isFavorite: favorite, isEdited: false, isVideo: category == .largeVideos, duplicateGroup: nil)
    }
    func refreshAccess() {}
    func requestAccess() async -> LibraryAccess { requestAccessCalls += 1; return access }
    func manageAccess() { manageAccessCalls += 1 }
    func scanIncrementally(progress: @escaping (Int, Int) -> Void) async throws -> [ClearKeep.LibraryItem] {
        scanCalls += 1
        if suspendsScan { while true { try Task.checkCancellation(); await Task.yield() } }
        progress(items.count, items.count); return items
    }
    func thumbnail(identifier: String, targetSize: CGSize) async -> UIImage? { nil }
    func image(identifier: String) async -> UIImage? { nil }
    func playerItem(identifier: String) async -> AVPlayerItem? { nil }
    func existingIdentifiers(_ identifiers: Set<String>) -> Set<String> { existing.intersection(identifiers) }
    func refreshedProtectionItems(_ items: [ClearKeep.LibraryItem]) -> [ClearKeep.LibraryItem] {
        guard let liveProtectionItems else { return items }
        let live = Dictionary(uniqueKeysWithValues: liveProtectionItems.map { ($0.id, $0) })
        return items.map { live[$0.id] ?? $0 }
    }
    func delete(identifiers: Set<String>) async throws {
        deleteRequests.append(identifiers)
        switch deleteBehavior {
        case .succeed: existing.subtract(identifiers)
        case .partial: if let first = identifiers.sorted().first { existing.remove(first) }
        case .cancel: throw NSError(domain: PHPhotosErrorDomain, code: 3072)
        case .fail: throw NSError(domain: PHPhotosErrorDomain, code: -1)
        case .noOp: break
        case .cancelAfterExternalRemoval, .failAfterExternalRemoval:
            existing.subtract(identifiers)
            throw NSError(domain: PHPhotosErrorDomain, code: deleteBehavior == .cancelAfterExternalRemoval ? 3072 : -1)
        }
    }
}

private enum TestStoreError: Error { case corrupt, writeFailed }

private final class FailingProtectedItemStore: ProtectedItemStoring {
    let readError: Error?
    let writeError: Error?
    init(readError: Error? = nil, writeError: Error? = nil) { self.readError = readError; self.writeError = writeError }
    func records() throws -> [ProtectedItemRecord] { if let readError { throw readError }; return [] }
    func upsert(_ record: ProtectedItemRecord) throws { if let writeError { throw writeError } }
    func removeUserSkipped(id: String) throws { if let writeError { throw writeError } }
    func reconcile(existingIDs: Set<String>) throws { if let readError { throw readError } }
}
