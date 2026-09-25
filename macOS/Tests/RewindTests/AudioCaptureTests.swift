import XCTest
import AVFoundation
@testable import Rewind

final class AudioCaptureTests: XCTestCase {
    /// Reproduce the actual hardware input that previously caused an uncaught
    /// NSInvalidArgumentException, then inspect the encoded asset, not just settings.
    func testHighRateMicrophoneIsEncodedAsPlayable48kHzAAC() async throws {
        for rate in [96000.0,192000.0] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let sink = AudioTrackSink(root:root,path:"microphone.m4a",start:Date())
            let sample = try pcm(sampleRate:rate)
            sink.queue.sync { sink.consume(sample) }
            let result = await sink.finish()
            XCTAssertNotNil(result,"\(rate) Hz source must finish without crashing or losing the audio track")
            let asset = AVURLAsset(url:root.appendingPathComponent("microphone.m4a"))
            let tracks = try await asset.loadTracks(withMediaType:.audio)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
            XCTAssertEqual(format.mSampleRate,48000)
            XCTAssertEqual(format.mFormatID,kAudioFormatMPEG4AAC)
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration,0.4); XCTAssertLessThan(duration,0.7)
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
            reader.add(output); XCTAssertTrue(reader.startReading())
            XCTAssertNotNil(output.copyNextSampleBuffer(),"The resulting AAC file must decode")
            reader.cancelReading()
        }
    }
    private func pcm(sampleRate:Double) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate:sampleRate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,mBytesPerPacket:2,mFramesPerPacket:1,mBytesPerFrame:2,mChannelsPerFrame:1,mBitsPerChannel:16,mReserved:0)
        var description:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&format,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&description),noErr)
        let samples = Int(sampleRate/2),bytes = samples*2
        var data:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:bytes,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:bytes,flags:0,blockBufferOut:&data),noErr)
        let block = try XCTUnwrap(data)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with:0,blockBuffer:block,offsetIntoDestination:0,dataLength:bytes),noErr)
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:Int32(sampleRate)),presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
        var buffer:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:description,sampleCount:samples,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&buffer),noErr)
        return try XCTUnwrap(buffer)
    }
}
