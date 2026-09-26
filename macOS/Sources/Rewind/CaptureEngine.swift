import AppKit
import ScreenCaptureKit
import Vision
import AVFoundation
import CoreImage
import ImageIO

enum NativeOCR {
    private static let recovery = OCRRecovery(defaults:.standard)
    private static let labelLock = NSLock()
    private static var lastBackend = "vision"
    static var backendLabel:String {labelLock.withLock {lastBackend}}
    static func recognize(_ image: CGImage,source:URL? = nil) throws -> (String,[TextRegion]) {
        if NeuralOCR.root != nil,let result = try? NeuralOCR.shared.recognize(image,source:source) {labelLock.withLock {lastBackend = "ppocr-v6-small"};return result}
        try Task.checkCancellation()
        return try recovery.recognize(primary:{try perform(image,compatible:false)},compatible:{try perform(image,compatible:true)})
    }
    static func perform(_ image:CGImage,compatible:Bool) throws -> (String,[TextRegion]) {
        if compatible {labelLock.withLock {lastBackend = "local-lstm"};return try LocalOCR.recognize(image)}
        labelLock.withLock {lastBackend = "vision"}
        return try autoreleasepool {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.003
        request.recognitionLanguages = ["en-US","zh-Hans"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        return try BoundedOCRWork.run(timeout:8,cancel:{request.cancel()}) {
            try autoreleasepool {
                try VNImageRequestHandler(cgImage:image).perform([request])
                let regions = (request.results ?? []).compactMap { observation -> TextRegion? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return TextRegion(text:candidate.string,x:box.minX,y:1-box.maxY,width:box.width,height:box.height)
                }
                return (regions.map(\.text).joined(separator:"\n"),regions)
            }
        }
        }
    }
}

final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label:"studio.rewind.frames",qos:.utility)
    let interval: Double
    var onImage: ((CGImage,Date) -> Void)?
    var onVideoSample: ((CMSampleBuffer) -> Void)?
    var onUnavailable: (() -> Void)?
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let lock = NSLock()
    private var requestGeneration = 0
    private var consumedGeneration = 0
    private var latestBuffer: CVPixelBuffer?
    private var last = Date.distantPast
    private var heartbeat: DispatchSourceTimer?
    init(interval: Double) { self.interval = interval }
    func beginSampling() {
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+interval,repeating:interval)
        timer.setEventHandler { [weak self] in self?.consume(nil,status:.idle,time:Date()) }
        heartbeat = timer; timer.resume()
    }
    func stopSampling() { heartbeat?.cancel(); heartbeat = nil }
    func flush()async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    deinit { heartbeat?.cancel() }
    func requestFrame() { lock.withLock { requestGeneration += 1 } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        consumeScreenSample(sampleBuffer,time:Date())
    }
    func consumeScreenSample(_ sampleBuffer:CMSampleBuffer,time:Date) {
        guard sampleBuffer.isValid else { return }
        onVideoSample?(sampleBuffer)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) ?? .complete
        consume(sampleBuffer.imageBuffer,status:status,time:time)
    }
    func consume(_ buffer:CVPixelBuffer?,status:SCFrameStatus,time now:Date) {
        guard status == .complete || status == .idle else {
            latestBuffer = nil; onUnavailable?(); return
        }
        // Retain the newest surface even between OCR intervals; the final change
        // before a screen becomes idle must be the image used by its heartbeat.
        if status == .complete, let buffer { latestBuffer = buffer }
        let generation = lock.withLock { requestGeneration }
        let forced = generation != consumedGeneration
        guard now.timeIntervalSince(last) >= interval || forced else { return }
        // An idle sample has no new image. Reuse only the last valid image;
        // never reuse it across blank/suspended frames or an app activation.
        if status == .idle, forced { return }
        guard let buffer = latestBuffer else { return }
        let pixels = CIImage(cvPixelBuffer:buffer)
        guard let image = context.createCGImage(pixels,from:pixels.extent) else { return }
        consumedGeneration = generation; last = now
        onImage?(image,now)
    }
}

