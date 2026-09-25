import AppKit
import ImageIO

/// Decode on a serial actor, not the UI thread. A bounded cache keeps nearby
/// history frames hot without retaining an entire recording in memory.
actor MemoryImagePipeline {
    static let shared = MemoryImagePipeline()
    // Grid thumbnails must not queue ahead of the frame under the timeline cursor.
    static let previews = MemoryImagePipeline()
    private final class Entry { let image:CGImage; init(_ image:CGImage) { self.image = image } }
    private let cache = NSCache<NSString,Entry>()
    private(set) var decodeCount = 0
    init() { cache.totalCostLimit = 128*1024*1024; cache.countLimit = 32 }
    func image(at url:URL,maxPixels:Int = 4096) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = (url.path+"#\(maxPixels)") as NSString
        if let existing = cache.object(forKey:key) { return existing.image }
        guard let image = StoredImage.load(url,maxPixels:maxPixels) else { return nil }
        decodeCount += 1
        cache.setObject(Entry(image),forKey:key,cost:image.bytesPerRow*image.height)
        return image
    }
}
