import Combine
import Foundation

enum CompressionProfile: String, CaseIterable, Codable, Sendable {
    case smaller, balanced, higherQuality
    var title: String { switch self { case .smaller: "Smaller"; case .balanced: "Balanced"; case .higherQuality: "Higher quality" } }
    var detail: String { switch self { case .smaller: "Up to 720p"; case .balanced: "Up to 1080p"; case .higherQuality: "Source dimensions, higher quality" } }
}

enum CompressionFailure: String, Error, LocalizedError, Sendable {
    case busy, purchaseRequired, protectedSource, unavailableSource, unsupportedFormat
    case insufficientDiskSpace, exportFailed, cancelled, invalidOutput, saveFailed, saveIntentFailed, sourceChanged, persistence, unknownOperation, verificationRequired
    var errorDescription: String? {
        switch self {
        case .busy: "Another compression is in progress."
        case .purchaseRequired: "Your 10 free successful video compressions have been used. Lifetime unlocks unlimited compression."
        case .protectedSource: "This video is protected. Review its protection rules before creating a full compressed copy."
        case .unavailableSource: "This video is not available locally. Download it in Photos and try again."
        case .unsupportedFormat: "This video format is not supported for safe compression on this device."
        case .insufficientDiskSpace: "There is not enough temporary storage to export safely."
        case .exportFailed: "The video could not be exported. Your original is unchanged."
        case .cancelled: "Compression was cancelled. Your original is unchanged."
        case .invalidOutput: "The compressed video did not pass validation. Your original is unchanged."
        case .saveFailed: "The compressed video could not be saved to Photos. No free compression was used."
        case .saveIntentFailed: "The saved-copy record could not be prepared, so no video resource was added to Photos. No free compression was used. Please try again when storage is available."
        case .sourceChanged: "The video changed while it was being prepared. Review it and try again."
        case .persistence: "Compression records could not be verified. No new export will start until they can be read safely."
        case .unknownOperation: "This compression operation could not be found."
        case .verificationRequired: "A previous Photos save still needs verification. Check its status before exporting another video. A copy may already exist in Photos."
        }
    }
}

struct CompressionSource: Codable, Equatable, Sendable {
    var duration: Double
    var bytes: Int64
    var bytesAreMeasured: Bool
    var hasAudio: Bool
    var displayWidth: Double
    var displayHeight: Double
    var modificationIdentity: String? = nil
}

struct CompressionExportedFile: Sendable { let url: URL; let bytes: Int64 }
struct CompressionValidatedOutput: Codable, Equatable, Sendable {
    var bytes: Int64
    var duration: Double
    var hasAudio: Bool
    var displayWidth: Double
    var displayHeight: Double
}
struct CompressionSample: Identifiable, Sendable {
    let operationID: UUID
    let url: URL
    let bytes: Int64
    let duration: Double
    var id: UUID { operationID }
}

enum CompressionOperationState: String, Codable, Sendable {
    case preflight, exporting, validating, readyToSave, saving, pendingVerification, verified, completed, cancelled, failed, interrupted
}

/// This ledger is separate from Activity: only it contains the exact media mapping.
struct CompressionOperation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var sourceID: String
    var profile: CompressionProfile
    var algorithmVersion = 1
    var createdAt = Date()
    var state: CompressionOperationState = .preflight
    var source: CompressionSource?
    var output: CompressionValidatedOutput?
    var outputID: String?
    var outputModificationIdentity: String?
    var consumesFreeAllowance = true
    var quotaCommitted = false
    var activityCommitted: Bool? = nil
    var errorMessage: String?
    var keepsOriginal: Bool { true }

    var receipt: CompressionReceipt? {
        guard state == .completed, let source, let output else { return nil }
        return CompressionReceipt(operationID: id, date: createdAt, sourceBytes: source.bytes, sourceBytesAreMeasured: source.bytesAreMeasured, outputBytes: output.bytes)
    }
}

