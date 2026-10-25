import AVKit
import CryptoKit
import Photos
import PhotosUI
import Security
import StoreKit
import SwiftUI

enum LibraryAccess: Equatable { case notDetermined, limited, full, denied }
enum MediaCategory: String, CaseIterable, Codable {
    case recommended = "Recommended first batch"
    case screenshots = "Screenshots"
    case screenRecordings = "Screen recordings"
    case largeVideos = "Large videos"
    case exactDuplicates = "Exact duplicates"
    case similar = "Similar photos"
}

struct LibraryItem: Identifiable, Hashable, Codable {
    let id: String
    let category: MediaCategory
    let createdAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let estimatedBytes: Int64
    let isFavorite: Bool
    let isEdited: Bool
    let isVideo: Bool
    let duplicateGroup: String?
    var isSuggestedKeeper: Bool = false

    var isProtected: Bool { isFavorite || isEdited }
    var title: String { isVideo ? "Video" : "Photo" }
    func regrouped(category: MediaCategory, group: String?, keeper: Bool) -> LibraryItem {
        LibraryItem(id: id, category: category, createdAt: createdAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, estimatedBytes: estimatedBytes, isFavorite: isFavorite, isEdited: isEdited, isVideo: isVideo, duplicateGroup: group, isSuggestedKeeper: keeper)
    }
    var optimizationCandidate: CKMediaCandidate {
        let kind: CKMediaKind = isVideo ? (category == .screenRecordings ? .screenRecording : .video) : category == .screenshots ? .screenshot : category == .similar ? .similar : duplicateGroup == nil ? .photo : .exactDuplicate
        return CKMediaCandidate(id: id, groupID: duplicateGroup, kind: kind, createdAt: createdAt, estimatedBytes: estimatedBytes, pixelWidth: pixelWidth, pixelHeight: pixelHeight, isFavorite: isFavorite, isEdited: isEdited, previewAvailable: isVideo)
    }
}

struct ScanCheckpoint: Codable {
    // v3 stores raw metadata and content modification identities. Legacy caches rescan.
    var schemaVersion = 3
    var modificationIdentities: [String: String] = [:]
    var analyzedIdentifiers: Set<String> = []
    var items: [LibraryItem] = []
    var fingerprints: [String: String] = [:]
    var updatedAt = Date()

    mutating func needsAnalysis(identifier: String, modificationIdentity: String?) -> Bool {
        let changed = !analyzedIdentifiers.contains(identifier) || modificationIdentity == nil || modificationIdentities[identifier] != modificationIdentity
        if changed {
            fingerprints.removeValue(forKey: identifier)
            modificationIdentities[identifier] = modificationIdentity
            analyzedIdentifiers.insert(identifier)
        }
        return changed
    }

    mutating func reconcile(currentIdentifiers: Set<String>) {
        analyzedIdentifiers.formIntersection(currentIdentifiers)
        items.removeAll { !currentIdentifiers.contains($0.id) }
        fingerprints = fingerprints.filter { currentIdentifiers.contains($0.key) }
        modificationIdentities = modificationIdentities.filter { currentIdentifiers.contains($0.key) }
    }
}

struct CandidateFinalization {
    let items: [LibraryItem]
    /// Deterministic collection/membership operations for scale regression tests.
    let operationCount: Int
}

final class OneShotContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(returning value: sending Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

final class ResourceStatsContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Int64, String)?, Never>?
    private var bytes: Int64 = 0
    private var hasher = SHA256()

    init(_ continuation: CheckedContinuation<(Int64, String)?, Never>) { self.continuation = continuation }

    func append(_ data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        bytes += Int64(data.count)
        hasher.update(data: data)
        lock.unlock()
    }

    func finish(error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = error == nil ? (bytes, Data(hasher.finalize()).base64EncodedString()) : nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

enum PhotoKitCallbackBridge {
    static func resourceStats(_ resource: PHAssetResource) async -> (Int64, String)? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            let box = ResourceStatsContinuationBox(continuation)
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data in
                box.append(data)
            }, completionHandler: { error in
                box.finish(error: error)
            })
        }
    }

    static func thumbnail(manager: PHImageManager, asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox<UIImage?>(continuation)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !degraded { box.resume(returning: image) }
            }
        }
    }

    static func image(manager: PHImageManager, asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox<UIImage?>(continuation)
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                box.resume(returning: data.flatMap(UIImage.init(data:)))
            }
        }
    }

    static func playerItem(manager: PHImageManager, asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox<AVPlayerItem?>(continuation)
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                box.resume(returning: item)
            }
        }
    }
}

