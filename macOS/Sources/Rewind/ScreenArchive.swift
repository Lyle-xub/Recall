import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct ScreenArchive:Sendable {
    static let compressionQuality = 0.5
    let data:Data
    let fileExtension:String
    let tiles:[ScreenTile]
    init(data:Data,fileExtension:String,tiles:[ScreenTile] = []) {self.data=data;self.fileExtension=fileExtension;self.tiles=tiles}
    var path:String { (fileExtension == PackedScreen.fileExtension ? "frames/pack1-":"frames/screen-") + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() + "." + fileExtension }
    var totalBytes:Int {data.count+tiles.reduce(0){$0+$1.data.count}}
    static func pack(_ image:CGImage) throws -> ScreenArchive {try PackedScreen.encode(image)}
    static func encode(_ image:CGImage,type:UTType,quality:Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,type.identifier as CFString,1,nil) else { throw RewindError.message("This Mac cannot encode the screen image.") }
        var properties:[CFString:Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination,image,properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RewindError.message("Could not save the screen image.") }
        return data as Data
    }
    /// OCR reads this full-resolution, lossless spool before any lossy archive
    /// encoding. A crash can resume indexing from exactly the captured pixels.
    static func saveSource(_ image:CGImage,to url:URL) throws {
        try encode(image,type:.png).write(to:url,options:.atomic)
    }
    static func make(_ image:CGImage,lossless:Data? = nil) throws -> ScreenArchive {
        let png = try lossless ?? encode(image,type:.png)
        guard let heic = try? encode(image,type:.heic,quality:compressionQuality),
              let source = CGImageSourceCreateWithData(heic as CFData,nil),
              let decoded = CGImageSourceCreateImageAtIndex(source,0,nil),
              decoded.width == image.width,decoded.height == image.height,
              Double(heic.count)*1.2 < Double(png.count) else {
            return ScreenArchive(data:png,fileExtension:"png")
        }
        return ScreenArchive(data:heic,fileExtension:"heic")
    }
}

struct ScreenIndexResult:Sendable {
    let text:String
    let regions:[TextRegion]
    let archive:ScreenArchive
    let sourceURL:String?
    init(text:String,regions:[TextRegion],archive:ScreenArchive) {
        self.text = text;self.regions = regions;self.archive = archive
        sourceURL = LinkDetector.links(in:text).first?.absoluteString
    }
}

/// One Vision request at a time with a small bounded cache. Reuse is exact,
/// never perceptual: even a one-character pixel change gets fresh recognition.
actor ScreenIndexProcessor {
    private struct Cached {
        let recognition:(String,[TextRegion])
        let archive:ScreenArchive?
    }
    private var cache:[String:Cached] = [:]
    private var order:[String] = []
    private var cachedBytes = 0
    func process(_ url:URL,archiveImage:Bool = true) throws -> ScreenIndexResult {
        // Recording is requested by the user even while the overlay is hidden.
        // End this assertion on success, failure and cancellation; idle sleep,
        // foreground gates and the serial work budget remain enabled.
        let activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Recognize saved screen text")
        defer {ProcessInfo.processInfo.endActivity(activity)}
        let data = try Data(contentsOf:url)
        let key = (archiveImage ? "tiles:":"visual:")+SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        if let cached = cache[key] {
            return ScreenIndexResult(text:cached.recognition.0,regions:cached.recognition.1,archive:cached.archive ?? ScreenArchive(data:data,fileExtension:"png"))
        }
        let recognition:(String,[TextRegion]),archive:ScreenArchive?
        if archiveImage {
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw RewindError.message("Could not read captured frame.") }
            recognition = try NativeOCR.recognize(image,source:url)
            archive = try ScreenArchive.pack(image)
        } else {
            recognition = try NativeOCR.recognize(source:url)
            archive = nil
        }
        // Video-backed recognition only caches text. Do not retain six full
        // lossless screenshots after their durable spools have been released.
        cache[key] = Cached(recognition:recognition,archive:archive);order.append(key)
        cachedBytes += archive?.totalBytes ?? 0
        while order.count > 6 || cachedBytes > 32*1024*1024 {
            cachedBytes -= cache.removeValue(forKey:order.removeFirst())?.archive?.totalBytes ?? 0
        }
        return ScreenIndexResult(text:recognition.0,regions:recognition.1,archive:archive ?? ScreenArchive(data:data,fileExtension:"png"))
    }
}
