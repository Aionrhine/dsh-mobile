import XCTest
@testable import DeepSeekHarnessMobile

@MainActor
final class WorkspaceDrawerFeedbackTests: XCTestCase {
    func testReleaseFiresSynchronouslyOnceForEachDragIncludingRebound() {
        var preparations = 0
        var pulses = 0
        let feedback = WorkspaceDrawerFeedback(prepare: { preparations += 1 }, impact: { pulses += 1 })
        // 不依赖位移或动画目标，打开、关闭和短滑回弹都在松手时反馈。
        for count in 1...3 {
            feedback.beginDrag()
            feedback.beginDrag()
            XCTAssertEqual(preparations, count)
            XCTAssertEqual(pulses, count - 1)
            feedback.endDrag(cancelled: false)
            XCTAssertEqual(pulses, count)
            feedback.endDrag(cancelled: false)
            XCTAssertEqual(pulses, count)
        }
    }

    func testCancellationDoesNotPulseAndNextReleaseStillWorks() {
        var pulses = 0
        let feedback = WorkspaceDrawerFeedback(prepare: {}, impact: { pulses += 1 })
        feedback.beginDrag()
        feedback.endDrag(cancelled: true)
        feedback.endDrag(cancelled: false)
        XCTAssertEqual(pulses, 0)
        feedback.beginDrag()
        feedback.endDrag(cancelled: false)
        XCTAssertEqual(pulses, 1)
    }

    func testTapFiresImmediatelyAndDoesNotLeaveAPendingDragPulse() {
        var pulses = 0
        let feedback = WorkspaceDrawerFeedback(prepare: {}, impact: { pulses += 1 })
        feedback.tap()
        XCTAssertEqual(pulses, 1)
        feedback.beginDrag()
        feedback.tap()
        XCTAssertEqual(pulses, 2)
        feedback.endDrag(cancelled: false)
        XCTAssertEqual(pulses, 2)
    }
}
