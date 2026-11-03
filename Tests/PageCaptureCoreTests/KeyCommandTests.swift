import AppKit
import XCTest
@testable import PageCaptureCore

final class KeyCommandTests: XCTestCase {
    private func event(_ keyCode: UInt16, _ characters: String? = nil, _ flags: NSEvent.ModifierFlags = [],
                       in phase: CapturePhase = .picking) -> CaptureEvent? {
        KeyCommand.event(keyCode: keyCode, characters: characters, flags: flags, phase: phase)
    }

    func testEscapeAndReturnWhilePicking() {
        XCTAssertEqual(event(53), .escape)
        XCTAssertEqual(event(36), .returnKey)
        XCTAssertEqual(event(76), .returnKey)
    }

    func testEscapeAndReturnOnlyWhilePicking() {
        for phase: CapturePhase in [.idle, .capturing(.wholePage), .stopping(.wholePage), .saving] {
            XCTAssertNil(event(53, in: phase))
            XCTAssertNil(event(36, in: phase))
        }
    }

    func testCapsLockNumericPadAndFunctionFlagsAreIgnored() {
        XCTAssertEqual(event(53, nil, [.capsLock]), .escape)
        XCTAssertEqual(event(36, nil, [.capsLock]), .returnKey)
        XCTAssertEqual(event(76, nil, [.numericPad]), .returnKey)
        XCTAssertEqual(event(53, nil, [.function]), .escape)
        XCTAssertEqual(event(1, "S", [.command, .shift, .capsLock]), .shortcut)
    }

    func testRealModifiersStillBlockEscapeAndReturn() {
        XCTAssertNil(event(53, nil, [.command]))
        XCTAssertNil(event(36, nil, [.shift]))
        XCTAssertNil(event(36, nil, [.option, .capsLock]))
    }

    func testCommandShiftSInEveryPhase() {
        let phases: [CapturePhase] = [.idle, .picking, .capturing(.picked), .stopping(.picked), .saving]
        for phase in phases {
            XCTAssertEqual(event(1, "S", [.command, .shift], in: phase), .shortcut)
            XCTAssertEqual(event(1, "s", [.command, .shift], in: phase), .shortcut)
        }
    }

    func testCommandShiftSFollowsTheLayoutCharacter() {
        XCTAssertEqual(event(2, "s", [.command, .shift]), .shortcut)
        XCTAssertNil(event(1, "o", [.command, .shift]))
    }

    func testOtherSModifierCombinationsPassThrough() {
        XCTAssertNil(event(1, "s", [.command]))
        XCTAssertNil(event(1, "S", [.shift]))
        XCTAssertNil(event(1, "s", [.command, .shift, .option]))
        XCTAssertNil(event(1, "s", [.command, .shift, .control]))
    }
}
