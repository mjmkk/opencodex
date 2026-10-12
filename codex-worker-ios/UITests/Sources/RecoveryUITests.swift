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
    func testGoalOverviewRealServiceAndRestart() {
        continueAfterFailure = false
        let overviewApp = XCUIApplication(bundleIdentifier: "li.CodexWorkerApp")
        overviewApp.terminate()
        overviewApp.activate()
        if overviewApp.buttons["允许"].exists { overviewApp.buttons["允许"].tap() }
        func openOverview() {
            let drawerClose = overviewApp.buttons["收起线程列表"]
            if drawerClose.exists && drawerClose.frame.minX >= 0 && drawerClose.frame.maxX < overviewApp.frame.width { drawerClose.tap() }
            XCTAssertTrue(overviewApp.buttons["任务更多选项"].waitForExistence(timeout: 20))
            overviewApp.buttons["任务更多选项"].tap()
            overviewApp.buttons["Goal Overview"].tap()
            XCTAssertTrue(overviewApp.navigationBars["Goal Overview"].waitForExistence(timeout: 5))
        }
        func evidence(_ name: String) {
            let screenshot = XCTAttachment(screenshot: overviewApp.screenshot())
            screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: overviewApp.debugDescription)
            tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        openOverview()
        let row = overviewApp.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "展开 ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 35), "Requires real Goal inventory; error or empty fixture is not success")
        let original = row.label
        row.tap()
        XCTAssertTrue(overviewApp.staticTexts["资料覆盖："].waitForExistence(timeout: 5))
        XCTAssertTrue(overviewApp.staticTexts["判断时间："].exists)
        evidence("goal-overview-real-expanded")
        let workers = overviewApp.buttons["Workers"]
        XCTAssertTrue(workers.exists)
        workers.tap()
        XCTAssertTrue(overviewApp.staticTexts["Worker 观察时间："].firstMatch.waitForExistence(timeout: 5))
        evidence("goal-overview-real-workers")
        overviewApp.segmentedControls.buttons["Risk"].tap()
        evidence("goal-overview-risk")
        overviewApp.segmentedControls.buttons["Blocked"].tap()
        evidence("goal-overview-blocked")
        overviewApp.segmentedControls.buttons["All"].tap()
        overviewApp.terminate()
        overviewApp.activate()
        openOverview()
        XCTAssertTrue(overviewApp.buttons[original].waitForExistence(timeout: 5), "Real cached Goal must survive restart")
        evidence("goal-overview-after-restart")
    }

}
