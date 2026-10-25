import Foundation

enum DeletionJournalPhase: String, Codable { case prepared, executing, confirmed, completed }
struct DeletionJournalEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let requested: Set<String>
    let exempt: Set<String>
    let bytesByID: [String: Int64]
    let consumesFreeAllowance: Bool
    var phase: DeletionJournalPhase = .prepared
    var confirmedDeleted = Set<String>()
    var unchanged = Set<String>()
    var status: ActivityStatus = .pendingVerification
    var quotaCommitted = false
    var activityCommitted = false
    var closureReason: String? = nil
    var estimatedBytes: Int64 { confirmedDeleted.reduce(0) { total, id in
        let (sum, overflow) = total.addingReportingOverflow(max(0, bytesByID[id] ?? 0))
        return overflow ? Int64.max : sum
    } }
    var receipt: ActivityReceipt { .init(operationID: id, date: date, kind: .deletion, status: status, requestedCount: requested.count, confirmedCount: confirmedDeleted.count, unchangedCount: unchanged.count, estimatedDeletedSize: closureReason == nil ? .init(bytes: estimatedBytes, provenance: .estimated) : nil, verificationNote: closureReason) }
}
protocol DeletionJournalStoring: AnyObject {
    func load() throws -> [DeletionJournalEntry]
    func save(_ entry: DeletionJournalEntry) throws
}
