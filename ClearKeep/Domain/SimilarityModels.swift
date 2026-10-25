import Foundation

enum CKMediaKind: String, Codable, Sendable { case photo, exactDuplicate, similar, screenshot, video, screenRecording }
struct CKMediaCandidate: Codable, Equatable, Sendable {
    let id: String
    var groupID: String? = nil
    let kind: CKMediaKind
    var createdAt: Date? = nil
    var estimatedBytes: Int64 = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var isFavorite = false
    var isEdited = false
    var sharpness: Double? = nil
    var previewAvailable = false
    var modificationDate: Date? = nil
}
enum KeeperReason: String, Codable, Sendable { case favorite, edited, higherResolution, sharper }
struct KeeperSuggestion: Equatable, Sendable { let id: String; let reasons: [KeeperReason] }
enum KeeperPolicy {
    static func suggest(_ values: [CKMediaCandidate]) -> KeeperSuggestion? {
        let sorted = values.sorted { a,b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.isEdited != b.isEdited { return a.isEdited }
            let ap = Int64(a.pixelWidth) * Int64(a.pixelHeight), bp = Int64(b.pixelWidth) * Int64(b.pixelHeight)
            if ap != bp { return ap > bp }
            let sa = a.sharpness.map { Int(($0 * 50).rounded()) } ?? Int.min
            let sb = b.sharpness.map { Int(($0 * 50).rounded()) } ?? Int.min
            if sa != sb { return sa > sb }
            return a.id < b.id
        }
        guard let best = sorted.first, sorted.count > 1 else { return nil }
        var reasons: [KeeperReason] = []
        if best.isFavorite { reasons.append(.favorite) }
        if best.isEdited { reasons.append(.edited) }
        if sorted.dropFirst().contains(where: { Int64($0.pixelWidth) * Int64($0.pixelHeight) < Int64(best.pixelWidth) * Int64(best.pixelHeight) }) { reasons.append(.higherResolution) }
        if let sharpness = best.sharpness, sorted.dropFirst().contains(where: { ($0.sharpness ?? sharpness) + 0.02 < sharpness }) { reasons.append(.sharper) }
        return reasons.isEmpty ? nil : .init(id: best.id, reasons: reasons)
    }
}
struct SimilarityCluster: Equatable, Sendable {
    let id: String
    let memberIDs: [String]
    let keeper: KeeperSuggestion?
    let algorithmVersion: String
    let whyGrouped: [String]
}
struct ComparisonState: Equatable {
    let firstID: String
    let secondID: String
    var keeperID: String?
    mutating func chooseKeeper(_ id: String) { if id == firstID || id == secondID { keeperID = id } }
}
enum SimilarityEngine {
    /// At most eight pending anchors per time/aspect bucket; every group member is
    /// compared to its anchor, so transitive chains cannot silently merge events.
    static func group(candidates: [CKMediaCandidate], threshold: Float, distance: (String, String) -> Float?) -> [SimilarityCluster] {
        let photos = candidates.filter { $0.kind == .photo || $0.kind == .similar }.sorted { a,b in
            if a.createdAt != b.createdAt { return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast) }; return a.id < b.id
        }
        var buckets: [String: [CKMediaCandidate]] = [:]
        for item in photos {
            guard let date = item.createdAt else { continue }
            let aspect = item.pixelHeight > 0 ? Int((Double(item.pixelWidth) / Double(item.pixelHeight) * 10).rounded()) : 0
            let key = "\(Int(date.timeIntervalSince1970 / 3))-\(aspect)"
            buckets[key, default: []].append(item)
        }
        return buckets.keys.sorted().flatMap { key -> [SimilarityCluster] in
            var groups: [[CKMediaCandidate]] = []
            for item in buckets[key] ?? [] {
            if let index = groups.indices.reversed().prefix(8).first(where: { index in
                guard let anchor = groups[index].first, let d = distance(anchor.id, item.id) else { return false }
                return d.isFinite && d >= 0 && d <= threshold
            }) { groups[index].append(item) }
            else { groups.append([item]) }
            }
            return groups.filter { $0.count > 1 }.map { members in
                SimilarityCluster(id: "visual-\(members[0].id)", memberIDs: members.map(\.id), keeper: KeeperPolicy.suggest(members), algorithmVersion: "vision-anchor-v1", whyGrouped: ["Close capture time", "Similar proportions", "Visual feature match"])
            }
        }
    }
}
