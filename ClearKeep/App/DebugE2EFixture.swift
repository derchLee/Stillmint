#if DEBUG
import Foundation

/// Explicit, sandbox-isolated platform boundaries. All review/quota/safety logic remains production.
@MainActor enum DebugE2EFixture {
    static func makeModelIfRequested() -> AppModel? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--clearkeep-e2e"), let index = args.firstIndex(of: "--e2e-session-id"), args.indices.contains(index + 1) else { return nil }
        let session = args[index + 1]
        guard !session.isEmpty, session.count <= 80, session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClearKeep-E2E", isDirectory: true).appendingPathComponent(session, isDirectory: true)
        let suite = "ClearKeep.E2E." + session
        let defaults = UserDefaults(suiteName: suite)!
        if args.contains("--e2e-reset") {
            // Exact validated fixture child only; never removes production stores or Keychain.
            if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
            defaults.removePersistentDomain(forName: suite)
            if args.contains("--e2e-delete-99") { defaults.set(99, forKey: "clearkeep.free.deletedItems") }
            if args.contains("--e2e-delete-100") { defaults.set(100, forKey: "clearkeep.free.deletedItems") }
            if args.contains("--e2e-compress-9") { defaults.set(9, forKey: "compressionSeed") }
            if args.contains("--e2e-compress-10") { defaults.set(10, forKey: "compressionSeed") }
        }
        let library = DebugFixtureLibrary()
        library.persistence = defaults
        library.successfulDeletion = !args.contains("--e2e-delete-cancel")
        if args.contains("--e2e-welcome") { library.access = .notDetermined }
        if args.contains("--e2e-many") {
            let template = library.items.first { $0.id == "screen" }!
            for index in 3...105 { library.items.append(.init(id: "screen-\(index)", category: .screenshots, createdAt: template.createdAt, pixelWidth: template.pixelWidth, pixelHeight: template.pixelHeight, duration: 0, estimatedBytes: template.estimatedBytes, isFavorite: false, isEdited: false, isVideo: false, duplicateGroup: nil)) }
        }
        let service = VideoCompressionService(exporter: E2EVideoExporter(fail: args.contains("--e2e-export-fail")), library: E2EVideoLibrary(defaults: defaults), operations: FileCompressionOperationStore(directory: root.appendingPathComponent("compression")), quota: E2ECompressionQuota(defaults: defaults))
        let deletionJournal = FileDeletionJournalStore(url: root.appendingPathComponent("deletion-journal.json"))
        if args.contains("--e2e-reset"), args.contains("--e2e-unverified-cleanup") {
            var entry = DeletionJournalEntry(requested: ["unverified-missing-fixture"], exempt: [], bytesByID: [:], consumesFreeAllowance: true)
            entry.phase = .executing
            do { try deletionJournal.save(entry) } catch { preconditionFailure("Could not seed isolated cleanup fixture") }
        }
        let model = AppModel(deletionJournalStore: deletionJournal, photoLibrary: library, store: StoreService(defaults: defaults, durableQuota: false, liveEntitlements: false), reviewCheckpointStore: FileReviewCheckpointStore(url: root.appendingPathComponent("review.json")), protectedItemStore: FileProtectedItemStore(url: root.appendingPathComponent("protected.json")), rulesStore: FileProtectionRulesStore(url: root.appendingPathComponent("rules.json")), activityStore: FileActivityStore(url: root.appendingPathComponent("activity.json")), albumSnapshotProvider: { .init(fullAccess: true, membersByAlbumID: ["family": ["screen"]], titlesByAlbumID: ["family": "Family"]) }, compressionService: service)
        model.finishedOnboarding = !args.contains("--e2e-welcome")
        if model.finishedOnboarding { model.startScan() }
        return model
    }
    static func deletionObservation(_ model: AppModel) -> String? {
        guard ProcessInfo.processInfo.arguments.contains("--clearkeep-e2e"), ProcessInfo.processInfo.arguments.contains("--e2e-unverified-cleanup"), let library = model.photoLibrary as? DebugFixtureLibrary, let defaults = library.persistence else { return nil }
        let items = (try? DefaultsQuotaLedger(defaults).read().items).map(String.init) ?? "unavailable"
        return "Used items: \(items) · Delete calls: \(defaults.integer(forKey: "deleteCallCount")) · Pending: \(model.deletionRecoveryPending ? "yes" : "no")"
    }
}

@MainActor private final class E2ECompressionQuota: CompressionQuotaLedger {
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func read() throws -> CompressionQuotaSnapshot {
        var ids = Set((defaults.stringArray(forKey: "compressionIDs") ?? []).compactMap(UUID.init(uuidString:)))
        for index in 0..<defaults.integer(forKey: "compressionSeed") { ids.insert(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!) }
        return .init(consumedOperationIDs: ids)
    }
    func commit(operationID: UUID) throws { var value = try read(); value.consumedOperationIDs.insert(operationID); defaults.set(value.consumedOperationIDs.map(\.uuidString), forKey: "compressionIDs") }
}

@MainActor private final class E2EVideoExporter: VideoCompressionExporting {
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func inspect(sourceID: String) async throws -> CompressionSource { .init(duration: 1, bytes: 1_000_000, bytesAreMeasured: true, hasAudio: false, displayWidth: 160, displayHeight: 90) }
    func availableTemporaryBytes() throws -> Int64 { 1_000_000_000 }
    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile {
        if fail { throw CompressionFailure.exportFailed }
        let url = try await DebugLayoutVideo.url(); progress(1)
        return .init(url: url, bytes: Int64((try Data(contentsOf: url)).count))
    }
    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput { .init(bytes: file.bytes, duration: expectedDuration, hasAudio: false, displayWidth: 160, displayHeight: 90) }
    func cleanup(operationID: UUID) throws {}
}

@MainActor private final class E2EVideoLibrary: CompressionPhotoLibraryWriting {
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let id = UUID().uuidString; try recordPlaceholder(id)
        var ids = defaults.stringArray(forKey: "savedVideoIDs") ?? []; ids.append(id); defaults.set(ids, forKey: "savedVideoIDs"); return id
    }
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool { defaults.stringArray(forKey: "savedVideoIDs")?.contains(outputID) == true }
    func exists(sourceID: String) -> Bool { sourceID == "video" || sourceID == "recording" || defaults.stringArray(forKey: "savedVideoIDs")?.contains(sourceID) == true }
}
#endif
