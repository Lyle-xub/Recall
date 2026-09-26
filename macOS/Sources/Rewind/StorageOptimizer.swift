import Foundation
import Combine

@MainActor final class StorageOptimizer:ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var waitingForInterface = false
    @Published private(set) var status = "New screenshots and completed recordings optimize automatically."
    @Published private(set) var savedBytes:Int64 = 0
    private let store:MemoryStore
    private enum Job:Hashable,Sendable { case image(String),video(String),index }
    private var pending:[Job] = []
    private var scheduled = Set<Job>()
    private var includeExisting = false
    @Published private(set) var checkedImages = 0
    @Published private(set) var checkedVideos = 0
    @Published private(set) var checkedIndexes = 0
    @Published private(set) var totalItems = 0
    var onImageArchived:((String,String)->Void)?
    private var worker:Task<Void,Never>?
    private var paused = false
    private var interfaceVisible = false
    private var userInitiated = false
    private let workGate = BackgroundWorkGate()
    func setInterfaceVisible(_ visible:Bool) {
        interfaceVisible = visible;waitingForInterface = visible && !userInitiated && running;workGate.setSuspended(visible && !userInitiated)
    }
    init(store:MemoryStore) { self.store = store }
    func resume() {
        // Only artifacts with our private staging prefix are candidates for
        // recovery; committed media and user files are never swept by age.
        let referenced = Set(((try? store.sessions()) ?? []).map(\.videoPath))
        let directory = store.root.appendingPathComponent("recordings")
        if let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
            for file in files where file.lastPathComponent.hasPrefix("archive-work-") && file.pathExtension == "mp4" && !referenced.contains("recordings/"+file.lastPathComponent) {
                guard UUID(uuidString:String(file.deletingPathExtension().lastPathComponent.dropFirst("archive-work-".count))) != nil else { continue }
                try? FileManager.default.removeItem(at:file)
            }
        }
        if store.needsIndexCompaction { add(.index);startWorker() }
        for session in ((try? store.sessions()) ?? []) where session.storagePolicy == 1 && session.endedAt != nil && session.videoOptimizationVersion != VideoArchive.policyVersion { enqueue(session.id) }
    }
    func continueWhileOpen() { userInitiated = true;waitingForInterface = false;workGate.setSuspended(false) }
    func optimizeExisting() {
        continueWhileOpen()
        guard !running else { return }
        paused = false;includeExisting = true;startWorker()
    }
    func enqueue(_ id:String) {
        guard !paused else { return }
        add(.video(id));startWorker()
    }
    private func add(_ job:Job) {
        guard scheduled.insert(job).inserted else { return }
        pending.append(job);totalItems += 1
    }
    private func startWorker() {
        guard worker == nil else { return }
        running = true;waitingForInterface = interfaceVisible && !userInitiated;checkedImages = 0;checkedVideos = 0;checkedIndexes = 0;totalItems = pending.count
        worker = Task { [weak self] in
            guard let self else { return }
            defer { worker = nil;running = false;waitingForInterface = false;scheduled.removeAll();pending.removeAll();userInitiated = false;workGate.setSuspended(interfaceVisible) }
            var failed = 0,keptVideos = 0
            if includeExisting {
                includeExisting = false;status = "Preparing images and videos…"
                let store = self.store
                do {
                    let plan = try await Task.detached(priority:.utility) {
                        (try store.imageArchiveCandidates(),try store.sessions().filter { $0.endedAt != nil && $0.videoOptimizationVersion != VideoArchive.policyVersion }.sorted { $0.startedAt > $1.startedAt }.map(\.id))
                    }.value
                    try Task.checkCancellation()
                    add(.index)
                    for path in plan.0 { add(.image(path)) }
                    for id in plan.1 { add(.video(id)) }
                } catch {
                    status = Task.isCancelled ? "Optimization paused.":"Could not read the library. Your originals are safe; try again."
                    return
                }
            }
            while !pending.isEmpty,!Task.isCancelled {
                do { try await workGate.wait() } catch { break }
                let started = Date()
                let job = pending.removeFirst()
                switch job {
                case .index:
                    status = "Compacting shared text index…"
                    let database = store
                    do {
                        let released = try await Task.detached(priority:.utility) {
                            let url = database.root.appendingPathComponent("memory.sqlite")
                            let before = (try? CleanupFiles.size(url)) ?? 0
                            try database.compactIndex()
                            return max(0,before-((try? CleanupFiles.size(url)) ?? before))
                        }.value
                        savedBytes += released
                    } catch { failed += 1 }
                    checkedIndexes += 1

                case .image(let path):
                    status = "Optimizing image \(checkedImages+1) · \(pending.count) waiting · \(StorageUsage.formatted(savedBytes)) saved"
                    let store = self.store
                    do {
                        let work = Task.detached(priority:.utility) {
                            let source = try CleanupFiles.ownedURL(path,root:store.root)
                            let result = try ImageArchive.make(source:source)
                            try Task.checkCancellation()
                            return try store.commitImageArchive(originalPath:path,result:result)
                        }
                        let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        if result.changed,let destination = result.destination { onImageArchived?(path,destination) }
                        if result.savedBytes > 0 { savedBytes += result.savedBytes }
                    } catch {
                        if Task.isCancelled { break }
                        failed += 1
                        CaptureDiagnostics(root:store.root).write("Image optimization retained original; code=\((error as NSError).code)")
                    }
                    checkedImages += 1
                case .video(let id):
                    guard let session = try? store.session(id),session.endedAt != nil,session.videoOptimizationVersion != VideoArchive.policyVersion else { checkedVideos += 1;continue }
                    status = "Optimizing video \(checkedVideos+1) · \(pending.count) waiting · \(StorageUsage.formatted(savedBytes)) saved"
                    let path = "recordings/archive-work-"+UUID().uuidString+".mp4",root = store.root
                    let candidate = root.appendingPathComponent(path)
                    do {
                        let source = try CleanupFiles.ownedURL(session.videoPath,root:root)
                        let modified = try source.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
                        let work = Task.detached(priority:.utility) { try await VideoArchive.make(source:source,destination:candidate,externalAudio:AudioArchiveReference.candidates(session:session,root:root)) }
                        let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                        try Task.checkCancellation()
                        let database = store
                        let released = try await Task.detached(priority:.utility) {
                            try database.commitVideoArchive(sessionID:id,originalPath:session.videoPath,candidatePath:path,result:result,originalModifiedAt:modified)
                        }.value
                        if released > 0 { savedBytes += released }
                        if !result.accepted { keptVideos += 1 }
                        if (try? store.session(id)?.videoPath) != path { try? FileManager.default.removeItem(at:candidate) }
                    } catch {
                        if (try? store.session(id)?.videoPath) != path { try? FileManager.default.removeItem(at:candidate) }
                        if Task.isCancelled { break }
                        failed += 1
                        CaptureDiagnostics(root:root).write("Storage optimization retained original; code=\((error as NSError).code)")
                    }
                    checkedVideos += 1
                }
                // Leave room for capture/OCR and UI work between encodes.
                if !pending.isEmpty {
                    try? await Task.sleep(for:.seconds(BackgroundProcessingPolicy.recoveryInterval(after:Date().timeIntervalSince(started))))
                }
            }
            let summary = "\(checkedImages) images · \(checkedVideos) videos · \(StorageUsage.formatted(savedBytes)) saved"
            status = Task.isCancelled ? "Paused · \(summary)":"Checked \(summary)\(keptVideos > 0 ? " · \(keptVideos) original videos kept":"")\(failed > 0 ? " · \(failed) items kept for retry":"")"
        }
    }
    func cancel() { paused = true;status = "Pausing optimization… Your originals are safe.";worker?.cancel() }
    // A system codec/OCR call can ignore cancellation. Quit must remain usable;
    // uncommitted scratch files are recovered at launch, originals stay intact.
    func stop() async { worker?.cancel() }
}
