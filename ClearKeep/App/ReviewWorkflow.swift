import Foundation

enum ReviewDecision: String, Codable, Equatable { case undecided, keepForNow, delete, skip }

struct ReviewCandidateSnapshot: Codable, Equatable, Hashable {
    let id: String
    let groupID: String?
    let estimatedBytes: Int64
}

struct ReviewSession: Codable, Equatable {
    let category: MediaCategory
    var candidates: [ReviewCandidateSnapshot]
    var batchSize = 20
    var cursor = 0
    var decisions: [String: ReviewDecision] = [:]
    var unlockedIDs = Set<String>()
    var keeperOverrides: [String: String]? = nil
    var resolvedRecentCutoff: Date? = nil
    var protectionFingerprint: String? = nil

    mutating func applyDeletion(deleted: Set<String>, unchanged: Set<String>) {
        candidates.removeAll { deleted.contains($0.id) }
        for id in deleted { decisions.removeValue(forKey: id); unlockedIDs.remove(id) }
        for id in unchanged { decisions[id] = .delete }
        cursor = 0
    }
}

struct ReviewBatch: Equatable {
    let candidateIDs: [String]
    let number: Int
    let totalBatches: Int
    let completedCount: Int
}

struct DeletionPlan: Equatable { let identifiers: Set<String> }

enum ReviewBatcher {
    static func currentBatch(for session: ReviewSession, excludedIDs: Set<String> = []) -> ReviewBatch {
        let unresolved = session.candidates.filter { candidate in
            !excludedIDs.contains(candidate.id) && (session.decisions[candidate.id] ?? .undecided) != .keepForNow
        }
        let batches = buildBatches(unresolved, target: session.batchSize)
        let index = min(session.cursor, max(0, batches.count - 1))
        return ReviewBatch(candidateIDs: batches.isEmpty ? [] : batches[index].map(\.id), number: batches.isEmpty ? 0 : index + 1, totalBatches: batches.count, completedCount: session.candidates.count - unresolved.count)
    }

    static func deletionPlan(for session: ReviewSession, excludedIDs: Set<String> = []) -> DeletionPlan {
        let visible = Set(currentBatch(for: session, excludedIDs: excludedIDs).candidateIDs)
        return DeletionPlan(identifiers: Set(session.decisions.compactMap { id, decision in decision == .delete && visible.contains(id) && !excludedIDs.contains(id) ? id : nil }))
    }

    private static func buildBatches(_ candidates: [ReviewCandidateSnapshot], target: Int) -> [[ReviewCandidateSnapshot]] {
        guard target > 0 else { return [] }
        var units: [[ReviewCandidateSnapshot]] = []
        var seenGroups = Set<String>()
        for item in candidates {
            guard let group = item.groupID else { units.append([item]); continue }
            guard seenGroups.insert(group).inserted else { continue }
            units.append(candidates.filter { $0.groupID == group })
        }
        var batches: [[ReviewCandidateSnapshot]] = [], current: [ReviewCandidateSnapshot] = []
        for unit in units {
            if !current.isEmpty && current.count + unit.count > target { batches.append(current); current = [] }
            current.append(contentsOf: unit)
            if current.count >= target { batches.append(current); current = [] }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

struct ReviewCheckpoint: Codable, Equatable {
    let schemaVersion: Int
    let scopeFingerprint: String
    var session: ReviewSession
    var updatedAt: Date
    init(scopeFingerprint: String, session: ReviewSession, updatedAt: Date = .now) { schemaVersion = 1; self.scopeFingerprint = scopeFingerprint; self.session = session; self.updatedAt = updatedAt }
}

enum ReviewCheckpointError: Error { case corrupt, unsupportedVersion }
protocol ReviewCheckpointStoring: AnyObject {
    var resumeOffer: ReviewCheckpoint? { get }
    func load() throws -> ReviewCheckpoint?
    func save(_ checkpoint: ReviewCheckpoint) throws
    func clear() throws
}

final class FileReviewCheckpointStore: ReviewCheckpointStoring {
    private let url: URL
    private(set) var resumeOffer: ReviewCheckpoint?
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("clearkeep-review-v1.json")
        resumeOffer = try? load()
    }
    func load() throws -> ReviewCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ReviewCheckpoint.self, from: Data(contentsOf: url))
            guard decoded.schemaVersion == 1 else { throw ReviewCheckpointError.unsupportedVersion }
            resumeOffer = decoded; return decoded
        } catch let error as ReviewCheckpointError { resumeOffer = nil; throw error }
        catch { resumeOffer = nil; throw ReviewCheckpointError.corrupt }
    }
    func save(_ checkpoint: ReviewCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: [.atomic, .completeFileProtection])
        resumeOffer = checkpoint
    }
    func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; resumeOffer = nil }
}