/// Safe to convert to Activity: no media IDs, file paths, names or album details.
struct CompressionReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let date: Date
    let sourceBytes: Int64
    let sourceBytesAreMeasured: Bool
    let outputBytes: Int64
    var potentialSavingsBytes: Int64 { max(0, sourceBytes - outputBytes) }
}

struct CompressionCleanupProof: Sendable, Equatable {
    let operationID: UUID
    let sourceID: String
    let outputID: String
}

struct CompressionQuotaSnapshot: Codable, Equatable, Sendable {
    var consumedOperationIDs: Set<UUID> = []
    var consumedCount: Int { consumedOperationIDs.count }
}

protocol CompressionOperationStoring: Sendable {
    func load(id: UUID) throws -> CompressionOperation?
    func all() throws -> [CompressionOperation]
    func save(_ operation: CompressionOperation) throws
}
@MainActor protocol CompressionQuotaLedger: AnyObject {
    func read() throws -> CompressionQuotaSnapshot
    func commit(operationID: UUID) throws
}
@MainActor protocol VideoCompressionExporting: AnyObject {
    func inspect(sourceID: String) async throws -> CompressionSource
    func availableTemporaryBytes() throws -> Int64
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput
    func cleanup(operationID: UUID) throws
    func cancelCurrentExport()
}
extension VideoCompressionExporting { func cancelCurrentExport() {} }
@MainActor protocol CompressionPhotoLibraryWriting: AnyObject {
    var requiresModificationIdentity: Bool { get }
    func identity(sourceID: String) -> String?
    /// True only when current Full Photos scope can prove this exact output is absent.
    func absenceIsConfirmed(outputID: String) -> Bool
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool
    func exists(sourceID: String) -> Bool
}
extension CompressionPhotoLibraryWriting {
    var requiresModificationIdentity: Bool { false }
    func identity(sourceID: String) -> String? { nil }
    func absenceIsConfirmed(outputID: String) -> Bool { false }
}

@MainActor
final class VideoCompressionService: ObservableObject {
    @Published private(set) var activeOperation: CompressionOperation?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isBusy = false
    let exporter: VideoCompressionExporting
    let library: CompressionPhotoLibraryWriting
    let operations: CompressionOperationStoring
    let quota: CompressionQuotaLedger
    private var cancellationRequested = false
    private var progressGeneration = UUID()

    init(exporter: VideoCompressionExporting = VideoCompressionAdapter(), library: CompressionPhotoLibraryWriting = CompressionPhotoLibraryAdapter(), operations: CompressionOperationStoring = FileCompressionOperationStore(), quota: CompressionQuotaLedger = KeychainCompressionQuotaLedger()) {
        self.exporter = exporter; self.library = library; self.operations = operations; self.quota = quota
    }

    var remainingFreeExports: Int? { (try? quota.read()).map { max(0, 10 - $0.consumedCount) } }
    func cancel() { cancellationRequested = true; exporter.cancelCurrentExport() }
    func history() throws -> [CompressionOperation] { try operations.all().sorted { $0.createdAt > $1.createdAt } }
    func uncommittedCompletedOperations() throws -> [CompressionOperation] {
        try history().filter { $0.state == .completed && $0.activityCommitted != true }
    }
    func acknowledgeActivity(operationID: UUID) throws {
        guard var job = try operations.load(id: operationID), job.state == .completed else { throw CompressionFailure.unknownOperation }
        guard job.activityCommitted != true else { return }
        job.activityCommitted = true
        try operations.save(job)
        if activeOperation?.id == job.id { activeOperation = job }
    }

    func preview(sourceID: String, profile: CompressionProfile) async throws -> CompressionSample {
        guard !isBusy else { throw CompressionFailure.busy }
        isBusy = true; progress = 0; progressGeneration = UUID(); cancellationRequested = false; activeOperation = nil
        defer { isBusy = false }
        let id = UUID()
        do {
            let source = try await exporter.inspect(sourceID: sourceID)
            try checkCancellation()
            let seconds = min(10, source.duration)
            try preflight(source: source, seconds: seconds)
            let file = try await exporter.export(sourceID: sourceID, profile: profile, sampleDuration: seconds, operationID: id, progress: progressHandler())
            try checkCancellation()
            _ = try await exporter.validate(file: file, source: source, expectedDuration: seconds)
            try checkCancellation()
            progress = 1
            return CompressionSample(operationID: id, url: file.url, bytes: file.bytes, duration: seconds)
        } catch {
            try? exporter.cleanup(operationID: id)
            throw error
        }
    }
    func discardSample(_ sample: CompressionSample) { try? exporter.cleanup(operationID: sample.operationID) }

