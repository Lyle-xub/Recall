import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let store: MemoryStore
    let capture: CaptureEngine
    let foregroundWork:ForegroundWorkBudget
    let storageUsage: StorageUsageModel
    @Published private(set) var storageClearing = false
    @Published private(set) var storageCleanupStatus = ""
    let storageOptimizer: StorageOptimizer
    @Published var settings: AppSettings
    @Published private(set) var interfaceVisible = false
    @Published var frames: [MemoryFrame] = []
    @Published var archiveFrames: [MemoryFrame] = []
    @Published var archiveTimelinePosition:Date?
    @Published private(set) var archiveExtractionID:String?
    @Published private(set) var archiveNavigationTarget:ArchiveNavigationTarget?
    @Published private(set) var archiveImagePreparation:ArchiveImagePreparation?
    private(set) var archiveDestinationWindow:ArchiveWindow?
    private var archiveDestinationRevision=0
    private var archiveNavigationGeneration=0
    private var archiveNavigationIntent:Date?
    private var archiveSettledGeneration:Int?
    private var archiveSettlementWaiters:[CheckedContinuation<Void,Never>]=[]
    @Published private(set) var timelineDragging = false
    @Published private(set) var archiveWindow=ArchiveWindow()
    @Published private(set) var archiveWindowLoading=false
    private(set) var archiveWindowRequestCount=0
    private(set) var archiveScrollRow:Double=0
    private var archiveEpoch=0
    private var archiveRequestedRow:Double?
    private var archiveNavigating=false
    private var archiveRequestedDay:Date?
    private var archiveHasNewFrames=false
    private var archiveCaptureRevision=0
    private var archiveFocusedID:String?
    private var archiveProtectedFrames:[ArchivePinnedRecord] = []
    private var archivePendingQuery:ArchiveWindowQuery?
    private var archiveRefreshTask:Task<Void,Never>?
    private var archiveRefreshRevision=0
    private var archiveWindowRefreshing=false
    private let archiveRefreshDelay:@MainActor ()async throws->Void
    private let archiveNavigationWorker:LatestRequestWorker<ArchiveWindowQuery,ArchiveWindow>
    @Published var archiveDay = Calendar.current.startOfDay(for:Date())
    private var archiveDayInitialized = false
    @Published var apps: [String] = []
    @Published var timeline: [CapturedAppMoment] = []
    @Published var selected: MemoryFrame?
    @Published var query = ""
    @Published var appFilter: String?
    @Published var starredOnly = false
    @Published var trash = false
    @Published var searchPresented = false
    @Published var inspectorOpen = false
    @Published var timelineCursor: Date?
    /// Includes the panel's exit animation so archive controls stay covered
    /// until the native timeline has completely left the screen.
    @Published var timelineVisible = false
    @Published var timelineSpan = 300.0
    @Published var timelineViewportWidth = 1200.0
    @Published var timelineActivity: [AppTimeSegment] = []
    @Published var timelineStart: Date?
    private var activityWindow: DateInterval?
    private var requestedActivityWindow: DateInterval?
    private var navigationWindow: DateInterval?
    private var requestedNavigationDate: Date?
    private var previewRequestedID: String?
    private var frameCache: [String:MemoryFrame] = [:]
    private var frameCacheOrder: [String] = []
    private var imageAliases:[String:String] = [:]
    private var transcriptSessionID: String?
    private let previewWorker: LatestRequestWorker<String,MemoryFrame?>
    private let navigationWorker: LatestRequestWorker<TimelineNavigationQuery,TimelineNavigationResult>
    private let activityWorker: LatestRequestWorker<TimelineActivityQuery,TimelineActivityResult>
    private let transcriptWorker: LatestRequestWorker<String,RecordingRecognitionDetail>
    let recognitionActivity = RecognitionActivity()
    @Published private(set) var recordingDetail:RecordingRecognitionDetail?
    private let searchWorker: LatestRequestWorker<MemorySearchQuery,MemorySearchPage>
    @Published var searchHasMore = false
    @Published var searchLoading = false
    @Published var usageOpen = false
    @Published var onboardingOpen = false
    @Published var launchFilmOpen = false
    @Published var launchFilmID = UUID()
    @Published var askStatus = ""
    @Published var askError: String?
    private let evidenceStore: MemoryStore
    private let libraryReader: MemoryStore
    private var searchLimit = 200
    private var usageRefreshTask: Task<Void,Never>?

    var timelineScale: Double { timelineViewportWidth / timelineSpan }
    var timelineDate: Date { timelineCursor ?? Date() }
    @Published var timelineJumpOpen = false
    @Published var since: Date?
    @Published var recording = false
    @Published private(set) var recordingRequested = false
    @Published private(set) var recordingAutomaticallyPaused = false
    private var transcriptionTask:Task<Void,Never>?
    private var transcriptionQueue:[RecordingSession] = []
    private lazy var recordingCoordinator:RecordingCoordinator = {
        let coordinator = RecordingCoordinator(start:{ [weak self] in
            guard let self else { throw CancellationError() }
            try await self.beginCapture()
        },stop:{ [weak self] in await self?.finishCapture() })
        coordinator.changed = { [weak self] state in
            guard let self else { return }
            if recording != state.active { recording = state.active }
            if recordingRequested != state.requested { recordingRequested = state.requested }
            if recordingAutomaticallyPaused != state.automaticallyPaused { recordingAutomaticallyPaused = state.automaticallyPaused }
            if working != state.transitioning { working = state.transitioning }
        }
        coordinator.failed = { [weak self] in self?.captureFailed($0) }
        return coordinator
    }()
    var recordingActionTitle:String { recordingRequested ? "Pause recording":"Start recording" }
    var recordingStatusTitle:String { recordingAutomaticallyPaused ? "Paused while Recall is open":recording ? "Recording":"Recording paused" }
    var recordingStatusDetail:String { recordingAutomaticallyPaused ? "Screen and audio recording resume when you close Recall.":recording ? "\(recordedFrames) moments captured this session":"Start whenever you’re ready." }
    @Published var recordedFrames = 0
    @Published var working = false
    @Published var error: String?
    @Published var capturePermissionRequired = false
    @Published var toast: String?
    @Published var settingsOpen = false
    @Published var shortcutStatus = "Registering global shortcuts…"
    @Published var shortcutAvailable = false
    @Published var settingsTab = "recording"
    @Published var desktopInsets = EdgeInsets()
    @Published var askOpen = false
    @Published var showText = false
    @Published var meetingView = false
    @Published var lines: [TranscriptLine] = []
    @Published var transcriptQuery = ""
    @Published private(set) var originalTranscriptLines: [TranscriptLine] = []
    @Published private(set) var screenRecognition = RecognitionProgress()
    @Published private(set) var speechRecognition = RecognitionProgress()
    @Published private(set) var speechIssue: String?
    @Published var messages: [ChatMessage] = []
    @Published var asking = false
    @Published var total = 0
    @Published var dateJump = Date()
    @Published var indexingStatus = "Everything stays on this device"
    @Published var indexingIssue:String?
    @Published var player: AVPlayer?
    @Published private(set) var videoReady=false
    private var pendingMutations = Set<String>()
    private var searchTask: Task<Void,Never>?
    private var rotationTask: Task<Void,Never>?
    private var chatTask: Task<Void,Never>?
    private var askGeneration = 0
    private var toastTask: Task<Void,Never>?
    var configureShortcuts: ((ShortcutConfiguration) throws -> Void)?
    var window: NSWindow?
    private var cliControl:NativeCLIControl?

    func enableCLIControl(lease:CoreCLILease) throws {
        cliControl = try NativeCLIControl(lease:lease) { [weak self] operation,args in
            guard let self else { throw CoreCLIError(code:"service_unavailable",message:"Recall is shutting down.") }
            switch operation {
            case "service-stop":
                guard CommandLine.arguments.contains("--headless-service") else {throw CoreCLIError(code:"unsupported",message:"This owner is a desktop app. Quit it normally.")}
                await stopRecording()
                // AppKit's terminateLater loop cannot make progress when
                // entered from this MainActor task. A headless owner drains
                // its jobs directly after the response has been persisted.
                Task {
                    try? await Task.sleep(for:.milliseconds(250))
                    await self.stopCLIControl();self.prepareToQuit()
                    await self.shutDownRecording();await self.storageOptimizer.stop()
                    await LocalInference.shared.stop();exit(0)
                }
                return ["stopping":true]
            case "recording-start","recording-stop","recording-status":
                if operation == "recording-start" {
                    if CommandLine.arguments.contains("--headless-service") {
                        guard CGPreflightScreenCaptureAccess() else {throw CoreCLIError(code:"capture_unavailable",message:"Screen Recording permission is missing for this native helper. Grant permission before starting headless recording.")}
                        if settings.microphone,AVCaptureDevice.authorizationStatus(for:.audio) != .authorized {throw CoreCLIError(code:"capture_unavailable",message:"Microphone permission is missing. Grant it through the desktop app or disable microphone.")}
                    }
                    await startRecording()
                }
                if operation == "recording-stop" { await stopRecording() }
                if operation == "recording-start",!recording,!recordingAutomaticallyPaused,let error { throw CoreCLIError(code:"capture_failed",message:error) }
                return ["available":true,"requested":recordingRequested,"active":recording,"automaticallyPaused":recordingAutomaticallyPaused,"owner":CommandLine.arguments.contains("--headless-service") ? "headless":"desktop","error":error ?? ""]
            case "tasks-status": return ["indexing":indexingStatus,"optimizing":storageOptimizer.running,"optimizationStatus":storageOptimizer.status,"clearing":storageClearing]
            case "index":
                let frame = args["id"] is String ? try NativeCoreCLI.required(args,store:store):nil
                await capture.suspendIndexing()
                do {
                    if var frame { frame.indexingComplete = false;try store.save(frame) }
                } catch { await capture.resumeIndexingAfterCleanup();throw error }
                await capture.resumeIndexingAfterCleanup()
                return ["accepted":true,"owner":"desktop"]
            case "export":
                guard !storageClearing else { throw CoreCLIError(code:"busy",message:"Storage maintenance is running.") }
                await storageOptimizer.beginCleanup();await capture.suspendIndexing()
                do {
                    let database=store
                    let result=try await Task.detached(priority:.utility) {try NativeCoreCLI.execute("export",args:args,store:database)}.value
                    await capture.resumeIndexingAfterCleanup();storageOptimizer.endCleanup();return result
                } catch {await capture.resumeIndexingAfterCleanup();storageOptimizer.endCleanup();throw error}
            case "config-set":
                let next=try NativeCoreCLI.configured(args,current:settings)
                if next.microphone,AVCaptureDevice.authorizationStatus(for:.audio) != .authorized {throw CoreCLIError(code:"capture_unavailable",message:"Grant microphone permission through the desktop app before enabling it through the CLI.")}
                try await saveSettings(next,chatKey:"",speechKey:"",updateKeys:false,applyRetention:args["key"] as? String == "retention-days")
                return try NativeCoreCLI.object(next)
            case "index-one":
                _ = try NativeCoreCLI.required(args,store:store)
                await capture.suspendIndexing()
                do {
                    let database = store
                    let result = try await Task.detached(priority:.utility) { try NativeCoreCLI.execute("index-one",args:args,store:database) }.value
                    await capture.resumeIndexingAfterCleanup();reload();return result
                } catch { await capture.resumeIndexingAfterCleanup();throw error }
            case "optimize":
                storageOptimizer.optimizeExisting();await storageOptimizer.waitUntilFinished()
                if storageOptimizer.failedItems>0 {throw CoreCLIError(code:"optimization_failed",message:storageOptimizer.status)}
                return ["completed":true,"owner":"desktop","savedBytes":storageOptimizer.savedBytes,"status":storageOptimizer.status]
            case "cleanup":
                guard args["confirmed"] as? Bool == true else { throw CoreCLIError(code:"confirmation_required",message:"Permanent cleanup requires --yes.") }
                return NativeCoreCLI.cleanupResult(try await clearStorage(NativeCoreCLI.cleanupPlan(args,store:store)))
            case "compact":
                guard !storageOptimizer.running,!storageClearing else { throw CoreCLIError(code:"busy",message:"Desktop storage maintenance is already running.") }
                storageClearing = true
                recordingCoordinator.setInterfaceVisible(true)
                await recordingCoordinator.waitUntilSettled()
                await storageOptimizer.beginCleanup()
                await capture.suspendIndexing()
                defer {
                    storageClearing = false
                    recordingCoordinator.setInterfaceVisible(interfaceVisible)
                    storageOptimizer.endCleanup()
                    storageUsage.refresh(force:true)
                }
                let database = store
                do { try await Task.detached(priority:.utility) { try database.compactIndex() }.value }
                catch { await capture.resumeIndexingAfterCleanup();throw error }
                await capture.resumeIndexingAfterCleanup()
                return ["compacted":true]
            default:
                guard NativeCoreCLI.writes.contains(operation),operation != "init",operation != "index-offline" else { throw CoreCLIError(code:"unsupported",message:"Unsupported desktop control operation.") }
                let database = store
                let result = try await Task.detached(priority:.utility) { try NativeCoreCLI.execute(operation,args:args,store:database) }.value
                // Fresh reader also invalidates shared OCR cache entries in selected views.
                reload();if let id = selected?.id { selected = try MemoryStore(root:store.root,readOnly:true).frame(id) }
                return result
            }
        }
    }
    func stopCLIControl() async { await cliControl?.stop();cliControl = nil }

    init(root: URL? = nil,maintenanceOnly:Bool = false,
         archiveRefreshDelay:@escaping @MainActor ()async throws->Void = {try await Task.sleep(for:.milliseconds(120))},
         archiveWindowLoad:(@Sendable (ArchiveWindowQuery)throws->ArchiveWindow)? = nil) throws {
        self.archiveRefreshDelay=archiveRefreshDelay
        let root = try DefaultLibrary.resolve(explicit:root)
        DefaultLibrary.configuredRoot = root
        store = try MemoryStore(root:root,maintenanceOnly:maintenanceOnly)
        if maintenanceOnly {try store.recoverForHeadless()}
        storageOptimizer = StorageOptimizer(store:store)
        storageUsage = StorageUsageModel(root:root,modelRoot:BuiltinModels.shared.root)
        // A separate WAL reader keeps long history/search queries from holding
        // the writer's lock while screen capture saves the next frame.
        let previewDB = try MemoryStore(root:root,readOnly:true), navigationDB = try MemoryStore(root:root,readOnly:true)
        let activityDB = try MemoryStore(root:root,readOnly:true), searchDB = try MemoryStore(root:root,readOnly:true)
        evidenceStore = try MemoryStore(root:root,readOnly:true)
        libraryReader = try MemoryStore(root:root,readOnly:true)
        previewWorker = LatestRequestWorker { try previewDB.frame($0) }
        navigationWorker = LatestRequestWorker { try TimelineNavigationResult.load($0,store:navigationDB) }
        activityWorker = LatestRequestWorker { try TimelineActivityResult.load($0,store:activityDB) }
        let archiveDB = try MemoryStore(root:root,readOnly:true)
        archiveNavigationWorker = LatestRequestWorker(operation:archiveWindowLoad ?? {try archiveDB.archiveWindow($0)})
        transcriptWorker = LatestRequestWorker { try RecordingRecognitionDetail.load($0,store:previewDB) }
        searchWorker = LatestRequestWorker { try MemorySearchPage.load($0,store:searchDB) }
        foregroundWork=ForegroundWorkBudget(observeSystem:!maintenanceOnly)
        capture = CaptureEngine(store:store,workBudget:foregroundWork)
        settings = (try? JSONDecoder().decode(AppSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))) ?? AppSettings()
        storageOptimizer.onImageArchived = { [weak self] source,destination in
            guard let self else { return }
            imageAliases[source] = destination
            func refreshed(_ frame:MemoryFrame)->MemoryFrame {
                var frame = frame
                if frame.imagePath == source { frame.imagePath = destination }
                if frame.meetingImagePath == source { frame.meetingImagePath = destination }
                return frame
            }
            frameCache = frameCache.mapValues(refreshed)
            if let current = selected,current.imagePath == source || current.meetingImagePath == source { selected = refreshed(current) }
            if frames.contains(where:{$0.imagePath == source || $0.meetingImagePath == source}) { frames = frames.map(refreshed) }
            let changed=archiveWindow.frames.contains {$0.imagePath == source || $0.meetingImagePath == source} || archiveDestinationWindow?.frames.contains {$0.imagePath == source || $0.meetingImagePath == source} == true
            if changed {updateArchiveMetadata(refreshed)}
            if changed {refreshArchiveWindowAfterMaintenance()}
        }
        capture.onFrame = { [weak self] frame in self?.receiveCapturedFrame(frame) }
        capture.onFrameExtended = { [weak self] id,date in
            guard let self else { return }
            if let index = timeline.firstIndex(where:{$0.id == id}) { timeline[index].endTimestamp = date }
            if var cached = frameCache[id] { cached.endTimestamp = date;frameCache[id] = cached }
            if selected?.id == id { selected?.endTimestamp = date }
        }
        capture.onIndexed = { [weak self] frame in
            guard let self else { return }
            let previous=archiveDestinationWindow?.frames.first {$0.id == frame.id} ?? archiveFrames.first {$0.id == frame.id}
            if previous != nil {updateArchiveMetadata {$0.id == frame.id ? frame:$0}}
            if let previous,previous.imagePath != frame.imagePath {refreshArchiveWindowAfterMaintenance()}
            if frameCache[frame.id] != nil { cache(frame) }
            if selected?.id == frame.id { selected = frame }
            if searchPresented { reloadSearch() }
        }
        capture.onArchived = { [weak self] archived in
            guard let self else {return}
            let updates=Dictionary(uniqueKeysWithValues:archived.map {($0.id,$0)})
            updateArchiveMetadata {updates[$0.id] ?? $0}
            frames=frames.map {updates[$0.id] ?? $0}
            for frame in archived where frameCache[frame.id] != nil {cache(frame)}
            if let id=selected?.id,let frame=updates[id] {selected=frame}
            if searchPresented {reloadSearch()}
            refreshArchiveWindowAfterMaintenance()
        }
        storageOptimizer.onFramesArchived = capture.onArchived
        storageOptimizer.onFinished = { [weak self] in
            guard let self,!storageClearing else { return };storageUsage.refresh(force:true);refreshArchiveWindowAfterMaintenance()
        }
        capture.onError = { [weak self] text in self?.error = text }
        capture.onIndexingIssue = { [weak self] text in self?.indexingIssue = text }
        capture.onFrameRecognition = { [weak self] id,state in self?.recognitionActivity.set(state,for:.image(id)) }
        capture.onRecognitionProgress = { [weak self] progress in
            if self?.screenRecognition != progress { self?.screenRecognition = progress }
        }
        capture.onUsageChanged = { [weak self] in
            guard let self,window?.isVisible == true else { return }
            if let cursor = timelineCursor,cursor.addingTimeInterval(timelineSpan) < Date().addingTimeInterval(-10) { return }
            usageRefreshTask?.cancel()
            usageRefreshTask = Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(80)); guard !Task.isCancelled else { return }
                self?.refreshTimelineActivity(force:true)
            }
        }
        capture.onStopped = { [weak self] in self?.recordingCoordinator.interrupted(); self?.rotationTask?.cancel(); self?.indexingStatus = "Recording stopped" }
        if !maintenanceOnly {try? store.applyRetention(days:settings.retentionDays)}
        reload()
        onboardingOpen = OnboardingPolicy.shouldPresent(completed:settings.onboardingComplete,memories:total)
        launchFilmOpen = OnboardingPolicy.shouldPlayFilm(settings:settings,memories:total)
        if !maintenanceOnly {capture.resumePendingIndexing()}
        if !maintenanceOnly {storageOptimizer.resume()}
        let pendingURL = store.root.appendingPathComponent("pending-transcriptions.json")
        if !maintenanceOnly,let data = try? Data(contentsOf:pendingURL),let ids = try? JSONDecoder().decode([String].self,from:data) {
            for id in ids { if let session = try? libraryReader.session(id),session.endedAt != nil { enqueueTranscription(session) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.recording == true { await self?.stopRecording() } }
        }
    }
    func showOnboarding() {
        returnToDesktop(); settingsOpen = false; usageOpen = false; launchFilmID = UUID(); launchFilmOpen = true; onboardingOpen = true
    }
    func markLaunchFilmSeen() {
        guard !settings.launchFilmSeen else { return }
        let updated = OnboardingPolicy.filmStartedSettings(settings)
        do {
            try JSONEncoder().encode(updated).write(to:store.root.appendingPathComponent("settings.json"),options:.atomic)
            settings = updated
        } catch { CaptureDiagnostics(root:store.root).write("Could not save launch film state: \(error.localizedDescription)") }
    }
    @discardableResult func finishOnboarding(startRecording:Bool = false)->Bool {
        let updated = OnboardingPolicy.completedSettings(settings)
        do { try JSONEncoder().encode(updated).write(to:store.root.appendingPathComponent("settings.json"),options:.atomic) }
        catch { self.error = "Could not save setup: " + error.localizedDescription;return false }
        settings = updated;launchFilmOpen = false;onboardingOpen = false
        if startRecording, CapturePermissions.screen {
            if !recordingRequested { toggleRecording() }
            hideOverlay()
        }
        return true
    }
    func debounceSearch() {
        searchLimit = 200; searchWorker.cancel(); searchLoading = true
        if !query.isEmpty || appFilter != nil || starredOnly || trash { searchPresented = true }
        inspectorOpen = false; askOpen = false
        searchTask?.cancel(); searchTask = Task {
            try? await Task.sleep(for:.milliseconds(180)); guard !Task.isCancelled else { return }; reloadSearch()
        }
    }
    private func receiveCapturedFrame(_ frame:MemoryFrame) {
        recordedFrames += 1; total += 1
        let calendar = Calendar.current
        if let delta=calendar.dateComponents([.day],from:archiveDay,to:calendar.startOfDay(for:frame.timestamp)).day,abs(delta) <= 2 {
            archiveHasNewFrames=true;archiveCaptureRevision += 1
            if archiveScrollRow <= Double(archiveWindow.minimumRow)+1,!archiveNavigating {
                archiveEpoch += 1
                submitArchiveWindow(ArchiveWindowQuery(day:archiveDay,epoch:archiveEpoch),navigating:true)
            }
        }
        timelineStart = min(timelineStart ?? frame.timestamp,frame.timestamp)
        if !trash,navigationWindow?.contains(frame.timestamp) != false {
            timeline.append(CapturedAppMoment(frame)); timeline.sort { $0.timestamp < $1.timestamp }
            if timeline.count > 2000 { timeline.removeFirst(timeline.count-2000) }
            navigationWindow = DateInterval(start:timeline.first?.timestamp ?? .distantPast,end:.distantFuture)
        }
        if !apps.contains(frame.appName) { apps.append(frame.appName); apps.sort() }
        if searchPresented { reloadSearch() }
    }
    func reload() {
        cancelArchiveRefresh()
        if archiveNavigationIntent != nil {cancelArchiveExtraction(keepNavigation:true)} else {clearArchiveDestination()}
        navigationWorker.cancel(); requestedNavigationDate = nil
        frameCache.removeAll(); frameCacheOrder.removeAll()
        do {
            timeline = try libraryReader.timelineMoments(trash:trash,since:since,limit:2000).reversed()
            navigationWindow = DateInterval(start:timeline.count < 2000 ? .distantPast:timeline.first!.timestamp,end:.distantFuture)
            total = try libraryReader.count(demo:false)
            apps = try libraryReader.appNames(demo:false,trash:trash,since:since)
            timelineStart = try libraryReader.firstTimelineDate()
            if !archiveDayInitialized {
                let latest = try libraryReader.frames(demo:false,limit:1).first?.timestamp ?? Date()
                archiveDay = Calendar.current.startOfDay(for:latest);archiveDayInitialized = true
            }
            cancelArchiveWindowLoad();archiveEpoch += 1
            let window=try libraryReader.archiveWindow(ArchiveWindowQuery(day:archiveNavigationIntent.map {Calendar.current.startOfDay(for:$0)} ?? archiveDay,row:archiveScrollRow,near:archiveNavigationIntent,anchors:archiveAnchors(near:archiveScrollRow),epoch:archiveEpoch,pins:archiveProtectedFrames))
            applyArchiveWindow(archiveNavigationIntent.map {prepareArchiveDestination(window,at:$0,generation:archiveNavigationGeneration)} ?? window)
            refreshTimelineActivity(force:true)
            if searchPresented { reloadSearch() }
            if let selected,!timeline.contains(where:{$0.id == selected.id}) { loadTimeline(around:selected.timestamp) }
        } catch { self.error = error.localizedDescription }
    }
    func clearStorage(_ plan:StorageCleanupPlan) async throws -> StorageCleanupResult {
        guard !storageClearing else { throw RewindError.message("Storage cleanup is already running.") }
        storageClearing = true;storageCleanupStatus = "Finishing background work…";cancelAsk();back()
        recordingCoordinator.setInterfaceVisible(true)
        await recordingCoordinator.waitUntilSettled()
        await storageOptimizer.beginCleanup()
        await capture.suspendIndexing()
        defer {
            storageClearing = false
            recordingCoordinator.setInterfaceVisible(interfaceVisible)
            storageOptimizer.endCleanup()
            storageUsage.refresh(force:true)
        }
        let root = store.root
        let report:@Sendable (String)->Void = { [weak self] text in Task { @MainActor in self?.storageCleanupStatus = text } }
        do {
            let result = try await Task.detached(priority:.utility) {
                try MemoryStore(root:root,maintenanceOnly:true).clearStorage(plan,progress:report)
            }.value
            messages.removeAll { $0.sources.contains { plan.frameIDs.contains($0.id) } }
            storageCleanupStatus = "Refreshing your library…"
            await reloadAfterCleanup()
            await capture.resumeIndexingAfterCleanup()
            return result
        } catch {
            await capture.resumeIndexingAfterCleanup()
            throw error
        }
    }
    private func reloadAfterCleanup() async {
        clearArchiveDestination()
        navigationWorker.cancel();cancelArchiveWindowLoad();requestedNavigationDate = nil
        frameCache.removeAll();frameCacheOrder.removeAll()
        let root = store.root,trash = trash,since = since,day = archiveDay,near = archiveTimelinePosition
        let row=archiveScrollRow,anchors=archiveAnchors(near:archiveScrollRow),pins=archiveProtectedFrames
        do {
            let snapshot = try await Task.detached(priority:.utility) {
                let reader = try MemoryStore(root:root,readOnly:true)
                return (Array(try reader.timelineMoments(trash:trash,since:since,limit:2000).reversed()),
                        try reader.count(demo:false),try reader.appNames(demo:false,trash:trash,since:since),
                        try reader.firstTimelineDate(),try reader.archiveWindow(ArchiveWindowQuery(day:day,row:row,near:near,anchors:anchors,pins:pins)))
            }.value
            timeline = snapshot.0;total = snapshot.1;apps = snapshot.2;timelineStart = snapshot.3;archiveEpoch += 1;var window=snapshot.4;window.epoch=archiveEpoch;applyArchiveWindow(window)
            navigationWindow = DateInterval(start:timeline.count < 2000 ? .distantPast:timeline.first!.timestamp,end:.distantFuture)
            refreshTimelineActivity(force:true)
            if searchPresented { reloadSearch() }
        } catch { self.error = error.localizedDescription }
    }
    func moveArchiveDay(by offset:Int) {
        let navigationDay=archiveRequestedDay ?? archiveDay
        timelineDragging = false;cancelArchiveExtraction();cancelArchiveWindowLoad();archiveTimelinePosition = nil;timelineCursor = nil
        guard let day = Calendar.current.date(byAdding:.day,value:offset,to:navigationDay) else { return }
        archiveProtectedFrames=[];archiveFocusedID=nil
        archiveEpoch += 1;archiveScrollRow=0
        submitArchiveWindow(ArchiveWindowQuery(day:day,epoch:archiveEpoch),navigating:true)
    }
    private func cancelArchiveWindowLoad() {
        archiveNavigationWorker.cancel();archiveWindowLoading=false;archiveWindowRefreshing=false;archiveRequestedRow=nil;archiveNavigating=false;archiveRequestedDay=nil;archivePendingQuery=nil
    }
    private func applyArchiveWindow(_ window:ArchiveWindow) {
        archiveWindow=window;archiveProtectedFrames=window.pins;archiveFrames=window.frames
        if let day=window.columns.first(where:{$0.lane == 0})?.day {archiveDay=day}
        archiveWindowLoading=false;archiveWindowRefreshing=false;archiveRequestedRow=nil;archiveNavigating=false;archiveRequestedDay=nil
        if let row=window.focusRow {archiveScrollRow=row}
        publishArchiveExtractionIfReady()
    }
    private func submitArchiveWindow(_ request:ArchiveWindowQuery,navigating:Bool = false,refreshing:Bool = false) {
        var query=request;query.pins=archiveProtectedFrames;archivePendingQuery=query
        archiveWindowRefreshing = archiveWindowRefreshing || refreshing
        let captureRevision=archiveCaptureRevision,navigationGeneration=archiveNavigationGeneration,destinationRevision=archiveDestinationRevision
        archiveWindowLoading=true;archiveRequestedRow=query.row;archiveNavigating=navigating;archiveRequestedDay=query.day
        archiveWindowRequestCount += 1
        archiveNavigationWorker.submit(query,apply:{ [weak self] window in
            guard let self,self.archiveEpoch == query.epoch,
                  query.near == nil || self.archiveDestinationRevision == destinationRevision else {return}
            var current=window
            if !navigating,query.near == nil {current.focusRow=self.archiveScrollRow}
            if navigating,let date=query.near,self.archiveNavigationIntent == date,
               self.archiveNavigationGeneration == navigationGeneration,self.archiveDestinationRevision == destinationRevision {
                current=self.prepareArchiveDestination(window,at:date,generation:navigationGeneration)
            }
            self.applyArchiveWindow(current)
            if navigating {
                self.archiveHasNewFrames=self.archiveCaptureRevision != captureRevision
                if query.near == nil,self.archiveHasNewFrames,self.archiveScrollRow <= Double(self.archiveWindow.minimumRow)+1 {self.requestArchiveWindow(at:self.archiveScrollRow)}
            }
        },fail:{ [weak self] error in
            guard let self,self.archiveEpoch == query.epoch,
                  query.near == nil || self.archiveDestinationRevision == destinationRevision else {return}
            self.archiveWindowLoading=false;self.archiveWindowRefreshing=false;self.archiveRequestedRow=nil;self.archiveNavigating=false;self.error=error.localizedDescription
            if navigating {self.cancelArchiveExtraction()}
        })
    }
    private func prepareArchiveDestination(_ window:ArchiveWindow,at date:Date,generation:Int)->ArchiveWindow {
        // Resolving a far destination must not evict the screenshots
        // still on screen. Reuse at most one bounded page per day;
        // motion requests replace these pages as the viewport travels.
        var current=window
        current.columns=window.columns.map {column in
            guard let old=archiveWindow.columns.first(where:{$0.day == column.day}) else {return column}
            let center=max(0,min(column.totalCount-1,Int(archiveScrollRow)-old.origin))
            let first=max(0,center-ArchiveDayLayout.renderedRows/2)
            let last=min(column.totalCount,center+ArchiveDayLayout.renderedRows/2+1)
            let keepOld=column.startIndex > first || column.startIndex+column.records.count < last
            return ArchiveDayColumn(day:column.day,lane:column.lane,records:keepOld ? old.records:column.records,
                startIndex:keepOld ? old.startIndex:column.startIndex,totalCount:column.totalCount,origin:old.origin)
        }
        var destinationWindow=window
        destinationWindow.columns=window.columns.map {column in
            ArchiveDayColumn(day:column.day,lane:column.lane,records:column.records,startIndex:column.startIndex,totalCount:column.totalCount,
                origin:archiveWindow.columns.first(where:{$0.day == column.day})?.origin ?? 0)
        }
        archiveNavigationTarget=destinationWindow.navigationTarget(at:date,generation:generation)
            ?? ArchiveNavigationTarget(generation:generation,date:date,row:window.focusRow ?? 0,recordID:nil)
        archiveDestinationWindow=destinationWindow
        if let target=archiveNavigationTarget {archiveImagePreparation=destinationWindow.imagePreparation(for:target)}
        current.focusRow=archiveScrollRow
        return current
    }
    /// Patch both bounded pages together. Path merges also schedule a fresh
    /// rank/uniqueness query; text-only OCR updates need no database round trip.
    private func updateArchiveMetadata(_ transform:(MemoryFrame)->MemoryFrame) {
        func updated(_ window:ArchiveWindow)->ArchiveWindow {
            var result=window
            result.columns=window.columns.map {column in
                ArchiveDayColumn(day:column.day,lane:column.lane,records:column.records.map(transform),startIndex:column.startIndex,totalCount:column.totalCount,origin:column.origin)
            }
            result.pins=window.pins.map {pin in var pin=pin;pin.frame=transform(pin.frame);return pin}
            return result
        }
        archiveWindow=updated(archiveWindow);archiveFrames=archiveWindow.frames;archiveProtectedFrames=archiveWindow.pins
        if let destination=archiveDestinationWindow {archiveDestinationWindow=updated(destination)}
        if let target=archiveNavigationTarget,archiveImagePreparation != nil {
            archiveImagePreparation=(archiveDestinationWindow ?? archiveWindow).imagePreparation(for:target)
        }
    }
    /// Called with world coordinates even when no record metadata is loaded at
    /// a fast scroll's destination. A missing card can never suppress demand.
    func requestArchiveWindow(at row:Double,navigation:Bool = false) {
        guard !archiveNavigating else {return}
        archiveScrollRow=row
        if !navigation,archiveTimelinePosition != nil {archiveTimelinePosition=nil;cancelArchiveExtraction()}
        if !navigation,archiveHasNewFrames,row <= Double(archiveWindow.minimumRow)+1 {
            archiveEpoch += 1
            submitArchiveWindow(ArchiveWindowQuery(day:archiveDay,epoch:archiveEpoch),navigating:true);return
        }
        if archiveWindow.covers(row),!archiveWindowRefreshing {
            if archiveWindowLoading {cancelArchiveWindowLoad()}
            return
        }
        // Replacing a 30 ms read on every 60 Hz wheel sample would starve
        // continuous scrolling. A 96-row page safely covers this demand band.
        if let requested=archiveRequestedRow,abs(requested-row) <= 16 {return}
        submitArchiveWindow(ArchiveWindowQuery(day:archiveDay,row:row,anchors:archiveAnchors(near:row),epoch:archiveEpoch))
    }
    func requestArchiveNavigationWindow(at row:Double,target:ArchiveNavigationTarget) {
        guard archiveNavigationTarget == target,target.generation == archiveNavigationGeneration else {return}
        if !archiveWindow.covers(row),let destination=archiveDestinationWindow,
           destination.epoch == archiveEpoch,destination.covers(row) {
            // The near-time read already paid for this page. Arrival replaces
            // an obsolete intermediate request without a second database read.
            cancelArchiveWindowLoad()
            var ready=destination;ready.focusRow=row;ready.pins=archiveProtectedFrames
            applyArchiveWindow(ready);return
        }
        requestArchiveWindow(at:row,navigation:true)
    }

    private func clearArchiveDestination() {
        archiveDestinationRevision += 1;archiveDestinationWindow=nil;archiveImagePreparation=nil
    }

    /// Archive batches may merge source paths and therefore change daily
    /// uniqueness. Coalesce maintenance notifications into one background read.
    func refreshArchiveWindowAfterMaintenance() {
        guard !archiveWindow.columns.isEmpty else {return}
        if archiveNavigationIntent != nil {cancelArchiveExtraction(keepNavigation:true);cancelArchiveWindowLoad()}
        else {clearArchiveDestination()}
        cancelArchiveRefresh()
        let revision=archiveRefreshRevision,delay=archiveRefreshDelay
        archiveRefreshTask=Task { [weak self] in
            defer {if let self,self.archiveRefreshRevision == revision {self.archiveRefreshTask=nil}}
            do {try await delay()} catch {return}
            guard let self,!Task.isCancelled else {return}
            if self.archiveNavigating {await self.archiveNavigationWorker.waitUntilIdle()}
            guard !Task.isCancelled,!self.storageClearing else {return}
            let near=self.archiveNavigationIntent
            // Read the latest intent after the debounce, not the date that
            // triggered maintenance. A changed rank gets a new motion identity.
            if near != nil {self.cancelArchiveExtraction(keepNavigation:true)}
            self.archiveEpoch += 1
            self.submitArchiveWindow(ArchiveWindowQuery(day:near.map {Calendar.current.startOfDay(for:$0)} ?? self.archiveDay,row:self.archiveScrollRow,near:near,anchors:self.archiveAnchors(near:self.archiveScrollRow),epoch:self.archiveEpoch),navigating:near != nil,refreshing:true)
        }
    }
    private func cancelArchiveRefresh() {
        archiveRefreshRevision += 1;archiveRefreshTask?.cancel();archiveRefreshTask=nil
    }
    private func archiveAnchors(near row:Double)->[ArchivePageAnchor] {
        var anchors=archiveWindow.anchors(near:row)
        if let focused=archiveProtectedFrames.first(where:{$0.frame.id == archiveFocusedID}) {
            anchors.insert(ArchivePageAnchor(day:focused.day,id:focused.frame.id,timestamp:focused.frame.timestamp,row:focused.row),at:0)
        }
        return anchors
    }
    func pinArchiveRecord(_ id:String?) {
        archiveFocusedID=id
        guard let id,let column=archiveWindow.columns.first(where:{$0.row(of:id) != nil}),let row=column.row(of:id),let frame=archiveFrames.first(where:{$0.id == id}) else {return}
        archiveProtectedFrames.removeAll {$0.frame.id == id}
        archiveProtectedFrames.append(ArchivePinnedRecord(frame:frame,day:column.day,lane:column.lane,row:row))
        if archiveProtectedFrames.count > 2 {archiveProtectedFrames.removeFirst(archiveProtectedFrames.count-2)}
        archiveWindow.pins=archiveProtectedFrames
        if let pending=archivePendingQuery,archiveWindowLoading {submitArchiveWindow(pending,navigating:archiveNavigating)}
    }
    private func reloadSearch() {
        guard searchPresented else { return }
        searchLoading = true
        searchWorker.submit(MemorySearchQuery(query:query,app:appFilter,starred:starredOnly,trash:trash,since:since,limit:searchLimit),apply:{ [weak self] page in guard let self else { return }; self.frames = page.frames.map(self.canonicalImages); self.searchHasMore = page.hasMore; self.searchLoading = false },fail:{ [weak self] in self?.error = $0.localizedDescription; self?.searchLoading = false })
    }
    func loadMore() {
        guard !searchLoading,searchHasMore else { return }; searchLimit = min(9999,searchLimit+200); reloadSearch()
    }
    private func canonicalImages(_ frame:MemoryFrame)->MemoryFrame {
        var frame = frame
        func canonical(_ path:String)->String {
            var value = path,seen = Set<String>()
            while seen.insert(value).inserted,let next = imageAliases[value] {value = next}
            return value
        }
        frame.imagePath = canonical(frame.imagePath)
        if let meeting = frame.meetingImagePath {frame.meetingImagePath = canonical(meeting)}
        return frame
    }
    private func cache(_ frame:MemoryFrame) {
        let frame = canonicalImages(frame)
        if frameCache[frame.id] == nil { frameCacheOrder.append(frame.id) }
        frameCache[frame.id] = frame
        while frameCacheOrder.count > 24 { frameCache.removeValue(forKey:frameCacheOrder.removeFirst()) }
    }
    private func display(_ frame:MemoryFrame) {
        stopVideo()
        let frame = canonicalImages(frame)
        cache(frame)
        selected = frame; meetingView = frame.meetingImagePath != nil; transcriptQuery = query
        if transcriptSessionID != frame.sessionID {
            transcriptWorker.cancel(); transcriptSessionID = frame.sessionID; lines = []; originalTranscriptLines = [];recordingDetail = nil
            if let session = frame.sessionID { loadRecordingDetail(session) }
        }
    }
    private func loadRecordingDetail(_ id:String) {
        transcriptWorker.submit(id,apply:{ [weak self] detail in
            guard let self,selected?.sessionID == id else { return }
            recordingDetail = detail;lines = detail.transcript.lines;originalTranscriptLines = detail.transcript.original
        },fail:{ [weak self] _ in
            guard let self,selected?.sessionID == id else { return }
            recordingDetail = RecordingRecognitionDetail(sessionID:id,session:nil,transcript:TranscriptPage([]),outcome:.failed("The saved status of this recording could not be loaded."))
        })
    }
    func select(_ frame: MemoryFrame) {
        timelineDragging = false;cancelArchiveExtraction();cancelArchiveWindowLoad();archiveTimelinePosition = nil
        previewWorker.cancel(); previewRequestedID = frame.id
        searchPresented = false; timelineCursor = frame.timestamp; display(frame)
        if !timeline.contains(where:{$0.id == frame.id}) { loadTimeline(around:frame.timestamp) }
    }
    private func requestPreview(_ moment:CapturedAppMoment) {
        guard previewRequestedID != moment.id else { return }
        previewRequestedID = moment.id
        if let frame = frameCache[moment.id] { previewWorker.cancel(); display(frame); return }
        previewWorker.submit(moment.id,apply:{ [weak self] frame in
            guard let self,let frame,self.previewRequestedID == frame.id else { return }
            self.display(frame)
        },fail:{ [weak self] in self?.error = $0.localizedDescription })
    }
    func back() {
        stopVideo()
        timelineDragging = false;cancelArchiveExtraction();cancelArchiveWindowLoad();archiveTimelinePosition = nil
        previewWorker.cancel(); navigationWorker.cancel(); transcriptWorker.cancel(); searchWorker.cancel()
        previewRequestedID = nil; requestedNavigationDate = nil; transcriptSessionID = nil
        selected = nil; timelineCursor = nil; inspectorOpen = false; player?.pause(); player = nil; lines = []; originalTranscriptLines = [];recordingDetail = nil
    }
    func returnToDesktop() {
        query = ""; appFilter = nil; starredOnly = false; trash = false; since = nil
        askOpen = false; searchPresented = false; back()
        loadTimeline(around:Date()); refreshTimelineActivity(force:true)
    }
    func showSearch() { back(); askOpen = false; searchPresented = true; searchLimit = 200; reloadSearch() }
    private func browseArchive(at time:Date) {
        previewWorker.cancel();previewRequestedID = nil
        selected = nil;inspectorOpen = false;askOpen = false
        stopVideo()
        transcriptWorker.cancel();transcriptSessionID = nil;lines = [];recordingDetail = nil
        cancelArchiveExtraction(keepNavigation:true)
        archiveTimelinePosition = time;archiveNavigationIntent=time
        archiveEpoch += 1
        // Scrubbing within the current bounded page does not need another SQL
        // round trip. Keep the previous motion alive while distant data loads.
        if let target=archiveWindow.navigationTarget(at:time,generation:archiveNavigationGeneration,requireCovered:true) {
            cancelArchiveWindowLoad();archiveNavigationTarget=target;archiveImagePreparation=archiveWindow.imagePreparation(for:target);return
        }
        submitArchiveWindow(ArchiveWindowQuery(day:Calendar.current.startOfDay(for:time),near:time,epoch:archiveEpoch),navigating:true)
    }

    func cancelArchiveExtraction(keepNavigation:Bool = false) {
        clearArchiveDestination()
        archiveNavigationGeneration += 1;archiveSettledGeneration=nil
        if !keepNavigation {
            archiveNavigationIntent=nil;archiveNavigationTarget=nil
            if archiveNavigating {cancelArchiveWindowLoad()}
        }
        archiveExtractionID = nil
        finishArchiveSettlementWaiters()
    }
    func beginTimelineDrag() {
        timelineDragging = true;cancelArchiveExtraction()
    }
    func endTimelineDrag() {
        timelineDragging = false
        publishArchiveExtractionIfReady()
    }
    func archiveNavigationDidSettle(_ target:ArchiveNavigationTarget) {
        guard archiveNavigationTarget == target,target.generation == archiveNavigationGeneration,
              archiveTimelinePosition == target.date else {return}
        archiveSettledGeneration=target.generation
        archiveScrollRow=target.row
        publishArchiveExtractionIfReady()
    }
    private func publishArchiveExtractionIfReady() {
        guard settings.glassArchiveEnabled,!timelineDragging,let target=archiveNavigationTarget,
              target.generation == archiveSettledGeneration else {return}
        if let id=target.recordID {
            guard archiveFrames.contains(where:{$0.id == id}) else {return}
            archiveExtractionID=id
        }
        finishArchiveSettlementWaiters()
    }
    private func finishArchiveSettlementWaiters() {
        let waiters=archiveSettlementWaiters;archiveSettlementWaiters=[]
        for waiter in waiters {waiter.resume()}
    }
    func waitForArchiveSettlement() async {
        await archiveNavigationWorker.waitUntilIdle()
        guard !timelineDragging,let target=archiveNavigationTarget,target.recordID != nil,
              archiveExtractionID == nil else {return}
        await withCheckedContinuation {archiveSettlementWaiters.append($0)}
    }
    func scrub(to date: Date, keepingInspector:Bool = false) {
        guard let first = timelineStart ?? timeline.first?.timestamp else { return }
        let time = max(first,min(Date(),date))
        timelineCursor = time
        if searchPresented { searchPresented = false; searchWorker.cancel() }
        if inspectorOpen && !keepingInspector { inspectorOpen = false }
        refreshTimelineActivity()
        if settings.glassArchiveEnabled && !(keepingInspector && inspectorOpen) { browseArchive(at:time);return }
        timelineDragging = false;cancelArchiveExtraction();cancelArchiveWindowLoad();archiveTimelinePosition = nil
        if navigationWindow?.contains(time) != true { loadTimeline(around:time); return }
        resolvePreview(at:time)
    }
    private func resolvePreview(at time:Date) {
        guard archiveTimelinePosition == nil else { return }
        guard activityWindow?.contains(time) == true else { return }
        let segment = timelineActivity.first { $0.start <= time && $0.end >= time && $0.kind == .application }
        if let segment,let moment = TimelineFrameLookup.nearest(to:time,in:timeline,segment:segment) { requestPreview(moment) }
        else {
            previewWorker.cancel(); previewRequestedID = nil
            if selected != nil {
                selected = nil;stopVideo();lines = [];originalTranscriptLines = []
                transcriptWorker.cancel();transcriptSessionID = nil;recordingDetail = nil
            }
        }
    }
    func panTimeline(points: Double) {
        let anchor = timelineDate
        scrub(to:anchor.addingTimeInterval(-points / timelineScale))
    }
    func setTimelineSpan(_ seconds:Double) {
        timelineSpan = TimelineZoom.clamp(seconds)
        refreshTimelineActivity()
    }
    func resizeTimeline(width:Double) { timelineViewportWidth = max(1,width); refreshTimelineActivity() }
    func displayedTimeline(at date:Date) -> [AppTimeSegment] {
        guard let current = capture.usageRecorder.current,
              let index = timelineActivity.firstIndex(where:{$0.id == current.id}) else { return timelineActivity }
        var result = timelineActivity
        let end = min(date,activityWindow?.end ?? date)
        result[index].end = max(result[index].end,end)
        if result.indices.contains(index+1),result[index+1].kind == nil {
            let gap = result[index+1]
            result[index+1] = AppTimeSegment(id:gap.id,appName:gap.appName,bundleID:gap.bundleID,start:min(end,gap.end),end:gap.end,kind:nil)
        }
        return result
    }
    func refreshTimelineActivity(force:Bool = false) {
        let date = timelineDate
        let visible = DateInterval(start:date.addingTimeInterval(-timelineSpan/2),end:date.addingTimeInterval(timelineSpan/2))
        if !force,let activityWindow,activityWindow.start <= visible.start,activityWindow.end >= visible.end { return }
        if !force,let requestedActivityWindow,requestedActivityWindow.start <= visible.start,requestedActivityWindow.end >= visible.end { return }
        let range = DateInterval(start:date.addingTimeInterval(-timelineSpan),end:date.addingTimeInterval(timelineSpan))
        requestedActivityWindow = range
        activityWorker.submit(TimelineActivityQuery(range:range,interval:settings.captureInterval),apply:{ [weak self] result in
            guard let self else { return }
            self.timelineActivity = result.segments; self.activityWindow = result.range; self.requestedActivityWindow = nil
            if self.timelineStart != result.firstDate { self.timelineStart = result.firstDate }
            if let cursor = self.timelineCursor,self.navigationWindow?.contains(cursor) == true { self.resolvePreview(at:cursor) }
        },fail:{ [weak self] in self?.requestedActivityWindow = nil; self?.error = $0.localizedDescription })
    }
    private func loadTimeline(around date: Date) {
        if let requestedNavigationDate,abs(requestedNavigationDate.timeIntervalSince(date)) < 30 { return }
        requestedNavigationDate = date
        navigationWorker.submit(TimelineNavigationQuery(date:date,trash:trash,since:since),apply:{ [weak self] result in
            guard let self else { return }
            self.timeline = result.moments; self.navigationWindow = result.coverage; self.requestedNavigationDate = nil
            if let cursor = self.timelineCursor {
                if result.coverage.contains(cursor) { self.resolvePreview(at:cursor) }
                else { self.loadTimeline(around:cursor) }
            }
        },fail:{ [weak self] in self?.requestedNavigationDate = nil; self?.error = $0.localizedDescription })
    }
    func waitForPendingLoads() async {
        repeat {
            await archiveRefreshTask?.value
            await archiveNavigationWorker.waitUntilIdle()
            await activityWorker.waitUntilIdle(); await navigationWorker.waitUntilIdle()
            await previewWorker.waitUntilIdle(); await transcriptWorker.waitUntilIdle(); await searchWorker.waitUntilIdle()
            // A maintenance notification can replace the debounce task during
            // any await above. Completion means the current refresh has applied,
            // not merely that an older, cancelled task has finished.
        } while archiveRefreshTask != nil || !archiveNavigationWorker.isIdle
    }
    func step(_ offset: Int) {
        guard !timeline.isEmpty else {return}
        let current = timelineCursor.flatMap { date in timeline.firstIndex { $0.timestamp == date } } ?? selected.flatMap{frame in timeline.firstIndex{$0.id == frame.id}} ?? timeline.count-1
        let next = current+offset
        if next >= 0 && next < timeline.count {
            if settings.glassArchiveEnabled && !inspectorOpen { scrub(to:timeline[next].timestamp) }
            else { timelineCursor = timeline[next].timestamp; requestPreview(timeline[next]) }
            return
        }
        guard let edge = offset < 0 ? timeline.first:timeline.last else {return}
        do {
            let frame = offset < 0 ? try libraryReader.frames(trash:trash,since:since,until:edge.timestamp.addingTimeInterval(-0.001),demo:false,limit:1).first : try libraryReader.frames(trash:trash,since:edge.timestamp.addingTimeInterval(0.001),demo:false,limit:1,ascending:true).first
            if let frame {select(frame)}
        } catch {self.error = error.localizedDescription}
    }
    func jump(to date: Date) {
        // Reuse the coalescing background navigation path; copying/selecting
        // transcript text never triggers a synchronous history reload.
        since = nil
        scrub(to: date, keepingInspector:true)
    }
    func star(_ frame: MemoryFrame) {
        mutate(frame,operation: { try $0.toggleStar(frame.id) },completion: { [weak self] updated in
            guard let self,let updated else { return }
            cache(updated)
            if selected?.id == frame.id { selected = updated }
        })
    }
    func delete(_ frame: MemoryFrame) {
        mutate(frame,operation: { try $0.moveToTrash(frame); return nil },completion: { [weak self] _ in
            guard let self else { return }
            if selected?.id == frame.id { back() }
            notify("Moved to Trash · restore from the menu")
        })
    }
    func restore(_ frame: MemoryFrame) {
        mutate(frame,operation: { try $0.restore(frame); return nil },completion: { [weak self] _ in
            guard let self else { return }
            if selected?.id == frame.id { back() }
            notify("Memory restored")
        })
    }
    private func mutate(_ frame:MemoryFrame,operation:@escaping @Sendable(MemoryStore) throws -> MemoryFrame?,completion:@escaping(MemoryFrame?)->Void) {
        guard pendingMutations.insert(frame.id).inserted else { return }
        let database = store
        Task {
            defer { pendingMutations.remove(frame.id) }
            do {
                let updated = try await Task.detached(priority:.userInitiated) { try operation(database) }.value
                completion(updated);reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); notify("Copied to clipboard") }
    func notify(_ text: String) {
        toastTask?.cancel(); toast = text
        toastTask = Task { try? await Task.sleep(for:.seconds(3)); if !Task.isCancelled { toast = nil } }
    }
    func hideOverlay() {
        cancelArchiveExtraction()
        if let overlay = window as? RewindOverlayWindow { overlay.dismiss(hideApplication:true) }
        else { window?.orderOut(nil); NSApp.hide(nil) }
    }
    func dismissTimeline() {
        if let overlay = window as? RewindOverlayWindow { overlay.dismiss(hideApplication:true) { [weak self] in self?.returnToDesktop() } }
        else { returnToDesktop(); hideOverlay() }
    }
    func interfaceVisibilityChanged(_ visible:Bool) {
        // Visibility stops capture; a short interaction budget also lets the
        // interface settle before starting another saved-media OCR job.
        interfaceVisible = visible
        foregroundWork.setVisible(visible)
        if !visible {stopVideo();cancelArchiveExtraction()}
        capture.setInterfaceVisible(visible)
        storageOptimizer.setInterfaceVisible(visible)
        recordingCoordinator.setInterfaceVisible(visible || storageClearing)
        CaptureDiagnostics(root:store.root).write("Recall interface visible=\(visible); recordingRequested=\(recordingRequested)")
    }
    func toggleRecording() {
        recordingCoordinator.request(!recordingRequested)
        if recordingAutomaticallyPaused { notify("Recording will start when you close Recall") }
    }
    func startRecording() async { recordingCoordinator.request(true);await recordingCoordinator.waitUntilSettled() }
    func stopRecording() async { recordingCoordinator.request(false);await recordingCoordinator.waitUntilSettled() }
    func shutDownRecording() async { await recordingCoordinator.shutdown();transcriptionTask?.cancel() }
    // Prevent a pending animation completion from restarting capture during quit.
    func prepareToQuit() { foregroundWork.stop();stopVideo();cancelArchiveRefresh();cancelArchiveWindowLoad();cancelArchiveExtraction();recordingCoordinator.request(false) }
    private func beginCapture() async throws {
        error = nil;capturePermissionRequired = false
        try await capture.start(settings:settings,allowed:{ [weak self] in self?.recordingCoordinator.state.shouldCapture == true })
        recordedFrames = 0;settings.onboardingComplete = true
        do { try persistSettings() } catch { notify("Recording started; preferences could not be saved") }
        indexingStatus = "Recording on this device"
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(300))
                guard !Task.isCancelled,let self else { break }
                self.recordingCoordinator.rotateSegment()
            }
        }
    }
    private func finishCapture() async {
        rotationTask?.cancel();rotationTask = nil
        do {
            if let session = try await capture.stop() { enqueueTranscription(session) }
            indexingStatus = "Recording paused"
        } catch { self.error = error.localizedDescription }
    }
    private func captureFailed(_ error:Error) {
        if error is CapturePermissionError { settingsTab = "permissions";settingsOpen = true }
        capturePermissionRequired = (error as NSError).code == -3801
        self.error = capturePermissionRequired
            ? "macOS refused screen capture for this copy of Recall. Open Privacy & Security → Screen Recording and allow /Applications/Recall.app."
            : error.localizedDescription
    }
    private func enqueueTranscription(_ session:RecordingSession) {
        guard !transcriptionQueue.contains(where:{$0.id == session.id}) else { return }
        if settings.transcriptionEnabled,session.hasAudio { recognitionActivity.set(.queued,for:.recording(session.id)) }
        if selected?.sessionID == session.id { loadRecordingDetail(session.id) }
        transcriptionQueue.append(session);speechRecognition.pending = transcriptionQueue.count;persistTranscriptionQueue()
        guard transcriptionTask == nil else { return }
        transcriptionTask = Task(priority:.utility) { [weak self] in
            guard let self else { return }
            defer { transcriptionTask = nil }
            while !transcriptionQueue.isEmpty,!Task.isCancelled {
                let next = transcriptionQueue[0]
                await transcribe(next)
                guard !Task.isCancelled else { return }
                transcriptionQueue.removeFirst();speechRecognition.pending = transcriptionQueue.count;persistTranscriptionQueue()
            }
        }
    }
    private func persistTranscriptionQueue() {
        do { try JSONEncoder().encode(transcriptionQueue.map(\.id)).write(to:store.root.appendingPathComponent("pending-transcriptions.json"),options:.atomic) }
        catch { CaptureDiagnostics(root:store.root).write("Could not checkpoint pending transcription work") }
    }
    func transcribe(_ session: RecordingSession) async {
        defer { storageOptimizer.enqueue(session.id) }
        guard settings.transcriptionEnabled, session.hasAudio else {
            recognitionActivity.set(nil,for:.recording(session.id));return
        }
        speechIssue = nil
        defer { speechRecognition.active = false }
        recognitionActivity.set(.processing,for:.recording(session.id))
        speechRecognition.active = true
        do {
            var tracks: [(URL,Double,String)] = []
            if let path = session.systemAudioPath {tracks.append((store.root.appendingPathComponent(path),session.systemAudioOffset ?? 0,"Meeting"))}
            if let path = session.microphoneAudioPath {tracks.append((store.root.appendingPathComponent(path),session.microphoneAudioOffset ?? 0,"You"))}
            if tracks.isEmpty,let file = try await CaptureEngine.audioFile(for:session,root:store.root) {tracks.append((file,0,"Audio"))}
            guard !tracks.isEmpty else {
                indexingStatus = "No audio track in this recording"
                let database = store
                try await Task.detached(priority:.utility) { try database.saveRecognitionOutcome(session.id,state:.noAudio) }.value
                recognitionActivity.set(.noAudio,for:.recording(session.id));return
            }
            var result: [TranscriptLine] = []
            indexingStatus = "Transcribing audio…"
            for (file,offset,speaker) in tracks {
                try Task.checkCancellation()
                var transcript = try await ModelClient.transcribe(file:file,sessionID:session.id,start:session.startedAt.addingTimeInterval(offset),profile:settings.transcription,key:SecretStore.read("transcription"))
                for index in transcript.indices {transcript[index].speaker = speaker};result += transcript
            }
            result.sort{$0.timestamp < $1.timestamp}
            let database = store, completed = result
            let page = try await Task.detached(priority: .utility) {
                guard try database.replaceExistingSessionTranscript(sessionID: session.id, lines: completed) else { return nil as TranscriptPage? }
                return TranscriptPage(completed)
            }.value
            if let page, selected?.sessionID == session.id { lines = page.lines; originalTranscriptLines = page.original }
            recognitionActivity.set(page.map { $0.lines.isEmpty ? .empty:.complete },for:.recording(session.id))
            if selected?.sessionID == session.id { loadRecordingDetail(session.id) }
            if searchPresented { reloadSearch() }
            indexingStatus = recording ? "Recording on this device" : "Everything stays on this device"
        } catch is CancellationError { recognitionActivity.set(.queued,for:.recording(session.id));return }
        catch {
            speechIssue = "Transcription needs attention. The audio is saved locally. " + error.localizedDescription
            let state = MediaRecognitionState.failed("Transcription of this recording failed. The audio is saved locally. " + error.localizedDescription)
            let database = store
            try? await Task.detached(priority:.utility) { try database.saveRecognitionOutcome(session.id,state:state) }.value
            recognitionActivity.set(state,for:.recording(session.id))
            indexingStatus = "Transcription needs attention"
            CaptureDiagnostics(root: store.root).write("Speech recognition failed; domain=\((error as NSError).domain); code=\((error as NSError).code)")
        }
    }
    func persistSettings() throws { try NativeCoreCLI.saveConfiguration(settings,root:store.root) }
    func toggleAppearance() {
        settings.appearance = settings.appearance == .warmDay ? .deepNight:.warmDay
        do { try persistSettings() } catch { notify("Appearance preference could not be saved") }
    }
    func saveSettings(_ new: AppSettings, chatKey: String, speechKey: String,updateKeys:Bool = true,applyRetention:Bool = true) async throws {
        try new.shortcuts.validate()
        _ = try ModelClient.endpoint(new.chat,path:"models")
        if new.transcriptionEnabled { _ = try ModelClient.endpoint(new.transcription,path:"audio/transcriptions") }
        let old = settings
        // Do this before changing shortcuts, writing preferences, or stopping a
        // working capture. A denied microphone must not interrupt screen capture.
        if new.microphone && (!old.microphone || recording) {
            try await CapturePermissions.ensureMicrophone(enabled:true)
        }
        let shortcutsChanged = old.shortcuts != new.shortcuts
        if shortcutsChanged { try configureShortcuts?(new.shortcuts) }
        do {
            if updateKeys {try SecretStore.save(chatKey,account:"chat"); try SecretStore.save(speechKey,account:"transcription")}
            if new.launchAtLogin != old.launchAtLogin {
                if new.launchAtLogin { try SMAppService.mainApp.register() }
                else if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
            }
            try NativeCoreCLI.saveConfiguration(new,root:store.root)
        } catch {
            if shortcutsChanged { try? configureShortcuts?(old.shortcuts) }
            throw error
        }
        let captureChanged = old.captureInterval != new.captureInterval || old.displayID != new.displayID || old.systemAudio != new.systemAudio || old.microphone != new.microphone || old.excludedApps != new.excludedApps || old.excludedNames != new.excludedNames
        let restart = recording && captureChanged
        if restart { await stopRecording() }
        settings = new
        NotificationCenter.default.post(name:.recallSettingsSaved,object:nil)
        let database = store
        if applyRetention {try await Task.detached(priority:.utility) { try database.applyRetention(days:new.retentionDays) }.value}
        reload(); settingsOpen = false; notify("Settings saved")
        if restart { await startRecording() }
    }
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !asking,!question.isEmpty else { return }
        asking = true; askError = nil; askStatus = "Finding relevant memories…"
        askGeneration += 1; let generation = askGeneration
        let history = messages, previous = messages.last(where:{$0.role == "user"})?.text
        let db = evidenceStore, scope = since, app = appFilter, profile = settings.chat
        messages.append(ChatMessage(role:"user",text:question))
        chatTask = Task { [self] in
            do {
                let worker = Task.detached(priority:.userInitiated) {
                    try Task.checkCancellation()
                    return try db.evidence(question,since:scope,app:app,previous:previous,limit:profile.isBuiltin ? 5:12)
                }
                let evidence = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                try Task.checkCancellation(); guard askGeneration == generation else { return }
                guard !evidence.sources.isEmpty else {
                    messages.append(ChatMessage(role:"assistant",text:"No matching memories were found in this scope. Try a more specific topic, change the application or date filter, or record the content first."))
                    asking = false; askStatus = ""; return
                }
                askStatus = "Answering from \(evidence.sources.count) memories…"
                let reply = ChatMessage(role:"assistant",text:"",sources:evidence.sources); messages.append(reply)
                let answer = try await ModelClient.answer(question:question,sources:evidence.sources,transcripts:evidence.transcripts,history:history,profile:profile,key:SecretStore.read("chat")) { [weak self] partial in
                    guard let self,self.askGeneration == generation,let index = self.messages.firstIndex(where:{$0.id == reply.id}) else { return };self.messages[index].text = partial
                }
                if !Task.isCancelled,askGeneration == generation,let index = messages.firstIndex(where:{$0.id == reply.id}) { messages[index].text = answer }
            } catch {
                if askGeneration == generation {
                    if !Task.isCancelled { askError = error.localizedDescription }
                    messages.removeAll { $0.role == "assistant" && $0.text.isEmpty }
                }
            }
            if askGeneration == generation { asking = false; askStatus = "" }
        }
    }
    func retryAsk() {
        guard !asking,let index = messages.lastIndex(where:{$0.role == "user"}) else { return }
        let question = messages[index].text
        messages.removeSubrange(index...); ask(question)
    }
    func cancelAsk() { askGeneration += 1; chatTask?.cancel(); asking = false; askStatus = ""; messages.removeAll { $0.role == "assistant" && $0.text.isEmpty } }
    private var videoLoadTask:Task<Void,Never>?
    private var videoGeneration=0
    private var preparingPlayer:AVPlayer?
    func stopVideo() {
        videoGeneration += 1;videoLoadTask?.cancel();videoLoadTask=nil
        preparingPlayer?.pause();preparingPlayer?.currentItem?.cancelPendingSeeks();preparingPlayer=nil
        player?.pause();player?.currentItem?.cancelPendingSeeks();player=nil;videoReady=false
    }
    func videoDidBecomeReady(_ candidate:AVPlayer) {
        guard player === candidate,!videoReady,inspectorOpen else {return}
        videoReady=true;candidate.play()
    }
    func videoDidFail(_ candidate:AVPlayer,message:String) {
        guard player === candidate else {return}
        stopVideo();notify("Playback: "+message)
    }
    func waitForVideoLoad() async {await videoLoadTask?.value}
    func openVideo() {
        guard let frame = selected,let id = frame.sessionID else { return }
        stopVideo()
        let generation=videoGeneration,meeting=meetingView
        let time = max(frame.timestamp,min(timelineCursor ?? frame.timestamp,frame.endTimestamp ?? frame.timestamp))
        videoLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reader = libraryReader
                guard let session = try await Task.detached(priority:.userInitiated,operation:{try reader.session(id)}).value else {throw RewindError.message("The recording is no longer available.")}
                guard !Task.isCancelled,videoGeneration == generation else {return}
                guard session.endedAt != nil else { notify("Pause recording to play this active segment");return }
                let asset = try await RecordingPlayback.asset(session:session,root:store.root)
                guard !Task.isCancelled,videoGeneration == generation,selected?.id == frame.id,inspectorOpen,meetingView == meeting else { return }
                guard try await asset.load(.isPlayable),!(try await asset.loadTracks(withMediaType:.video)).isEmpty else {throw RewindError.message("This recording has no playable video.")}
                let player = AVPlayer(playerItem:AVPlayerItem(asset:asset))
                guard !Task.isCancelled,videoGeneration == generation else {return}
                preparingPlayer=player
                let duration=try await asset.load(.duration).seconds
                let offset=max(0,min(time.timeIntervalSince(session.startedAt),duration.isFinite ? max(0,duration-1/600):.greatestFiniteMagnitude))
                let completed=await player.seek(to:CMTime(seconds:offset,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                guard !Task.isCancelled,videoGeneration == generation,selected?.id == frame.id,inspectorOpen,meetingView == meeting else {player.pause();return}
                guard completed else {throw RewindError.message("The recording could not seek to this moment.")}
                preparingPlayer=nil
                // Seeking is not presentation: the mounted AVPlayerView must
                // acknowledge its first frame before audio or video starts.
                self.player = player
            } catch { if !Task.isCancelled,videoGeneration == generation {stopVideo();notify("Playback: " + error.localizedDescription)} }
        }
    }
    func importImages() {
        let panel = NSOpenPanel();panel.level = NSWindow.Level(rawValue:(window?.level.rawValue ?? 0)+1); panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            working = true; defer { working = false }
            for url in panel.urls {
                do {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { continue }
                    var frame = MemoryFrame(timestamp:Date(),appName:"Imported",bundleID:"",title:url.deletingPathExtension().lastPathComponent,imagePath:"",text:"",regions:[])
                    let result = try await Task.detached(priority:.utility) {
                        let text = try NativeOCR.recognize(image)
                        return ScreenIndexResult(text:text.0,regions:text.1,archive:try ScreenArchive.pack(image))
                    }.value
                    frame.text = result.text;frame.regions = result.regions;frame.sourceURL = result.sourceURL;frame.indexingComplete = true
                    try store.saveRecognizedFrame(frame,archive:result.archive)
                } catch { self.error = error.localizedDescription }
            }
            query = ""; appFilter = nil; since = nil; reload(); notify("Images indexed locally")
        }
    }
    func exportMemories() {
        let panel = NSOpenPanel();panel.level = NSWindow.Level(rawValue:(window?.level.rawValue ?? 0)+1); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let destination = directory.appendingPathComponent("Recall Export \(Int(Date().timeIntervalSince1970))")
            let memories = try store.frames(query:query,app:appFilter,starred:starredOnly,trash:trash,since:since,demo:false,limit:10000)
            try store.export(to:destination,frames:memories); NSWorkspace.shared.activateFileViewerSelecting([destination]); notify("Exported \(memories.count) memories")
        } catch { self.error = error.localizedDescription }
    }
}