@MainActor final class CaptureEngine: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var sink: FrameSink?
    private var videoTrack:LightweightVideoSink?
    private var systemTrack: AudioTrackSink?
    private var microphoneTrack: AudioTrackSink?
    private var current: RecordingSession?
    private var settings = AppSettings()
    private var captureTasks: [UUID:Task<Void,Never>] = [:]
    private var ocrQueue: [MemoryFrame] = []
    private var ocrTask: Task<Void,Never>?
    private let indexProcessor = ScreenIndexProcessor()
    private let frameWriter:CaptureFrameStore
    private var continuityID = UUID().uuidString
    private var activationObserver: NSObjectProtocol?
    private var capturing = false
    private var interfaceVisible = false
    private var nextIndexingAllowed = ContinuousClock.now
    private var starting = false
    private let diagnostics: CaptureDiagnostics
    private var meetingWindow: SCWindow?
    private var lastWindowsRefresh = Date.distantPast
    private var meetingRefreshTask: Task<Void,Never>?
    private let store: MemoryStore
    private var selectedDisplayID: CGDirectDisplayID?
    let usageRecorder: AppUsageRecorder
    private var usageHeartbeat: Task<Void,Never>?
    private var screenAvailable = true
    var onUsageChanged: (() -> Void)?
    var onIndexed: ((MemoryFrame) -> Void)?
    var onFrame: ((MemoryFrame) -> Void)?
    var onFrameExtended: ((String,Date) -> Void)?
    var onError: ((String) -> Void)?
    private var recognizingText = false
    private var processingFrame = false
    var onRecognitionProgress: ((RecognitionProgress) -> Void)?
    var onFrameRecognition: ((String,MediaRecognitionState?) -> Void)?
    private func publishRecognitionProgress() {
        onRecognitionProgress?(RecognitionProgress(pending:ocrQueue.count + (processingFrame ? 1:0), active:recognizingText))
    }
    var onIndexingIssue: ((String?) -> Void)?
    var onStopped: (() -> Void)?

    init(store: MemoryStore) {
        self.store = store
        frameWriter = CaptureFrameStore(store:store)
        usageRecorder = AppUsageRecorder(store:store,backgroundWrites:true)
        diagnostics = CaptureDiagnostics(root:store.root)
        super.init()
        usageRecorder.onError = { [weak self] error in self?.diagnostics.write("Application usage save failed; code=\((error as NSError).code)") }
        usageRecorder.onChange = { [weak self] in self?.onUsageChanged?() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let date = Date()
            Task { @MainActor in self?.foregroundChanged(app:app,at:date) }
        }
        for event in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName:event,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in await self?.refreshExclusions() }
            }
        }
    }
    private func foregroundChanged(app: NSRunningApplication?, at date:Date) {
        guard current != nil else { return }
        recordUsage(app:app,at:date)
        if settings.excludedApps.contains(app?.bundleIdentifier ?? "") || app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            continuityID = UUID().uuidString
            Task { [weak self] in await self?.refreshExclusions() }
        }
        sink?.requestFrame()
    }
    private func recordUsage(app:NSRunningApplication?,at date:Date) {
        guard capturing else { return }
        let target = CaptureForeground.resolve(app:app,displayID:selectedDisplayID)
        let identity = screenAvailable ? AppUsageIdentity.resolved(name:target.name,bundleID:target.bundleID,ownApp:false,settings:settings):.unavailable
        do { try usageRecorder.transition(to:identity,at:date) }
        catch { diagnostics.write("Application usage save failed; code=\((error as NSError).code)") }
    }
    private func contentFilter(_ content:SCShareableContent,display:SCDisplay)->SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier,ownID = Bundle.main.bundleIdentifier ?? "studio.rewind.replica"
        let excluded = content.applications.filter {settings.excludedApps.contains($0.bundleIdentifier) || $0.bundleIdentifier == ownID || $0.processID == ownPID}
        let excludedPIDs = Set(excluded.map(\.processID))
        let ownWindows = CaptureWindowIDs.valid(NSApp.windows.map(\.windowNumber))
        // Some macOS versions omit status-level panels from the application
        // inventory. Exclude their window IDs as well, but never "except" a
        // window whose app is excluded: that would explicitly include it again.
        let extra = content.windows.filter {window in
            ownWindows.contains(window.windowID) && !excludedPIDs.contains(window.owningApplication?.processID ?? -1)
        }
        diagnostics.write("Capture filter; ownAppExcluded=\(excludedPIDs.contains(ownPID)); extraOwnWindows=\(extra.count)")
        return SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:extra)
    }
    private func refreshExclusions() async {
        guard capturing, let stream, let id = selectedDisplayID else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let display = content.displays.first(where:{$0.displayID == id}) else {return}
            try await stream.updateContentFilter(contentFilter(content,display:display))
        } catch {
            _ = try? await stop();onStopped?();onError?("Recording paused because the exclusion filter could not be updated.")
        }
    }
    static func displays() async throws -> [SCDisplay] { try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true).displays }
    func resumePendingIndexing() {
        ocrQueue += ((try? store.pendingIndexFrames()) ?? []).reversed()
        publishRecognitionProgress()
        if !ocrQueue.isEmpty { startOCRIfNeeded() }
    }

    func setInterfaceVisible(_ visible:Bool) {
        interfaceVisible = visible
        // Stop accepting new screen pixels; saved screenshots keep indexing.
    }
    func start(settings: AppSettings,allowed:() -> Bool = { true }) async throws {
        guard stream == nil, !starting else { throw RewindError.message("A recording is already starting or running.") }
        starting = true; defer { starting = false }
        self.settings = settings
        diagnostics.write("Start requested; screenPermission=\(CGPreflightScreenCaptureAccess()); bundle=\(Bundle.main.bundleURL.path)")
        do {
            try await CapturePermissions.ensureMicrophone(enabled:settings.microphone)
            let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard allowed() else { throw CancellationError() }
            updateMeetingWindow(content)
            lastWindowsRefresh = Date()
            let chosenID = CaptureDisplaySelection.choose(available:content.displays.map(\.displayID),preferred:settings.displayID,main:CGMainDisplayID())
            guard let display = content.displays.first(where:{$0.displayID == chosenID}) else { throw RewindError.message("The selected display is not connected. Choose Primary display in Recording settings.") }
            diagnostics.write("Display selected=\(display.displayID); primary=\(CGMainDisplayID()); available=\(content.displays.map { String($0.displayID) }.joined(separator:","))")
            selectedDisplayID = display.displayID
            let filter = contentFilter(content,display:display)
            let config = SCStreamConfiguration()
            let pixels = CaptureDimensions.native(width:filter.contentRect.width,height:filter.contentRect.height,scale:Double(filter.pointPixelScale),fallbackWidth:display.width,fallbackHeight:display.height)
            config.width = pixels.width; config.height = pixels.height
            config.minimumFrameInterval = CMTime(value:1,timescale:3)
            config.queueDepth = 3; config.showsCursor = true
            config.capturesAudio = settings.systemAudio; config.captureMicrophone = settings.microphone
            config.excludesCurrentProcessAudio = true; config.sampleRate = 48000; config.channelCount = 2
            let session = RecordingSession(startedAt:Date(),videoPath:"recordings/\(UUID().uuidString).mp4",appName:NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screen",hasAudio:settings.systemAudio || settings.microphone,storagePolicy:2,videoOptimizationChecked:true,videoOptimizationVersion:VideoArchive.policyVersion,usesExternalAudio:true,audioSources:[settings.systemAudio ? "system":nil,settings.microphone ? "microphone":nil].compactMap{$0})
            let hostStart = CMClockGetTime(CMClockGetHostTimeClock())
            let stream = SCStream(filter:filter,configuration:config,delegate:self)
            let sink = FrameSink(interval:settings.captureInterval)
            continuityID = UUID().uuidString
            sink.onImage = { [weak self] image,time in Task { @MainActor in self?.receive(image,time:time,sessionID:session.id) } }
            sink.onUnavailable = { [weak self] in Task { @MainActor in
                guard let self, self.current?.id == session.id else { return }
                self.continuityID = UUID().uuidString
                if self.screenAvailable { self.screenAvailable = false; self.recordUsage(app:nil,at:Date()) }
            } }
            try stream.addStreamOutput(sink,type:.screen,sampleHandlerQueue:sink.queue)
            if settings.systemAudio {let track = AudioTrackSink(root:store.root,path:"recordings/\(session.id)-system.m4a",start:session.startedAt,hostStart:hostStart);try stream.addStreamOutput(track,type:.audio,sampleHandlerQueue:track.queue);systemTrack = track}
            if settings.microphone {let track = AudioTrackSink(root:store.root,path:"recordings/\(session.id)-microphone.m4a",start:session.startedAt,hostStart:hostStart);try stream.addStreamOutput(track,type:.microphone,sampleHandlerQueue:track.queue);microphoneTrack = track}
            let video = try LightweightVideoSink(url:store.root.appendingPathComponent(session.videoPath),width:pixels.width,height:pixels.height,startedAt:session.startedAt,hostStart:hostStart)
            video.onError = { [weak self] error in Task { @MainActor in
                guard let self,self.current?.id == session.id else { return }
                _ = try? await self.stop();self.onStopped?();self.onError?("Recording failed: \(error.localizedDescription)")
            } }
            // One system screen output fans out to both branches. Registering
            // two screen destinations can silently replace the first on macOS.
            sink.onVideoSample = { [weak video] sample in video?.append(sample) }
            self.sink = sink;self.videoTrack = video;self.current = session;self.stream = stream
            diagnostics.write("Starting stream; pixels=\(config.width)x\(config.height); systemAudio=\(settings.systemAudio); microphone=\(settings.microphone)")
            try await stream.startCapture()
            let database = store
            try await Task.detached(priority:.utility) { try database.saveSession(session) }.value
            capturing = true
            screenAvailable = true
            recordUsage(app:NSWorkspace.shared.frontmostApplication,at:Date())
            usageHeartbeat?.cancel()
            usageHeartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(5))
                    guard !Task.isCancelled,let self,self.capturing else { break }
                    // Bound crash recovery to the last checkpoint, never to the
                    // next app launch. Pausing recording ends this list as well.
                    self.recordUsage(app:NSWorkspace.shared.frontmostApplication,at:Date())
                }
            }
            sink.beginSampling()
            diagnostics.write("Stream running; session=\(session.id)")
        } catch {
            diagnostics.write("Start failed; domain=\((error as NSError).domain); code=\((error as NSError).code); microphonePermission=\(CapturePermissions.microphone.label)")
            sink?.stopSampling()
            if let stream { try? await stream.stopCapture() }
            _ = await systemTrack?.finish(); _ = await microphoneTrack?.finish()
            try? await videoTrack?.finish(at:Date())
            stream = nil; current = nil; videoTrack = nil; sink = nil; systemTrack = nil; microphoneTrack = nil; capturing = false
            throw error
        }
    }
    private func receive(_ image: CGImage, time: Date, sessionID: String) {
        guard !interfaceVisible,capturing,let session = current, session.id == sessionID else { return }
        // Capture provenance before asynchronous encoding/OCR, not after the user switches apps.
        let app = NSWorkspace.shared.frontmostApplication
        let target = CaptureForeground.resolve(app:app,displayID:selectedDisplayID)
        if !screenAvailable { screenAvailable = true; recordUsage(app:app,at:time) }
        let bundleID = target.bundleID
        if settings.excludedApps.contains(bundleID) || settings.excludedNames.contains(target.name) {
            continuityID = UUID().uuidString; return
        }
        var frame = MemoryFrame(timestamp:time,appName:target.name,bundleID:bundleID,title:target.title,imagePath:"frames/source-\(UUID().uuidString).png",text:"",regions:[],sessionID:session.id)
        frame.continuityID = continuityID
        frame.indexingComplete = false
        let token = UUID()
        captureTasks[token] = Task(priority:.utility) { [self] in
            defer { captureTasks[token] = nil }
            do {
                let saved = try await frameWriter.save(image,frame:frame)
                if let id = saved.extendedID { onFrameExtended?(id,saved.through) }
                if let captured = saved.frame {
                    diagnostics.write("Frame saved; session=\(session.id); size=\(image.width)x\(image.height)")
                    onFrame?(captured)
                    if captured.indexingComplete != true { ocrQueue.insert(captured,at:0);publishRecognitionProgress();startOCRIfNeeded() }
                }
            } catch { diagnostics.write("Frame save failed; code=\((error as NSError).code)");onError?("Screen capture: \(error.localizedDescription)") }
        }
        refreshMeetingWindowIfNeeded(sessionID:sessionID)
    }
    private func startOCRIfNeeded() {
        guard ocrTask == nil else { return }
        ocrTask = Task(priority:.utility) { [self] in
            defer { ocrTask = nil; recognizingText = false; processingFrame = false; publishRecognitionProgress() }
            var failures = 0
            while !ocrQueue.isEmpty,!Task.isCancelled {
                // Retain the deadline even when the queue briefly empties, so
                // incoming captures cannot bypass the background work budget.
                do { try await ContinuousClock().sleep(until:nextIndexingAllowed) }
                catch { break }
                let queued = ocrQueue.removeFirst(),database = store
                guard let frame = try? await Task.detached(priority:.utility,operation:{ try database.frame(queued.id) }).value,
                      frame.deletedAt == nil else { continue }
                if frame.indexingComplete == true { onIndexed?(frame);continue }
                var issue:MediaRecognitionState?
                onFrameRecognition?(frame.id,.processing)
                processingFrame = true; recognizingText = true; publishRecognitionProgress()
                defer { processingFrame = false; recognizingText = false; publishRecognitionProgress();onFrameRecognition?(frame.id,issue) }
                do {
                    let url = store.root.appendingPathComponent(frame.imagePath), started = Date()
                    let result = try await indexProcessor.process(url)
                    // Saving the index is part of the same operation; do not
                    // flash a queued state between recognition and commit.
                    // A delayed OCR result must not resurrect a trashed/deleted frame or undo a star.
                    try Task.checkCancellation()
                    let database = store
                    let saved = try await Task.detached(priority:.utility) {
                        try database.updateIndex(frameID:frame.id,text:result.text,regions:result.regions,archive:result.archive,sourceURL:result.sourceURL)
                    }.value
                    nextIndexingAllowed = .now.advanced(by:.seconds(BackgroundProcessingPolicy.recoveryInterval(after:Date().timeIntervalSince(started))))
                    guard let saved else { continue }
                    try Task.checkCancellation()
                    onIndexed?(saved)
                    if failures > 0 { failures = 0;onIndexingIssue?(nil) }
                    diagnostics.write("OCR finished; mode=\(NativeOCR.backendLabel); elapsed=\(Date().timeIntervalSince(started))")
                } catch {
                    if error is CancellationError { break }
                    // Cleanup may remove a queued image before decoding begins.
                    recognizingText = false; publishRecognitionProgress()
                    let database = store
                    guard let saved = try? await Task.detached(priority:.utility, operation:{ try database.frame(frame.id) }).value, saved.deletedAt == nil else { continue }
                    // Keep the lossless source and retry with backoff. A system
                    // Vision outage must not open one blocking alert per frame.
                    failures += 1
                    issue = .failed("Text recognition of this image failed and will retry. The original screenshot is saved safely.")
                    onFrameRecognition?(frame.id,issue)
                    onIndexingIssue?("Text recognition is retrying. Original screenshots are saved safely.")
                    diagnostics.write("Indexing deferred; domain=\((error as NSError).domain); code=\((error as NSError).code)")
                    ocrQueue.append(saved)
                    do { try await Task.sleep(for:.seconds(min(30,pow(2,Double(min(failures,5)))))) }
                    catch { break }
                }
            }
        }
    }
    private func updateMeetingWindow(_ content: SCShareableContent) {
        meetingWindow = content.windows.first { w in
            let id = w.owningApplication?.bundleIdentifier ?? ""
            return ["us.zoom.xos","com.microsoft.teams2","com.cisco.webexmeetingsapp"].contains(id) && !settings.excludedApps.contains(id) && w.frame.width > 400 && w.frame.height > 250
        }
    }
    private func refreshMeetingWindowIfNeeded(sessionID: String) {
        guard Date().timeIntervalSince(lastWindowsRefresh) > 15, meetingRefreshTask == nil else { return }
        // Window enumeration is optional enrichment. Never hold screen indexing
        // behind a slow WindowServer/ScreenCaptureKit enumeration request.
        meetingRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if current?.id == sessionID { meetingRefreshTask = nil } }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true),
                  !Task.isCancelled,!interfaceVisible,current?.id == sessionID else { return }
            updateMeetingWindow(content); lastWindowsRefresh = Date()
            guard let window = meetingWindow, let frame = try? store.frames(demo:false,limit:1).first,
                  frame.sessionID == sessionID else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width)*2; configuration.height = Int(window.frame.height)*2
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:configuration),
                  !Task.isCancelled,!interfaceVisible,current?.id == sessionID else { return }
            let database = store
            guard let saved = try? await Task.detached(priority:.utility,operation:{
                let text = try NativeOCR.recognize(image)
                let result = ScreenIndexResult(text:text.0,regions:text.1,archive:try ScreenArchive.pack(image))
                try Task.checkCancellation()
                return try database.updateMeetingIndex(frameID:frame.id,result:result)
            }).value,!Task.isCancelled,!interfaceVisible else { return }
            onIndexed?(saved)
        }
    }
    func stop() async throws -> RecordingSession? {
        guard let stream, var session = current else { return nil }
        usageHeartbeat?.cancel(); usageHeartbeat = nil
        try? usageRecorder.stop(at:Date())
        current = nil; capturing = false
        let stoppedAt = Date()
        sink?.stopSampling()
        meetingRefreshTask?.cancel(); meetingRefreshTask = nil; meetingWindow = nil
        diagnostics.write("Stopping stream; session=\(session.id)")
        defer { self.stream = nil; sink = nil;videoTrack = nil;systemTrack = nil;microphoneTrack = nil }
        // Stop screen and both audio sources before flushing accepted frames.
        // Filesystem latency must not extend capture into the visible overlay.
        var stopError: Error?
        do {try await stream.stopCapture()} catch {stopError = error}
        await sink?.flush()
        for task in Array(captureTasks.values) { await task.value }
        do { try await frameWriter.finish(at:stoppedAt) } catch { stopError = stopError ?? error }
        await usageRecorder.flush()
        if let track = await systemTrack?.finish() {session.systemAudioPath = track.0;session.systemAudioOffset = track.1}
        if let track = await microphoneTrack?.finish() {session.microphoneAudioPath = track.0;session.microphoneAudioOffset = track.1}
        if settings.systemAudio,session.systemAudioPath == nil { stopError = stopError ?? RewindError.message("The system audio track could not be saved. Other captured media is retained.") }
        if settings.microphone,session.microphoneAudioPath == nil { stopError = stopError ?? RewindError.message("The microphone track could not be saved. Other captured media is retained.") }
        session.hasAudio = session.systemAudioPath != nil || session.microphoneAudioPath != nil
        do { try await videoTrack?.finish(at:stoppedAt) } catch { stopError = stopError ?? error }
        self.stream = nil;sink = nil;videoTrack = nil
        session.endedAt = stoppedAt
        let database = store,finishedSession = session
        try await Task.detached(priority:.utility) { try database.saveSession(finishedSession) }.value
        diagnostics.write("Session saved; id=\(session.id); duration=\(session.endedAt!.timeIntervalSince(session.startedAt))")
        if let stopError {onError?(stopError.localizedDescription)}
        return session
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            diagnostics.write("Stream interrupted; code=\((error as NSError).code)")
            _ = try? await stop(); onStopped?(); onError?("Recording stopped: \(error.localizedDescription)")
        }
    }
    static func audioFile(for session: RecordingSession, root: URL) async throws -> URL? {
        guard session.hasAudio else { return nil }
        let asset = AVURLAsset(url:root.appendingPathComponent(session.videoPath))
        guard !(try await asset.loadTracks(withMediaType:.audio)).isEmpty else { return nil }
        guard let exporter = AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetAppleM4A) else { throw RewindError.message("Cannot extract the recording's audio.") }
        let target = root.appendingPathComponent("recordings/\(session.id).m4a")
        if FileManager.default.fileExists(atPath:target.path) { return target }
        try await exporter.export(to:target,as:.m4a)
        return target
    }
}