    func compress(sourceID: String, profile: CompressionProfile, isLifetime: Bool, protectionAllowsExport: Bool) async throws -> CompressionOperation {
        guard !isBusy else { throw CompressionFailure.busy }
        guard protectionAllowsExport else { throw CompressionFailure.protectedSource }
        // Read both stores before any external work; unknown ledgers do not regrant allowance.
        let previous = try operations.all()
        guard !previous.contains(where: { [.saving, .pendingVerification, .verified].contains($0.state) }) else { throw CompressionFailure.verificationRequired }
        if !isLifetime, try quota.read().consumedCount >= 10 { throw CompressionFailure.purchaseRequired }
        isBusy = true; progress = 0; progressGeneration = UUID(); cancellationRequested = false
        defer { isBusy = false }
        var job = CompressionOperation(sourceID: sourceID, profile: profile)
        job.consumesFreeAllowance = !isLifetime
        try persist(job)
        do {
            let source = try await exporter.inspect(sourceID: sourceID)
            try checkCancellation()
            try preflight(source: source, seconds: source.duration)
            job.source = source; job.state = .exporting; try persist(job)
            let file = try await exporter.export(sourceID: sourceID, profile: profile, sampleDuration: nil, operationID: job.id, progress: progressHandler())
            try checkCancellation()
            job.state = .validating; try persist(job)
            let output = try await exporter.validate(file: file, source: source, expectedDuration: source.duration)
            try checkCancellation()
            job.output = output; job.state = .readyToSave; try persist(job)
            // Persist before invoking Photos. If terminated here, recovery never blindly saves again.
            job.state = .saving; try persist(job)
            let savingJob = job; let operationStore = operations
            let outputID = try await library.save(file: file.url) { id in
                var intent = savingJob; intent.outputID = id
                try operationStore.save(intent)
            }
            job.outputID = outputID; job.state = .pendingVerification; try persist(job)
            try? exporter.cleanup(operationID: job.id)
            return try await verifyAndCommit(job)
        } catch {
            // A Photos transaction may already have committed. Keep its identity, never resave on retry.
            if job.state == .saving, let failure = error as? CompressionFailure, failure == .saveFailed || failure == .saveIntentFailed {
                job.state = .failed
            } else if job.state == .saving || job.state == .pendingVerification || job.state == .verified {
                if let recorded = try? operations.load(id: job.id) { job = recorded }
                job.state = .pendingVerification
            } else { job.state = (error is CancellationError || (error as? CompressionFailure) == .cancelled) ? .cancelled : .failed }
            job.errorMessage = job.state == .pendingVerification && job.outputID == nil
                ? "A Photos save may have completed, but its exact copy could not be recorded. No allowance was used. Check Photos; Stillmint will not save again or delete the original automatically."
                : error.localizedDescription
            try? persist(job); try? exporter.cleanup(operationID: job.id)
            throw error
        }
    }

    func retryVerification(operationID: UUID, isLifetime: Bool) async throws -> CompressionOperation {
        guard !isBusy else { throw CompressionFailure.busy }
        guard var job = try operations.load(id: operationID) else { throw CompressionFailure.unknownOperation }
        guard [.saving, .pendingVerification, .verified, .completed].contains(job.state) else { throw CompressionFailure.unknownOperation }
        isBusy = true; defer { isBusy = false }
        if job.state == .completed { activeOperation = job; return job }
        job.state = .pendingVerification; try persist(job)
        // Use persisted allowance ownership, never a new entitlement value to rewrite past usage.
        return try await verifyAndCommit(job, resolveConfirmedMissing: true)
    }

