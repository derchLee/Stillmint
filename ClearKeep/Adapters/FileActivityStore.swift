import Foundation

enum ActivityStoreError: Error { case corrupt, unsupportedVersion }
final class FileActivityStore: ActivityStoring {
    private struct Envelope: Codable { let schemaVersion: Int; let entries: [ActivityReceipt] }
    let url: URL
    private let now: () -> Date
    init(url: URL, now: @escaping () -> Date = Date.init) { self.url = url; self.now = now }
    func load() throws -> [ActivityReceipt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)) else { throw ActivityStoreError.corrupt }
        guard envelope.schemaVersion == 1 else { throw ActivityStoreError.unsupportedVersion }
        return retained(envelope.entries)
    }
    func upsert(_ receipt: ActivityReceipt) throws {
        var values = try load()
        if let existing = values.first(where: { $0.operationID == receipt.operationID }), existing.status != .pendingVerification { return }
        values.removeAll { $0.operationID == receipt.operationID }; values.append(receipt)
        try persist(retained(values))
    }
    func clear() throws { try persist([]) }
    private func retained(_ values: [ActivityReceipt]) -> [ActivityReceipt] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: now()) ?? .distantPast
        return Array(values.filter { $0.date >= cutoff }.sorted { a,b in a.date == b.date ? a.operationID.uuidString < b.operationID.uuidString : a.date > b.date }.prefix(200))
    }
    private func persist(_ entries: [ActivityReceipt]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(schemaVersion: 1, entries: entries)).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
