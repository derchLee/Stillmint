import Foundation
import Security

/// Protected local source/output mapping. Clearing Activity must never delete this file.
final class FileCompressionOperationStore: CompressionOperationStoring, @unchecked Sendable {
    private struct Envelope: Codable { var version = 1; var operations: [CompressionOperation] }
    private let directory: URL
    private let lock = NSLock()
    private var url: URL { directory.appendingPathComponent("operations.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CompressionOperations", isDirectory: true)
    }
    func load(id: UUID) throws -> CompressionOperation? { try all().first { $0.id == id } }
    func all() throws -> [CompressionOperation] { try lock.withLock { try readUnlocked() } }
    func save(_ operation: CompressionOperation) throws {
        try lock.withLock {
            guard Self.isSupported(operation) else { throw CompressionFailure.persistence }
            var operations = try readUnlocked()
            operations.removeAll { $0.id == operation.id }; operations.append(operation)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
            try JSONEncoder().encode(Envelope(operations: operations)).write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
    private func readUnlocked() throws -> [CompressionOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1, Set(envelope.operations.map(\.id)).count == envelope.operations.count,
                  envelope.operations.allSatisfy(Self.isSupported) else { throw CompressionFailure.persistence }
            return envelope.operations
        } catch { throw CompressionFailure.persistence }
    }
    private static func isSupported(_ operation: CompressionOperation) -> Bool {
        operation.algorithmVersion == 1 && !operation.sourceID.isEmpty
            && (operation.outputID == nil || operation.outputID != operation.sourceID)
    }
}

@MainActor
final class KeychainCompressionQuotaLedger: CompressionQuotaLedger {
    private struct Envelope: Codable { var version = 1; var snapshot: CompressionQuotaSnapshot }
    private let service = "com.clearkeep.compression-quota"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "successful-free-operations"] }
    func read() throws -> CompressionQuotaSnapshot {
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return CompressionQuotaSnapshot() }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.snapshot.consumedCount <= 10 else { throw CompressionFailure.persistence }
        return value.snapshot
    }
    func commit(operationID: UUID) throws {
        var snapshot = try read()
        if snapshot.consumedOperationIDs.contains(operationID) { return }
        guard snapshot.consumedCount < 10 else { throw CompressionFailure.purchaseRequired }
        snapshot.consumedOperationIDs.insert(operationID)
        let data = try JSONEncoder().encode(Envelope(snapshot: snapshot))
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CompressionFailure.persistence }
    }
}
