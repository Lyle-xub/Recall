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
private struct ArchiveDecodeJob:Hashable,Sendable {
    let path:String
    let root:URL
    let isPreview:Bool
}

/// Four background decoders feed a staging cache. Small cohorts publish
/// together; a moving viewport schedules partial publication every 150 ms.
@MainActor final class ArchiveImageLoader:ObservableObject {
    typealias Decode = @Sendable (URL) async -> CGImage?
    typealias PublicationWait = @Sendable (ContinuousClock.Instant) async throws -> Void
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
    private var preparation:ArchiveImagePreparation?
    private var detailFailures=Set<String>()
    private var preparedPreviewPaths=Set<String>()
    private(set) var viewport = ArchiveViewportRecords()
    private var hoverID:String?
    private var hoverTask:Task<Void,Never>?
    private var wanted = Set<String>()
    private var nearby = Set<String>()
    private var failed = Set<String>()
    private var root = URL(fileURLWithPath:"/")
    private var workers:[ArchiveDecodeJob:Task<Void,Never>]=[:]
    private var cacheInstalling=false
    private var cacheWaiters:[(id:UUID,priority:Bool,continuation:CheckedContinuation<Void,Error>)]=[]
    private var publicationTask:Task<Void,Never>?
    private var cacheRevision=0
    private var active = true
    private weak var workBudget:ForegroundWorkBudget?
    private var budgetSubscription:AnyCancellable?
    private(set) var budgetLimited=false
    private var underMemoryPressure=false
    var decodeConcurrency:Int {underMemoryPressure ? 2:4}
    private let decode:Decode
    private let decodePreview:Decode
    private let rebalanceWait:@Sendable ()async->Void
    private let waitForPublication:PublicationWait
    private let hoverDelay:@Sendable ()async throws->Void
    private(set) var publicationCount = 0
    private(set) var decodeCount = 0
    private(set) var rebalanceCount=0
    nonisolated static let memoryBudget = 96*1024*1024
    private let budget:Int
    var cachedBytes:Int {costs.values.reduce(0,+)+detailCosts.values.reduce(0,+)}
    var cachedImageCount:Int {thumbnails.count+detailCosts.count}

