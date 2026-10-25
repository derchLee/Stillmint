import XCTest
import UIKit
import Photos
@testable import ClearKeep

final class VisionSimilarityAdapterTests: XCTestCase {
    func test_albumAdapterLimitedAndDeniedNeverFetchOrClaimFullMembership() {
        var called = false
        for access in [PHAuthorizationStatus.limited, .denied, .restricted, .notDetermined] {
            let snapshot = PhotoAlbumAdapter.snapshot(access: access) { called = true; return .init(fullAccess: true) }
            XCTAssertFalse(snapshot.fullAccess)
            XCTAssertTrue(snapshot.membersByAlbumID.isEmpty)
        }
        XCTAssertFalse(called)
        XCTAssertTrue(PhotoAlbumAdapter.snapshot(access: .authorized) { .init(fullAccess: true) }.fullAccess)
    }
    @MainActor
    func test_nativeVisionSmokeGeneratesValidFiniteFeatureForFirstPartyFixture() async throws {
        let first = fixture(alternate: false)
        let adapter = VisionSimilarityAdapter()
        let same = try await adapter.distance(first: first, second: first)
        XCTAssertEqual(same, 0)
    }
    @MainActor
    func test_nativeVisionDistinctFixtureEitherSeparatesOrExplicitlyRejectsDegenerateRuntimeSignal() async throws {
        let adapter = VisionSimilarityAdapter()
        do {
            let distance = try await adapter.distance(first: fixture(alternate: false), second: fixture(alternate: true))
            XCTAssertTrue(distance.isFinite); XCTAssertGreaterThan(distance, 1e-7)
        } catch let error as VisionSimilarityAdapter.AdapterError {
            XCTAssertEqual(error, .degenerateSignal)
            print("Native Vision runtime produced a degenerate distinct-input distance; grouping is safely rejected. This is not an accuracy pass.")
        }
    }
    func test_zeroDifferentInputDistanceIsUnavailableAndCannotBecomeSimilarityEvidence() {
        XCTAssertThrowsError(try VisionSimilarityAdapter.checkedDistance(0, identicalInput: false)) { error in
            XCTAssertEqual(error as? VisionSimilarityAdapter.AdapterError, .degenerateSignal)
        }
        XCTAssertThrowsError(try VisionSimilarityAdapter.checkedDistance(.nan, identicalInput: false))
        XCTAssertNoThrow(try VisionSimilarityAdapter.checkedDistance(0, identicalInput: true))
    }
    @MainActor
    private func fixture(alternate: Bool) -> Data {
        let image = UIGraphicsImageRenderer(size: .init(width: 384, height: 384)).image { context in
            UIColor.white.setFill(); context.fill(.init(x: 0,y: 0,width: 384,height: 384))
            for y in 0..<48 { for x in 0..<48 {
                let seed = alternate ? (x * 71 + y * 197 + x * y * 13) % 251 : (x + y) % 2 == 0 ? 10 : 240
                UIColor(red: CGFloat(seed) / 255, green: alternate ? CGFloat((seed * 3) % 255) / 255 : CGFloat(seed) / 255, blue: alternate ? CGFloat((seed * 7) % 255) / 255 : CGFloat(seed) / 255, alpha: 1).setFill()
                context.fill(.init(x: x * 8,y: y * 8,width: 8,height: 8))
            } }
            if alternate {
                UIColor.black.setFill(); context.fill(.init(x: 70,y: 60,width: 250,height: 200))
                let text = "NEW YORK\nPHOTO 2026" as NSString
                text.draw(in: .init(x: 80,y: 90,width: 230,height: 140), withAttributes: [.font:UIFont.boldSystemFont(ofSize: 40),.foregroundColor:UIColor.white])
            }
        }
        return image.jpegData(compressionQuality: 0.9)!
    }
}
