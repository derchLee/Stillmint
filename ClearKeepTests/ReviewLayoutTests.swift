import SwiftUI
import UIKit
import XCTest
@testable import ClearKeep

@MainActor final class ReviewLayoutTests: XCTestCase {
    func testLoadedMediaAndActionsStayInsideReviewViewportAtPhoneWidths() async throws {
        for width in [375.0, 390.0, 440.0] {
            for category in [MediaCategory.screenshots, .largeVideos, .similar] {
                try await verifyReview(width: width, category: category, textSize: .large, colorScheme: .light)
            }
        }
    }

    func testAccessibilityTextAndDarkModeKeepLoadedMediaInsideViewport() async throws {
        for category in [MediaCategory.screenshots, .largeVideos, .similar] {
            try await verifyReview(width: 375, category: category, textSize: .accessibility5, colorScheme: .dark)
        }
    }

    func testPrimaryButtonForegroundMeetsContrastInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = luminance(UIColor(CKColor.focus).resolvedColor(with: traits))
            let foreground = luminance(UIColor(CKColor.onFocus).resolvedColor(with: traits))
            XCTAssertGreaterThanOrEqual((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05), 4.5)
        }
    }

    func testAllProductionPagesRenderAtPhoneWidthsAndAccessibilitySize() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clearkeep-layout-matrix-20261018")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("LAYOUT_MATRIX_DIRECTORY \(output.path)")
        for (width, size, scheme) in [(375.0, DynamicTypeSize.large, ColorScheme.light), (390.0, .large, .light), (440.0, .large, .light), (375.0, .accessibility5, .dark)] {
            for page in DebugLayoutGallery.pages {
                let model = await DebugReviewFixture.preparedModel(page: page)
                let capture = FrameCapture()
                let content = DebugLayoutGallery.view(page: page, model: model)
                    .environment(\.dynamicTypeSize, size).preferredColorScheme(scheme)
                    .onPreferenceChange(LayoutFramesKey.self) { frames in Task { @MainActor in capture.frames = frames } }
                let controller = UIHostingController(rootView: content)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
                window.rootViewController = controller; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(180))
                controller.view.layoutIfNeeded()
                if page == "preview-video" {
                    // The cold AVAssetWriter fixture + SwiftUI .task may outlive the initial layout.
                    // Await the actual player surface, not a longer unconditional screenshot delay.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while capture.frames["preview.player"].map({ $0.width > 0 && $0.height >= 180 }) != true && ContinuousClock.now < deadline {
                        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let prefix = "\(Int(width))-\(size == .accessibility5 ? "AX5-dark" : "normal-light")-\(page)"
                try snapshot(controller, to: output.appendingPathComponent(prefix + "-top.png"))
                assertHorizontalFrames(capture.frames, width: width, context: prefix)
                if page == "preview-video" {
                    let player = try XCTUnwrap(capture.frames["preview.player"], "A real playable fixture must create the player surface")
                    XCTAssertGreaterThanOrEqual(player.height, 180)
                }
                if let scroll = findScrollView(controller.view) {
                    let offset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    controller.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(70))
                    try snapshot(controller, to: output.appendingPathComponent(prefix + "-bottom.png"))
                    assertHorizontalFrames(capture.frames, width: width, context: prefix + " bottom")
                    if let complete = capture.frames["review.completeBatch"], let footer = capture.frames["review.footer"] {
                        XCTAssertLessThanOrEqual(complete.maxY, footer.minY + 1, "Complete Batch must remain reachable above the tray: \(prefix)")
                    }
                }
            }
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> Double { let d = Double(value); return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let found = findScrollView(child) { return found } }
        return nil
    }
    private func snapshot<V: View>(_ controller: UIHostingController<V>, to url: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: url)
    }
    private func assertHorizontalFrames(_ frames: [String: CGRect], width: Double, context: String) {
        for (id, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(context) \(id): \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(context) \(id): \(frame)")
        }
    }

    private func verifyReview(width: Double, category: MediaCategory, textSize: DynamicTypeSize, colorScheme: ColorScheme) async throws {
        let model = DebugReviewFixture.makeModel()
        for _ in 0..<1000 { if !model.isScanning { break }; await Task.yield() }
        model.beginReview(category: category)
        let capture = FrameCapture()
        let root = ReviewView(model: model, category: category)
            .environment(\.dynamicTypeSize, textSize).preferredColorScheme(colorScheme)
            .onPreferenceChange(LayoutFramesKey.self) { frames in Task { @MainActor in capture.frames = frames } }
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let frames = capture.frames
        XCTAssertFalse(frames.isEmpty, "Actual SwiftUI layout must be measured")
        let media = frames.filter { $0.key.hasPrefix("preview.") }
        XCTAssertFalse(media.isEmpty, "Loaded thumbnail frames must exist")
        for (id, frame) in media { XCTAssertEqual(frame.width, frame.height, accuracy: 1, "\(id) must remain square after the image loads") }
        for (id, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(category) \(width) \(textSize) \(id) starts off-screen: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(category) \(width) \(textSize) \(id) overflows: \(frame)")
        }
    }
}

@MainActor private final class FrameCapture { var frames: [String: CGRect] = [:] }
