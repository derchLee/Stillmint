import Foundation

enum ByteProvenance: String, Codable, Sendable { case estimated, measured, deviceAvailable }
struct ByteAmount: Codable, Equatable, Sendable { let bytes: Int64; let provenance: ByteProvenance }
enum ActivityKind: String, Codable, Sendable { case deletion, compression }
enum ActivityStatus: String, Codable, Sendable { case success, partial, cancelled, failed, pendingVerification }
struct ActivityReceipt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { operationID }
    let operationID: UUID
    var date = Date()
    let kind: ActivityKind
    let status: ActivityStatus
    var requestedCount = 0
    var confirmedCount = 0
    var unchangedCount = 0
    var sourceSize: ByteAmount? = nil
    var outputSize: ByteAmount? = nil
    var estimatedDeletedSize: ByteAmount? = nil
    var availableBefore: ByteAmount? = nil
    var availableAfter: ByteAmount? = nil
    var verificationNote: String? = nil
    var comparison: ByteAmount? {
        guard let sourceSize, let outputSize else { return nil }
        return .init(bytes: max(0, sourceSize.bytes - outputSize.bytes), provenance: sourceSize.provenance == .measured && outputSize.provenance == .measured ? .measured : .estimated)
    }
    var comparisonLabel: String { guard let comparison else { return "Size comparison unavailable" }; if comparison.bytes == 0 { return "No space savings" }; return comparison.provenance == .measured ? "Measured file size difference · original may still be kept" : "Estimated potential savings · original may still be kept" }
}
protocol ActivityStoring: AnyObject {
    func load() throws -> [ActivityReceipt]
    func upsert(_ receipt: ActivityReceipt) throws
    func clear() throws
}
