import XCTest
@testable import ClearKeep

final class ReleaseConfigurationTests: XCTestCase {
    func testLegalLinksRejectMissingPlaceholdersAndUnsafeDestinations() {
        let invalid: [String?] = [nil, "", "$(CK_SUPPORT_URL)", "https://YOUR-DOMAIN.example/support", "https://example.com/support", "http://apple.com/privacy", "https:///missing", "https://localhost/support", "https://127.0.0.1/support", "https://host.invalid/support", "https://user:pass@apple.com/support", "https://apple.com/#placeholder"]
        for value in invalid {
            XCTAssertNil(LegalLinks.validatedURL(value), value ?? "nil")
        }
    }

    func testLegalLinksAcceptConfiguredPublicHTTPSWithoutInventingFallback() {
        XCTAssertEqual(LegalLinks.validatedURL("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")?.scheme, "https")
        XCTAssertNil(LegalLinks.validatedURL(nil))
    }
}
