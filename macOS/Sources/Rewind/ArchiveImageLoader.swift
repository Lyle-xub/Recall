import AppKit
import Combine

/// Publish each completed decode immediately. Cancelling a scrub must not throw
/// away images that have already reached the screen.
@MainActor final class ArchiveImageLoader:ObservableObject {
    @Published private(set) var images:[String:NSImage] = [:]
    private var thumbnails:[String:NSImage] = [:]
    private var detailPaths:[String] = []
    private var visiblePaths = Set<String>()

    func load(_ frames:[MemoryFrame],root:URL,near date:Date?,
              decode:((URL) async -> CGImage?)? = nil) async {
        visiblePaths = Set(frames.map(\.imagePath))
        images = images.filter { visiblePaths.contains($0.key) }
        thumbnails = thumbnails.filter { visiblePaths.contains($0.key) }
        detailPaths.removeAll { !visiblePaths.contains($0) }
        let target = date ?? frames.map(\.timestamp).max() ?? Date()
        let ordered = frames.sorted { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }
        for frame in ordered where thumbnails[frame.imagePath] == nil {
            guard !Task.isCancelled else { return }
            let url = root.appendingPathComponent(frame.imagePath)
            let pixels:CGImage?
            if let decode { pixels = await decode(url) }
            else { pixels = await MemoryImagePipeline.shared.image(at:url,maxPixels:720) }
            // A decode may finish just as a newer request cancels this task.
            // Keep it if the new window still contains that actual record.
            if let pixels,visiblePaths.contains(frame.imagePath) {
                let image = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
                thumbnails[frame.imagePath] = image
                if !detailPaths.contains(frame.imagePath) { images[frame.imagePath] = image }
            }
        }
    }
    func showDetail(_ pixels:CGImage,for path:String) {
        guard visiblePaths.contains(path) else { return }
        detailPaths.removeAll { $0 == path };detailPaths.append(path)
        if CGFloat(pixels.width) > (images[path]?.size.width ?? 0) {
            images[path] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
        }
        // Keep only two enlarged screenshots; distant cards return to thumbnails.
        while detailPaths.count > 2 {
            let old = detailPaths.removeFirst()
            if let thumbnail = thumbnails[old] { images[old] = thumbnail }
        }
    }
}
