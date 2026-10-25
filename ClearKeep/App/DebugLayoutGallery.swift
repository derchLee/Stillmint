#if DEBUG
import AVKit
import SwiftUI

@MainActor enum DebugLayoutGallery {
    static let pages = ["welcome", "permission", "scan", "map", "review-screenshots", "review-recordings", "review-large-videos", "review-exact", "review-similar", "preview-photo", "preview-video", "compare", "summary", "purchase-loading", "purchase-unavailable", "result-partial", "activity", "activity-detail", "settings", "rules", "protected", "video-catalog", "compression"]
    static func reviewCategory(_ page: String) -> MediaCategory? {
        switch page { case "review-screenshots": .screenshots; case "review-recordings": .screenRecordings; case "review-large-videos": .largeVideos; case "review-exact": .exactDuplicates; case "review-similar": .similar; default: nil }
    }
    static func view(page: String, model: AppModel) -> AnyView {
        if let category = reviewCategory(page) { return wrap(ReviewView(model: model, category: category)) }
        switch page {
        case "welcome": return AnyView(WelcomeView(model: model))
        case "permission": return wrap(PermissionView(model: model))
        case "scan": return wrap(ScanView(model: model))
        case "map": return AnyView(StorageMapNavigation(model: model))
        case "preview-photo": return wrap(PreviewView(model: model, identifier: "photo-a"))
        case "preview-video": return wrap(PreviewView(model: model, identifier: "video"))
        case "compare": return wrap(ComparisonView(model: model, firstID: "photo-a", secondID: "photo-b"))
        case "summary": return wrap(SummaryView(model: model))
        case "purchase-loading", "purchase-unavailable": return AnyView(PurchaseView(store: model.store))
        case "result-partial": return wrap(ResultView(model: model))
        case "activity": return AnyView(ActivityView(model: model))
        case "activity-detail": return model.activityEntries.first.map { wrap(ActivityDetailView(entry: $0)) } ?? AnyView(EmptyView())
        case "settings", "protected": return AnyView(SettingsView(model: model))
        case "rules": return wrap(ProtectionRulesView(model: model))
        case "video-catalog": return wrap(VideoCatalogView(model: model))
        case "compression": return wrap(CompressionView(model: model, identifier: "video"))
        default: return AnyView(EmptyView())
        }
    }
    private static func wrap<V: View>(_ content: V) -> AnyView { AnyView(NavigationStack { content }) }
}

@MainActor enum DebugLayoutVideo {
    private static var cachedURL: URL?
    static func url() async throws -> URL {
        if let cachedURL { return cachedURL }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clearkeep-layout-" + UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        guard writer.startWriting() else { throw CompressionFailure.exportFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { guard writer.status == .writing else { throw CompressionFailure.exportFailed }; try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CompressionFailure.exportFailed }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, Int32(100 + frame * 3), CVPixelBufferGetDataSize(pixel)) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw CompressionFailure.exportFailed }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw CompressionFailure.exportFailed }
        cachedURL = url; return url
    }
}
#endif
