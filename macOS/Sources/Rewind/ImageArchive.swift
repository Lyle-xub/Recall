import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

struct ImageArchiveResult:Sendable {
    let sourceDigest:String
    let sourceBytes:Int64
    let archive:ScreenArchive
    let recompressed:Bool
}

/// Convert older full images once to shared tiles. OCR text and coordinates
/// are preserved; compressed pixels are never used to rebuild the search index.
enum ImageArchive {
    static let policyVersion = 3
    static func digest(_ data:Data)->String {
        SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func make(source url:URL) throws -> ImageArchiveResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let data = try Data(contentsOf:url)
            guard let reader = CGImageSourceCreateWithData(data as CFData,nil),
                  CGImageSourceGetCount(reader) == 1,
                  let image = CGImageSourceCreateImageAtIndex(reader,0,nil) else {
                throw RewindError.message("This screenshot could not be decoded. Its original has been kept.")
            }
            let original = ScreenArchive(data:data,fileExtension:url.pathExtension.lowercased())
            var chosen = original
            let properties = CGImageSourceCopyPropertiesAtIndex(reader,0,nil) as? [CFString:Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            // Preserve unusual/rotated imports and transparency without changing
            // their appearance. Our capture pipeline produces upright images.
            if orientation == 1,image.width <= 16000,image.height <= 16000,
               image.width * image.height <= 40_000_000,
               ["jpg","jpeg","png","heic"].contains(url.pathExtension.lowercased()) {
                let packed = try ScreenArchive.pack(image)
                if packed.totalBytes < data.count {chosen = packed}
                else {
                    let compact = try ScreenArchive.make(image,lossless:url.pathExtension.lowercased() == "png" ? data:nil)
                    if compact.data.count < data.count {chosen = compact}
                }
            }
            try Task.checkCancellation()
            return ImageArchiveResult(sourceDigest:digest(data),sourceBytes:try CleanupFiles.size(url),archive:chosen,recompressed:chosen.data != data)
        }
    }
    /// Full-size comparison, including alpha and high-contrast text edges.
    /// Downsampled checks can hide damage to small glyphs, so none is used here.
    static func preservesPixels(_ original:CGImage,_ candidate:CGImage)->Bool {
        guard original.width == candidate.width,original.height == candidate.height else { return false }
        let width = original.width,height = original.height
        func pixels(_ image:CGImage)->[UInt8]? {
            var bytes = [UInt8](repeating:0,count:width*height*4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
            }
            return drawn ? bytes:nil
        }
        guard let a = pixels(original),let b = pixels(candidate) else { return false }
        var squared = 0.0,edges = 0,edgeError = 0.0
        for y in 0..<height {
            if Task.isCancelled { return false }
            for x in 0..<width {
                let i = (y*width+x)*4
                if a[i+3] != b[i+3] { return false }
                for c in 0..<3 {
                    let error = Double(Int(a[i+c])-Int(b[i+c]));squared += error*error
                    let horizontal = x > 0 ? abs(Int(a[i+c])-Int(a[i-4+c])):0
                    let vertical = y > 0 ? abs(Int(a[i+c])-Int(a[i-width*4+c])):0
                    if max(horizontal,vertical) >= 35 { edges += 1;edgeError += abs(error) }
                }
            }
        }
        let mse = squared/Double(width*height*3)
        return mse <= 6.5025 && (edges == 0 || edgeError/Double(edges) <= 5)
    }
}

struct ImageArchiveCommit:Sendable {
    let savedBytes:Int64
    let changed:Bool
    let destination:String?
    static let skipped = ImageArchiveCommit(savedBytes:0,changed:false,destination:nil)
}
