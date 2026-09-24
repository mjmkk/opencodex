import XCTest

@MainActor
final class RecoveryUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "chenken.CodexWorkerApp")

    func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testRestoresSelectedTaskAndCachedMessages() {
        continueAfterFailure = false
        app.activate()
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        XCTAssertTrue(app.buttons["打开线程列表"].waitForExistence(timeout: 15))
        if !app.buttons["收起线程列表"].isHittable { app.buttons["打开线程列表"].tap() }
        if app.buttons["按时间"].exists { app.buttons["按时间"].tap() }
        let thread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AGT-12 ·")).firstMatch
        for _ in 0..<6 {
            if thread.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(thread.isHittable)
        thread.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AGT-12 ·")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Capture an actual visible message, then require it after process restart.
        let cells = app.tables.cells
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15))
        let visibleMessage = cells.allElementsBoundByIndex.flatMap { $0.staticTexts.allElementsBoundByIndex }
            .first { $0.isHittable && $0.label.count > 25 }
        capture("01-before-restart-AGT12")
        XCTAssertNotNil(visibleMessage, "Real AGT-12 message must be readable before restart")
        guard let text = visibleMessage?.label else { return }
        app.terminate()
        app.activate()
        capture("02-first-frame-after-restart")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Must restore AGT-12, not the most recent other task")
        XCTAssertTrue(app.tables.staticTexts[text].firstMatch.waitForExistence(timeout: 5), "Cached message must remain readable after restart")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CancellationError")).firstMatch.exists)
        capture("03-restored-AGT12-messages")
    }
}