    init(decode:Decode? = nil,decodePreview:Decode? = nil,waitForPublication:@escaping PublicationWait = {try await Task.sleep(until:$0,clock:.continuous)},hoverDelay:@escaping @Sendable ()async throws->Void = {try await Task.sleep(for:.milliseconds(320))},cacheBudget:Int = ArchiveImageLoader.memoryBudget,rebalanceWait:@escaping @Sendable ()async->Void = {}) {
        self.budget=max(4,cacheBudget);self.rebalanceWait=rebalanceWait
        self.waitForPublication=waitForPublication;self.hoverDelay=hoverDelay
        self.decode = decode ?? { url in
            await Task.detached(priority:.utility) { StoredImage.load(url,maxPixels:560) }.value
        }
        self.decodePreview=decodePreview ?? {url in await MemoryImagePipeline.previews.image(at:url,maxPixels:1600)}
    }
    func bind(to budget:ForegroundWorkBudget) {
        guard workBudget !== budget else {return};workBudget=budget
        applyBudget(budget.state)
        budgetSubscription=budget.changes.sink { [weak self] state in self?.applyBudget(state) }
    }
    private func applyBudget(_ state:ForegroundWorkBudget.State) {
        if state.stopped {budgetLimited=true;stop();return}
        // Scrolling only postpones speculative work. Keep the four visible
        // decoders so a moving viewport does not spend longer without images.
        underMemoryPressure=state.pressure != .normal
        guard budgetLimited != state.limited else {return}
        budgetLimited=state.limited
        scheduleHover()
        updateViewport(viewport)
    }
    func request(_ frames:[MemoryFrame],viewport:ArchiveViewportRecords,root:URL,preparation:ArchiveImagePreparation? = nil) {
        guard workBudget?.state.stopped != true else {return}
        active = true
        if self.root != root {
            thumbnails=[:];thumbnailPixels=[:];detailPixels=[:];detailImages=[:];costs=[:];detailCosts=[:];detailPaths=[];recent=[];images=[:];failed=[];detailFailures=[];preparedPreviewPaths=[];cacheRevision += 1
        }
        self.root = root
        var byID = Dictionary(uniqueKeysWithValues:frames.map { ($0.id,$0.imagePath) })
        // A visible frame can receive newer OCR/archive metadata before SwiftUI
        // delivers the matching preparation update. Never restore its old path.
        func latest(_ image:ArchiveImageReference)->ArchiveImageReference {.init(id:image.id,path:byID[image.id] ?? image.path)}
        let preparation=preparation.map {ArchiveImagePreparation(generation:$0.generation,target:latest($0.target),nearby:$0.nearby.map(latest))}
        if self.preparation != preparation {detailFailures=[]}
        self.preparation=preparation
        for image in preparation?.images ?? [] where byID[image.id] == nil {byID[image.id]=image.path}
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
            detailFailures.formIntersection(paths)
            preparedPreviewPaths.formIntersection(paths)
            let retained = images.filter { paths.contains($0.key) }
            if retained.count != images.count { images = retained }
        }
        updateViewport(viewport)
    }
    func updateViewport(_ viewport:ArchiveViewportRecords) {
        self.viewport = viewport
        let nextWanted=Set(viewport.visible.compactMap {pathsByID[$0]})
        let nextNearby=Set(viewport.nearby.compactMap {pathsByID[$0]}).subtracting(nextWanted)
        wanted=nextWanted;nearby=nextNearby
        publishViewportIfReady()
        scheduleDecodes()
    }
    private var missingPaths:[String] {
        let ready = Set(thumbnails.keys).union(detailImages.keys).union(failed)
        let priorityImages: [ArchiveImageReference]
        if let preparation,!preparedPreviewPaths.contains(preparation.target.path),!detailFailures.contains(preparation.target.path) {
            priorityImages=[preparation.target]
        } else {priorityImages=preparation?.images ?? []}
        let destination=priorityImages.map(\.path).filter {!ready.contains($0)}
        let priority=Set(destination)
        return destination+wanted.subtracting(ready).subtracting(priority).sorted()+(budgetLimited ? []:nearby.subtracting(ready).subtracting(priority).sorted())
    }
    private func nextJob(excluding inFlight:Set<ArchiveDecodeJob>)->ArchiveDecodeJob? {
        guard active else {return nil}
        if let preparation,!preparedPreviewPaths.contains(preparation.target.path),!detailFailures.contains(preparation.target.path) {
            let job=ArchiveDecodeJob(path:preparation.target.path,root:root,isPreview:true)
            if !inFlight.contains(job) {return job}
        }
        for path in missingPaths {
            // The priority preview also supplies the target's first pixels;
            // don't spend a second decoder on its smaller thumbnail.
            if preparation?.target.path == path,!detailFailures.contains(path) {continue}
            let job=ArchiveDecodeJob(path:path,root:root,isPreview:false)
            if !inFlight.contains(job) {return job}
        }
        return nil
    }
    private func scheduleDecodes() {
        while active,workers.count < decodeConcurrency,let job=nextJob(excluding:Set(workers.keys)) {
            decodeCount += 1
            let decoder=job.isPreview ? decodePreview:decode
            let reserve=max(budget/4,detailCosts.values.reduce(0,+))
            let allowance=job.isPreview ? budget/4:max(64*1024,Int(Double(budget-reserve)*0.86)/max(24,wanted.union(nearby).count))
            workers[job]=Task(priority:job.isPreview ? .userInitiated:.utility) { [weak self] in
                var prepared:CGImage?
                if !Task.isCancelled,let pixels=await decoder(job.root.appendingPathComponent(job.path)),!Task.isCancelled {
                    prepared=await Task.detached(priority:.utility) {Self.limit(pixels,to:allowance,normalize:!job.isPreview)}.value
                }
                await self?.complete(job,pixels:prepared)
            }
        }
    }
    private func complete(_ job:ArchiveDecodeJob,pixels:CGImage?)async {
        if !Task.isCancelled,active,job.root == root,paths.contains(job.path) {
            if job.isPreview {
                // Scrubbing can create many generations for one immutable
                // image. Keep one in-flight read; only a different path is stale.
                if preparation?.target.path == job.path {
                    if let pixels {
                        if (detailPixels[job.path]?.width ?? 0) < pixels.width {await commitCache(detail:(job.path,pixels),base:job.root)}
                        if active,job.root == root,preparation?.target.path == job.path,detailPixels[job.path] != nil {
                            preparedPreviewPaths.insert(job.path);publishViewportIfReady(allowPartial:true)
                        }
                    } else {detailFailures.insert(job.path)}
                }
            } else if let pixels {await commitCache(updates:[job.path:pixels],base:job.root)}
            else {failed.insert(job.path)}
        }
        workers[job]=nil
        // A slow obsolete read owns only its slot. New destinations also use
        // already-free slots immediately, without waiting for an old batch.
        scheduleDecodes()
        if active,workers.isEmpty {publishViewportIfReady(allowPartial:true)}
    }
    private func publishViewportIfReady(allowPartial:Bool = false) {
        guard active else {return}
        let ready=wanted.allSatisfy {thumbnails[$0] != nil || detailImages[$0] != nil || failed.contains($0)}
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
        let deadline=ContinuousClock.now.advanced(by:.milliseconds(150)),waitForPublication=waitForPublication
        publicationTask=Task { @MainActor [weak self] in
            do {try await waitForPublication(deadline)} catch {return}
            guard let self,!Task.isCancelled else {return}
            self.publicationTask=nil;self.publishViewportIfReady(allowPartial:true)
        }
    }

    private var protectedPaths:Set<String> {
        wanted.union(nearby).union(preparation?.images.map(\.path) ?? []).union(detailPaths)
    }
    private func acquireCache(priority:Bool)async throws {
        try Task.checkCancellation()
        if !cacheInstalling {cacheInstalling=true;return}
        let id=UUID()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                if Task.isCancelled {continuation.resume(throwing:CancellationError())}
                else {cacheWaiters.append((id,priority,continuation))}
            }
        },onCancel:{Task { @MainActor [weak self] in
            guard let self,let index=cacheWaiters.firstIndex(where:{$0.id == id}) else {return}
            cacheWaiters.remove(at:index).continuation.resume(throwing:CancellationError())
        }})
        // If cancellation raced with ownership transfer, the caller's defer
        // still releases the acquired slot before returning.
    }
    private func releaseCache() {
        if !cacheWaiters.isEmpty {
            let index=cacheWaiters.firstIndex(where:{$0.priority}) ?? 0
            cacheWaiters.remove(at:index).continuation.resume()
        } else {cacheInstalling=false}
    }
    /// Ordinary inserts need no resize worker. Oversized plans rebalance away
    /// from the main actor, then validate content and current protected paths.
    /// Moving a viewport alone cannot endlessly restart an otherwise safe plan.
    private func commitCache(updates:[String:CGImage]=[:],detail:(String,CGImage)? = nil,base:URL)async {
        do {try await acquireCache(priority:detail != nil)} catch {return}
        defer {releaseCache()}
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
            let pending=plan,protected=protectedPaths.union(plan.detailPaths),budget=budget
            let total=pending.thumbnails.values.reduce(0) {$0+$1.bytesPerRow*$1.height}+pending.details.values.reduce(0) {$0+$1.bytesPerRow*$1.height}
            let bounded:ArchivePixelCache
            if total <= budget {bounded=pending}
            else {
                rebalanceCount += 1
                let wait=rebalanceWait
                bounded=await Task.detached(priority:.utility) {await wait();return Self.bounded(pending,protected:protected,budget:budget)}.value
            }
            guard active,!Task.isCancelled,base == root else {return}
            guard revision == cacheRevision else {continue}
            let evicted=Set(pending.thumbnails.keys).subtracting(bounded.thumbnails.keys)
            guard evicted.isDisjoint(with:protectedPaths) else {continue}
            func image(_ pixels:CGImage)->NSImage {NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))}
            thumbnails=Dictionary(uniqueKeysWithValues:bounded.thumbnails.map {path,pixels in (path,thumbnailPixels[path] === pixels ? thumbnails[path] ?? image(pixels):image(pixels))})
            detailImages=Dictionary(uniqueKeysWithValues:bounded.details.map {path,pixels in (path,detailPixels[path] === pixels ? detailImages[path] ?? image(pixels):image(pixels))})
            thumbnailPixels=bounded.thumbnails;detailPixels=bounded.details;detailPaths=bounded.detailPaths;recent=bounded.recent
            preparedPreviewPaths.formIntersection(detailPixels.keys)
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
        hoverID=id;scheduleHover()
    }
    private func scheduleHover() {
        hoverTask?.cancel();hoverTask=nil
        guard active,!budgetLimited,let id=hoverID,let path=pathsByID[id] else {return}
        let base=root,hoverDelay=hoverDelay
        hoverTask = Task { [weak self] in
            do {try await hoverDelay()} catch {return}
            guard !Task.isCancelled,
                  let pixels = await MemoryImagePipeline.previews.image(at:base.appendingPathComponent(path),maxPixels:1000),
                  !Task.isCancelled,let self,self.active,self.root == base,self.hoverID == id else { return }
            await self.showDetail(pixels,for:path)
        }
    }
    func stop() { active = false;preparation=nil;workers.values.forEach {$0.cancel()};publicationTask?.cancel();publicationTask=nil;hover(nil) }
    func waitUntilIdle() async { while !workers.isEmpty {let pending=Array(workers.values);for worker in pending {await worker.value}} }
    func waitForHover()async {await hoverTask?.value}
}
