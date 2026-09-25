import XCTest
import AVFoundation
@testable import Rewind
final class LocalInferenceTests: XCTestCase {
    func testWhisperTimestamps() throws {
        let data = Data("{\"transcription\":[{\"offsets\":{\"from\":12500},\"text\":\" A meeting note \"}]}".utf8)
        let start = Date();let lines = try LocalInference.parseTranscript(data,sessionID:"sample",start:start)
        XCTAssertEqual(lines.first?.text,"A meeting note");XCTAssertEqual(lines.first?.timestamp.timeIntervalSince(start),12.5)
    }
    func testAudioConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let source = root.appendingPathComponent("test.caf"),target = root.appendingPathComponent("test.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        do {let file = try AVAudioFile(forWriting:source,settings:format.settings);let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;buffer.frameLength = 48000
            for c in 0..<2 {for i in 0..<48000 {buffer.floatChannelData![c][i] = 0.1 * sin(Float(i)*0.05)}}
            try file.write(from:buffer)
        }
        try LocalInference.convertAudio(source,to:target);let result = try AVAudioFile(forReading:target)
        XCTAssertEqual(result.processingFormat.sampleRate,16000);XCTAssertEqual(result.processingFormat.channelCount,1);XCTAssertEqual(Double(result.length)/16000,1,accuracy:0.02)
    }
    func testInstalledModelsEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["REWIND_LIVE_MODEL_TEST"] == "1" else {throw XCTSkip("Opt-in real inference test needs downloaded models and packaged engines")}
        do {
            let frame = MemoryFrame(timestamp:Date(),appName:"Test",bundleID:"test",title:"Project note",imagePath:"",text:"The agreed project budget is 42 dollars. The deadline is Friday.",regions:[])
            let answer = try await ModelClient.answer(question:"What is the project budget? Include the number and cite the source.",sources:[frame],transcripts:[],history:[],profile:.builtinChat,key:"") {partial in XCTAssertFalse(partial.isEmpty)}
            XCTAssertTrue(answer.contains("42"),answer);XCTAssertTrue(answer.contains("[1]"),answer)
            let audio = URL(fileURLWithPath:ProcessInfo.processInfo.environment["REWIND_TEST_AUDIO"]!)
            let lines = try await ModelClient.transcribe(file:audio,sessionID:"test",start:Date(),profile:.builtinSpeech,key:"")
            let text = lines.map(\.text).joined(separator:" ").lowercased();XCTAssertTrue(text.contains("report"),text)
            await LocalInference.shared.stop()
        } catch {await LocalInference.shared.stop();throw error}
    }
}