@MainActor
protocol PhotoLibraryServing: AnyObject {
    var access: LibraryAccess { get }
    var unavailableAssetCount: Int { get }
    var visualUnavailableCount: Int { get }
    func refreshAccess()
    func requestAccess() async -> LibraryAccess
    func manageAccess()
    func scanIncrementally(progress: @escaping (Int, Int) -> Void) async throws -> [LibraryItem]
    func thumbnail(identifier: String, targetSize: CGSize) async -> UIImage?
    func image(identifier: String) async -> UIImage?
    func playerItem(identifier: String) async -> AVPlayerItem?
    func existingIdentifiers(_ identifiers: Set<String>) -> Set<String>
    func delete(identifiers: Set<String>) async throws
    var allVideos: [LibraryItem] { get }
    var similarityClusters: [SimilarityCluster] { get }
    func setScanProtection(rules: ProtectionRules, manuallyProtectedIDs: Set<String>)
    func refreshedProtectionItems(_ items: [LibraryItem]) -> [LibraryItem]
}

extension PhotoLibraryServing {
    var visualUnavailableCount: Int { 0 }
    var allVideos: [LibraryItem] { [] }
    var similarityClusters: [SimilarityCluster] { [] }
    func setScanProtection(rules: ProtectionRules, manuallyProtectedIDs: Set<String>) {}
    func refreshedProtectionItems(_ items: [LibraryItem]) -> [LibraryItem] { items }
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject, PhotoLibraryServing, @preconcurrency PHPhotoLibraryChangeObserver {
    @Published private(set) var access: LibraryAccess = .notDetermined
    @Published private(set) var changeToken = 0
    @Published private(set) var unavailableAssetCount = 0
    private(set) var visualUnavailableCount = 0
    private(set) var allVideos: [LibraryItem] = []
    private(set) var similarityClusters: [SimilarityCluster] = []
    private var scanRules = ProtectionRules()
    private var scanManualIDs = Set<String>()
    func setScanProtection(rules: ProtectionRules, manuallyProtectedIDs: Set<String>) { scanRules = rules; scanManualIDs = manuallyProtectedIDs }
    func refreshedProtectionItems(_ items: [LibraryItem]) -> [LibraryItem] {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: items.map(\.id), options: nil)
        var assets: [String: PHAsset] = [:]
        for index in 0..<fetch.count { let asset = fetch.object(at: index); assets[asset.localIdentifier] = asset }
        return items.compactMap { item in
            guard let asset = assets[item.id], let fresh = classifyMetadata(asset, includeSmallVideos: true) else { return nil }
            return LibraryItem(id: item.id, category: item.category, createdAt: fresh.createdAt, pixelWidth: fresh.pixelWidth, pixelHeight: fresh.pixelHeight, duration: fresh.duration, estimatedBytes: fresh.estimatedBytes, isFavorite: fresh.isFavorite, isEdited: fresh.isEdited, isVideo: fresh.isVideo, duplicateGroup: item.duplicateGroup, isSuggestedKeeper: item.isSuggestedKeeper)
        }
    }
    private let imageManager = PHCachingImageManager()
    private let checkpointURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isObservingChanges = false

    override init() {
        checkpointURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("clearkeep-scan.json")
        super.init()
        refreshAccess()
        if access == .full || access == .limited { beginObservingChanges() }
    }

