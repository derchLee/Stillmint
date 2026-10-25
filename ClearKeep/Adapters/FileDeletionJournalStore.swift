import Foundation

final class FileDeletionJournalStore: DeletionJournalStoring {
    private struct Envelope: Codable { var version = 1; let entries: [DeletionJournalEntry] }
    private let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("clearkeep-deletion-journal-v1.json")) { self.url = url }
    func load() throws -> [DeletionJournalEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1, Set(envelope.entries.map(\.id)).count == envelope.entries.count,
              envelope.entries.allSatisfy({ $0.exempt.isSubset(of: $0.requested) && $0.confirmedDeleted.isSubset(of: $0.requested) && $0.unchanged.isSubset(of: $0.requested) && $0.confirmedDeleted.isDisjoint(with: $0.unchanged) }) else { throw CocoaError(.fileReadCorruptFile) }
        return envelope.entries
    }
    func save(_ entry: DeletionJournalEntry) throws {
        var entries = try load(); entries.removeAll { $0.id == entry.id }; entries.append(entry)
        // Retain at most the latest terminal receipt alongside unresolved operations.
        entries = entries.filter { $0.phase != .completed || $0.id == entry.id }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(entries: entries)).write(to: url, options: [.atomic, .completeFileProtection])
        var mutableURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
