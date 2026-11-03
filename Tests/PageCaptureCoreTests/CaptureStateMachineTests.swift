import XCTest
@testable import PageCaptureCore

final class CaptureStateMachineTests: XCTestCase {
    private func machine(after events: CaptureEvent...) -> CaptureStateMachine {
        var machine = CaptureStateMachine()
        for event in events { machine.handle(event) }
        return machine
    }

    func testIdleHasNoBanner() {
        let machine = CaptureStateMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.bannerText)
    }

    func testShortcutStartsPicking() {
        var machine = CaptureStateMachine()
        XCTAssertEqual(machine.handle(.shortcut), [.beginPicking])
        XCTAssertEqual(machine.phase, .picking)
        XCTAssertEqual(machine.bannerText, "Pick a frame, scrolling area or article… (Return = whole page, Esc = cancel)")
    }

    func testEscapeWhilePickingCancels() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.escape), [.endPicking])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.bannerText)
    }

    func testShortcutWhilePickingCancels() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.shortcut), [.endPicking])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testPickingATargetStartsCapturingIt() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.picked(.picked)), [.endPicking, .beginCollection(.picked)])
        XCTAssertEqual(machine.phase, .capturing(.picked))
        XCTAssertEqual(machine.bannerText, "Capturing…")
    }

    func testClickOutsideAnyTargetCapturesWholePage() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.picked(.wholePage)), [.endPicking, .beginCollection(.wholePage)])
        XCTAssertEqual(machine.phase, .capturing(.wholePage))
    }

    func testReturnCapturesWholePage() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.returnKey), [.endPicking, .beginCollection(.wholePage)])
        XCTAssertEqual(machine.phase, .capturing(.wholePage))
    }

    func testShortcutWhileCapturingStopsAndKeepsCollecting() {
        var machine = machine(after: .shortcut, .returnKey)
        XCTAssertEqual(machine.handle(.shortcut), [.stopCollection])
        XCTAssertEqual(machine.phase, .stopping(.wholePage))
        XCTAssertEqual(machine.bannerText, "Capturing…")
        XCTAssertEqual(machine.handle(.collectionEnded), [.presentSave])
        XCTAssertEqual(machine.phase, .saving)
        XCTAssertNil(machine.bannerText)
    }

    func testReachingTheBottomPresentsSave() {
        var machine = machine(after: .shortcut, .picked(.picked))
        XCTAssertEqual(machine.handle(.collectionEnded), [.presentSave])
        XCTAssertEqual(machine.phase, .saving)
        XCTAssertNil(machine.bannerText)
    }

    func testSaveFinishedReturnsToIdle() {
        var machine = machine(after: .shortcut, .returnKey, .collectionEnded)
        XCTAssertEqual(machine.handle(.saveFinished), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testCollectionFailureReturnsToIdle() {
        var machine = machine(after: .shortcut, .returnKey)
        XCTAssertEqual(machine.handle(.collectionFailed), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testKeysThatDoNotApplyAreIgnored() {
        var idle = CaptureStateMachine()
        XCTAssertEqual(idle.handle(.escape), [])
        XCTAssertEqual(idle.handle(.returnKey), [])
        XCTAssertEqual(idle.handle(.picked(.picked)), [])
        XCTAssertEqual(idle.phase, .idle)

        var capturing = machine(after: .shortcut, .returnKey)
        XCTAssertEqual(capturing.handle(.escape), [])
        XCTAssertEqual(capturing.handle(.returnKey), [])
        XCTAssertEqual(capturing.handle(.picked(.picked)), [])
        XCTAssertEqual(capturing.phase, .capturing(.wholePage))

        var stopping = machine(after: .shortcut, .returnKey, .shortcut)
        XCTAssertEqual(stopping.handle(.escape), [])
        XCTAssertEqual(stopping.phase, .stopping(.wholePage))

        var saving = machine(after: .shortcut, .returnKey, .collectionEnded)
        XCTAssertEqual(saving.handle(.shortcut), [])
        XCTAssertEqual(saving.phase, .saving)
    }

    func testShortcutWhileStoppingAbortsToIdle() {
        var machine = machine(after: .shortcut, .returnKey, .shortcut)
        XCTAssertEqual(machine.handle(.shortcut), [.abortCollection])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.bannerText)
    }

    func testNavigationWhilePickingEndsPicking() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.navigated), [.endPicking])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testNavigationWhileCapturingOrStoppingAbortsWithoutSaving() {
        var capturing = machine(after: .shortcut, .picked(.picked))
        XCTAssertEqual(capturing.handle(.navigated), [.abortCollection])
        XCTAssertEqual(capturing.phase, .idle)
        XCTAssertNil(capturing.bannerText)

        var stopping = machine(after: .shortcut, .returnKey, .shortcut)
        XCTAssertEqual(stopping.handle(.navigated), [.abortCollection])
        XCTAssertEqual(stopping.phase, .idle)
    }

    func testNavigationIsIgnoredWhenIdleOrSaving() {
        var idle = CaptureStateMachine()
        XCTAssertEqual(idle.handle(.navigated), [])
        var saving = machine(after: .shortcut, .returnKey, .collectionEnded)
        XCTAssertEqual(saving.handle(.navigated), [])
        XCTAssertEqual(saving.phase, .saving)
    }
}
