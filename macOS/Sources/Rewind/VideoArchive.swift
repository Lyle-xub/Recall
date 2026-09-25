import Foundation
import AVFoundation
import CoreVideo

struct VideoArchiveResult:Sendable {
    let accepted:Bool
    let originalBytes:Int64
    let archivedBytes:Int64
    let reason:String
    var externalAudio:[AudioArchiveReference] = []
}

/// Re-encode only completed recordings. OCR never depends on this video: its
/// source remains the full-resolution lossless screenshot captured beforehand.
enum VideoArchive {
    static let policyVersion = 5
    static func make(source:URL,destination:URL,externalAudio:[AudioArchiveReference] = []) async throws -> VideoArchiveResult {
        try Task.checkCancellation()
        let originalBytes = try CleanupFiles.size(source)
        let asset = AVURLAsset(url:source)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite,duration.seconds > 1,
              let video = try await asset.loadTracks(withMediaType:.video).first else {
            return .init(accepted:false,originalBytes:originalBytes,archivedBytes:originalBytes,reason:"No complete video")
        }
        let embeddedAudio = try await asset.loadTracks(withMediaType:.audio)
        for reference in externalAudio { try await reference.validate(duration:duration.seconds) }
        let audio = externalAudio.isEmpty ? embeddedAudio:[]
        let size = try await video.load(.naturalSize), fps = try await video.load(.nominalFrameRate)
        let bitRate = try await video.load(.estimatedDataRate)
        let orientation = try await video.load(.preferredTransform)
        let bounds = CGRect(origin:.zero,size:size).applying(orientation)
        let scale = min(1,CGFloat(ReplayVideoPolicy.longestEdge)/max(bounds.width,bounds.height))
        let dimensions = (max(2,Int(bounds.width*scale)/2*2),max(2,Int(bounds.height*scale)/2*2))
        let renderSize = CGSize(width:dimensions.0,height:dimensions.1)
        let outputFPS = ReplayVideoPolicy.fps
        let target = ReplayVideoPolicy.bitRate
        guard Double(bitRate) > Double(target)*1.15 || fps > Float(outputFPS)+0.1 || max(bounds.width,bounds.height) > CGFloat(ReplayVideoPolicy.longestEdge) else {
            if !externalAudio.isEmpty,!embeddedAudio.isEmpty {
                return try await removeEmbeddedAudio(asset:asset,video:video,duration:duration,destination:destination,originalBytes:originalBytes,references:externalAudio)
            }
            return .init(accepted:false,originalBytes:originalBytes,archivedBytes:originalBytes,reason:"Already efficient",externalAudio:externalAudio)
        }
        let reader = try AVAssetReader(asset:asset)
        let writer = try AVAssetWriter(outputURL:destination,fileType:.mp4)
        // Video is a lightweight replay, independent of full-resolution OCR
        // screenshots. The composition downsamples pixels and frame cadence.
        let output = AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize;composition.frameDuration = CMTime(value:1,timescale:Int32(outputFPS))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start:.zero,duration:duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:video)
        let transform = orientation.concatenating(CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY)).concatenating(CGAffineTransform(scaleX:Double(dimensions.0)/bounds.width,y:Double(dimensions.1)/bounds.height))
        layer.setTransform(transform,at:.zero);instruction.layerInstructions = [layer]
        composition.instructions = [instruction];output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        var compression:[String:Any] = [AVVideoAverageBitRateKey:Int(target),AVVideoMaxKeyFrameIntervalDurationKey:2,AVVideoAllowFrameReorderingKey:true]
        compression[AVVideoExpectedSourceFrameRateKey] = outputFPS
        var settings:[String:Any] = [AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:dimensions.0,AVVideoHeightKey:dimensions.1,AVVideoCompressionPropertiesKey:compression]
        if let format = try await video.load(.formatDescriptions).first {
            let mapping:[CFString:String] = [kCMFormatDescriptionExtension_ColorPrimaries:AVVideoColorPrimariesKey,kCMFormatDescriptionExtension_TransferFunction:AVVideoTransferFunctionKey,kCMFormatDescriptionExtension_YCbCrMatrix:AVVideoYCbCrMatrixKey]
            var color:[String:Any] = [:]
            for (sourceKey,key) in mapping { if let value = CMFormatDescriptionGetExtension(format,extensionKey:sourceKey) { color[key] = value } }
            if !color.isEmpty { settings[AVVideoColorPropertiesKey] = color }
        }
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw RewindError.message("Efficient HEVC encoding is unavailable.") }
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        var pairs:[(AVAssetReaderOutput,AVAssetWriterInput)] = [(output,input)]
        for track in audio {
            guard let format = try await track.load(.formatDescriptions).first else { throw RewindError.message("Cannot preserve this recording’s audio.") }
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:nil)
            output.alwaysCopiesSampleData = false
            pairs.append((output,AVAssetWriterInput(mediaType:.audio,outputSettings:nil,sourceFormatHint:format)))
        }
        for (output,input) in pairs {
            guard reader.canAdd(output),writer.canAdd(input) else { throw RewindError.message("Cannot preserve all recording tracks.") }
            reader.add(output);writer.add(input)
        }
        let job = VideoArchiveJob(reader:reader,writer:writer,pairs:pairs,duration:duration)
        try await withTaskCancellationHandler(operation:{ try Task.checkCancellation();try await job.run() },onCancel:{job.cancel()})
        try Task.checkCancellation()
        let archivedBytes = try CleanupFiles.size(destination)
        guard archivedBytes < originalBytes*(externalAudio.isEmpty ? 85:100)/100 else {
            return .init(accepted:false,originalBytes:originalBytes,archivedBytes:archivedBytes,reason:"No useful space saving")
        }
        let copy = AVURLAsset(url:destination)
        let copyDuration = try await copy.load(.duration)
        guard abs(copyDuration.seconds-duration.seconds) <= 0.15,
              try await copy.loadTracks(withMediaType:.audio).count == audio.count,
              let copyTrack = try await copy.loadTracks(withMediaType:.video).first,
              try await copyTrack.load(.naturalSize) == renderSize,
              try await copyTrack.load(.nominalFrameRate) <= 1.1 else { throw RewindError.message("The smaller recording did not preserve its tracks or duration.") }
        // Validate playback, never OCR or textual fidelity on the video.
        _ = try await AVAssetImageGenerator(asset:copy).image(at:CMTime(seconds:duration.seconds/2,preferredTimescale:600))
        return .init(accepted:true,originalBytes:originalBytes,archivedBytes:archivedBytes,reason:"Verified",externalAudio:externalAudio)
    }
    private static func removeEmbeddedAudio(asset:AVAsset,video:AVAssetTrack,duration:CMTime,destination:URL,originalBytes:Int64,references:[AudioArchiveReference])async throws->VideoArchiveResult {
        let reader = try AVAssetReader(asset:asset),writer = try AVAssetWriter(outputURL:destination,fileType:.mp4)
        guard let format = try await video.load(.formatDescriptions).first else { throw RewindError.message("Cannot preserve the existing video encoding.") }
        let output = AVAssetReaderTrackOutput(track:video,outputSettings:nil)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:format)
        input.transform = try await video.load(.preferredTransform)
        guard reader.canAdd(output),writer.canAdd(input) else { throw RewindError.message("Cannot remove duplicate audio safely.") }
        reader.add(output);writer.add(input)
        let job = VideoArchiveJob(reader:reader,writer:writer,pairs:[(output,input)],duration:duration)
        try await withTaskCancellationHandler(operation:{try await job.run()},onCancel:{job.cancel()})
        try Task.checkCancellation()
        let copy = AVURLAsset(url:destination),size = try CleanupFiles.size(destination)
        guard try await copy.loadTracks(withMediaType:.audio).isEmpty,
              abs(try await copy.load(.duration).seconds-duration.seconds) < 0.15 else { throw RewindError.message("Audio deduplication changed the recording duration.") }
        _ = try await AVAssetImageGenerator(asset:copy).image(at:CMTime(seconds:duration.seconds/2,preferredTimescale:600))
        return .init(accepted:size < originalBytes,originalBytes:originalBytes,archivedBytes:size,reason:"Video packets preserved; duplicate audio removed",externalAudio:references)
    }

}

