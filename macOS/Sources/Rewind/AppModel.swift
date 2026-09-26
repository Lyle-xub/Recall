import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let store: MemoryStore
    let capture: CaptureEngine
    let storageOptimizer: StorageOptimizer
    @Published var settings: AppSettings
    @Published private(set) var interfaceVisible = false
    @Published var frames: [MemoryFrame] = []
    @Published var archiveFrames: [MemoryFrame] = []
    @Published var archiveTimelinePosition:Date?
    @Published private(set) var archiveExtractionID:String?
    private var archiveSettleTask:Task<Void,Never>?
    @Published private(set) var timelineDragging = false
    private let archiveNavigationWorker:LatestRequestWorker<Date,[MemoryFrame]>
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
    private var pendingMutations = Set<String>()
    private var searchTask: Task<Void,Never>?
    private var rotationTask: Task<Void,Never>?
    private var chatTask: Task<Void,Never>?
    private var askGeneration = 0
    private var toastTask: Task<Void,Never>?
    var configureShortcuts: ((ShortcutConfiguration) throws -> Void)?
    var window: NSWindow?

    init(root: URL? = nil) throws {
        let root = root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RewindReplica")
        store = try MemoryStore(root:root)
        storageOptimizer = StorageOptimizer(store:store)
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
        archiveNavigationWorker = LatestRequestWorker { try archiveDB.archiveFrames(around:$0,near:$0) }
        transcriptWorker = LatestRequestWorker { try RecordingRecognitionDetail.load($0,store:previewDB) }
        searchWorker = LatestRequestWorker { try MemorySearchPage.load($0,store:searchDB) }
        capture = CaptureEngine(store:store)
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
            if archiveFrames.contains(where:{$0.imagePath == source || $0.meetingImagePath == source}) { archiveFrames = archiveFrames.map(refreshed) }
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
            if let index = archiveFrames.firstIndex(where: { $0.id == frame.id }) { archiveFrames[index] = frame }
            if frameCache[frame.id] != nil { cache(frame) }
            if selected?.id == frame.id { selected = frame }
            if searchPresented { reloadSearch() }
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
        try? store.applyRetention(days:settings.retentionDays)
        reload()
        onboardingOpen = OnboardingPolicy.shouldPresent(completed:settings.onboardingComplete,memories:total)
        launchFilmOpen = OnboardingPolicy.shouldPlayFilm(settings:settings,memories:total)
        capture.resumePendingIndexing()
        storageOptimizer.resume()
        let pendingURL = store.root.appendingPathComponent("pending-transcriptions.json")
        if let data = try? Data(contentsOf:pendingURL),let ids = try? JSONDecoder().decode([String].self,from:data) {
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
        if let delta = calendar.dateComponents([.day],from:archiveDay,to:calendar.startOfDay(for:frame.timestamp)).day,abs(delta) <= 2 {
            archiveFrames.removeAll { $0.imagePath == frame.imagePath && calendar.isDate($0.timestamp,inSameDayAs:frame.timestamp) }
            archiveFrames.insert(frame,at:0)
            archiveFrames = ArchiveDayLayout.columns(frames:archiveFrames,around:archiveDay).flatMap(\.records)
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
            archiveFrames = try libraryReader.archiveFrames(around:archiveDay,near:archiveTimelinePosition)
            refreshTimelineActivity(force:true)
            if searchPresented { reloadSearch() }
            if let selected,!timeline.contains(where:{$0.id == selected.id}) { loadTimeline(around:selected.timestamp) }
        } catch { self.error = error.localizedDescription }
    }
    func moveArchiveDay(by offset:Int) {
        timelineDragging = false;cancelArchiveExtraction();archiveNavigationWorker.cancel();archiveTimelinePosition = nil;timelineCursor = nil
        guard let day = Calendar.current.date(byAdding:.day,value:offset,to:archiveDay) else { return }
        do { let records = try libraryReader.archiveFrames(around:day);archiveDay = day;archiveFrames = records }
        catch { self.error = error.localizedDescription }
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
        videoLoadTask?.cancel()
        let frame = canonicalImages(frame)
        cache(frame); player?.pause(); player = nil
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
        timelineDragging = false;cancelArchiveExtraction();archiveNavigationWorker.cancel();archiveTimelinePosition = nil
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
        videoLoadTask?.cancel()
        timelineDragging = false;cancelArchiveExtraction();archiveNavigationWorker.cancel();archiveTimelinePosition = nil
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
        player?.pause();player = nil;videoLoadTask?.cancel()
        transcriptWorker.cancel();transcriptSessionID = nil;lines = [];recordingDetail = nil
        cancelArchiveExtraction()
        archiveTimelinePosition = time
        if !timelineDragging { scheduleArchiveExtraction(delay:.milliseconds(220)) }
        let records = archiveFrames.filter { Calendar.current.isDate($0.timestamp,inSameDayAs:time) }
        if Calendar.current.isDate(archiveDay,inSameDayAs:time),
           let first = records.map(\.timestamp).min(),let last = records.map(\.timestamp).max(),time >= first,time <= last {
            archiveNavigationWorker.cancel();return
        }
        archiveNavigationWorker.submit(time,apply:{ [weak self] records in
            guard let self,self.settings.glassArchiveEnabled,self.archiveTimelinePosition == time else { return }
            self.archiveDay = Calendar.current.startOfDay(for:time);self.archiveFrames = records
        },fail:{ [weak self] in self?.error = $0.localizedDescription })
    }
    func cancelArchiveExtraction() {
        archiveSettleTask?.cancel();archiveSettleTask = nil
        archiveExtractionID = nil
    }
    func beginTimelineDrag() {
        timelineDragging = true;cancelArchiveExtraction()
    }
    func endTimelineDrag() {
        timelineDragging = false
        scheduleArchiveExtraction(delay:.zero)
    }
    private func scheduleArchiveExtraction(delay:Duration) {
        guard settings.glassArchiveEnabled,let time = archiveTimelinePosition else { return }
        archiveSettleTask?.cancel()
        archiveSettleTask = Task { [weak self] in
            do { try await Task.sleep(for:delay) } catch { return }
            guard let self else { return }
            await self.archiveNavigationWorker.waitUntilIdle()
            guard !Task.isCancelled,self.settings.glassArchiveEnabled,!self.timelineDragging,
                  self.archiveTimelinePosition == time else { return }
            self.archiveExtractionID = self.archiveFrames
                .filter { Calendar.current.isDate($0.timestamp,inSameDayAs:time) }
                .min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }?.id
        }
    }
    func waitForArchiveSettlement() async { await archiveSettleTask?.value }
    func scrub(to date: Date, keepingInspector:Bool = false) {
        guard let first = timelineStart ?? timeline.first?.timestamp else { return }
        let time = max(first,min(Date(),date))
        timelineCursor = time
        if searchPresented { searchPresented = false; searchWorker.cancel() }
        if inspectorOpen && !keepingInspector { inspectorOpen = false }
        refreshTimelineActivity()
        if settings.glassArchiveEnabled && !(keepingInspector && inspectorOpen) { browseArchive(at:time);return }
        timelineDragging = false;cancelArchiveExtraction();archiveNavigationWorker.cancel();archiveTimelinePosition = nil
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
                selected = nil;player?.pause();player = nil;lines = [];originalTranscriptLines = []
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
        await archiveNavigationWorker.waitUntilIdle()
        await activityWorker.waitUntilIdle(); await navigationWorker.waitUntilIdle()
        await previewWorker.waitUntilIdle(); await transcriptWorker.waitUntilIdle(); await searchWorker.waitUntilIdle()
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
        // Visibility controls capture, never processing of already saved media.
        interfaceVisible = visible
        capture.setInterfaceVisible(visible)
        storageOptimizer.setInterfaceVisible(visible)
        recordingCoordinator.setInterfaceVisible(visible)
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
    func prepareToQuit() { cancelArchiveExtraction();recordingCoordinator.request(false) }
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
    func persistSettings() throws { try JSONEncoder().encode(settings).write(to:store.root.appendingPathComponent("settings.json"),options:.atomic) }
    func toggleAppearance() {
        settings.appearance = settings.appearance == .warmDay ? .deepNight:.warmDay
        do { try persistSettings() } catch { notify("Appearance preference could not be saved") }
    }
    func saveSettings(_ new: AppSettings, chatKey: String, speechKey: String) async throws {
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
            try SecretStore.save(chatKey,account:"chat"); try SecretStore.save(speechKey,account:"transcription")
            if new.launchAtLogin != old.launchAtLogin {
                if new.launchAtLogin { try SMAppService.mainApp.register() }
                else if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
            }
            try JSONEncoder().encode(new).write(to:store.root.appendingPathComponent("settings.json"),options:.atomic)
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
        try await Task.detached(priority:.utility) { try database.applyRetention(days:new.retentionDays) }.value
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
    func openVideo() {
        guard let frame = selected,let id = frame.sessionID else { return }
        videoLoadTask?.cancel()
        let time = max(frame.timestamp,min(timelineCursor ?? frame.timestamp,frame.endTimestamp ?? frame.timestamp))
        videoLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reader = libraryReader
                guard let session = try await Task.detached(priority:.userInitiated,operation:{try reader.session(id)}).value else { return }
                guard session.endedAt != nil else { notify("Pause recording to play this active segment");return }
                let asset = try await RecordingPlayback.asset(session:session,root:store.root)
                guard !Task.isCancelled,selected?.id == frame.id,inspectorOpen else { return }
                let player = AVPlayer(playerItem:AVPlayerItem(asset:asset))
                await player.seek(to:CMTime(seconds:max(0,time.timeIntervalSince(session.startedAt)),preferredTimescale:600))
                guard !Task.isCancelled,selected?.id == frame.id,inspectorOpen else { return }
                self.player = player;player.play()
            } catch { if !Task.isCancelled { notify("Playback: " + error.localizedDescription) } }
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
