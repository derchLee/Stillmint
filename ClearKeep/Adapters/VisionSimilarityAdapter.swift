import Foundation
import CryptoKit
@preconcurrency import Photos
@preconcurrency import Vision
import CoreML
@preconcurrency import UIKit

actor VisionSimilarityAdapter {
    struct Result: Sendable {
        let clusters: [SimilarityCluster]
        let unavailableIDs: Set<String>
        let analyzedCount: Int
        let revision: Int
    }
    /// Version-specific conservative development threshold; real-world dataset
    /// calibration remains a release gate. Never displayed as a confidence score.
    let threshold: Float
    let revision: Int
    init(threshold: Float = 0.18, revision: Int = VNGenerateImageFeaturePrintRequestRevision2) {
        self.threshold = threshold; self.revision = revision
    }
    func analyze(_ candidates: [CKMediaCandidate]) async throws -> Result {
        let eligible = candidates.filter { $0.kind == .photo || $0.kind == .similar }
        let buckets = Dictionary(grouping: eligible.filter { $0.createdAt != nil }) { candidate in
            let aspect = candidate.pixelHeight > 0 ? Int((Double(candidate.pixelWidth) / Double(candidate.pixelHeight) * 10).rounded()) : 0
            return "\(Int(candidate.createdAt!.timeIntervalSince1970 / 3))-\(aspect)"
        }
        var clusters: [SimilarityCluster] = [], unavailable = Set<String>(), analyzed = 0
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key], bucket.count > 1 else { continue }
            try Task.checkCancellation()
            var active: [(anchor: VNFeaturePrintObservation, digest: Data, members: [CKMediaCandidate])] = []
            func flush(_ members: [CKMediaCandidate]) {
                guard members.count > 1 else { return }
                clusters.append(.init(id: "visual-\(members[0].id)", memberIDs: members.map(\.id), keeper: KeeperPolicy.suggest(members), algorithmVersion: "vision-anchor-v1", whyGrouped: ["Close capture time", "Similar proportions", "Visual feature match"]))
            }
            // Keep only eight anchor observations, even for a pathological 50k
            // bucket. Every member compares directly with a live group anchor.
            let ordered = bucket.sorted { a,b in a.createdAt == b.createdAt ? a.id < b.id : (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast) }
            for candidate in ordered {
                try Task.checkCancellation()
                guard let data = await Self.localThumbnailData(candidate.id) else { unavailable.insert(candidate.id); continue }
                do {
                    let print = try featurePrint(data)
                    let digest = Data(SHA256.hash(data: data))
                    var match: Int?
                    var degenerateSignal = false
                    for index in active.indices.reversed() {
                        guard active[index].anchor.requestRevision == print.requestRevision else { continue }
                        var distance: Float = 0
                        do {
                            try active[index].anchor.computeDistance(&distance, to: print)
                            if active[index].digest != digest && (distance <= 1e-7 || active[index].anchor.data == print.data) { degenerateSignal = true; break }
                            if distance.isFinite && distance >= 0 && distance <= threshold { match = index; break }
                        } catch { continue }
                    }
                    if degenerateSignal { unavailable.insert(candidate.id); continue }
                    if let match { active[match].members.append(candidate) }
                    else {
                        if active.count == 8 { flush(active.removeFirst().members) }
                        active.append((print, digest, [candidate]))
                    }
                    analyzed += 1
                } catch { unavailable.insert(candidate.id) }
                await Task.yield()
            }
            for group in active { flush(group.members) }
        }
        return .init(clusters: clusters, unavailableIDs: unavailable, analyzedCount: analyzed, revision: revision)
    }
    func featurePrint(_ jpeg: Data) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        request.imageCropAndScaleOption = .scaleFit
        #if targetEnvironment(simulator)
        // Simulator has no Neural Engine. Vision's automatic Espresso backend
        // can fail before inference; use an actually supported CPU per stage.
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        try VNImageRequestHandler(data: jpeg, options: [:]).perform([request])
        guard let observation = request.results?.first else { throw AdapterError.noFeaturePrint }
        guard observation.elementCount > 0, observation.elementType == .float,
              observation.data.count == observation.elementCount * MemoryLayout<Float>.size else { throw AdapterError.invalidFeaturePrint }
        let valid = observation.data.withUnsafeBytes { raw -> Bool in
            var squaredNorm: Double = 0
            for index in 0..<observation.elementCount {
                let value = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                guard value.isFinite else { return false }
                squaredNorm += Double(value) * Double(value)
            }
            return squaredNorm.isFinite && squaredNorm > 1e-12
        }
        guard valid else { throw AdapterError.invalidFeaturePrint }
        return observation
    }
    /// Real-Vision smoke path for deterministic first-party image fixtures.
    func distance(first: Data, second: Data) throws -> Float {
        let a = try featurePrint(first)
        if first == second { return 0 }
        let b = try featurePrint(second)
        guard a.data != b.data else { throw AdapterError.degenerateSignal }
        var value: Float = 0; try a.computeDistance(&value, to: b)
        return try Self.checkedDistance(value, identicalInput: false)
    }
    nonisolated static func checkedDistance(_ value: Float, identicalInput: Bool) throws -> Float {
        guard value.isFinite, value >= 0 else { throw AdapterError.invalidFeaturePrint }
        guard identicalInput || value > 1e-7 else { throw AdapterError.degenerateSignal }
        return value
    }
    private static func localThumbnailData(_ identifier: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let bridge = ThumbnailDataBridge()
        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            guard bridge.install(continuation) else { return }
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat; options.resizeMode = .exact
            let requestID = PHImageManager.default().requestImage(for: asset, targetSize: .init(width: 384, height: 384), contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                bridge.finish(image?.jpegData(compressionQuality: 0.85))
            }
            bridge.setRequestID(requestID)
          }
        } onCancel: {
            bridge.cancel()
        }
    }
    enum AdapterError: Error, Equatable { case noFeaturePrint, invalidFeaturePrint, degenerateSignal }
}

private final class ThumbnailDataBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    func install(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
        lock.lock(); let cancelled = cancelled; if !cancelled { self.continuation = continuation }; lock.unlock()
        if cancelled { continuation.resume(returning: nil) }
        return !cancelled
    }
    func setRequestID(_ id: PHImageRequestID) {
        lock.lock(); requestID = id; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let c = continuation; continuation = nil; let id = requestID; lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }; c?.resume(returning: nil)
    }
    func finish(_ value: Data?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
