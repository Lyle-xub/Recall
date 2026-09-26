import Foundation
import Combine

@MainActor final class StorageOptimizer:ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var waitingForInterface = false
    @Published private(set) var maintenanceSuspended = false
    @Published private(set) var status = "New recordings share their video with memory cards automatically."
    @Published private(set) var savedBytes:Int64 = 0
    @Published private(set) var completedItems = 0
    @Published private(set) var totalItems = 0
    @Published private(set) var indeterminate = true
    private let root:URL
    private var needsIndexCompaction:Bool
    private var database:MemoryStore?
    private enum Job:Hashable,Sendable { case discover(Bool),image(String),video(String),visual(String),index,tileStorage }
    private var pending:[Job] = []
    private var scheduled = Set<Job>()
    private(set) var checkedImages = 0,checkedVideos = 0,checkedIndexes = 0
    private var packedTiles = 0
    var onImageArchived:((String,String)->Void)?
    var onFramesArchived:(([MemoryFrame])->Void)?
    var onFinished:(()->Void)?
    private var worker:Task<Void,Never>?
    private var interruptMaintenance:(()->Void)?
    private var paused = false
    private var interfaceVisible = false
    private var storagePageVisible = false
    private var userInitiated = false
    private let workGate = BackgroundWorkGate()
    private var shouldWait:Bool { interfaceVisible && !storagePageVisible && !userInitiated }
    var progress:Double? { indeterminate || totalItems == 0 ? nil:min(1,Double(completedItems)/Double(totalItems)) }
    init(store:MemoryStore) { root = store.root;needsIndexCompaction = store.needsIndexCompaction }
    func setInterfaceVisible(_ visible:Bool) { interfaceVisible = visible;updateGate() }
    func setStoragePageVisible(_ visible:Bool) { storagePageVisible = visible;updateGate() }
    private func updateGate() {
        waitingForInterface = shouldWait && running;workGate.setSuspended(shouldWait)
        if shouldWait { interruptMaintenance?() }
    }
    func resume() { guard !paused,!maintenanceSuspended else { return };add(.discover(false));startWorker() }
    func continueWhileOpen() { userInitiated = true;updateGate() }
    func optimizeExisting() {
        guard !maintenanceSuspended else { return }
        paused = false;continueWhileOpen();add(.discover(true));startWorker()
    }
    func enqueue(_ id:String) {
        guard !paused,!maintenanceSuspended else { return }
        add(.discover(false));add(.video(id));startWorker()
    }
    private func add(_ job:Job) {
        guard scheduled.insert(job).inserted else { return }
        pending.append(job)
        if case .discover = job {} else { totalItems += 1 }
    }
    private func startWorker() {
        guard worker == nil,!maintenanceSuspended else { return }
        totalItems = pending.filter { if case .discover = $0 {return false};return true }.count
        running = true;completedItems = 0;checkedImages = 0;checkedVideos = 0;checkedIndexes = 0;packedTiles = 0;indeterminate = true
        updateGate()
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                interruptMaintenance = nil;worker = nil;running = false;waitingForInterface = false
                scheduled.removeAll();pending.removeAll();userInitiated = false;updateGate();onFinished?()
            }
            let store:MemoryStore
            do {
                if let database { store = database }
                else {
                    let root = self.root
                    store = try await Task.detached(priority:.utility) { try MemoryStore(root:root,maintenanceOnly:true) }.value
                    database = store
                }
            } catch { status = "Could not open storage for optimization. Try again.";return }
            var failed = 0,keptVideos = 0,tileScanStarted = false
            while !pending.isEmpty,!Task.isCancelled {
                do { try await workGate.wait() } catch { break }
                let started = Date(),job = pending.removeFirst()
                indeterminate = true
                var completed = true
                do {
                    switch job {
                    case .discover(let all):
                        status = "Preparing storage…"
                        let compactIndex = needsIndexCompaction
                        let work = Task.detached(priority:.utility) { () throws -> [Job] in
                            let sessions = try store.sessions()
                            let referenced = Set(sessions.map(\.videoPath))
                            let directory = store.root.appendingPathComponent("recordings")
                            for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
                                try Task.checkCancellation()
                                if file.lastPathComponent.hasPrefix("archive-work-"),file.pathExtension == "mp4",!referenced.contains("recordings/"+file.lastPathComponent),UUID(uuidString:String(file.deletingPathExtension().lastPathComponent.dropFirst("archive-work-".count))) != nil { try? FileManager.default.removeItem(at:file) }
                            }
                            var jobs:[Job] = []
                            // Pack before the final compaction so its freed pages
                            // are reclaimed in the same maintenance run.
                            if store.needsTileStorageOptimization { jobs.append(.tileStorage) }
                            jobs += try store.unfinishedVisualSessions().map(Job.visual)
                            jobs += try (all ? store.imageArchiveCandidates():store.interruptedVisualImages()).map(Job.image)
                            jobs += sessions.filter { $0.unifiedVisualArchive != true && $0.endedAt != nil && $0.videoOptimizationVersion != VideoArchive.policyVersion && (all || $0.storagePolicy == 1) }.map { .video($0.id) }
                            if all || compactIndex { jobs.append(.index) }
                            return jobs
                        }
                        let jobs = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        try Task.checkCancellation()
                        jobs.forEach(add);scheduled.remove(job);completed = false
                    case .visual(let id):
                        status = "Finalizing recorded cards…"
                        let work = Task.detached(priority:.utility) {try store.finalizeVisualSession(id)}
                        let frames = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        if !frames.isEmpty {onFramesArchived?(frames)}
                        checkedImages += frames.count
                    case .tileStorage:
                        status = "Compacting screenshots · \(packedTiles) tiles processed · \(StorageUsage.formatted(max(0,savedBytes))) saved"
                        let restart = !tileScanStarted;tileScanStarted = true
                        let work = Task.detached(priority:.background) {try store.packLegacyTiles(restartScan:restart)}
                        interruptMaintenance = { work.cancel() }
                        do {
                            let batch = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                            packedTiles += batch.processed;savedBytes += batch.savedBytes
                            if batch.more { pending.append(job);completed = false }
                        } catch {
                            if work.isCancelled && !Task.isCancelled { pending.append(job);completed = false }
                            else { throw error }
                        }
                        interruptMaintenance = nil
                    case .index:
                        status = "Compacting search index…"
                        let work = Task.detached(priority:.background) {
                            let url = store.root.appendingPathComponent("memory.sqlite")
                            let before = (try? CleanupFiles.size(url)) ?? 0
                            try store.compactIndex()
                            return max(0,before-((try? CleanupFiles.size(url)) ?? before))
                        }
                        interruptMaintenance = { work.cancel() }
                        do { savedBytes += try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()}) }
                        catch {
                            if work.isCancelled && !Task.isCancelled { pending.append(job);completed = false }
                            else { throw error }
                        }
                        interruptMaintenance = nil
                        if completed {checkedIndexes += 1;needsIndexCompaction = false}
                    case .image(let path):
                        indeterminate = false
                        status = "Optimizing image \(checkedImages+1) · \(StorageUsage.formatted(max(0,savedBytes))) saved"
                        let work = Task.detached(priority:.utility) {
                            let source = try CleanupFiles.ownedURL(path,root:store.root)
                            let result = try ImageArchive.make(source:source)
                            try Task.checkCancellation()
                            return try store.commitImageArchive(originalPath:path,result:result)
                        }
                        let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        if result.changed,let destination = result.destination { onImageArchived?(path,destination) }
                        savedBytes += max(0,result.savedBytes);checkedImages += 1
                    case .video(let id):
                        indeterminate = false
                        status = "Optimizing video \(checkedVideos+1) · \(StorageUsage.formatted(max(0,savedBytes))) saved"
                        // Session lookup, file inspection, encoding and commit all
                        // stay on the maintenance worker, including error cleanup.
                        let work = Task.detached(priority:.utility) { () throws -> (Int64,Bool) in
                            guard let session = try store.session(id),session.unifiedVisualArchive != true,session.endedAt != nil,session.videoOptimizationVersion != VideoArchive.policyVersion else { return (0,false) }
                            let path = "recordings/archive-work-"+UUID().uuidString+".mp4",root = store.root
                            let candidate = root.appendingPathComponent(path)
                            defer { if (try? store.session(id)?.videoPath) != path { try? FileManager.default.removeItem(at:candidate) } }
                            let source = try CleanupFiles.ownedURL(session.videoPath,root:root)
                            let modified = try source.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
                            let result = try await VideoArchive.make(source:source,destination:candidate,externalAudio:AudioArchiveReference.candidates(session:session,root:root))
                            try Task.checkCancellation()
                            let released = try store.commitVideoArchive(sessionID:id,originalPath:session.videoPath,candidatePath:path,result:result,originalModifiedAt:modified)
                            return (released,!result.accepted)
                        }
                        let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        savedBytes += max(0,result.0);if result.1 { keptVideos += 1 };checkedVideos += 1
                    }
                } catch {
                    if Task.isCancelled { break }
                    failed += 1;CaptureDiagnostics(root:root).write("Storage optimization deferred; originals retained; code=\((error as NSError).code)")
                }
                if completed { completedItems += 1 }
                if !pending.isEmpty { try? await Task.sleep(for:.seconds(BackgroundProcessingPolicy.recoveryInterval(after:Date().timeIntervalSince(started)))) }
            }
            let summary = "\(checkedImages) images · \(checkedVideos) videos\(packedTiles > 0 ? " · \(packedTiles) tiles":"") · \(StorageUsage.formatted(max(0,savedBytes))) saved"
            status = Task.isCancelled ? "Paused · \(summary)":"Checked \(summary)\(keptVideos > 0 ? " · \(keptVideos) originals kept":"")\(failed > 0 ? " · \(failed) items kept for retry":"")"
        }
    }
    func cancel() { paused = true;status = "Pausing optimization…";worker?.cancel() }
    func beginCleanup() async {
        maintenanceSuspended = true
        worker?.cancel();await worker?.value
        // A cleanup can invalidate the tile iterator and pack file handles.
        database = nil
    }
    func endCleanup() { maintenanceSuspended = false;resume() }
    func stop() async { worker?.cancel() }
}