    deinit { if isObservingChanges { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }

    func refreshAccess() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: access = .full
        case .limited: access = .limited
        case .denied, .restricted: access = .denied
        case .notDetermined: access = .notDetermined
        @unknown default: access = .denied
        }
    }

    func requestAccess() async -> LibraryAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshAccess()
        if access == .full || access == .limited { beginObservingChanges() }
        return access
    }

    private func beginObservingChanges() {
        guard !isObservingChanges else { return }
        PHPhotoLibrary.shared().register(self)
        isObservingChanges = true
    }

    func manageAccess() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        if access == .limited { PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) }
        else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    func scanIncrementally(progress: @escaping (Int, Int) -> Void) async throws -> [LibraryItem] {
        guard access == .full || access == .limited else { return [] }
        var checkpoint = loadCheckpoint()
        var itemByID = Dictionary(checkpoint.items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        let total = assets.count
        var currentIDs = Set<String>()
        unavailableAssetCount = 0
        visualUnavailableCount = 0
        allVideos = []
        for index in 0..<total {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            if asset.mediaType == .video, let video = classifyMetadata(asset, includeSmallVideos: true) { allVideos.append(video) }
            currentIDs.insert(asset.localIdentifier)
            let identity = asset.modificationDate.map { "\($0.timeIntervalSince1970)-\(asset.pixelWidth)-\(asset.pixelHeight)-\(asset.duration)" }
            if checkpoint.needsAnalysis(identifier: asset.localIdentifier, modificationIdentity: identity) {
                itemByID[asset.localIdentifier] = classifyMetadata(asset)
            }
            if index.isMultiple(of: 50) || index == total - 1 {
                checkpoint.items = Array(itemByID.values)
                checkpoint.items.removeAll { !currentIDs.contains($0.id) && checkpoint.analyzedIdentifiers.contains($0.id) && index == total - 1 }
                checkpoint.updatedAt = Date()
                try save(checkpoint)
                progress(index + 1, total)
                await Task.yield()
            }
        }
        // Exact hashing is deliberately lazy and bounded. Metadata groups make unrelated
        // assets ineligible, while the budget prevents one scan from streaming a huge library.
        let hashBudget = 500
        let hashCandidates = Dictionary(grouping: checkpoint.items.filter { $0.category == .exactDuplicates }) {
            "\($0.pixelWidth)x\($0.pixelHeight)-\($0.estimatedBytes)"
        }.values.filter { $0.count > 1 }.flatMap { $0 }.filter { checkpoint.fingerprints[$0.id] == nil }.prefix(hashBudget)
        for item in hashCandidates {
            try Task.checkCancellation()
            guard let asset = fetch(item.id) else { unavailableAssetCount += 1; continue }
            guard let resource = PHAssetResource.assetResources(for: asset).first else { unavailableAssetCount += 1; continue }
            if let stats = await PhotoKitCallbackBridge.resourceStats(resource) { checkpoint.fingerprints[asset.localIdentifier] = stats.1 }
            else { unavailableAssetCount += 1 }
        }
        checkpoint.reconcile(currentIdentifiers: currentIDs)
        try save(checkpoint)
        let raw = checkpoint.items
        let protection = scanRules.evaluate(candidates: raw.map(\.optimizationCandidate), albumSnapshot: PhotoAlbumAdapter.snapshot(), manuallyProtectedIDs: scanManualIDs)
        let hashGroups = Dictionary(grouping: raw.filter { $0.category == .exactDuplicates && checkpoint.fingerprints[$0.id] != nil }) { checkpoint.fingerprints[$0.id]! }.filter { $0.value.count > 1 }
        let exactIDs = Set(hashGroups.values.flatMap { $0.map(\.id) })
        let eligible = raw.filter { $0.category == .exactDuplicates && !exactIDs.contains($0.id) && !protection.excludedIDs.contains($0.id) }
        let visual = protection.unknownBoundary ? nil : try await VisionSimilarityAdapter().analyze(eligible.map(\.optimizationCandidate))
        similarityClusters = visual?.clusters ?? []
        visualUnavailableCount = visual?.unavailableIDs.count ?? 0
        let byID = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, $0) })
        var output = raw.filter { $0.category == .screenshots || $0.isVideo }
        for (hash, members) in hashGroups {
            for item in members { output.append(item.regrouped(category: .exactDuplicates, group: "exact-" + hash, keeper: false)) }
        }
        for cluster in similarityClusters {
            for id in cluster.memberIDs { if let item = byID[id] { output.append(item.regrouped(category: .similar, group: cluster.id, keeper: cluster.keeper?.id == id)) } }
        }
        return output
    }

    private func classifyMetadata(_ asset: PHAsset, includeSmallVideos: Bool = false) -> LibraryItem? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Public PhotoKit exposes no resource byte count without reading the resource.
        // Use a conservative estimate for the review UI and label it as estimated.
        let pixels = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
        let bytes = asset.mediaType == .video
            ? max(1, Int64(asset.duration * 6_000_000 / 8))
            : max(1, pixels / 4)
        let edited = resources.contains { $0.type == .adjustmentData || $0.type == .adjustmentBasePhoto }
        let category: MediaCategory?
        if asset.mediaType == .image && asset.mediaSubtypes.contains(.photoScreenshot) { category = .screenshots }
        else if asset.mediaType == .video && asset.mediaSubtypes.contains(.videoScreenRecording) { category = .screenRecordings }
        else if asset.mediaType == .video && (includeSmallVideos || bytes >= 100 * 1_024 * 1_024) { category = .largeVideos }
        else if asset.mediaType == .image { category = .exactDuplicates }
        else { category = nil }
        guard let category else { return nil }
        return LibraryItem(id: asset.localIdentifier, category: category, createdAt: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration, estimatedBytes: bytes, isFavorite: asset.isFavorite, isEdited: edited, isVideo: asset.mediaType == .video, duplicateGroup: nil)
    }

    static func finalizePhotoCandidates(_ items: [LibraryItem], fingerprints: [String: String]) -> CandidateFinalization {
        let hashCounts = Dictionary(grouping: fingerprints.values, by: { $0 }).mapValues(\.count)
        let photos = items.filter { $0.category == .exactDuplicates }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        var result: [LibraryItem] = []
        var emittedIdentifiers = Set<String>()
        var operationCount = fingerprints.count + items.count
        func appendUnique(_ item: LibraryItem) {
            operationCount += 1
            if emittedIdentifiers.insert(item.id).inserted { result.append(item) }
        }
        for item in items where item.category != .exactDuplicates { appendUnique(item) }
        var priorByBucket: [String: LibraryItem] = [:]
        for item in photos {
            operationCount += 1
            if let hash = fingerprints[item.id], (hashCounts[hash] ?? 0) > 1 { appendUnique(item); continue }
            guard let date = item.createdAt else { continue }
            let bucket = "\(Int(date.timeIntervalSince1970 / 3))-\(item.pixelWidth / 100)x\(item.pixelHeight / 100)"
            operationCount += 1
            if let prior = priorByBucket[bucket] {
                let group = "similar-\(bucket)"
                let keeper = LibraryItem(id: prior.id, category: .similar, createdAt: prior.createdAt, pixelWidth: prior.pixelWidth, pixelHeight: prior.pixelHeight, duration: prior.duration, estimatedBytes: prior.estimatedBytes, isFavorite: prior.isFavorite, isEdited: prior.isEdited, isVideo: false, duplicateGroup: group, isSuggestedKeeper: true)
                appendUnique(keeper)
                appendUnique(LibraryItem(id: item.id, category: .similar, createdAt: item.createdAt, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, duration: item.duration, estimatedBytes: item.estimatedBytes, isFavorite: item.isFavorite, isEdited: item.isEdited, isVideo: false, duplicateGroup: group))
            } else { priorByBucket[bucket] = item }
        }
        return CandidateFinalization(items: result, operationCount: operationCount)
    }

    func thumbnail(identifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = fetch(identifier) else { return nil }
        return await PhotoKitCallbackBridge.thumbnail(manager: imageManager, asset: asset, targetSize: targetSize)
    }

    func image(identifier: String) async -> UIImage? {
        guard let asset = fetch(identifier) else { return nil }
        return await PhotoKitCallbackBridge.image(manager: imageManager, asset: asset)
    }

    func playerItem(identifier: String) async -> AVPlayerItem? {
        guard let asset = fetch(identifier) else { return nil }
        return await PhotoKitCallbackBridge.playerItem(manager: imageManager, asset: asset)
    }

    func existingIdentifiers(_ identifiers: Set<String>) -> Set<String> {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var found = Set<String>()
        for index in 0..<result.count { found.insert(result.object(at: index).localIdentifier) }
        return found
    }

    func delete(identifiers: Set<String>) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        guard assets.count == identifiers.count else { throw LibraryError.libraryChanged }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        enqueueLibraryChange()
    }

    /// PhotoKit invokes its observer on a private queue. Keep this Objective-C entry
    /// point free of actor-isolated reads and hop immediately to the UI actor.
    nonisolated func enqueueLibraryChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            changeToken += 1
            refreshAccess()
        }
    }

    private func fetch(_ identifier: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject }
    private func loadCheckpoint() -> ScanCheckpoint { (try? Data(contentsOf: checkpointURL)).flatMap { try? decoder.decode(ScanCheckpoint.self, from: $0) } ?? ScanCheckpoint() }
    private func save(_ value: ScanCheckpoint) throws {
        try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: checkpointURL, options: [.atomic, .completeFileProtection])
    }
    enum LibraryError: Error { case libraryChanged }
}

