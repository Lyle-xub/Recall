import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage

struct ReplayVideoPolicy {
    static let longestEdge = 720
    static let fps = 1
    static let bitRate = 100_000
    static func size(width:Int,height:Int)->CGSize {
        let scale = min(1,Double(longestEdge)/Double(max(1,max(width,height))))
        return CGSize(width:max(2,Int(Double(width)*scale)/2*2),height:max(2,Int(Double(height)*scale)/2*2))
    }
}

/// The full-resolution SCStream is shared with the screenshot branch. Only
/// these video pixels are downsampled; no native-resolution movie is spooled.
final class LightweightVideoSink:NSObject,@unchecked Sendable {
    let queue = DispatchQueue(label:"studio.recall.light-video",qos:.utility)
    let dimensions:CGSize
    var onError:((Error)->Void)?
    private let writer:AVAssetWriter
    private let input:AVAssetWriterInput
    private let adaptor:AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let hostStart:CMTime
    private let startedAt:Date
    private var lastTime:CMTime?
    private var lastPixels:CVPixelBuffer?
    private var failure:Error?
    private var finishing = false
    private var unavailable = false
    init(url:URL,width:Int,height:Int,startedAt:Date,hostStart:CMTime)throws {
        dimensions = ReplayVideoPolicy.size(width:width,height:height)
        self.startedAt = startedAt;self.hostStart = hostStart
        writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        var settings:[String:Any] = [AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:Int(dimensions.width),AVVideoHeightKey:Int(dimensions.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:ReplayVideoPolicy.bitRate,AVVideoExpectedSourceFrameRateKey:ReplayVideoPolicy.fps,AVVideoMaxKeyFrameIntervalDurationKey:5,AVVideoAllowFrameReorderingKey:false]]
        if !writer.canApply(outputSettings:settings,forMediaType:.video) { settings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw RewindError.message("Lightweight video encoding is unavailable.") }
        input = AVAssetWriterInput(mediaType:.video,outputSettings:settings);input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:Int(dimensions.width),kCVPixelBufferHeightKey as String:Int(dimensions.height),kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.canAdd(input) else { throw RewindError.message("Cannot start the lightweight video branch.") }
        writer.add(input)
        super.init()
    }
    func append(_ buffer:CMSampleBuffer) {
        queue.async { [self] in consumeScreenSample(buffer) }
    }
    private func consumeScreenSample(_ buffer:CMSampleBuffer) {
        guard buffer.isValid else { return }
        let info = CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
        let status = (info?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) ?? .complete
        let time = CMTimeSubtract(buffer.presentationTimeStamp,hostStart)
        if status == .complete,let image = buffer.imageBuffer { unavailable = false;consume(CIImage(cvPixelBuffer:image),at:time) }
        else if status != .idle,!unavailable { unavailable = true;consume(CIImage(color:.black).cropped(to:CGRect(origin:.zero,size:dimensions)),at:time,force:true) }
    }
    /// Serial queue only. An unavailable frame becomes black instead of leaking
    /// the previous app through a protected/unavailable interval.
    func consume(_ image:CIImage,at sourceTime:CMTime,force:Bool = false) {
        guard !finishing,failure == nil,sourceTime.isNumeric else { return }
        let time = CMTimeMaximum(.zero,sourceTime)
        if let lastTime,!force,time.seconds-lastTime.seconds < 1.0/Double(ReplayVideoPolicy.fps)-0.01 { return }
        do {
            if writer.status == .unknown {
                guard writer.startWriting() else { throw writer.error ?? RewindError.message("Cannot start video encoding.") }
                writer.startSession(atSourceTime:.zero)
            }
            guard input.isReadyForMoreMediaData else { return }
            guard let pool = adaptor.pixelBufferPool else { throw RewindError.message("Cannot allocate replay video pixels.") }
            var pixels:CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&pixels) == kCVReturnSuccess,let pixels else { throw RewindError.message("Replay video pixel allocation failed.") }
            let normalized = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            let scaled = normalized.transformed(by:CGAffineTransform(scaleX:dimensions.width/image.extent.width,y:dimensions.height/image.extent.height))
            context.render(scaled,to:pixels,bounds:CGRect(origin:.zero,size:dimensions),colorSpace:colorSpace)
            let stamp = lastTime == nil ? CMTime.zero:CMTimeMaximum(time,CMTimeAdd(lastTime!,CMTime(value:1,timescale:600)))
            guard adaptor.append(pixels,withPresentationTime:stamp) else { throw writer.error ?? RewindError.message("Replay video write failed.") }
            lastPixels = pixels;lastTime = stamp
        } catch { failure = error;onError?(error) }
    }
    func finish(at date:Date)async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in queue.async { [self] in
            guard !finishing else { continuation.resume(throwing:RewindError.message("Video is already finishing."));return }
            finishing = true
            if let failure { writer.cancelWriting();continuation.resume(throwing:failure);return }
            guard let lastTime,let lastPixels,writer.status == .writing else { writer.cancelWriting();continuation.resume(throwing:RewindError.message("No video frames were captured."));return }
            let end = CMTime(seconds:max(lastTime.seconds+0.001,date.timeIntervalSince(startedAt)),preferredTimescale:600)
            // A static screen may produce no more SCStream frames. Explicitly
            // hold its last frame through the end of the recording segment.
            let tail = CMTimeSubtract(end,CMTime(value:1,timescale:600))
            if tail > lastTime,input.isReadyForMoreMediaData { _ = adaptor.append(lastPixels,withPresentationTime:tail) }
            writer.endSession(atSourceTime:end);input.markAsFinished()
            writer.finishWriting { [self] in
                if writer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing:writer.error ?? RewindError.message("Replay video finalization failed.")) }
            }
        } }
    }
}
