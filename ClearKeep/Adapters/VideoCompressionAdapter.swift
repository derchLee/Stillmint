@preconcurrency import AVFoundation
@preconcurrency import Photos
import UIKit

private final class CompressionAssetBox: @unchecked Sendable {
    let asset: AVAsset
    init(_ asset: AVAsset) { self.asset = asset }
}
private final class CompressionExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

/// Completion handlers are created outside MainActor, so PhotoKit/AVFoundation may call them on their queues.
private enum CompressionPlatformBridge {
    static func asset(sourceID: String) async throws -> CompressionAssetBox {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject, asset.mediaType == .video else { throw CompressionFailure.unavailableSource }
        let result: CompressionAssetBox? = await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox<CompressionAssetBox?>(continuation)
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false; options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { value, _, _ in
                box.resume(returning: value.map(CompressionAssetBox.init))
            }
        }
        guard let result else { throw CompressionFailure.unavailableSource }
        return result
    }

    static func export(_ wrapped: CompressionExportSessionBox) async throws {
        let result: Result<Void, CompressionFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = OneShotContinuationBox<Result<Void, CompressionFailure>>(continuation)
                wrapped.session.exportAsynchronously {
                    switch wrapped.session.status {
                    case .completed: box.resume(returning: .success(()))
                    case .cancelled: box.resume(returning: .failure(.cancelled))
                    default: box.resume(returning: .failure(.exportFailed))
                    }
                }
                if Task.isCancelled { wrapped.cancel() }
            }
        } onCancel: { wrapped.cancel() }
        try result.get()
    }
}

@MainActor
final class VideoCompressionAdapter: VideoCompressionExporting {
    typealias AssetResolver = @MainActor (String) async throws -> AVAsset
    private let resolve: AssetResolver
    private let directory: URL
    private var prepared: (id: String, asset: AVAsset)?
    private var activeSession: CompressionExportSessionBox?

    init(directory: URL? = nil, assetResolver: AssetResolver? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ClearKeepCompression", isDirectory: true)
        self.resolve = assetResolver ?? { id in try await CompressionPlatformBridge.asset(sourceID: id).asset }
    }

    func inspect(sourceID: String) async throws -> CompressionSource {
        let initialIdentity = CompressionPhotoLibraryAdapter.currentIdentity(sourceID: sourceID)
        let asset = try await resolve(sourceID)
        try Task.checkCancellation()
        var source = try await Self.describe(asset)
        source.modificationIdentity = CompressionPhotoLibraryAdapter.currentIdentity(sourceID: sourceID)
        guard initialIdentity == source.modificationIdentity else { throw CompressionFailure.sourceChanged }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw CompressionFailure.unsupportedFormat }
        for format in try await video.load(.formatDescriptions) {
            if let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
               transfer.contains("2084") || transfer.lowercased().contains("hlg") {
                throw CompressionFailure.unsupportedFormat
            }
        }
        prepared = (sourceID, asset)
        return source
    }

    func availableTemporaryBytes() throws -> Int64 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return capacity }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let value = attributes[.systemFreeSize] as? NSNumber else { throw CompressionFailure.insufficientDiskSpace }
        return value.int64Value
    }

    func export(sourceID: String, profile: CompressionProfile, sampleDuration: Double?, operationID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionExportedFile {
        let asset: AVAsset
        if let cached = prepared, cached.id == sourceID { asset = cached.asset } else { asset = try await resolve(sourceID) }
        try Task.checkCancellation()
        let preset: String
        switch profile { case .smaller: preset = AVAssetExportPreset1280x720; case .balanced: preset = AVAssetExportPreset1920x1080; case .higherQuality: preset = AVAssetExportPresetHighestQuality }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw CompressionFailure.unsupportedFormat }
        let types = session.supportedFileTypes
        let type: AVFileType
        if types.contains(.mp4) { type = .mp4 } else if types.contains(.mov) { type = .mov } else { throw CompressionFailure.unsupportedFormat }
        let folder = directory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(type == .mp4 ? "compressed.mp4" : "compressed.mov")
        // Only this adapter's generated output is ever removed; never a source URL.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        session.outputURL = url; session.outputFileType = type; session.shouldOptimizeForNetworkUse = true
        if let sampleDuration { session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(10, sampleDuration), preferredTimescale: 600)) }
        let wrapped = CompressionExportSessionBox(session); activeSession = wrapped
        let background = UIApplication.shared.beginBackgroundTask(withName: "ClearKeep video export") { wrapped.cancel() }
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            monitor.cancel(); activeSession = nil
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        try await CompressionPlatformBridge.export(wrapped)
        try Task.checkCancellation()
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard bytes > 0 else { throw CompressionFailure.invalidOutput }
        return CompressionExportedFile(url: url, bytes: bytes)
    }

    func validate(file: CompressionExportedFile, source: CompressionSource, expectedDuration: Double) async throws -> CompressionValidatedOutput {
        let asset = AVURLAsset(url: file.url)
        let output = try await Self.describe(asset)
        guard file.bytes > 0, try await asset.load(.isPlayable), output.duration.isFinite,
              abs(output.duration - expectedDuration) <= 0.25,
              output.hasAudio == source.hasAudio,
              Self.sameDisplayAspect(width: output.displayWidth, height: output.displayHeight, source: source) else { throw CompressionFailure.invalidOutput }
        return CompressionValidatedOutput(bytes: file.bytes, duration: output.duration, hasAudio: output.hasAudio, displayWidth: output.displayWidth, displayHeight: output.displayHeight)
    }

    func cleanup(operationID: UUID) throws {
        let folder = directory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        prepared = nil
    }
    func cancelCurrentExport() { activeSession?.cancel() }

    static func describe(_ asset: AVAsset) async throws -> CompressionSource {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw CompressionFailure.invalidOutput }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        guard abs(display.width) > 0, abs(display.height) > 0 else { throw CompressionFailure.invalidOutput }
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        var measured: Int64?
        if let local = asset as? AVURLAsset, local.url.isFileURL { measured = (try? local.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
        let estimated = min(Double(Int64.max - 1_024), duration * 1_000_000)
        return CompressionSource(duration: duration, bytes: measured ?? Int64(estimated), bytesAreMeasured: measured != nil, hasAudio: hasAudio, displayWidth: abs(display.width), displayHeight: abs(display.height))
    }
    static func sameDisplayAspect(width: Double, height: Double, source: CompressionSource) -> Bool {
        guard height > 0, source.displayHeight > 0 else { return false }
        return abs(width / height - source.displayWidth / source.displayHeight) <= 0.02
    }
}