private final class VideoArchiveJob:@unchecked Sendable {
    let reader:AVAssetReader,writer:AVAssetWriter,pairs:[(AVAssetReaderOutput,AVAssetWriterInput)],duration:CMTime
    let queue = DispatchQueue(label:"studio.recall.video-archive",qos:.utility)
    private var continuation:CheckedContinuation<Void,Error>?
    private var remaining = 0
    private var completed = false
    private var cancelled = false
    init(reader:AVAssetReader,writer:AVAssetWriter,pairs:[(AVAssetReaderOutput,AVAssetWriterInput)],duration:CMTime) { self.reader = reader;self.writer = writer;self.pairs = pairs;self.duration = duration }
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(CancellationError());return }
            guard writer.startWriting(),reader.startReading() else { finish(writer.error ?? reader.error ?? RewindError.message("Cannot start video optimization."));return }
            writer.startSession(atSourceTime:.zero);remaining = pairs.count
            for (output,input) in pairs {
                input.requestMediaDataWhenReady(on:queue) { [self] in
                    guard !completed else { return }
                    while input.isReadyForMoreMediaData {
                        if let sample = output.copyNextSampleBuffer() {
                            guard input.append(sample) else { finish(writer.error ?? RewindError.message("Video encoding failed."));return }
                        } else {
                            input.markAsFinished();remaining -= 1
                            if let error = reader.error { finish(error);return }
                            if remaining == 0 {
                                writer.endSession(atSourceTime:duration)
                                writer.finishWriting { self.queue.async { self.finish(self.writer.status == .completed ? nil:self.writer.error ?? RewindError.message("Video finalization failed.")) } }
                            }
                            return
                        }
                    }
                }
            }
        } }
    }
    func cancel() { queue.async { self.cancelled = true;if self.continuation != nil { self.finish(CancellationError()) } } }
    private func finish(_ error:Error?) {
        guard !completed else { return };completed = true
        if let error {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            continuation?.resume(throwing:error)
        } else { continuation?.resume() }
        continuation = nil
    }
}
