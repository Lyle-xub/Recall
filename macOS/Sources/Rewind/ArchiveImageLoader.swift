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
    private var detailCosts:[String:Int] = [:]
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
    static let memoryBudget = 96*1024*1024
    private let budget = memoryBudget
    var cachedBytes:Int {costs.values.reduce(0,+)+detailCosts.values.reduce(0,+)}
    var cachedImageCount:Int {thumbnails.count+detailCosts.count}

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
            detailCosts=detailCosts.filter {paths.contains($0.key)}
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
        let protected=wanted.union(nearby).union(detailPaths)
        var removed=Set<String>()
        for path in recent where cachedBytes > budget && !protected.contains(path) {
            costs[path]=nil;thumbnails[path]=nil;detailCosts[path]=nil;removed.insert(path)
        }
        if !removed.isEmpty {
            recent.removeAll {removed.contains($0)}
            images=images.filter {!removed.contains($0.key)}
        }
        // Protected viewport/detail entries are still subject to the byte cap.
        // Downsample the thumbnail cohort together instead of evicting visible
        // cards into a decode/evict loop or allowing an unbounded exception.
        let thumbnailBytes=costs.values.reduce(0,+)
        let available=max(1,budget-detailCosts.values.reduce(0,+))
        guard thumbnailBytes > available else {return}
        var next=images
        for (path,cost) in costs {
            guard let old=thumbnails[path],let pixels=old.cgImage(forProposedRect:nil,context:nil,hints:nil) else {continue}
            let maximum=max(4,Int(Double(cost)*Double(available)/Double(thumbnailBytes)))
            let small=Self.limit(pixels,to:maximum)
            let replacement=NSImage(cgImage:small,size:NSSize(width:small.width,height:small.height))
            thumbnails[path]=replacement;costs[path]=small.bytesPerRow*small.height
            if next[path] === old {next[path]=replacement}
        }
        images=next
    }
    private static func limit(_ pixels:CGImage,to maximum:Int)->CGImage {
        guard pixels.bytesPerRow*pixels.height > maximum else {return pixels}
        let scale=sqrt(Double(maximum)/Double(pixels.bytesPerRow*pixels.height))*0.97
        let width=max(1,Int(Double(pixels.width)*scale)),height=max(1,Int(Double(pixels.height)*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return pixels}
        context.interpolationQuality = .high
        context.draw(pixels,in:CGRect(x:0,y:0,width:width,height:height))
        return context.makeImage() ?? pixels
    }
    func showDetail(_ pixels:CGImage,for path:String) {
        guard active,paths.contains(path) else { return }
        let pixels=Self.limit(pixels,to:budget/4)
        detailPaths.removeAll { $0 == path };detailPaths.append(path)
        var next = images,changed = false
        if CGFloat(pixels.width) > (next[path]?.size.width ?? 0) {
            next[path] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
            detailCosts[path]=pixels.bytesPerRow*pixels.height
            changed = true
        }
        while detailPaths.count > 2 {
            let old = detailPaths.removeFirst();detailCosts[old]=nil
            if let thumbnail = thumbnails[old],next[old] !== thumbnail { next[old] = thumbnail;changed = true }
            else if thumbnails[old] == nil {next[old]=nil;changed=true}
        }
        if changed { images = next;publicationCount += 1 }
        trimCache()
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
