import XCTest

@MainActor final class ClearKeepJourneyTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { super.setUp(); continueAfterFailure = false }
    override func tearDown() {
        if let app { let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot) }
        app?.terminate(); super.tearDown()
    }
    private func launch(_ scenario: String = "", reset: Bool = true, session: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["--clearkeep-e2e", "--e2e-session-id", session ?? String(name.filter { $0.isLetter || $0.isNumber }.suffix(75))]
        if reset { app.launchArguments.append("--e2e-reset") }
        app.launchArguments += scenario.split(separator: " ").map(String.init)
        app.launch()
    }
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<20 {
            let belowTray = element.identifier == "review.completeBatch" && element.frame.maxY >= app.staticTexts["review.selectionCount"].frame.minY - 8
            if element.exists && element.isHittable && !belowTray { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "Missing \(element)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "Not reachable \(element)", file: file, line: line)
        if element.identifier == "review.completeBatch" { XCTAssertLessThan(element.frame.maxY, app.staticTexts["review.selectionCount"].frame.minY - 8, "Complete Batch must be above the fixed tray", file: file, line: line) }
        element.tap()
    }
    private func review(_ category: String = "Screenshots") { tap(app.buttons["storageMap.category." + category]) }
    private func count(_ value: Int, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts["review.selectionCount"]
        XCTAssertTrue(element.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(element.label.hasPrefix("\(value) selected"), element.label, file: file, line: line)
    }
    private func back() { tap(app.navigationBars.buttons.element(boundBy: 0)) }
    private func expectLabel(_ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, element.label, file: file, line: line)
    }
    private func openVideo() { tap(app.buttons["storageMap.compression"]); tap(app.buttons["videos.open.video"]) }

    func testWelcomePermissionRequiresExplicitAction() {
        launch("--e2e-welcome")
        XCTAssertTrue(app.staticTexts["Make space without guessing."].waitForExistence(timeout: 8))
        XCTAssertEqual(app.alerts.count, 0)
        tap(app.buttons["Continue to Photo Access"])
        XCTAssertTrue(app.buttons["Choose Photo Access"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        tap(app.buttons["Not Now"])
        XCTAssertTrue(app.staticTexts["Make space without guessing."].exists)
        tap(app.buttons["Continue to Photo Access"]); tap(app.buttons["Choose Photo Access"])
        tap(app.buttons["Start On-device Scan"]); tap(app.buttons["Review Results"])
        XCTAssertTrue(app.buttons["storageMap.compression"].waitForExistence(timeout: 8))
    }
    func testSelectedDeletionCompletesAndActivityPersists() {
        launch(); review(); count(0)
        tap(app.buttons["review.select.screen"]); count(1)
        tap(app.buttons["Review Selection"])
        XCTAssertTrue(app.staticTexts["Review before deleting"].exists)
        back(); count(1); tap(app.buttons["Review Selection"])
        tap(app.buttons["Ask Photos to Delete 1 Items"])
        XCTAssertTrue(app.staticTexts["Cleanup complete"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 deleted · 0 unchanged'")).firstMatch.exists)
        tap(app.buttons["Done"]); tap(app.tabBars.buttons["Activity"])
        XCTAssertTrue(app.staticTexts["Cleanup · success"].waitForExistence(timeout: 8))
        app.terminate(); launch(reset: false); tap(app.tabBars.buttons["Activity"])
        XCTAssertTrue(app.staticTexts["Cleanup · success"].waitForExistence(timeout: 8))
    }
    func testCancelledDeletionDoesNotConsumeLastFreeItem() {
        launch("--e2e-delete-99 --e2e-delete-cancel"); review()
        tap(app.buttons["review.select.screen"]); tap(app.buttons["Review Selection"]); tap(app.buttons["Ask Photos to Delete 1 Items"])
        XCTAssertTrue(app.staticTexts["Deletion canceled"].waitForExistence(timeout: 8))
        app.terminate(); launch("--e2e-delete-cancel", reset: false)
        tap(app.buttons["storageMap.resumeReview"]); count(1)
        tap(app.buttons["Review Selection"])
        XCTAssertTrue(app.buttons["Ask Photos to Delete 1 Items"].exists)
    }
    func testCompareKeeperNeverAutoSelectsDeletion() {
        launch(); review(); tap(app.buttons["review.select.screen"]); count(1)
        back(); review("Similar photos"); count(0)
        tap(app.buttons["Compare photos"])
        tap(app.buttons["Prefer Photo B as keeper without selecting deletion"])
        back(); count(0)
        XCTAssertFalse(app.buttons["Review Selection"].isEnabled)
    }
    func testBatchSizeTwentyFiftyHundredAndCompletion() {
        launch("--e2e-many"); review()
        XCTAssertEqual(app.staticTexts["review.batchProgress"].label, "Batch 1 of 6")
        tap(app.buttons["review.batchSize"]); tap(app.buttons["50"])
        XCTAssertEqual(app.staticTexts["review.batchProgress"].label, "Batch 1 of 3")
        tap(app.buttons["review.batchSize"]); tap(app.buttons["100"])
        XCTAssertEqual(app.staticTexts["review.batchProgress"].label, "Batch 1 of 2")
        tap(app.buttons["review.batchSize"]); tap(app.buttons["20"])
        tap(app.buttons["review.completeBatch"])
        expectLabel(app.staticTexts["review.batchProgress"], "Batch 1 of 5")
        XCTAssertTrue(app.staticTexts["review.batchCounts"].label.hasSuffix("20 completed"))
        count(0)
    }
    func testSkipProtectionSurvivesRelaunchAndCanBeRemoved() {
        launch(); review(); tap(app.buttons["review.skipProtect.screen"])
        tap(app.tabBars.buttons["Settings"])
        XCTAssertTrue(app.buttons["settings.removeProtection.screen"].waitForExistence(timeout: 8))
        app.terminate(); launch(reset: false); tap(app.tabBars.buttons["Settings"])
        tap(app.buttons["settings.removeProtection.screen"])
        XCTAssertFalse(app.buttons["settings.removeProtection.screen"].exists)
        tap(app.tabBars.buttons["Review"]); review()
        XCTAssertTrue(app.buttons["review.select.screen"].exists)
    }
    func testChangingAlbumRuleClearsPendingDeletionIntent() {
        launch(); review(); tap(app.buttons["review.select.screen"]); count(1)
        tap(app.tabBars.buttons["Settings"]); tap(app.buttons["Albums and recent media"])
        let album = app.switches["Family"]
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        // SwiftUI exposes the entire labelled row as a switch; hit the actual trailing control.
        album.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: album)], timeout: 5), .completed)
        tap(app.tabBars.buttons["Review"])
        if app.staticTexts["review.selectionCount"].exists { back() }
        XCTAssertTrue(app.alerts["Review updated"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["Review updated"].staticTexts["Protection rules changed. Start a new review to use the updated rules."].exists)
        tap(app.alerts["Review updated"].buttons["OK"])
        review(); count(0)
        XCTAssertFalse(app.buttons["review.select.screen"].exists)
    }
    func testRelaunchRestoresActualFileCheckpointAndSelection() {
        launch(); review(); tap(app.buttons["review.select.screen"]); count(1)
        app.terminate(); launch(reset: false)
        tap(app.buttons["storageMap.resumeReview"]); count(1)
        XCTAssertTrue(app.buttons["review.select.screen"].label.hasPrefix("Deselect"))
        tap(app.buttons["Review Selection"])
        XCTAssertTrue(app.buttons["Ask Photos to Delete 1 Items"].exists)
    }
    func testHundredthDeletionAllowedThenNextBlockedButPreviewFree() {
        launch("--e2e-delete-99"); review()
        tap(app.buttons["review.select.screen"]); tap(app.buttons["Review Selection"]); tap(app.buttons["Ask Photos to Delete 1 Items"])
        XCTAssertTrue(app.staticTexts["Cleanup complete"].waitForExistence(timeout: 8))
        tap(app.buttons["Done"]); review()
        tap(app.buttons["review.preview.screen-2"])
        XCTAssertTrue(app.buttons["Select for deletion"].waitForExistence(timeout: 8))
        tap(app.buttons["Select for deletion"]); back(); tap(app.buttons["Review Selection"])
        XCTAssertTrue(app.staticTexts["This selection exceeds your free allowance, and purchases are unavailable."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Ask Photos to Delete 1 Items"].exists)
    }
    func testTenthCompressionThenEleventhBlockedAndSampleStillFree() {
        launch("--e2e-compress-9"); openVideo()
        XCTAssertTrue(app.staticTexts["1 successful free compressions remaining"].waitForExistence(timeout: 8))
        tap(app.buttons["Create free short preview"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Compressed sample'")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1 successful free compressions remaining"].exists)
        tap(app.buttons["Compress and save new copy"])
        XCTAssertTrue(app.staticTexts["Saved and verified · Keep both"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["0 successful free compressions remaining"].exists)
        tap(app.buttons["Compress and save new copy"])
        XCTAssertTrue(app.staticTexts.matching(identifier: "Lifetime Unlock").firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Restore Purchases"].exists)
        tap(app.buttons["Close"])
        tap(app.buttons["Create free short preview"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Compressed sample'")).firstMatch.waitForExistence(timeout: 8))
        app.terminate(); launch(reset: false); openVideo()
        XCTAssertTrue(app.staticTexts["0 successful free compressions remaining"].waitForExistence(timeout: 8))
    }
    func testFailedCompressionDoesNotConsumeAllowance() {
        launch("--e2e-compress-9 --e2e-export-fail"); openVideo()
        tap(app.buttons["Compress and save new copy"])
        XCTAssertTrue(app.staticTexts["The video could not be exported. Your original is unchanged."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1 successful free compressions remaining"].exists)
        app.terminate(); launch(reset: false); openVideo()
        XCTAssertTrue(app.staticTexts["1 successful free compressions remaining"].waitForExistence(timeout: 8))
    }

    func testUnverifiedCleanupCanBeRetriedAndClosedWithoutDeletingOrResettingUsage() {
        launch("--e2e-delete-99 --e2e-unverified-cleanup")
        tap(app.tabBars.buttons["Settings"])
        let counters = app.staticTexts["e2e.deletionJournalCounters"]
        expectLabel(counters, "Used items: 99 · Delete calls: 0 · Pending: yes")
        let retry = app.buttons["settings.retryDeletionVerification"]
        let close = app.buttons["settings.closeUnverifiedDeletion"]
        XCTAssertTrue(app.staticTexts["A previous cleanup needs verification. No media will be deleted again. Verification is always free."].exists)
        tap(retry)
        expectLabel(counters, "Used items: 99 · Delete calls: 0 · Pending: yes")
        XCTAssertTrue(close.exists)
        let pendingScreenshot = XCTAttachment(screenshot: app.screenshot())
        pendingScreenshot.name = "Unverified cleanup — reachable retry and close"
        pendingScreenshot.lifetime = .keepAlways; add(pendingScreenshot)
        tap(close)
        if app.alerts["Review updated"].waitForExistence(timeout: 2) {
            XCTAssertTrue(app.alerts["Review updated"].staticTexts["The unverified cleanup was closed. Start a fresh review; no deletion choices were carried over."].exists)
            tap(app.alerts["Review updated"].buttons["OK"])
        }
        expectLabel(counters, "Used items: 99 · Delete calls: 0 · Pending: no")
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(close.exists)
        let closedScreenshot = XCTAttachment(screenshot: app.screenshot())
        closedScreenshot.name = "Unverified cleanup — closed without quota change or deletion"
        closedScreenshot.lifetime = .keepAlways; add(closedScreenshot)
        app.terminate(); launch("--e2e-unverified-cleanup", reset: false)
        tap(app.tabBars.buttons["Settings"])
        expectLabel(app.staticTexts["e2e.deletionJournalCounters"], "Used items: 99 · Delete calls: 0 · Pending: no")
        XCTAssertFalse(app.buttons["settings.closeUnverifiedDeletion"].exists)
        tap(app.tabBars.buttons["Activity"])
        XCTAssertTrue(app.staticTexts["Cleanup · failed"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Cleanup · success"].exists)
    }
}
