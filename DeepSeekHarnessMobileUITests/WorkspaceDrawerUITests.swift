import XCTest

final class WorkspaceDrawerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let alert = app.alerts.firstMatch
        if alert.exists { alert.buttons.firstMatch.tap() }
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
    }

    func testRightSwipeFromSettingsOpensDrawerWithoutOpeningSettings() {
        dragRight(from: app.buttons["设置"])
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
        XCTAssertFalse(app.navigationBars["设置"].exists)
    }

    func testRightSwipeFromWorkspaceMenuOpensDrawerWithoutOpeningMenu() {
        let workspace = app.buttons["选择工作区"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        let originalY = workspace.frame.midY
        dragRight(from: workspace)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
        XCTAssertEqual(workspace.frame.midY, originalY, accuracy: 2, "右滑同时触发了纵向滚动")
        XCTAssertFalse(app.buttons["添加工作区"].exists)
    }

    func testRightSwipeFromHostSwitcherOpensDrawerWithoutOpeningHostList() {
        let host = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "当前主机：")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        dragRight(from: host)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
        XCTAssertFalse(app.navigationBars["主机"].exists)
    }

    func testRightSwipeFromNewSessionOpensDrawerWithoutCreatingSession() {
        let newSession = app.buttons["新建会话"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        dragRight(from: newSession)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
        XCTAssertFalse(app.navigationBars["新建会话"].exists)
    }

    func testRightSwipeFromSearchOpensDrawerWithoutKeyboard() {
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        dragRight(from: search)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testRightSwipeFromAuthenticationButtonOpensDrawerWithoutMenu() {
        let authentication = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设备认证")).firstMatch
        XCTAssertTrue(authentication.waitForExistence(timeout: 5))
        dragRight(from: authentication)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width, "主界面未右移：\(homeSettings.frame)")
    }

    func testVerticalSwipeDoesNotOpenDrawer() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.68))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(homeSettings.frame.minX < app.frame.width, "纵向滑动误开侧栏：\(homeSettings.frame)")
        XCTAssertTrue(app.buttons["设置"].exists)
    }

    func testSettingsTapStillOpensSettings() {
        homeSettings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    }

    func testFontSizePreviewUpdatesAndPersistsAfterRelaunch() {
        openFontSizePage()
        let slider = app.sliders["font-size-slider"]
        let followsSystem = app.switches["font-size-follow-system"]
        if followsSystem.value as? String == "1" { tapFontSystemSwitch(followsSystem) }
        let reset = app.buttons["font-size-reset"]
        reset.tap()
        let title = app.staticTexts["font-size-preview-title"]
        XCTAssertTrue(title.exists)
        let initialHeight = title.frame.height
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(title.frame.height > initialHeight * 1.2)
        XCTAssertEqual(slider.value as? String, "150%")

        tapFontSystemSwitch(followsSystem)
        XCTAssertEqual(followsSystem.value as? String, "1")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.lifetime = .keepAlways
        add(preview)
        XCTAssertFalse(slider.isEnabled)
        XCTAssertEqual(title.frame.height, initialHeight, accuracy: 1)
        tapFontSystemSwitch(followsSystem)
        XCTAssertEqual(slider.value as? String, "150%")

        app.navigationBars["字体大小"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["设置"].exists)
        XCTAssertFalse(slider.exists)
        app.terminate()
        app.launch()
        let alert = app.alerts.firstMatch
        if alert.exists { alert.buttons.firstMatch.tap() }
        openFontSizePage()
        XCTAssertEqual(slider.value as? String, "150%")
        reset.tap()
        XCTAssertEqual(slider.value as? String, "100%")
        let finalPreview = XCTAttachment(screenshot: app.screenshot())
        finalPreview.name = "字体大小预览页"
        finalPreview.lifetime = .keepAlways
        add(finalPreview)
    }

    private func tapFontSystemSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func openFontSizePage() {
        homeSettings.tap()
        let entry = app.buttons["font-size-settings-row"]
        for _ in 0..<6 {
            if entry.exists && entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        XCTAssertFalse(app.sliders["font-size-slider"].exists, "设置页只应显示入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["字体大小"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders["font-size-slider"].exists)
    }

    func testLeftSwipeClosesOpenDrawer() {
        let workspace = app.buttons["选择工作区"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        dragRight(from: workspace)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(homeSettings.frame.minX < app.frame.width, "侧栏未关闭：\(homeSettings.frame)")
    }

    func testDrawerItemRemainsTappableAfterSwipe() {
        let workspace = app.buttons["选择工作区"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        dragRight(from: workspace)
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width)
        app.buttons["插件"].tap()
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 3))
    }

    func testLeftSwipeOnDrawerSurfaceClosesWithoutOpeningPlugin() {
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(homeSettings.frame.minX > app.frame.width)

        let plugin = app.buttons["插件"]
        XCTAssertTrue(plugin.exists)
        let start = plugin.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = plugin.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(homeSettings.frame.minX < app.frame.width, "在侧栏上左滑未关闭")
        XCTAssertFalse(app.navigationBars["插件"].exists, "左滑误触发插件入口")
    }

    func testSmallSlowLeftDragKeepsDrawerOpenAndAllowsNextClose() {
        app.buttons["打开侧边栏"].tap()
        let closeControl = app.buttons["关闭侧边栏"]
        XCTAssertTrue(closeControl.exists)
        let openX = closeControl.frame.minX
        XCTAssertTrue(openX > app.frame.width * 0.7)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6))
        let end = start.withOffset(CGVector(dx: -16, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let returnedToOpen = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(closeControl.frame.minX - openX) <= 2 },
            object: nil
        )
        let result = XCTWaiter.wait(for: [returnedToOpen], timeout: 3)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(result, .completed, "短距离左滑应回到打开位置")

        app.buttons["关闭侧边栏"].tap()
        XCTAssertTrue(homeSettings.frame.minX < app.frame.width, "拖动后关闭层丢失")
        homeSettings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    }

    private func dragRight(from element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: start.screenPoint.y / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private var homeSettings: XCUIElement { app.buttons["设置"] }
}
