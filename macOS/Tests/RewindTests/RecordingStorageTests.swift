import XCTest
import AVFoundation
import CoreImage
import CryptoKit
@testable import Rewind

final class RecordingStorageTests:XCTestCase {
    func testInstalledCaptureKeepsOriginalImagesAndSeparateAudio()async throws {
        guard let path = ProcessInfo.processInfo.environment["RECALL_CAPTURE_LIBRARY"],
              let id = ProcessInfo.processInfo.environment["RECALL_CAPTURE_SESSION"] else { throw XCTSkip("Opt-in read-only installed capture check") }
        let root = URL(fileURLWithPath:path),store = try MemoryStore(root:root,readOnly:true)
        let session = try XCTUnwrap(store.session(id))
        XCTAssertEqual(session.storagePolicy,2);XCTAssertEqual(session.usesExternalAudio,true)
        let video = AVURLAsset(url:root.appendingPathComponent(session.videoPath))
        let videoTracks = try await video.loadTracks(withMediaType:.video)
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize),fps = try await track.load(.nominalFrameRate)
        let embedded = try await video.loadTracks(withMediaType:.audio)
        XCTAssertTrue(embedded.isEmpty);XCTAssertLessThanOrEqual(max(size.width,size.height),720)
        XCTAssertLessThan(fps,1.2)
        let frames = try store.frames(demo:false,limit:200).filter { $0.sessionID == id }
        let frame = try XCTUnwrap(frames.first,"A video-only recording is not a successful screen-index capture")
        let pixels = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
        XCTAssertGreaterThan(pixels.width,Int(size.width));XCTAssertNotNil(frame.pixelDigest)
        let composition = try await RecordingPlayback.asset(session:session,root:root)
        let tracks = try await composition.loadTracks(withMediaType:.audio)
        XCTAssertEqual(tracks.count,[session.systemAudioPath,session.microphoneAudioPath].compactMap{$0}.count)
        let duration = try await video.load(.duration)
        XCTAssertEqual(duration.seconds,try XCTUnwrap(session.endedAt).timeIntervalSince(session.startedAt),accuracy:0.2)
        print("INSTALLED_CAPTURE: screenshot=\(pixels.width)x\(pixels.height) video=\(Int(size.width))x\(Int(size.height)) fps=\(fps) duration=\(duration.seconds) frames=\(frames.count) embeddedAudio=\(embedded.count) playbackAudio=\(tracks.count)")
    }
    private func audio(root:URL,path:String,start:Date)async throws {
        let rate = 48000.0,samples = 480000
        var asbd = AudioStreamBasicDescription(mSampleRate:rate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,mBytesPerPacket:2,mFramesPerPacket:1,mBytesPerFrame:2,mChannelsPerFrame:1,mBitsPerChannel:16,mReserved:0)
        var description:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&description),noErr)
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:samples*2,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:samples*2,flags:0,blockBufferOut:&block),noErr)
        let tone = (0..<samples).map { Int16(sin(Double($0)*2*Double.pi*440/rate)*2000) }
        _ = tone.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:$0.count) }
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:.zero,decodeTimeStamp:.invalid),buffer:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:description,sampleCount:samples,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&buffer),noErr)
        let sink = AudioTrackSink(root:root,path:path,start:start)
        sink.queue.sync { sink.consume(buffer!) }
        let saved = await sink.finish();XCTAssertNotNil(saved)
    }
    private func videoPackets(_ url:URL)async throws->Data {
        let asset = AVURLAsset(url:url),reader = try AVAssetReader(asset:asset)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        let output = AVAssetReaderTrackOutput(track:try XCTUnwrap(tracks.first),outputSettings:nil)
        reader.add(output);XCTAssertTrue(reader.startReading())
        var result = Data()
        while let sample = output.copyNextSampleBuffer() {
            if let block = sample.dataBuffer {
                var bytes = Data(count:CMBlockBufferGetDataLength(block))
                _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }
                result.append(bytes)
            }
        }
        XCTAssertEqual(reader.status,.completed);return result
    }
    func testAudioStoredOnceAndPlayedWithOffsetsWithoutChangingEncodedVideo()async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),start = Date(),path = "recordings/light.mp4"
        let sink = try LightweightVideoSink(url:root.appendingPathComponent(path),width:1600,height:1000,startedAt:start,hostStart:.zero)
        sink.queue.sync { sink.consume(CIImage(color:.blue).cropped(to:CGRect(x:0,y:0,width:1600,height:1000)),at:.zero) }
        try await Task.sleep(for:.milliseconds(50));try await sink.finish(at:start.addingTimeInterval(10))
        try await audio(root:root,path:"recordings/system.m4a",start:start)
        try await audio(root:root,path:"recordings/microphone.m4a",start:start)
        var session = RecordingSession(startedAt:start,endedAt:start.addingTimeInterval(10),videoPath:path,appName:"Test",hasAudio:true,systemAudioPath:"recordings/system.m4a",microphoneAudioPath:"recordings/microphone.m4a",systemAudioOffset:0.25,microphoneAudioOffset:0.75,usesExternalAudio:true,audioSources:["system","microphone"])
        let composition = try await RecordingPlayback.asset(session:session,root:root)
        let audioTracks = try await composition.loadTracks(withMediaType:.audio)
        XCTAssertEqual(audioTracks.count,2)
        for (index,track) in audioTracks.enumerated() {
            let segments = try await track.load(.segments)
            let first = try XCTUnwrap(segments.first(where:{!$0.isEmpty}))
            XCTAssertEqual(first.timeMapping.target.start.seconds,index == 0 ? 0.25:0.75,accuracy:0.001)
            let formats = try await track.load(.formatDescriptions)
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(formats.first))?.pointee.mSampleRate,48000)
        }
        let systemBefore = try Data(contentsOf:root.appendingPathComponent("recordings/system.m4a")),micBefore = try Data(contentsOf:root.appendingPathComponent("recordings/microphone.m4a"))
        // Recreate the old storage layout: embedded audio plus two separate files.
        let embedded = root.appendingPathComponent("recordings/embedded.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough))
        try await exporter.export(to:embedded,as:.mp4)
        session.videoPath = "recordings/embedded.mp4";session.usesExternalAudio = nil;try store.saveSession(session)
        let candidate = root.appendingPathComponent("recordings/archive-work-copy.mp4")
        let references = try AudioArchiveReference.candidates(session:session,root:root)
        let result = try await VideoArchive.make(source:embedded,destination:candidate,externalAudio:references)
        XCTAssertTrue(result.accepted);XCTAssertEqual(result.externalAudio.count,2)
        let beforePackets = try await videoPackets(embedded),afterPackets = try await videoPackets(candidate)
        XCTAssertEqual(beforePackets,afterPackets,"Already-light video must be remuxed, not recompressed")
        let archivedAudio = try await AVURLAsset(url:candidate).loadTracks(withMediaType:.audio)
        XCTAssertTrue(archivedAudio.isEmpty)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("recordings/system.m4a")),systemBefore)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("recordings/microphone.m4a")),micBefore)
        XCTAssertGreaterThan(try store.commitVideoArchive(sessionID:session.id,originalPath:session.videoPath,candidatePath:"recordings/archive-work-copy.mp4",result:result),0)
        let updated = try XCTUnwrap(store.session(session.id));XCTAssertEqual(updated.usesExternalAudio,true)
        let replay = try await RecordingPlayback.asset(session:updated,root:root)
        let replayTracks = try await replay.loadTracks(withMediaType:.audio);XCTAssertEqual(replayTracks.count,2)
        print("AUDIO_DEDUP_FIXTURE: before=\(result.originalBytes) after=\(result.archivedBytes) videoPacketsIdentical=true audioFilesIdentical=true")
        // An old single saved track cannot prove that the other source succeeded.
        session.audioSources = nil;session.microphoneAudioPath = nil
        XCTAssertTrue(try AudioArchiveReference.candidates(session:session,root:root).isEmpty)
    }
}
