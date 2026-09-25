import XCTest
@testable import Rewind

final class OnboardingTests:XCTestCase {
    func testFirstLaunchAndExistingLibraryMigration() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8))
        XCTAssertTrue(OnboardingPolicy.shouldPresent(completed:legacy.onboardingComplete,memories:0))
        XCTAssertFalse(OnboardingPolicy.shouldPresent(completed:legacy.onboardingComplete,memories:125))
        XCTAssertFalse(OnboardingPolicy.shouldPresent(completed:true,memories:0))
    }
    func testFinishingOrSkippingPreservesAllCaptureAndModelPreferences() throws {
        var settings = AppSettings()
        settings.microphone = true;settings.systemAudio = true;settings.transcriptionEnabled = true
        settings.showDockIcon = true;settings.captureInterval = 17;settings.retentionDays = 90
        settings.chat = ModelProfile(provider:"Custom",baseURL:"https://example.com/v1",model:"private-model",isLocal:false)
        settings.excludedApps += ["example.private"]
        let completed = OnboardingPolicy.completedSettings(settings)
        let restored = try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(completed))
        XCTAssertTrue(restored.onboardingComplete)
        var actual = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(restored)) as? [String:Any])
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as? [String:Any])
        actual.removeValue(forKey:"onboardingComplete");expected.removeValue(forKey:"onboardingComplete")
        XCTAssertEqual(actual as NSDictionary,expected as NSDictionary)
        XCTAssertTrue(restored.microphone);XCTAssertTrue(restored.systemAudio)
        XCTAssertEqual(restored.chat.provider,"Custom")
    }
    func testFilmOnlyAutoplaysForUnseenNewInstall() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8))
        XCTAssertTrue(OnboardingPolicy.shouldPlayFilm(settings:legacy,memories:0))
        XCTAssertFalse(OnboardingPolicy.shouldPlayFilm(settings:legacy,memories:125))
        var completed = legacy;completed.onboardingComplete = true
        XCTAssertFalse(OnboardingPolicy.shouldPlayFilm(settings:completed,memories:0))
        let seen = OnboardingPolicy.filmStartedSettings(legacy)
        let restored = try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(seen))
        XCTAssertFalse(OnboardingPolicy.shouldPlayFilm(settings:restored,memories:0))
        XCTAssertTrue(OnboardingPolicy.shouldPresent(completed:restored.onboardingComplete,memories:0))
    }
    func testStartingFilmDoesNotCompleteSetupOrEnableCapture() throws {
        var initial = AppSettings();initial.captureInterval = 17;initial.systemAudio = true
        initial.showDockIcon = true;initial.excludedApps.append("private.example")
        let seen = OnboardingPolicy.filmStartedSettings(initial)
        XCTAssertTrue(seen.launchFilmSeen);XCTAssertFalse(seen.onboardingComplete)
        var actual = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(seen)) as? [String:Any])
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(initial)) as? [String:Any])
        actual.removeValue(forKey:"launchFilmSeen");expected.removeValue(forKey:"launchFilmSeen")
        XCTAssertEqual(actual as NSDictionary,expected as NSDictionary)
    }
}
