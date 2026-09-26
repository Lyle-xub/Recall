import AppKit
import Combine

struct ArchiveViewportRecords:Equatable {
    var visible:Set<String> = []
    var nearby:Set<String> = []
}

/// Four background decoders feed a staging cache. A viewport is published in
/// one transaction, rather than making screenshots appear one at a time.
@MainActor final class ArchiveImageLoader:ObservableObject {
    typealias Decode = @Sendable (URL) async -> CGImage?
    @Published private(set) var images:[String:NSImage] = [:]
    private var thumbnails:[String:NSImage] = [:]
    private var costs:[String:Int] = [:]
    private var recent:[String] = []
    private var detailPaths:[String] = []
    private var paths = Set<String>()
    private var pathsByID:[String:String] = [:]
    private(set) var viewport = ArchiveViewportRecords()
    private var hoverID:String?
    private var hoverTask:Task<Void,Never>?
    private var wanted = Set<String>()
    private var nearby = Set<String>()
    private var failed = Set<String>()
    private var root = URL(fileURLWithPath:"/")
    private var worker:Task<Void,Never>?
    private var active = true
    private let decode:Decode
    private(set) var publicationCount = 0
    private(set) var decodeCount = 0
    private let budget = 96*1024*1024

    init(decode:Decode? = nil) {
        self.decode = decode ?? { url in
            await Task.detached(priority:.utility) { StoredImage.load(url,maxPixels:560) }.value
        }
    }
    func request(_ frames:[MemoryFrame],viewport:ArchiveViewportRecords,root:URL) {
        active = true
        self.root = root
        let byID = Dictionary(uniqueKeysWithValues:frames.map { ($0.id,$0.imagePath) })
        pathsByID = byID
        if let hoverID,byID[hoverID] == nil { hover(nil) }
        let newPaths = Set(byID.values)
        if paths != newPaths {
            paths = newPaths
            thumbnails = thumbnails.filter { paths.contains($0.key) }
            costs = costs.filter { paths.contains($0.key) }
            recent.removeAll { !paths.contains($0) };detailPaths.removeAll { !paths.contains($0) }
            failed.formIntersection(paths)
            let retained = images.filter { paths.contains($0.key) }
            if retained.count != images.count { images = retained }
        }
        updateViewport(viewport)
    }
    func updateViewport(_ viewport:ArchiveViewportRecords) {
        self.viewport = viewport
        wanted = Set(viewport.visible.compactMap { pathsByID[$0] })
        nearby = Set(viewport.nearby.compactMap { pathsByID[$0] }).subtracting(wanted)
        publishViewportIfReady()
        guard active,worker == nil,!missingPaths.isEmpty else { return }
        worker = Task { [weak self] in await self?.run() }
    }
    private var missingPaths:[String] {
        let ready = Set(thumbnails.keys).union(failed)
        return wanted.subtracting(ready).sorted()+nearby.subtracting(ready).sorted()
    }
    private func run() async {
        while !Task.isCancelled {
            let batch = Array(missingPaths.prefix(4)),base = root,decode = decode
            guard !batch.isEmpty else { break }
            decodeCount += batch.count
            let decoded = await withTaskGroup(of:(String,CGImage?).self) { group in
                for path in batch { group.addTask { (path,await decode(base.appendingPathComponent(path))) } }
                var results:[(String,CGImage?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (path,pixels) in decoded where paths.contains(path) && base == root {
                if let pixels {
                    thumbnails[path] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
                    costs[path] = pixels.bytesPerRow*pixels.height
                    recent.removeAll { $0 == path };recent.append(path)
                } else { failed.insert(path) }
            }
            if !Task.isCancelled { publishViewportIfReady() }
            trimCache()
        }
        worker = nil
        if active,!missingPaths.isEmpty { worker = Task { [weak self] in await self?.run() } }
    }
    private func publishViewportIfReady() {
        guard active,wanted.allSatisfy({ thumbnails[$0] != nil || failed.contains($0) }) else { return }
        var next = images,changed = false
        for path in wanted {
            recent.removeAll { $0 == path };recent.append(path)
            if let thumbnail = thumbnails[path],!detailPaths.contains(path),next[path] !== thumbnail {
                next[path] = thumbnail;changed = true
            }
        }
        if changed { images = next;publicationCount += 1 }
    }
    private func trimCache() {
        var bytes = costs.values.reduce(0,+)
        let protected = wanted.union(nearby).union(detailPaths)
        var removed = Set<String>()
        for path in recent where bytes > budget && !protected.contains(path) {
            bytes -= costs.removeValue(forKey:path) ?? 0
            thumbnails[path] = nil;removed.insert(path)
        }
        if !removed.isEmpty {
            recent.removeAll { removed.contains($0) }
            images = images.filter { !removed.contains($0.key) }
        }
    }
    func showDetail(_ pixels:CGImage,for path:String) {
        guard active,paths.contains(path) else { return }
        detailPaths.removeAll { $0 == path };detailPaths.append(path)
        var next = images,changed = false
        if CGFloat(pixels.width) > (next[path]?.size.width ?? 0) {
            next[path] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
            changed = true
        }
        while detailPaths.count > 2 {
            let old = detailPaths.removeFirst()
            if let thumbnail = thumbnails[old],next[old] !== thumbnail { next[old] = thumbnail;changed = true }
        }
        if changed { images = next;publicationCount += 1 }
    }
    /// Pointer changes remain local to the loader: no SwiftUI invalidation,
    /// accessibility-tree rebuild or texture upload while sweeping the rack.
    func hover(_ id:String?) {
        guard hoverID != id else { return }
        hoverID = id;hoverTask?.cancel();hoverTask = nil
        guard active,let id,let path = pathsByID[id] else { return }
        let base = root
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(320)) } catch { return }
            guard !Task.isCancelled,
                  let pixels = await MemoryImagePipeline.previews.image(at:base.appendingPathComponent(path),maxPixels:1000),
                  !Task.isCancelled,let self,self.active,self.root == base,self.hoverID == id else { return }
            self.showDetail(pixels,for:path)
        }
    }
    func stop() { active = false;worker?.cancel();hover(nil) }
    func waitUntilIdle() async { await worker?.value }
}