private final class CompressionSaveState: @unchecked Sendable {
    private let lock = NSLock()
    private var outputID: String?
    private var error: Error?
    func record(id: String?, error: Error? = nil) { lock.withLock { outputID = id; self.error = error } }
    func result(success: Bool) -> Result<String, Error> {
        lock.withLock {
            if let error { return .failure(error) }
            guard success, let outputID else { return .failure(CompressionFailure.saveFailed) }
            return .success(outputID)
        }
    }
}

private enum CompressionSaveBridge {
    static func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            let box = OneShotContinuationBox<Result<String, Error>>(continuation)
            let state = CompressionSaveState()
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                guard let id = request.placeholderForCreatedAsset?.localIdentifier else { state.record(id: nil, error: CompressionFailure.saveFailed); return }
                do {
                    // Register the video resource only after its placeholder mapping is durable.
                    // An empty creation request cannot commit a valid video when persistence fails.
                    try recordPlaceholder(id)
                    request.addResource(with: .video, fileURL: file, options: nil)
                    state.record(id: id)
                }
                catch { state.record(id: id, error: CompressionFailure.saveIntentFailed) }
            }, completionHandler: { success, _ in box.resume(returning: state.result(success: success)) })
        }
        return try result.get()
    }
}

@MainActor
final class CompressionPhotoLibraryAdapter: CompressionPhotoLibraryWriting {
    var requiresModificationIdentity: Bool { true }
    func identity(sourceID: String) -> String? { Self.currentIdentity(sourceID: sourceID) }
    func absenceIsConfirmed(outputID: String) -> Bool {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return false }
        let absent = PHAsset.fetchAssets(withLocalIdentifiers: [outputID], options: nil).firstObject == nil
        return absent && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }
    static func currentIdentity(sourceID: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject, asset.mediaType == .video else { return nil }
        return "\(asset.modificationDate?.timeIntervalSince1970 ?? 0)|\(asset.creationDate?.timeIntervalSince1970 ?? 0)|\(asset.pixelWidth)|\(asset.pixelHeight)|\(asset.duration)"
    }
    func save(file: URL, recordPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try await CompressionSaveBridge.save(file: file, recordPlaceholder: recordPlaceholder)
    }
    func exists(sourceID: String) -> Bool { PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject?.mediaType == .video }
    func verify(outputID: String, expected: CompressionValidatedOutput) async throws -> Bool {
        let initialIdentity = identity(sourceID: outputID)
        guard let photos = PHAsset.fetchAssets(withLocalIdentifiers: [outputID], options: nil).firstObject, photos.mediaType == .video,
              abs(photos.duration - expected.duration) <= 0.25 else { return false }
        guard let asset = try? await CompressionPlatformBridge.asset(sourceID: outputID).asset,
              let actual = try? await VideoCompressionAdapter.describe(asset),
              (try? await asset.load(.isPlayable)) == true else { return false }
        return initialIdentity != nil && initialIdentity == identity(sourceID: outputID)
            && abs(actual.duration - expected.duration) <= 0.25 && actual.hasAudio == expected.hasAudio
            && abs(actual.displayWidth / actual.displayHeight - expected.displayWidth / expected.displayHeight) <= 0.02
    }
}
