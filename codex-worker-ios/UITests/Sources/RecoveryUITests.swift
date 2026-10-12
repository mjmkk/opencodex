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
        if overviewApp.buttons["Allow"].exists { overviewApp.buttons["Allow"].tap() }
        func openOverview() {
            prepareOverviewMenu(overviewApp)
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

    private func prepareOverviewMenu(_ app: XCUIApplication) {
        let more = app.buttons["任务更多选项"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: more)
        if XCTWaiter.wait(for: [ready], timeout: 5) != .completed {
            let drawerClose = app.buttons["收起线程列表"]
            if drawerClose.exists && drawerClose.isHittable && drawerClose.frame.minX >= 0 && drawerClose.frame.maxX < app.frame.width {
                drawerClose.tap()
            }
        }
    }

    private func openOverviewForTransportCheck(_ app: XCUIApplication) {
        prepareOverviewMenu(app)
        app.buttons["任务更多选项"].tap()
        app.buttons["Goal Overview"].tap()
        XCTAssertTrue(app.navigationBars["Goal Overview"].waitForExistence(timeout: 5))
    }

    private func captureOverview(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    // Uses the actual GET-only QA proxy and real saved production content.
    // The host switches only transport availability; no Goal fixture is created.
    func testGoalOverviewKeepsRealCacheDuringTransportFailure() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "li.CodexWorkerApp")
        app.terminate(); app.activate()
        openOverviewForTransportCheck(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "展开 ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "A previously saved real Goal is required")
        let original = row.label
        let failure = app.staticTexts["读取失败，保留上次观察；判断时间未更新。"]
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "Requires an actual HTTP503 from the isolated proxy")
        XCTAssertTrue(app.buttons[original].exists, "A transport failure must retain the actual cached Goal")
        app.buttons[original].tap()
        XCTAssertTrue(app.staticTexts["判断时间："].waitForExistence(timeout: 5))
        captureOverview(app, name: "controlled-http503-retains-real-goal")
    }

    func testGoalOverviewRecoversAfterTransportFailure() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "li.CodexWorkerApp")
        app.terminate(); app.activate()
        openOverviewForTransportCheck(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "展开 ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let refresh = app.buttons["刷新目标观察"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        refresh.tap()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 30), .completed)
        XCTAssertFalse(app.staticTexts["读取失败，保留上次观察；判断时间未更新。"].exists)
        XCTAssertTrue(row.exists)
        captureOverview(app, name: "controlled-http200-recovers-real-goal")
    }

}
