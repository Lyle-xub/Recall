import AppKit
import Combine

struct ArchiveViewportRecords:Equatable {
    var visible:Set<String> = []
    var nearby:Set<String> = []
}

private struct ArchivePixelCache:@unchecked Sendable {
    var thumbnails:[String:CGImage]
    var details:[String:CGImage]
    var detailPaths:[String]
    var recent:[String]
}

/// Four background decoders feed a staging cache. Small cohorts publish
/// together; a moving viewport schedules partial publication every 150 ms.
@MainActor final class ArchiveImageLoader:ObservableObject {
    typealias Decode = @Sendable (URL) async -> CGImage?
    @Published private(set) var images:[String:NSImage] = [:]
    private var thumbnails:[String:NSImage] = [:]
    private var thumbnailPixels:[String:CGImage] = [:]
    private var detailPixels:[String:CGImage] = [:]
    private var detailImages:[String:NSImage] = [:]
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
    private var publicationTask:Task<Void,Never>?
    private var cacheRevision=0
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
        if self.root != root {
            thumbnails=[:];thumbnailPixels=[:];detailPixels=[:];detailImages=[:];costs=[:];detailCosts=[:];detailPaths=[];recent=[];images=[:];failed=[];cacheRevision += 1
        }
        self.root = root
        let byID = Dictionary(uniqueKeysWithValues:frames.map { ($0.id,$0.imagePath) })
        pathsByID = byID
        if let hoverID,byID[hoverID] == nil { hover(nil) }
        let newPaths = Set(byID.values)
        if paths != newPaths {
            paths = newPaths
            cacheRevision += 1
            thumbnails = thumbnails.filter { paths.contains($0.key) }
            thumbnailPixels=thumbnailPixels.filter {paths.contains($0.key)}
            detailPixels=detailPixels.filter {paths.contains($0.key)}
            detailImages=detailImages.filter {paths.contains($0.key)}
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
        let nextWanted=Set(viewport.visible.compactMap {pathsByID[$0]})
        let nextNearby=Set(viewport.nearby.compactMap {pathsByID[$0]}).subtracting(nextWanted)
        if wanted != nextWanted || nearby != nextNearby {cacheRevision += 1}
        wanted=nextWanted;nearby=nextNearby
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
            // Reserve headroom before decoding. Existing pixels keep their
            // identity; adding four files must not shrink the entire cache.
            let reserve=max(budget/4,detailCosts.values.reduce(0,+))
            let allowance=max(64*1024,Int(Double(budget-reserve)*0.86)/max(24,wanted.union(nearby).count))
            decodeCount += batch.count
            let decoded = await withTaskGroup(of:(String,CGImage?).self) { group in
                for path in batch { group.addTask {
                    guard let pixels=await decode(base.appendingPathComponent(path)) else {return (path,nil)}
                    let prepared=await Task.detached(priority:.utility) {Self.limit(pixels,to:allowance,normalize:true)}.value
                    return (path,prepared)
                } }
                var results:[(String,CGImage?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (path,pixels) in decoded where pixels == nil && paths.contains(path) && base == root {failed.insert(path)}
            let updates=Dictionary(uniqueKeysWithValues:decoded.compactMap {path,pixels in pixels.map {(path,$0)}})
            await commitCache(updates:updates,base:base)
        }
        worker = nil
        if active,!Task.isCancelled {publishViewportIfReady(allowPartial:true)}
        if active,!missingPaths.isEmpty { worker = Task { [weak self] in await self?.run() } }
    }
    private func publishViewportIfReady(allowPartial:Bool = false) {
        guard active else {return}
        let ready=wanted.allSatisfy {thumbnails[$0] != nil || failed.contains($0)}
        guard ready || allowPartial else {schedulePublication();return}
        if ready {publicationTask?.cancel();publicationTask=nil}
        var next=images.filter {thumbnails[$0.key] != nil || detailImages[$0.key] != nil}
        var changed=next.count != images.count
        for path in Array(next.keys) {
            if let current=detailImages[path] ?? thumbnails[path],next[path] !== current {next[path]=current;changed=true}
        }
        for path in wanted.union(detailPaths) {
            recent.removeAll { $0 == path };recent.append(path)
            if let thumbnail=detailImages[path] ?? thumbnails[path],next[path] !== thumbnail {
                next[path] = thumbnail;changed = true
            }
        }
        if changed { images = next;publicationCount += 1 }
        if !ready {schedulePublication()}
    }
    private func schedulePublication() {
        guard publicationTask == nil else {return}
        let deadline=ContinuousClock.now.advanced(by:.milliseconds(150))
        publicationTask=Task { @MainActor [weak self] in
            do {try await Task.sleep(until:deadline,clock:.continuous)} catch {return}
            guard let self,!Task.isCancelled else {return}
            self.publicationTask=nil;self.publishViewportIfReady(allowPartial:true)
        }
    }

    /// Rebalance immutable pixels on a utility worker, then atomically install
    /// a plan that fits the budget. Viewport/detail changes invalidate the plan;
    /// no partially resized cache or stale root can be published.
    private func commitCache(updates:[String:CGImage]=[:],detail:(String,CGImage)? = nil,base:URL)async {
        while active,!Task.isCancelled,base == root {
            let revision=cacheRevision
            var plan=ArchivePixelCache(thumbnails:thumbnailPixels,details:detailPixels,detailPaths:detailPaths,recent:recent)
            for (path,pixels) in updates where paths.contains(path) {
                plan.thumbnails[path]=pixels;plan.recent.removeAll {$0 == path};plan.recent.append(path)
            }
            if let (path,pixels)=detail,paths.contains(path) {
                plan.details[path]=pixels;plan.detailPaths.removeAll {$0 == path};plan.detailPaths.append(path)
                while plan.detailPaths.count > 2 {plan.details[plan.detailPaths.removeFirst()]=nil}
            }
            let pending=plan,protected=wanted.union(nearby).union(plan.detailPaths),budget=budget
            let bounded=await Task.detached(priority:.utility) {Self.bounded(pending,protected:protected,budget:budget)}.value
            guard active,!Task.isCancelled,base == root else {return}
            guard revision == cacheRevision else {continue}
            func image(_ pixels:CGImage)->NSImage {NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))}
            thumbnails=Dictionary(uniqueKeysWithValues:bounded.thumbnails.map {path,pixels in (path,thumbnailPixels[path] === pixels ? thumbnails[path] ?? image(pixels):image(pixels))})
            detailImages=Dictionary(uniqueKeysWithValues:bounded.details.map {path,pixels in (path,detailPixels[path] === pixels ? detailImages[path] ?? image(pixels):image(pixels))})
            thumbnailPixels=bounded.thumbnails;detailPixels=bounded.details;detailPaths=bounded.detailPaths;recent=bounded.recent
            costs=thumbnailPixels.mapValues {$0.bytesPerRow*$0.height};detailCosts=detailPixels.mapValues {$0.bytesPerRow*$0.height}
            cacheRevision += 1
            publishViewportIfReady(allowPartial:detail != nil)
            return
        }
    }
    nonisolated private static func bounded(_ input:ArchivePixelCache,protected:Set<String>,budget:Int)->ArchivePixelCache {
        var result=input
        let detailBytes=result.details.values.reduce(0) {$0+$1.bytesPerRow*$1.height}
        let available=max(1,budget-detailBytes)
        var thumbnailBytes=result.thumbnails.values.reduce(0) {$0+$1.bytesPerRow*$1.height}
        for path in result.recent where thumbnailBytes > available && !protected.contains(path) {
            if let pixels=result.thumbnails.removeValue(forKey:path) {thumbnailBytes -= pixels.bytesPerRow*pixels.height}
        }
        if thumbnailBytes > available {
            // Headroom prevents another full cohort conversion on the next
            // four-image batch. Open-card details keep their original pixels.
            let ratio=Double(available)*0.82/Double(thumbnailBytes)
            result.thumbnails=result.thumbnails.mapValues {pixels in limit(pixels,to:max(4,Int(Double(pixels.bytesPerRow*pixels.height)*ratio)))}
        }
        result.recent.removeAll {result.thumbnails[$0] == nil}
        return result
    }
    nonisolated private static func limit(_ pixels:CGImage,to maximum:Int,normalize:Bool = false)->CGImage {
        let cost=normalize ? pixels.width*pixels.height*4:pixels.bytesPerRow*pixels.height
        guard cost > maximum || (normalize && pixels.bitsPerPixel != 32) else {return pixels}
        let scale=cost > maximum ? sqrt(Double(maximum)/Double(cost))*0.97:1
        let width=max(1,Int(Double(pixels.width)*scale)),height=max(1,Int(Double(pixels.height)*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return pixels}
        context.interpolationQuality = .high
        context.draw(pixels,in:CGRect(x:0,y:0,width:width,height:height))
        return context.makeImage() ?? pixels
    }
    func showDetail(_ pixels:CGImage,for path:String)async {
        guard active,paths.contains(path) else { return }
        let base=root,maximum=budget/4
        let pixels=await Task.detached(priority:.utility) {Self.limit(pixels,to:maximum)}.value
        guard !Task.isCancelled,CGFloat(pixels.width) > (images[path]?.size.width ?? 0) else {return}
        await commitCache(detail:(path,pixels),base:base)
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
            await self.showDetail(pixels,for:path)
        }
    }
    func stop() { active = false;worker?.cancel();publicationTask?.cancel();publicationTask=nil;hover(nil) }
    func waitUntilIdle() async { await worker?.value }
}
