import XCTest
@testable import ClearKeep

@MainActor final class DeletionJournalTests: XCTestCase {
    func testPhotosSuccessBeforeConfirmationWriteRequiresExplicitUnverifiedClosureWithoutCharging() async throws {
        let journal = MemoryDeletionJournalStore(); journal.failNextConfirmedWrite = true
        let quota = JournalQuotaLedger()
        let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "A", category: .screenshots)])
        let model = makeModel(library, quota: quota, journal: journal)
        model.startScan(); await scanned(model)
        model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        await model.deleteSelected()
        XCTAssertEqual(library.deleteRequests.count, 1)
        XCTAssertEqual(quota.value.items, 0)
        XCTAssertTrue(model.deletionRecoveryPending)
        let relaunched = makeModel(library, quota: quota, journal: journal)
        XCTAssertEqual(quota.value.items, 0)
        XCTAssertTrue(relaunched.deletionRecoveryPending)
        relaunched.retryPendingDeletionVerification()
        XCTAssertEqual(quota.value.items, 0)
        relaunched.closeUnverifiedDeletion()
        XCTAssertFalse(relaunched.deletionRecoveryPending)
        XCTAssertEqual(try journal.load().first?.status, .failed)
        XCTAssertEqual(library.deleteRequests.count, 1)
    }

    func testIntentWriteFailureNeverCallsPhotos() async {
        let journal = MemoryDeletionJournalStore(); journal.failAllWrites = true
        let quota = JournalQuotaLedger()
        let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "A", category: .screenshots)])
        let model = makeModel(library, quota: quota, journal: journal)
        model.startScan(); await scanned(model); model.beginReview(category: .screenshots); model.toggle(identifier: "A")
        await model.deleteSelected()
        XCTAssertTrue(library.deleteRequests.isEmpty)
        XCTAssertEqual(quota.value.items, 0)
        XCTAssertTrue(model.deletionRecoveryPending)
    }

    func testExecutingIntentBeforePhotosAndExternalDeletionNeverChargesEvenWithFullAccess() throws {
        let journal = MemoryDeletionJournalStore()
        var entry = DeletionJournalEntry(requested: ["missing"], exempt: [], bytesByID: ["missing": 20], consumesFreeAllowance: true)
        entry.phase = .executing; try journal.save(entry)
        let quota = JournalQuotaLedger(), library = FakePhotoLibrary(items: [], access: .limited)
        let model = makeModel(library, quota: quota, journal: journal)
        XCTAssertTrue(model.deletionRecoveryPending); XCTAssertEqual(quota.value.items, 0)
        XCTAssertEqual(model.deletionGate, .unavailable)
        model.retryPendingDeletionVerification()
        XCTAssertEqual(quota.value.items, 0)
        library.access = .full
        model.retryPendingDeletionVerification()
        XCTAssertTrue(model.deletionRecoveryPending); XCTAssertEqual(quota.value.items, 0)
        XCTAssertEqual(try journal.load().first?.phase, .executing)
        model.closeUnverifiedDeletion()
        XCTAssertFalse(model.deletionRecoveryPending); XCTAssertEqual(quota.value.items, 0)
        XCTAssertEqual(try journal.load().first?.confirmedDeleted, [])
        XCTAssertEqual(try journal.load().first?.unchanged, [])
        XCTAssertEqual(try journal.load().first?.status, .failed)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testPreparedIntentIsDurablyCancelledWithZeroUsage() throws {
        let journal = MemoryDeletionJournalStore()
        let entry = DeletionJournalEntry(requested: ["A"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
        try journal.save(entry)
        let quota = JournalQuotaLedger(), library = FakePhotoLibrary(items: [])
        _ = makeModel(library, quota: quota, journal: journal)
        XCTAssertEqual(quota.value.items, 0)
        XCTAssertEqual(try journal.load().first?.phase, .completed)
        XCTAssertEqual(try journal.load().first?.status, .cancelled)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testRecoveredMixedPartialChargesOnlyOrdinaryConfirmedIDsUsingOriginalEntitlement() throws {
        let journal = MemoryDeletionJournalStore()
        var entry = DeletionJournalEntry(requested: ["ordinary", "exempt", "remaining"], exempt: ["exempt"], bytesByID: [:], consumesFreeAllowance: true)
        entry.phase = .confirmed; entry.confirmedDeleted = ["ordinary", "exempt"]; entry.unchanged = ["remaining"]; entry.status = .partial; try journal.save(entry)
        let quota = JournalQuotaLedger(); quota.value = .init(items: 99, bytes: 0)
        let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "remaining", category: .screenshots)])
        _ = makeModel(library, quota: quota, journal: journal, entitlement: .lifetime)
        XCTAssertEqual(quota.value.items, 100)
        XCTAssertEqual(try journal.load().first?.confirmedDeleted, ["ordinary", "exempt"])
        XCTAssertEqual(try journal.load().first?.status, .partial)
        XCTAssertTrue(library.deleteRequests.isEmpty)
    }

    func testPaidIntentRecoveredAfterRevocationDoesNotConsumeFreeAllowance() throws {
        let journal = MemoryDeletionJournalStore()
        var entry = DeletionJournalEntry(requested: ["A"], exempt: [], bytesByID: [:], consumesFreeAllowance: false)
        entry.phase = .confirmed; entry.confirmedDeleted = ["A"]; entry.status = .success; try journal.save(entry)
        let quota = JournalQuotaLedger(); quota.value = .init(items: 99, bytes: 0)
        _ = makeModel(FakePhotoLibrary(items: []), quota: quota, journal: journal)
        XCTAssertEqual(quota.value.items, 99)
    }

    func testQuotaLostAcknowledgementUsesAtomicOperationMarkerOnRetry() throws {
        let ledger = JournalQuotaLedger(); ledger.throwAfterWrite = true
        let store = StoreService(ledger: ledger, liveEntitlements: false)
        let id = UUID()
        XCTAssertThrowsError(try store.commitJournalDeletion(operationID: id, items: 1, bytes: 20, consumesFreeAllowance: true))
        XCTAssertEqual(ledger.value.items, 1)
        let relaunched = StoreService(ledger: ledger, liveEntitlements: false)
        try relaunched.commitJournalDeletion(operationID: id, items: 1, bytes: 20, consumesFreeAllowance: true)
        XCTAssertEqual(ledger.value.items, 1)
    }

    func testDefaultsLegacyMigrationRetainsQuotaAndOperationMarkerAcrossNewInstances() throws {
        let suite = "ClearKeep.JournalTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(99, forKey: "clearkeep.free.deletedItems")
        defaults.set(Int64(8_000_000_000), forKey: "clearkeep.free.deletedBytes")
        let id = UUID()
        try StoreService(defaults: defaults, durableQuota: false, liveEntitlements: false).commitJournalDeletion(operationID: id, items: 1, bytes: 20, consumesFreeAllowance: true)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        try StoreService(defaults: reloaded, durableQuota: false, liveEntitlements: false).commitJournalDeletion(operationID: id, items: 1, bytes: 20, consumesFreeAllowance: true)
        let quota = try DefaultsQuotaLedger(reloaded).read()
        XCTAssertEqual(quota.items, 100); XCTAssertEqual(quota.bytes, 8_000_000_020)
        XCTAssertEqual(quota.deletionOperationIDs, [id])
    }

    func testLegacyQuotaDecodesWithoutResetAndJournalEncodingIsSeparateFromActivity() throws {
        let data = Data("{\"items\":99,\"bytes\":8000000000}".utf8)
        let quota = try JSONDecoder().decode(FreeQuota.self, from: data)
        XCTAssertEqual(quota.items, 99); XCTAssertTrue(quota.deletionOperationIDs.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDeletionJournalStore(url: directory.appendingPathComponent("journal.json"))
        let entry = DeletionJournalEntry(requested: ["private-asset"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
        try store.save(entry)
        XCTAssertEqual(try store.load().first?.requested, ["private-asset"])
        XCTAssertEqual(try storeURLBackupExclusion(directory.appendingPathComponent("journal.json")), true)
        let encoded = String(decoding: try JSONEncoder().encode(entry.receipt), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-asset"))
    }
    private func storeURLBackupExclusion(_ url: URL) throws -> Bool? { try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup }

    func testHistoryFailureRetryRepairsHealthWithoutRepeatingQuotaOrPhotos() throws {
        let journal = MemoryDeletionJournalStore(), quota = JournalQuotaLedger(), activity = JournalActivityStore()
        var entry = DeletionJournalEntry(requested: ["A"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
        entry.phase = .confirmed; entry.confirmedDeleted = ["A"]; entry.status = .success
        try journal.save(entry); activity.fails = true
        let model = makeModel(FakePhotoLibrary(items: []), quota: quota, journal: journal, activity: activity)
        XCTAssertEqual(quota.value.items, 1); XCTAssertTrue(model.deletionRecoveryPending)
        activity.fails = false; model.retryPendingDeletionVerification()
        XCTAssertEqual(quota.value.items, 1); XCTAssertEqual(activity.entries.count, 1)
        XCTAssertFalse(model.deletionRecoveryPending)
        XCTAssertEqual(model.deletionGate, .allowed)
    }

    func testExplicitHistoryClearAcknowledgesConfirmedQuotaOutboxWithoutResurrection() throws {
        let journal = MemoryDeletionJournalStore(), quota = JournalQuotaLedger(), activity = JournalActivityStore()
        let model = makeModel(FakePhotoLibrary(items: []), quota: quota, journal: journal, activity: activity)
        var entry = DeletionJournalEntry(requested: ["A"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
        entry.phase = .confirmed; entry.confirmedDeleted = ["A"]; entry.status = .success
        try journal.save(entry)
        model.clearActivity(); model.retryPendingDeletionVerification()
        XCTAssertTrue(activity.entries.isEmpty); XCTAssertEqual(quota.value.items, 1)
        XCTAssertEqual(try journal.load().first?.phase, .completed)
    }

    func testConfirmedLostQuotaAcknowledgementCannotUseUnverifiedClosureToBypassUsage() throws {
        let journal = MemoryDeletionJournalStore(), quota = JournalQuotaLedger()
        var entry = DeletionJournalEntry(requested: ["A"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
        entry.phase = .confirmed; entry.confirmedDeleted = ["A"]; entry.status = .success
        try journal.save(entry); quota.throwAfterWrite = true
        let model = makeModel(FakePhotoLibrary(items: []), quota: quota, journal: journal)
        XCTAssertTrue(model.deletionRecoveryPending); XCTAssertFalse(model.canCloseUnverifiedDeletion)
        XCTAssertEqual(quota.value.items, 1)
        model.closeUnverifiedDeletion()
        XCTAssertEqual(try journal.load().first?.phase, .confirmed)
        XCTAssertTrue(model.deletionRecoveryPending)
        model.retryPendingDeletionVerification()
        XCTAssertEqual(quota.value.items, 1); XCTAssertFalse(model.deletionRecoveryPending)
    }

    func testLiveCancelAndPartialHaveDurableTerminalOutcomesWithoutReplay() async throws {
        for behavior in [FakePhotoLibrary.DeleteBehavior.cancel, .partial] {
            let journal = MemoryDeletionJournalStore(), quota = JournalQuotaLedger()
            let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "A", category: .screenshots), FakePhotoLibrary.makeItem(id: "B", category: .screenshots)], deleteBehavior: behavior)
            let model = makeModel(library, quota: quota, journal: journal)
            model.startScan(); await scanned(model); model.beginReview(category: .screenshots); model.toggle(identifier: "A"); model.toggle(identifier: "B")
            await model.deleteSelected()
            let entry = try XCTUnwrap(journal.load().first)
            XCTAssertEqual(entry.phase, .completed)
            XCTAssertEqual(entry.status, behavior == .cancel ? .cancelled : .partial)
            XCTAssertEqual(quota.value.items, behavior == .cancel ? 0 : 1)
            _ = makeModel(library, quota: quota, journal: journal)
            XCTAssertEqual(library.deleteRequests.count, 1)
            XCTAssertEqual(quota.value.items, behavior == .cancel ? 0 : 1)
        }
    }

    func testLivePhotosErrorAndMissingFullAccessIDsRemainUnverifiedWithoutCharging() async throws {
        for behavior in [FakePhotoLibrary.DeleteBehavior.cancelAfterExternalRemoval, .failAfterExternalRemoval] {
            let journal = MemoryDeletionJournalStore(), quota = JournalQuotaLedger()
            let library = FakePhotoLibrary(items: [FakePhotoLibrary.makeItem(id: "A", category: .screenshots)], access: .full, deleteBehavior: behavior)
            let model = makeModel(library, quota: quota, journal: journal)
            model.startScan(); await scanned(model); model.beginReview(category: .screenshots); model.toggle(identifier: "A")
            await model.deleteSelected()
            XCTAssertEqual(quota.value.items, 0)
            XCTAssertTrue(model.deletionRecoveryPending)
            XCTAssertEqual(try journal.load().first?.phase, .executing)
            model.closeUnverifiedDeletion()
            XCTAssertEqual(quota.value.items, 0); XCTAssertEqual(library.deleteRequests.count, 1)
            XCTAssertEqual(try journal.load().first?.status, .failed)
            XCTAssertEqual(try journal.load().first?.confirmedDeleted, [])
        }
    }

    private func makeModel(_ library: FakePhotoLibrary, quota: JournalQuotaLedger, journal: MemoryDeletionJournalStore, entitlement: PaidEntitlement = .none, activity: ActivityStoring? = nil) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return AppModel(deletionJournalStore: journal, photoLibrary: library, store: StoreService(initialEntitlement: entitlement, ledger: quota, liveEntitlements: false), reviewCheckpointStore: InMemoryReviewCheckpointStore(), protectedItemStore: InMemoryProtectedItemStore(), rulesStore: FileProtectionRulesStore(url: directory.appendingPathComponent("rules.json")), activityStore: activity ?? FileActivityStore(url: directory.appendingPathComponent("activity.json")), albumSnapshotProvider: { .init(fullAccess: true) })
    }
    private func scanned(_ model: AppModel) async { for _ in 0..<1000 { if model.scanState == .complete { break }; await Task.yield() }; XCTAssertEqual(model.scanState, .complete) }
}

private final class JournalActivityStore: ActivityStoring {
    var entries: [ActivityReceipt] = []
    var fails = false
    func load() throws -> [ActivityReceipt] { entries }
    func upsert(_ receipt: ActivityReceipt) throws { if fails { throw CocoaError(.fileWriteUnknown) }; entries.removeAll { $0.id == receipt.id }; entries.append(receipt) }
    func clear() throws { entries = [] }
}

@MainActor private final class JournalQuotaLedger: QuotaLedger {
    var value = FreeQuota(items: 0, bytes: 0)
    var throwAfterWrite = false
    func read() throws -> FreeQuota { value }
    func write(_ quota: FreeQuota) throws { value = quota; if throwAfterWrite { throwAfterWrite = false; throw QuotaLedgerError.writeFailed(-50) } }
}

final class MemoryDeletionJournalStore: DeletionJournalStoring {
    var entries: [DeletionJournalEntry] = []
    var failAllWrites = false
    var failNextConfirmedWrite = false
    func load() throws -> [DeletionJournalEntry] { entries }
    func save(_ entry: DeletionJournalEntry) throws {
        if failAllWrites || (failNextConfirmedWrite && entry.phase == .confirmed) {
            failNextConfirmedWrite = false; throw CocoaError(.fileWriteUnknown)
        }
        entries.removeAll { $0.id == entry.id }; entries.append(entry)
    }
}
