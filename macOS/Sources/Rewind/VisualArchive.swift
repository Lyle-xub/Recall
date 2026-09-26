import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics

/// A card and its recording refer to the same native-resolution video sample.
/// The lossless OCR spool remains until both recognition and video finalization
/// succeed. Historical images are never transcoded by this format.
struct VisualArchive:Codable,Sendable {
    static let fileExtension="recallvideo"
    let version:Int
    let video:String
    let ticks:Int64
    let width:Int
    let height:Int
    init(video:String,time:Double,width:Int,height:Int) {
        version=1;self.video=video;ticks=Int64((time*600).rounded());self.width=width;self.height=height
    }
    func validate(root:URL)throws->URL {
        guard version==1,video.hasPrefix("recordings/"),video.hasSuffix(".mp4"),ticks>=0,width>0,height>0,width<=16000,height<=16000,width*height<=40_000_000 else {throw RewindError.message("Invalid visual archive reference.")}
        return try CleanupFiles.ownedURL(video,root:root)
    }
    static func load(_ url:URL,maxPixels:Int?)throws->CGImage {
        let data=try Data(contentsOf:url)
        guard data.count<4096 else {throw RewindError.message("Invalid visual archive reference.")}
        let reference=try JSONDecoder().decode(Self.self,from:data),root=url.deletingLastPathComponent().deletingLastPathComponent()
        let video=try reference.validate(root:root)
        return try VisualArchiveReader.image(video,time:CMTime(value:reference.ticks,timescale:600),maxPixels:maxPixels)
    }
}

private final class VisualArchiveReader:NSObject {
    private static let cache:NSCache<NSString,VisualArchiveReader> = {let value=NSCache<NSString,VisualArchiveReader>();value.countLimit=2;return value}()
    private static let cacheLock=NSLock()
    private static let decoderSlots=DispatchSemaphore(value:2)
    private let lock=NSLock()
    private let generator:AVAssetImageGenerator
    init(url:URL) {
        generator=AVAssetImageGenerator(asset:AVURLAsset(url:url))
        generator.appliesPreferredTrackTransform=true
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    }
    static func image(_ url:URL,time:CMTime,maxPixels:Int?)throws->CGImage {
        decoderSlots.wait();defer {decoderSlots.signal()}
        try Task.checkCancellation()
        let key=url.standardizedFileURL.path as NSString
        let reader=cacheLock.withLock {
            if let reader=cache.object(forKey:key) {return reader}
            let reader=VisualArchiveReader(url:url);cache.setObject(reader,forKey:key);return reader
        }
        return try reader.lock.withLock {
            try Task.checkCancellation()
            reader.generator.maximumSize=maxPixels.map {CGSize(width:$0,height:$0)} ?? .zero
            return try reader.generator.copyCGImage(at:time,actualTime:nil)
        }
    }
}

enum VisualArchivePolicy {
    static let quality=0.5
    static let keyFrameSeconds=60.0
    static func settings(width:Int,height:Int,codec:AVVideoCodecType = .hevc)->[String:Any] {
        [AVVideoCodecKey:codec,AVVideoWidthKey:width,AVVideoHeightKey:height,
         AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
         AVVideoCompressionPropertiesKey:[kVTCompressionPropertyKey_Quality as String:quality,
             AVVideoExpectedSourceFrameRateKey:1,AVVideoMaxKeyFrameIntervalDurationKey:keyFrameSeconds,AVVideoAllowFrameReorderingKey:false]]
    }
}