    func recoverInterruptedExports() throws {
        for var job in try operations.all() where [.preflight, .exporting, .validating, .readyToSave].contains(job.state) {
            job.state = .interrupted
            job.errorMessage = "Compression was interrupted. Your original is unchanged. Start a new export when ready."
            try persist(job); try exporter.cleanup(operationID: job.id)
        }
    }

    func cleanupProof(sourceID: String, protected: Bool) async throws -> CompressionCleanupProof? {
        guard !protected, library.exists(sourceID: sourceID) else { return nil }
        for job in try operations.all().sorted(by: { $0.createdAt > $1.createdAt }) where job.sourceID == sourceID && job.state == .completed && job.quotaCommitted {
            guard let outputID = job.outputID, outputID != sourceID, let output = job.output else { continue }
            guard mappingIdentityMatches(job: job, outputID: outputID) else { continue }
            if try await library.verify(outputID: outputID, expected: output) {
                guard mappingIdentityMatches(job: job, outputID: outputID) else { continue }
                return CompressionCleanupProof(operationID: job.id, sourceID: sourceID, outputID: outputID)
            }
        }
        return nil
    }

    private func mappingIdentityMatches(job: CompressionOperation, outputID: String) -> Bool {
        guard library.requiresModificationIdentity else { return true }
        guard let sourceIdentity = job.source?.modificationIdentity, let outputIdentity = job.outputModificationIdentity else { return false }
        return library.identity(sourceID: job.sourceID) == sourceIdentity && library.identity(sourceID: outputID) == outputIdentity
    }

    private func verifyAndCommit(_ original: CompressionOperation, resolveConfirmedMissing: Bool = false) async throws -> CompressionOperation {
        var job = original
        guard let outputID = job.outputID, let expected = job.output, outputID != job.sourceID else { job.state = .pendingVerification; try persist(job); return job }
        guard try await library.verify(outputID: outputID, expected: expected) else {
            if resolveConfirmedMissing, !job.quotaCommitted, library.absenceIsConfirmed(outputID: outputID) {
                job.state = .failed
                job.errorMessage = "Full Photos access confirms the saved copy is no longer present. No free compression was used. Your original is unchanged; you can start a new compression."
            } else { job.state = .pendingVerification }
            try persist(job); return job
        }
        if library.requiresModificationIdentity {
            guard let identity = library.identity(sourceID: outputID) else { job.state = .pendingVerification; try persist(job); return job }
            if let previous = job.outputModificationIdentity, previous != identity { job.state = .pendingVerification; try persist(job); return job }
            job.outputModificationIdentity = identity
        }
        job.state = .verified; try persist(job)
        if !job.quotaCommitted {
            if job.consumesFreeAllowance { try quota.commit(operationID: job.id) }
            job.quotaCommitted = true
        }
        job.state = .completed; job.errorMessage = nil; try persist(job); progress = 1
        return job
    }
    private func persist(_ job: CompressionOperation) throws { try operations.save(job); activeOperation = job }
    private func checkCancellation() throws { if cancellationRequested { throw CompressionFailure.cancelled }; try Task.checkCancellation() }
    private func preflight(source: CompressionSource, seconds: Double) throws {
        guard source.duration.isFinite, source.duration > 0, seconds.isFinite, seconds > 0 else { throw CompressionFailure.invalidOutput }
        let fraction = min(1, seconds / source.duration)
        let proportionalBytes = Double(max(0, source.bytes)) * fraction
        let required = min(Double(Int64.max), max(64 * 1_024 * 1_024, proportionalBytes * 2 + 32 * 1_024 * 1_024))
        guard Double(try exporter.availableTemporaryBytes()) >= required else { throw CompressionFailure.insufficientDiskSpace }
    }
    private func progressHandler() -> @Sendable (Double) -> Void {
        let generation = progressGeneration
        return { [weak self] value in Task { @MainActor in
            guard let self, self.isBusy, self.progressGeneration == generation else { return }
            self.progress = min(0.99, max(0, value))
        } }
    }
}
