import XCTest
@testable import Rewind

final class PermissionTests: XCTestCase {
    @MainActor func testScreenOnlyNeverRequestsMicrophone() async throws {
        var asked = false
        try await CapturePermissions.ensureMicrophone(enabled:false,status:{ .denied },request:{ asked = true; return false })
        XCTAssertFalse(asked)
    }
    @MainActor func testUndeterminedMicrophoneRequestsOnceAndPropagatesDecision() async throws {
        var calls = 0
        try await CapturePermissions.ensureMicrophone(enabled:true,status:{ .notDetermined },request:{ calls += 1; return true })
        XCTAssertEqual(calls,1)
        do {
            try await CapturePermissions.ensureMicrophone(enabled:true,status:{ .notDetermined },request:{ false })
            XCTFail("Denied permission must prevent microphone capture")
        } catch { XCTAssertTrue(error is CapturePermissionError) }
    }
    @MainActor func testKnownMicrophoneDecisionsNeverPromptAgain() async throws {
        var asked = false
        for state in [MicrophonePermission.denied,.restricted] {
            do {
                try await CapturePermissions.ensureMicrophone(enabled:true,status:{ state },request:{ asked = true; return true })
                XCTFail("Cannot record when access is denied or restricted")
            } catch { XCTAssertTrue(error is CapturePermissionError) }
        }
        try await CapturePermissions.ensureMicrophone(enabled:true,status:{ .authorized },request:{ asked = true; return true })
        XCTAssertFalse(asked)
    }
    func testRapidReopenInvalidatesDismissalCompletion() throws {
        var state = OverlayTransitionState()
        XCTAssertNotNil(state.setVisible(true))
        XCTAssertNil(state.setVisible(true))
        let closing = try XCTUnwrap(state.setVisible(false))
        XCTAssertTrue(state.isCurrent(closing,visible:false))
        _ = state.setVisible(true)
        XCTAssertFalse(state.isCurrent(closing,visible:false))
        XCTAssertTrue(state.visible)
        let final = try XCTUnwrap(state.setVisible(false))
        XCTAssertTrue(state.isCurrent(final,visible:false))
    }
}