struct StoreProduct: Identifiable, Equatable {
    let id: String
    let displayName: String
    let displayPrice: String
    fileprivate let product: Product
}

enum DeletionGate: Equatable { case allowed, purchaseRequired, unavailable }
enum PaidEntitlement: Equatable { case none, lifetime, legacy(expires: Date) }
struct EntitlementRecord: Equatable {
    let productID: String
    let purchaseDate: Date
    let expirationDate: Date?
    let isRevoked: Bool
}
struct FreeQuota: Codable, Equatable {
    var items: Int
    var bytes: Int64
    var deletionOperationIDs: Set<UUID> = []
    enum CodingKeys: String, CodingKey { case items, bytes, deletionOperationIDs }
    init(items: Int, bytes: Int64, deletionOperationIDs: Set<UUID> = []) { self.items = items; self.bytes = bytes; self.deletionOperationIDs = deletionOperationIDs }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode(Int.self, forKey: .items); bytes = try values.decode(Int64.self, forKey: .bytes)
        deletionOperationIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .deletionOperationIDs) ?? []
    }
}
enum QuotaLedgerError: Error, Equatable { case unavailable(OSStatus), corrupt, writeFailed(OSStatus) }

@MainActor protocol QuotaLedger: AnyObject {
    func read() throws -> FreeQuota
    func write(_ quota: FreeQuota) throws
}

