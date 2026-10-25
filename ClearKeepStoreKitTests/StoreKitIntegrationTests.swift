import StoreKit
import StoreKitTest
import XCTest
import UIKit
@testable import ClearKeepStoreKitHost

@MainActor final class StoreKitIntegrationTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "ClearKeep")
        session.resetToDefaultState()
        session.clearTransactions()
        // Modern API error simulation is separate from the legacy property overrides.
        try await session.setSimulatedError(nil, forAPI: StoreKitPurchaseAPI())
        try await session.setSimulatedError(nil, forAPI: StoreKitLoadProductsAPI())
        try await session.setSimulatedError(nil, forAPI: StoreKitVerificationAPI())
        try await session.setSimulatedError(nil, forAPI: StoreKitAppStoreSyncAPI())
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        session.locale = Locale(identifier: "en_US")
        session.storefront = "USA"
        suite = "ClearKeep.StoreKitIntegration." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        if let session { try await session.setSimulatedError(nil, forAPI: StoreKitPurchaseAPI()) }
        session?.clearTransactions()
        session?.resetToDefaultState()
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        defaults = nil; session = nil
    }
    private func service(id: String = StoreService.defaultLifetimeProductID) -> StoreService {
        StoreService(defaults: defaults, durableQuota: false, lifetimeProductID: id)
    }
    private func loaded(_ store: StoreService) async throws -> StoreProduct {
        // Product.purchase is UI-facing; hosted tests must have a foreground scene like a real tap.
        try await eventually { UIApplication.shared.applicationState == .active && UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        await store.load()
        XCTAssertEqual(store.state, .available)
        return try XCTUnwrap(store.products.first)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("StoreKit live state did not converge", file: file, line: line)
    }
    private func transaction() throws -> SKTestTransaction { try XCTUnwrap(session.allTransactions().last) }

    func testCatalogLoadsOnlyLocalizedNonConsumableLifetime() async throws {
        let store = service(); let product = try await loaded(store)
        let catalog = try await Product.products(for: [product.id])
        let rawProduct = try XCTUnwrap(catalog.first)
        XCTAssertEqual(store.products.map(\.id), [StoreService.defaultLifetimeProductID])
        XCTAssertEqual(rawProduct.type, .nonConsumable)
        XCTAssertEqual(rawProduct.price, Decimal(string: "19.99")) // Fixture, not final product pricing.
        XCTAssertEqual(product.displayPrice, "$19.99")
        XCTAssertEqual(rawProduct.displayName, "Lifetime Unlock")
        XCTAssertEqual(store.entitlement, .none)
    }
    func testProductionPurchaseVerifiesPermanentCurrentEntitlement() async throws {
        let store = service(); let product = try await loaded(store)
        await store.purchase(product)
        print("StoreKit production purchase state: \(store.state); local transaction states: \(session.allTransactions().map { $0.state.rawValue })")
        try await eventually { store.entitlement == .lifetime }
        XCTAssertEqual(store.entitlement, .lifetime)
        XCTAssertFalse(store.operationInProgress)
        var verified = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == product.id {
                verified = true; XCTAssertNil(transaction.expirationDate); XCTAssertNil(transaction.revocationDate)
            }
        }
        XCTAssertTrue(verified, "Must be a genuine locally verified StoreKit transaction")
        XCTAssertEqual(store.deletionGate(itemCount: 100_000, bytes: .max, now: .distantFuture), .allowed)
    }
    func testFreshServiceRestoreUsesRealSyncAndCurrentEntitlements() async throws {
        let original = service(); let product = try await loaded(original)
        await original.purchase(product)
        try await eventually { original.entitlement == .lifetime }
        XCTAssertEqual(original.entitlement, .lifetime)
        let fresh = service()
        XCTAssertEqual(fresh.entitlement, .none)
        await fresh.restore()
        XCTAssertEqual(fresh.entitlement, .lifetime)
        XCTAssertEqual(fresh.state, .available)
        XCTAssertFalse(fresh.operationInProgress)
    }
    func testRefundUpdatesRevokeLifetimeWithoutResettingFreeQuota() async throws {
        let store = service(); let product = try await loaded(store)
        XCTAssertTrue(store.recordFreeDeletion(items: 100, bytes: 5_000_000_000))
        await store.purchase(product)
        try await eventually { store.entitlement == .lifetime }
        XCTAssertEqual(store.entitlement, .lifetime)
        try session.refundTransaction(identifier: try transaction().identifier)
        // No refresh/load call: production Transaction.updates must revoke access itself.
        try await eventually { store.entitlement == .none }
        if let latest = await Transaction.latest(for: product.id), case .verified(let refunded) = latest {
            XCTAssertNotNil(refunded.revocationDate)
        } else { XCTFail("Refund must be a verified StoreKit revocation") }
        XCTAssertEqual(defaults.integer(forKey: "clearkeep.free.deletedItems"), 100)
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: 1), .purchaseRequired)
        let fresh = service(); await fresh.load()
        XCTAssertEqual(fresh.entitlement, .none)
        XCTAssertEqual(fresh.deletionGate(itemCount: 1, bytes: 1), .purchaseRequired)
    }
    func testAskToBuyPendingThenApprovedUnlocksThroughLiveUpdates() async throws {
        session.askToBuyEnabled = true
        let store = service(); let product = try await loaded(store)
        await store.purchase(product)
        XCTAssertEqual(store.entitlement, .none)
        XCTAssertEqual(store.state, .failed("Purchase is pending approval."))
        XCTAssertFalse(store.operationInProgress)
        try session.approveAskToBuyTransaction(identifier: try transaction().identifier)
        try await eventually { store.entitlement == .lifetime }
    }
    func testAskToBuyDeclinedNeverGrantsEntitlementOrConsumesQuota() async throws {
        session.askToBuyEnabled = true
        let store = service(); let product = try await loaded(store)
        XCTAssertTrue(store.recordFreeDeletion(items: 99, bytes: 100))
        await store.purchase(product)
        XCTAssertEqual(store.entitlement, .none)
        try session.declineAskToBuyTransaction(identifier: try transaction().identifier)
        await store.refreshEntitlements()
        XCTAssertEqual(store.entitlement, .none)
        XCTAssertEqual(defaults.integer(forKey: "clearkeep.free.deletedItems"), 99)
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: .max), .allowed)
    }
    func testCancelledAndFailedRealStoreKitPurchasesNeverGrantAccess() async throws {
        let store = service(); let product = try await loaded(store)
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: StoreKitPurchaseAPI())
        await store.purchase(product)
        XCTAssertEqual(store.entitlement, .none)
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertFalse(store.operationInProgress)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: StoreKitPurchaseAPI())
        await store.purchase(product)
        XCTAssertEqual(store.entitlement, .none)
        guard case .failed = store.state else { return XCTFail("Network error must be reported") }
        XCTAssertEqual(defaults.integer(forKey: "clearkeep.free.deletedItems"), 0)
    }
    func testWrongCatalogIdentifierFailsSafelyWithoutLifetime() async throws {
        let store = service(id: "com.clearkeep.not-a-real-product")
        await store.load()
        XCTAssertTrue(store.products.isEmpty)
        guard case .unavailable = store.state else { return XCTFail("Unknown product must be unavailable") }
        XCTAssertEqual(store.entitlement, .none)
        XCTAssertEqual(store.deletionGate(itemCount: 1, bytes: .max), .allowed)
    }

    /// Independent official local-store control. It does not replace production purchase coverage.
    func testLocalSessionControlCreatesVerifiedTransaction() async throws {
        let store = service(); let product = try await loaded(store)
        let transaction = try await session.buyProduct(identifier: product.id)
        XCTAssertEqual(transaction.productID, product.id)
        print("Official local-session control transaction id: \(transaction.id)")
        try await eventually { store.entitlement == .lifetime }
        await store.refreshEntitlements()
        XCTAssertEqual(store.entitlement, .lifetime)
        guard let latest = await Transaction.latest(for: product.id) else {
            return XCTFail("Official local-session control has no latest transaction")
        }
        if case .unverified(_, let error) = latest { print("Official local-session verification error: \(error)") }
        guard case .verified = latest else {
            return XCTFail("Official local-session control must produce a verified transaction")
        }
    }
}
