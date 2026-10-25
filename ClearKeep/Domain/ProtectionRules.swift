import Foundation

struct AlbumSnapshot: Sendable {
    var fullAccess: Bool
    var membersByAlbumID: [String: Set<String>] = [:]
    var titlesByAlbumID: [String: String] = [:]
}
struct ProtectionEvaluation: Equatable, Sendable {
    let excludedIDs: Set<String>
    let reasonCodes: [String: Set<String>]
    let unknownBoundary: Bool
    let cutoff: Date?
}
struct ProtectionRules: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var protectedAlbumIDs: Set<String> = []
    var recentDays: Int? = nil
    func evaluate(candidates: [CKMediaCandidate], albumSnapshot: AlbumSnapshot, now: Date = Date(), calendar: Calendar = .current, resolvedCutoff: Date? = nil, manuallyProtectedIDs: Set<String> = []) -> ProtectionEvaluation {
        let cutoff = resolvedCutoff ?? recentDays.flatMap { [7,30,90].contains($0) ? calendar.date(byAdding: .day, value: -$0, to: now) : nil }
        let unknown = !protectedAlbumIDs.isEmpty && (!albumSnapshot.fullAccess || !protectedAlbumIDs.isSubset(of: Set(albumSnapshot.membersByAlbumID.keys)))
        let albumIDs = protectedAlbumIDs.reduce(into: Set<String>()) { $0.formUnion(albumSnapshot.membersByAlbumID[$1] ?? []) }
        var reasons: [String: Set<String>] = [:]
        for item in candidates {
            var r = Set<String>()
            if item.isFavorite { r.insert("favorite") }; if item.isEdited { r.insert("edited") }
            if manuallyProtectedIDs.contains(item.id) { r.insert("userSkipped") }
            if albumIDs.contains(item.id) { r.insert("album") }
            if let cutoff, item.createdAt == nil || item.createdAt! >= cutoff { r.insert("recent") }
            if !r.isEmpty { reasons[item.id] = r }
        }
        return .init(excludedIDs: Set(reasons.keys), reasonCodes: reasons, unknownBoundary: unknown, cutoff: cutoff)
    }
}
enum ProtectionRulesError: Error { case corrupt, unsupportedVersion }
final class FileProtectionRulesStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> ProtectionRules {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let value = try? JSONDecoder().decode(ProtectionRules.self, from: Data(contentsOf: url)) else { throw ProtectionRulesError.corrupt }
        guard value.schemaVersion == 1, value.recentDays == nil || [7,30,90].contains(value.recentDays!) else { throw ProtectionRulesError.unsupportedVersion }
        return value
    }
    func save(_ value: ProtectionRules) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
