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

    private func dragRight(from element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: start.screenPoint.y / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private var homeSettings: XCUIElement { app.buttons["设置"] }
}
