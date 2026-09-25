import XCTest
@testable import Rewind

final class OCRRecoveryTests:XCTestCase {
    func testEngineFailureUsesCompatibilityThenRetriesPrimaryAfterCooldown() throws {
        let recovery = OCRRecovery(),now = Date(),failure = NSError(domain:"TextRecognition.CRImageReaderError",code:1)
        var attempts = 0
        func primary() throws -> String { attempts += 1;throw failure }
        XCTAssertEqual(try recovery.recognize(at:now,primary:primary,compatible:{"中文 Paper 12345"}),"中文 Paper 12345")
        XCTAssertEqual(try recovery.recognize(at:now.addingTimeInterval(5),primary:primary,compatible:{"next frame"}),"next frame")
        XCTAssertEqual(attempts,1)
        XCTAssertEqual(try recovery.recognize(at:now.addingTimeInterval(3601),primary:{attempts += 1;return "recovered"},compatible:{XCTFail("Primary recovered");return ""}),"recovered")
        XCTAssertEqual(attempts,2)
    }
    func testSystemRequestDeadlineFallsBackWithoutWaitingForStuckEngine() throws {
        let recovery = OCRRecovery(),start = Date()
        var cancelled = false
        let result = try recovery.recognize(primary:{
            try BoundedOCRWork.run(timeout:0.01,cancel:{cancelled = true}) { Thread.sleep(forTimeInterval:0.25);return "too late" }
        },compatible:{"local result"})
        XCTAssertEqual(result,"local result");XCTAssertTrue(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start),0.2)
    }
    func testCancellationDoesNotFallBackAndFailureIsNotAnEmptySuccess() {
        let recovery = OCRRecovery()
        XCTAssertThrowsError(try recovery.recognize(primary:{() throws -> String in throw CancellationError()},compatible:{XCTFail("Cancellation must propagate");return ""}))
        XCTAssertThrowsError(try recovery.recognize(primary:{throw NSError(domain:"TextRecognition.CRImageReaderError",code:1)},compatible:{throw NSError(domain:"CPU unavailable",code:1)}))
    }
    func testRecoveryPreferenceSurvivesRestartWithoutChangingUserSettings() throws {
        let name = "Recall.OCRRecoveryTests."+UUID().uuidString,defaults = UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let now = Date()
        _ = try OCRRecovery(defaults:defaults).recognize(at:now,primary:{throw NSError(domain:"TextRecognition.CRImageReaderError",code:1)},compatible:{"kept"})
        XCTAssertEqual(try OCRRecovery(defaults:defaults).recognize(at:now,primary:{XCTFail("Avoid broken accelerator after restart");return ""},compatible:{"safe"}),"safe")
    }
}