// Capture microphone and system audio separately so conversational bubbles have real provenance.
final class AudioTrackSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let path: String;let url: URL;let sessionStart: Date
    let queue = DispatchQueue(label:"studio.rewind.audio-track")
    private var writer: AVAssetWriter?;private var input: AVAssetWriterInput?
    private(set) var offset = 0.0
    private var error: Error?
    private let hostStart:CMTime?
    init(root: URL,path: String,start: Date,hostStart:CMTime? = nil) {self.path = path;url = root.appendingPathComponent(path);sessionStart = start;self.hostStart = hostStart}
    func stream(_ stream: SCStream,didOutputSampleBuffer buffer: CMSampleBuffer,of type: SCStreamOutputType) {
        guard type != .screen else { return }
        consume(buffer)
    }
    /// Called on the serial sample queue. AVAssetWriter converts source PCM into
    /// this explicit output format; microphone hardware can deliver 96/192 kHz
    /// even when SCStreamConfiguration.sampleRate is 48 kHz (system audio only).
    func consume(_ buffer:CMSampleBuffer) {
        guard buffer.isValid,CMSampleBufferDataIsReady(buffer),error == nil else {return}
        do {
            if writer == nil {
                guard let description = CMSampleBufferGetFormatDescription(buffer),let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {return}
                guard format.mSampleRate.isFinite,format.mSampleRate > 0,format.mChannelsPerFrame > 0,
                      format.mFormatID == kAudioFormatLinearPCM else { throw RewindError.message("The audio device returned an unsupported input format.") }
                let writer = try AVAssetWriter(outputURL:url,fileType:.m4a)
                let outputSettings:[String:Any] = [AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:min(2,Int(format.mChannelsPerFrame)),AVEncoderBitRateKey:96000]
                // Validate before constructing the input: invalid AAC settings
                // raise an Objective-C exception, which Swift do/catch cannot catch.
                guard writer.canApply(outputSettings:outputSettings,forMediaType:.audio) else { throw RewindError.message("AAC audio encoding is unavailable on this Mac.") }
                let input = AVAssetWriterInput(mediaType:.audio,outputSettings:outputSettings,sourceFormatHint:description)
                input.expectsMediaDataInRealTime = true;guard writer.canAdd(input) else {throw RewindError.message("Cannot record the separate audio track.")};writer.add(input)
                guard writer.startWriting() else {throw writer.error ?? RewindError.message("Audio writer failed.")}
                writer.startSession(atSourceTime:CMSampleBufferGetPresentationTimeStamp(buffer));offset = max(0,hostStart.map { CMTimeSubtract(buffer.presentationTimeStamp,$0).seconds } ?? Date().timeIntervalSince(sessionStart))
                self.writer = writer;self.input = input
            }
            if let input,input.isReadyForMoreMediaData,!input.append(buffer) {throw writer?.error ?? RewindError.message("Audio track write failed.")}
        } catch {
            self.error = error
            let root = url.deletingLastPathComponent().deletingLastPathComponent()
            let track = path.hasSuffix("microphone.m4a") ? "Microphone":"System audio"
            Task { @MainActor in CaptureDiagnostics(root:root).write("\(track) track failed; domain=\((error as NSError).domain); code=\((error as NSError).code)") }
        }
    }
    func finish() async -> (String,Double)? {
        await withCheckedContinuation {continuation in queue.async { [self] in
            guard error == nil,let writer,let input else {continuation.resume(returning:nil);return}
            input.markAsFinished();writer.finishWriting { [self] in continuation.resume(returning:writer.status == .completed ? (path,offset):nil) }
        } }
    }
}