@MainActor final class KeychainQuotaLedger: QuotaLedger {
    func read() throws -> FreeQuota {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clearkeep.free-quota", kSecAttrAccount as String: "ledger", kSecReturnData as String: true]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return FreeQuota(items: 0, bytes: 0) }
        guard status == errSecSuccess, let data = result as? Data else { throw QuotaLedgerError.unavailable(status) }
        guard let quota = try? JSONDecoder().decode(FreeQuota.self, from: data), quota.items >= 0, quota.bytes >= 0 else { throw QuotaLedgerError.corrupt }
        return quota
    }
    func write(_ quota: FreeQuota) throws {
        let data = try JSONEncoder().encode(quota)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clearkeep.free-quota", kSecAttrAccount as String: "ledger"]
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var add = base; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; status = SecItemAdd(add as CFDictionary, nil) }
        guard status == errSecSuccess else { throw QuotaLedgerError.writeFailed(status) }
    }
}

@MainActor final class DefaultsQuotaLedger: QuotaLedger {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func read() throws -> FreeQuota {
        if let data = defaults.data(forKey: "clearkeep.free.quota.v2") { return try JSONDecoder().decode(FreeQuota.self, from: data) }
        return FreeQuota(items: defaults.integer(forKey: "clearkeep.free.deletedItems"), bytes: (defaults.object(forKey: "clearkeep.free.deletedBytes") as? NSNumber)?.int64Value ?? 0)
    }
    func write(_ quota: FreeQuota) throws {
        defaults.set(try JSONEncoder().encode(quota), forKey: "clearkeep.free.quota.v2")
        // Legacy mirrors remain readable for existing diagnostics; the single envelope is authoritative.
        defaults.set(quota.items, forKey: "clearkeep.free.deletedItems"); defaults.set(quota.bytes, forKey: "clearkeep.free.deletedBytes")
    }
}

