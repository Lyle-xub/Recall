import Foundation
import CoreGraphics
import CryptoKit

enum ExactScreenFingerprint {
    /// Hash every original pixel bit, not a thumbnail or perceptual signature.
    /// Exclude row padding: GPU allocations may leave those non-image bytes unset.
    static func digest(_ image:CGImage)throws->String {
        guard let bytes = image.dataProvider?.data else { throw RewindError.message("Cannot read original screen pixels.") }
        var hash = SHA256()
        hash.update(data:Data("\(image.width):\(image.height):\(image.bitsPerComponent):\(image.bitsPerPixel):\(image.bitmapInfo.rawValue)".utf8))
        if let profile = image.colorSpace?.copyICCData() { hash.update(data:profile as Data) }
        let data = bytes as Data,packedRow = (image.width*image.bitsPerPixel+7)/8
        guard data.count >= image.bytesPerRow*image.height,packedRow <= image.bytesPerRow else { throw RewindError.message("The screen pixel layout is incomplete.") }
        for row in 0..<image.height {
            hash.update(data:data[(row*image.bytesPerRow)..<(row*image.bytesPerRow+packedRow)])
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}

struct SavedCapture:Sendable {
    let frame:MemoryFrame?
    let extendedID:String?
    let through:Date
}

/// Serial persistence keeps a hold from racing the initial PNG/row commit.
/// App usage is a separate recorder and does not depend on these samples.
actor CaptureFrameStore {
    let store:MemoryStore
    private var last:MemoryFrame?
    init(store:MemoryStore) { self.store = store }
    func save(_ image:CGImage,frame source:MemoryFrame)throws->SavedCapture {
        var frame = source
        let digest = try ExactScreenFingerprint.digest(image)
        frame.pixelDigest = digest;frame.endTimestamp = frame.timestamp
        if let last,last.pixelDigest == digest,last.sessionID == frame.sessionID,
           last.continuityID == frame.continuityID,last.bundleID == frame.bundleID,last.title == frame.title,
           frame.timestamp >= last.timestamp,try store.extendCapture(last.id,through:frame.timestamp) {
            return SavedCapture(frame:nil,extendedID:last.id,through:frame.timestamp)
        }
        if let last,last.sessionID == frame.sessionID,last.continuityID == frame.continuityID,last.bundleID == frame.bundleID {
            _ = try store.extendCapture(last.id,through:frame.timestamp)
        }
        if let previous = try store.frameWithPixels(digest),
           FileManager.default.fileExists(atPath:store.root.appendingPathComponent(previous.imagePath).path) {
            frame.imagePath = previous.imagePath
            if previous.indexingComplete == true {
                frame.regions = previous.regions
                frame.text = previous.meetingRegions.isEmpty ? previous.text:previous.regions.map(\.text).joined(separator:"\n")
                frame.sourceURL = previous.sourceURL;frame.indexingComplete = true
            }
        } else {
            frame.imagePath = "frames/source-"+digest+".png"
            try ScreenArchive.saveSource(image,to:store.root.appendingPathComponent(frame.imagePath))
        }
        try store.save(frame);last = frame
        return SavedCapture(frame:frame,extendedID:nil,through:frame.timestamp)
    }
    func finish(at date:Date)throws {
        if let last { _ = try store.extendCapture(last.id,through:date) }
        last = nil
    }
}