final class InMemoryReviewCheckpointStore: ReviewCheckpointStoring {
    private var data: Data?
    private(set) var resumeOffer: ReviewCheckpoint?
    init(rawData: Data? = nil) { data = rawData }
    func load() throws -> ReviewCheckpoint? {
        guard let data else { return nil }
        guard let value = try? JSONDecoder().decode(ReviewCheckpoint.self, from: data) else { resumeOffer = nil; throw ReviewCheckpointError.corrupt }
        guard value.schemaVersion == 1 else { resumeOffer = nil; throw ReviewCheckpointError.unsupportedVersion }
        resumeOffer = value; return value
    }
    func save(_ checkpoint: ReviewCheckpoint) throws { data = try JSONEncoder().encode(checkpoint); resumeOffer = checkpoint }
    func clear() throws { data = nil; resumeOffer = nil }
}

enum ProtectionReason: String, Codable, Hashable { case systemFavorite, edited, userSkipped }
struct ProtectedItemRecord: Codable, Equatable, Identifiable {
    let id: String
    var reasons: Set<ProtectionReason>
    let createdAt: Date
    var lastSeenAt: Date
}
protocol ProtectedItemStoring: AnyObject {
    func records() throws -> [ProtectedItemRecord]
    func upsert(_ record: ProtectedItemRecord) throws
    func removeUserSkipped(id: String) throws
    func reconcile(existingIDs: Set<String>) throws
}
enum ProtectionPolicy {
    static func isProtected(systemReasons: Set<ProtectionReason>, persistentReasons: Set<ProtectionReason>) -> Bool { !systemReasons.union(persistentReasons).isEmpty }
}

private struct ProtectedItemsEnvelope: Codable {
    let schemaVersion: Int
    var records: [ProtectedItemRecord]
}

enum ProtectedItemStoreError: Error { case corrupt, unsupportedVersion }

final class FileProtectedItemStore: ProtectedItemStoring {
    private let url: URL
    init(url: URL? = nil) { self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("clearkeep-protected-v1.json") }
    func records() throws -> [ProtectedItemRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(ProtectedItemsEnvelope.self, from: Data(contentsOf: url))
            guard envelope.schemaVersion == 1 else { throw ProtectedItemStoreError.unsupportedVersion }
            return envelope.records
        } catch let error as ProtectedItemStoreError { throw error }
        catch { throw ProtectedItemStoreError.corrupt }
    }
    func upsert(_ record: ProtectedItemRecord) throws { var values = try records(); values.removeAll { $0.id == record.id }; values.append(record); try persist(values) }
    func removeUserSkipped(id: String) throws { var values = try records(); if let index = values.firstIndex(where: { $0.id == id }) { values[index].reasons.remove(.userSkipped); if values[index].reasons.isEmpty { values.remove(at: index) } }; try persist(values) }
    func reconcile(existingIDs: Set<String>) throws { try persist(try records().filter { existingIDs.contains($0.id) }) }
    private func persist(_ values: [ProtectedItemRecord]) throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(ProtectedItemsEnvelope(schemaVersion: 1, records: values)).write(to: url, options: [.atomic, .completeFileProtection]) }
}

final class InMemoryProtectedItemStore: ProtectedItemStoring {
    var values: [ProtectedItemRecord] = []
    func records() throws -> [ProtectedItemRecord] { values }
    func upsert(_ record: ProtectedItemRecord) throws { values.removeAll { $0.id == record.id }; values.append(record) }
    func removeUserSkipped(id: String) throws { if let index = values.firstIndex(where: { $0.id == id }) { values[index].reasons.remove(.userSkipped); if values[index].reasons.isEmpty { values.remove(at: index) } } }
    func reconcile(existingIDs: Set<String>) throws { values.removeAll { !existingIDs.contains($0.id) } }
}
