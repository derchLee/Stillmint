import Foundation

struct RecommendationOpportunity: Equatable, Sendable {
    let candidateIDs: [String]
    let estimatedBytes: Int64
    let reason: String
}
enum RecommendationPolicy {
    static func rank(candidates: [CKMediaCandidate], excludedIDs: Set<String>, unknownBoundary: Bool, limit: Int = 20) -> [RecommendationOpportunity] {
        guard !unknownBoundary, limit > 0 else { return [] }
        let eligible = candidates.filter { !excludedIDs.contains($0.id) && !$0.isFavorite && !$0.isEdited }
        let groups = Dictionary(grouping: eligible, by: { $0.groupID ?? "item-\($0.id)" })
        let ranked = groups.values.map { members -> (Int, RecommendationOpportunity) in
            let localVideo = members.contains { ($0.kind == .video || $0.kind == .screenRecording) && $0.previewAvailable }
            let exact = members.allSatisfy { $0.kind == .exactDuplicate }
            let similar = members.contains { $0.kind == .similar }
            let unavailableVideo = members.contains { ($0.kind == .video || $0.kind == .screenRecording) && !$0.previewAvailable }
            let rank = localVideo ? 0 : exact ? 1 : unavailableVideo ? 4 : similar ? 3 : 2
            let reason = localVideo ? "Large local video" : exact ? "Exact duplicate group" : unavailableVideo ? "Video preview unavailable · inspect before deciding" : similar ? "Review similar photos carefully" : "Screenshots or recordings to review"
            let bytes = members.reduce(Int64(0)) { total, c in total > Int64.max - max(0,c.estimatedBytes) ? Int64.max : total + max(0,c.estimatedBytes) }
            return (rank, .init(candidateIDs: members.map(\.id).sorted(), estimatedBytes: bytes, reason: reason))
        }.sorted { a,b in
            if a.0 != b.0 { return a.0 < b.0 }; if a.1.estimatedBytes != b.1.estimatedBytes { return a.1.estimatedBytes > b.1.estimatedBytes }; return (a.1.candidateIDs.first ?? "") < (b.1.candidateIDs.first ?? "")
        }
        var result: [RecommendationOpportunity] = [], count = 0
        for (_, opportunity) in ranked where count + opportunity.candidateIDs.count <= limit {
            result.append(opportunity); count += opportunity.candidateIDs.count
        }
        return result
    }
}