@MainActor
final class StoreService: ObservableObject {
    static let defaultLifetimeProductID = "com.clearkeep.lifetime"
    static let legacyCleanupPassProductID = "com.clearkeep.cleanup_pass_30d"
    static let legacyAnnualProductID = "com.clearkeep.pro.annual"
    enum State: Equatable { case loading, unavailable(String), available, cancelled, failed(String) }
    @Published private(set) var state: State = .loading
    @Published private(set) var products: [StoreProduct] = []
    @Published private(set) var entitlement: PaidEntitlement = .none
    let saleIdentifiers: [String]
    private let ledger: QuotaLedger
    private let liveEntitlements: Bool
    private var quotaAvailable = true
    private var updatesTask: Task<Void, Never>?
    @Published private(set) var operationInProgress = false

    init(defaults: UserDefaults = .standard, initialEntitlement: PaidEntitlement = .none, durableQuota: Bool = true, ledger: QuotaLedger? = nil, liveEntitlements: Bool = true, lifetimeProductID: String? = nil) {
        self.entitlement = initialEntitlement
        self.ledger = ledger ?? (durableQuota ? KeychainQuotaLedger() : DefaultsQuotaLedger(defaults))
        self.liveEntitlements = liveEntitlements
        let configured = lifetimeProductID ?? (Bundle.main.object(forInfoDictionaryKey: "CKLifetimeProductID") as? String)
        let identifier = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.saleIdentifiers = [identifier.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultLifetimeProductID]
        if liveEntitlements {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    guard !Task.isCancelled, let self else { return }
                    if case .verified(let transaction) = update { await transaction.finish() }
                    await self.refreshEntitlements()
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func load() async {
        await refreshEntitlements()
        do {
            let loaded = try await Product.products(for: saleIdentifiers)
            products = loaded.filter { saleIdentifiers.contains($0.id) && $0.type == .nonConsumable }.map { StoreProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice, product: $0) }
            state = Self.catalogIsAvailable(loadedProductIDs: products.map(\.id), saleIdentifiers: saleIdentifiers) ? .available : .unavailable("Lifetime Unlock is unavailable. You can still scan and preview.")
        } catch { state = .unavailable("Purchases are unavailable. You can still scan and preview.") }
    }

    func purchase(_ item: StoreProduct) async {
        guard !operationInProgress, saleIdentifiers == [item.id], item.product.type == .nonConsumable else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            switch try await item.product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { state = .failed("Purchase could not be verified."); return }
                await transaction.finish(); await refreshEntitlements(); state = .available
            case .userCancelled: state = .cancelled
            case .pending: state = .failed("Purchase is pending approval.")
            @unknown default: state = .failed("Purchase did not complete.")
            }
        } catch { state = .failed("Purchase did not complete. Your selections are still here.") }
    }

    func restore() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        do { try await AppStore.sync(); await load() } catch { state = .failed("Restore purchases failed.") }
    }

    func refreshEntitlements(now: Date = Date()) async {
        var records: [EntitlementRecord] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            records.append(EntitlementRecord(productID: transaction.productID, purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate, isRevoked: transaction.revocationDate != nil))
        }
        entitlement = Self.resolveEntitlement(records: records, lifetimeProductID: saleIdentifiers[0], now: now)
    }

    static func catalogIsAvailable(loadedProductIDs: [String], saleIdentifiers: [String]) -> Bool {
        saleIdentifiers.count == 1 && Set(loadedProductIDs) == Set(saleIdentifiers)
    }

    static func resolveEntitlement(records: [EntitlementRecord], lifetimeProductID: String = defaultLifetimeProductID, now: Date = Date()) -> PaidEntitlement {
        if records.contains(where: { $0.productID == lifetimeProductID && !$0.isRevoked }) { return .lifetime }
        let expiries = records.compactMap { record -> Date? in
            guard !record.isRevoked else { return nil }
            if record.productID == legacyCleanupPassProductID {
                return record.expirationDate ?? record.purchaseDate.addingTimeInterval(30 * 24 * 60 * 60)
            }
            if record.productID == legacyAnnualProductID { return record.expirationDate }
            return nil
        }.filter { $0 > now }
        return expiries.max().map(PaidEntitlement.legacy(expires:)) ?? .none
    }

    func deletionGate(itemCount: Int, bytes: Int64, now: Date = Date()) -> DeletionGate {
        switch entitlement {
        case .lifetime: return .allowed
        case .legacy(let expiry) where expiry > now: return .allowed
        case .legacy: entitlement = .none
        case .none: break
        }
        guard quotaAvailable, let quota = try? ledger.read() else { quotaAvailable = false; state = .failed("Free allowance could not be verified. Deletion is disabled."); return .unavailable }
        let usedItems = quota.items
        // Keep the legacy byte ledger readable, but only confirmed item count gates deletion.
        if usedItems >= 0 && usedItems <= 100 && itemCount >= 0 && itemCount <= 100 - usedItems { return .allowed }
        return state == .available ? .purchaseRequired : .unavailable
    }

    func deletionGateRefreshing(itemCount: Int, bytes: Int64, now: Date = Date()) async -> DeletionGate {
        if liveEntitlements { await refreshEntitlements(now: now) }
        return deletionGate(itemCount: itemCount, bytes: bytes, now: now)
    }
    @discardableResult func recordFreeDeletion(items: Int, bytes: Int64, now: Date = Date()) -> Bool {
        switch entitlement {
        case .lifetime: return true
        case .legacy(let expiry) where expiry > now: return true
        case .legacy: entitlement = .none
        case .none: break
        }
        do { try commitJournalDeletion(operationID: UUID(), items: items, bytes: bytes, consumesFreeAllowance: true); return true }
        catch { quotaAvailable = false; state = .failed("Free allowance could not be saved. Further deletion is disabled."); return false }
    }
    var usesFreeDeletionAllowance: Bool {
        switch entitlement { case .lifetime: return false; case .legacy(let expiry) where expiry > Date(): return false; default: return true }
    }
    func commitJournalDeletion(operationID: UUID, items: Int, bytes: Int64, consumesFreeAllowance: Bool) throws {
        guard consumesFreeAllowance, items > 0 else { return }
        var current = try ledger.read()
        if current.deletionOperationIDs.contains(operationID) { quotaAvailable = true; return }
        guard current.items >= 0, items <= 100, current.items <= 100 - items, bytes >= 0 else { throw QuotaLedgerError.corrupt }
        current.items += items
        let (sum, overflow) = current.bytes.addingReportingOverflow(bytes); current.bytes = overflow ? Int64.max : sum
        current.deletionOperationIDs.insert(operationID)
        try ledger.write(current)
        quotaAvailable = true
    }
}
