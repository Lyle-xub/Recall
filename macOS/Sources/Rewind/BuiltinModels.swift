import Foundation
import Combine
import CryptoKit
import AVFoundation
import AppKit

struct ModelDownload: Codable, Identifiable {
    let id: String; let title: String; let subtitle: String; let file: String
    let url: URL; let bytes: Int64; let sha256: String; let license: String; let source: URL
    var sizeLabel: String {ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)}
}

@MainActor final class BuiltinModels: ObservableObject {
    static let shared = BuiltinModels()
    @Published var progress: [String:Double] = [:]
    @Published var status: [String:String] = [:]
    @Published var installed: Set<String> = []
    @Published var busy: Set<String> = []
    let catalog: [ModelDownload]
    let root: URL
    private var downloads: [String:NativeModelDownload] = [:]
    init() {
        root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["REWIND_MODEL_ROOT"] ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RewindReplica/models").path)
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = ProcessInfo.processInfo.environment["REWIND_CATALOG_PATH"].map{URL(fileURLWithPath:$0)} ?? Bundle.main.resourceURL?.appendingPathComponent("models/catalog.json")
        catalog = url.flatMap {try? Data(contentsOf:$0)}.flatMap {try? JSONDecoder().decode([ModelDownload].self,from:$0)} ?? []
        for item in catalog {if validReceipt(item) {installed.insert(item.id);status[item.id] = "Ready · Works offline"}}
    }
    func path(_ item: ModelDownload) -> URL {root.appendingPathComponent(item.file)}
    private func receipt(_ item: ModelDownload) -> URL {root.appendingPathComponent(item.file + ".verified")}
    private func validReceipt(_ item: ModelDownload) -> Bool {
        (try? String(contentsOf:receipt(item),encoding:.utf8)) == item.sha256 && ((try? path(item).resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) == item.bytes
    }
    func require(_ id: String) throws -> URL {
        guard let item = catalog.first(where:{$0.id == id}), validReceipt(item) else {throw RewindError.message("Download the built-in \(id == "chat" ? "Qwen3":"Whisper") model in Settings → Models first.")}
        return path(item)
    }
    func download(_ item: ModelDownload) {
        guard !busy.contains(item.id) else {return};busy.insert(item.id);status[item.id] = "Connecting…"
        let downloader = NativeModelDownload(item:item,directory:root)
        downloads[item.id] = downloader
        downloader.changed = { [weak self] fraction,message in Task { @MainActor in self?.progress[item.id] = fraction;self?.status[item.id] = message } }
        downloader.completed = { [weak self] error in Task { @MainActor in
            guard let self else {return};self.busy.remove(item.id);self.downloads.removeValue(forKey:item.id)
            if let error {self.status[item.id] = error.localizedDescription} else {self.installed.insert(item.id);self.status[item.id] = "Ready · Works offline";self.progress[item.id] = 1}
        } }
        downloader.start()
    }
    func cancel(_ id: String) {downloads[id]?.cancel()}
    func remove(_ item: ModelDownload) async {
        guard !busy.contains(item.id) else {return}
        await LocalInference.shared.stop()
        do {if FileManager.default.fileExists(atPath:path(item).path) {try FileManager.default.trashItem(at:path(item),resultingItemURL:nil)};try? FileManager.default.removeItem(at:receipt(item));installed.remove(item.id);status[item.id] = "Removed · Download again any time"} catch {status[item.id] = error.localizedDescription}
    }
}

/// URLSession downloads to disk, with resumable cancellation and off-main-thread verification.
final class NativeModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let item: ModelDownload; let directory: URL
    var changed: ((Double,String)->Void)?;var completed: ((Error?)->Void)?
    private var task: URLSessionDownloadTask?;private var session: URLSession!
    private var finished = false
    init(item: ModelDownload,directory: URL) {self.item = item;self.directory = directory}
    private var resumeURL: URL {directory.appendingPathComponent(item.file + ".resume")}
    func start() {
        let config = URLSessionConfiguration.default;config.timeoutIntervalForRequest = 45;config.timeoutIntervalForResource = 86400
        session = URLSession(configuration:config,delegate:self,delegateQueue:nil)
        if let resume = try? Data(contentsOf:resumeURL) {task = session.downloadTask(withResumeData:resume)} else {task = session.downloadTask(with:item.url)}
        task?.resume()
    }
    func cancel() {task?.cancel { [self] data in if let data {try? data.write(to:resumeURL,options:.atomic)} } }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didWriteData bytesWritten: Int64,totalBytesWritten: Int64,totalBytesExpectedToWrite: Int64) {
        let fraction = min(0.99,Double(totalBytesWritten)/Double(item.bytes))
        changed?(fraction,"\(Int(fraction*100))% · \(ByteCountFormatter.string(fromByteCount:totalBytesWritten,countStyle:.file)) / \(item.sizeLabel)")
    }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,(200..<300).contains(response.statusCode) else {throw RewindError.message("Download failed. Check your connection and retry.")}
            changed?(0.99,"Verifying SHA-256…")
            guard (try location.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) == item.bytes else {throw RewindError.message("Incomplete download. Please retry.")}
            let handle = try FileHandle(forReadingFrom:location);defer {try? handle.close()};var hash = SHA256()
            while let block = try handle.read(upToCount:1024*1024),!block.isEmpty {hash.update(data:block)}
            guard hash.finalize().map({String(format:"%02x",$0)}).joined() == item.sha256 else {throw RewindError.message("Model verification failed. Please download again.")}
            let target = directory.appendingPathComponent(item.file)
            if FileManager.default.fileExists(atPath:target.path) {try FileManager.default.removeItem(at:target)}
            try FileManager.default.moveItem(at:location,to:target)
            try item.sha256.write(to:directory.appendingPathComponent(item.file + ".verified"),atomically:true,encoding:.utf8)
            try? FileManager.default.removeItem(at:resumeURL);finish(nil)
        } catch {finish(error)}
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {try? data.write(to:resumeURL,options:.atomic)}
            finish(ns.code == NSURLErrorCancelled ? RewindError.message("Paused · Press Download to resume"):error)
        }
    }
    private func finish(_ error: Error?) {guard !finished else {return};finished = true;completed?(error);session.finishTasksAndInvalidate()}
}

actor LocalInference {
    static let shared = LocalInference()
    private var server: Process?
    private var runningProfile: ModelProfile?
    private var serverKey = ""
    private var starting: Task<(ModelProfile,String),Error>?
    private var speech: Process?
    private let speechGate = SpeechOperationGate()
    static func runtime(_ engine: String,_ executable: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["REWIND_RUNTIME_ROOT"].map{URL(fileURLWithPath:$0)} ?? Bundle.main.resourceURL!.appendingPathComponent("runtimes")
        let url = base.appendingPathComponent(engine).appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath:url.path) else {throw RewindError.message("The native \(engine) engine is missing. Install the complete application package.")};return url
    }
    func chat() async throws -> (ModelProfile,String) {
        if let server,server.isRunning,let runningProfile {return (runningProfile,serverKey)}
        if let starting {return try await starting.value}
        let task = Task {try await self.startChat()};starting = task
        defer {starting = nil};return try await task.value
    }
    private func startChat() async throws -> (ModelProfile,String) {
        let model = try await BuiltinModels.shared.require("chat")
        let executable = try Self.runtime("llama","llama-server")
        let listener = socket(AF_INET,SOCK_STREAM,0);guard listener >= 0 else {throw RewindError.message("Cannot allocate a local model port.")}
        var address = sockaddr_in();address.sin_family = sa_family_t(AF_INET);address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(listener,$0,&length)}};close(listener)
        guard bound == 0 && result == 0 else {throw RewindError.message("Cannot allocate a local model port.")}
        let port = UInt16(bigEndian:address.sin_port);let key = UUID().uuidString + UUID().uuidString
        let process = Process();process.executableURL = executable;process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["-m",model.path,"--host","127.0.0.1","--port",String(port),"--api-key",key,"--alias","rewind-local","-c","8192","-np","1","-n","768","--jinja","--chat-template-kwargs","{\"enable_thinking\":false}","--no-webui"]
        process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        try process.run();server = process
        let profile = ModelProfile(provider:"Internal runtime",baseURL:"http://127.0.0.1:\(port)/v1",model:"rewind-local",isLocal:true)
        let config = URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest = 2;let probe = URLSession(configuration:config);defer {probe.invalidateAndCancel()}
        for _ in 0..<240 {
            try Task.checkCancellation()
            guard process.isRunning else {throw RewindError.message("The built-in model could not start. Check available memory and reinstall the model.")}
            var request = URLRequest(url:try ModelClient.endpoint(profile,path:"models"));request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
            if let (_,response) = try? await probe.data(for:request),(response as? HTTPURLResponse)?.statusCode == 200 {runningProfile = profile;serverKey = key;return (profile,key)}
            try await Task.sleep(for:.milliseconds(250))
        }
        process.terminate();throw RewindError.message("Model loading timed out. Free some memory and retry.")
    }
    func stop() {starting?.cancel();starting = nil;if server?.isRunning == true {server?.terminate()};if speech?.isRunning == true {speech?.terminate()};server = nil;speech = nil;runningProfile = nil;serverKey = ""}
    func transcribe(_ file: URL,sessionID: String,start: Date) async throws -> [TranscriptLine] {
        try await speechGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await performTranscription(file, sessionID:sessionID, start:start)
            await speechGate.release(); return result
        } catch { await speechGate.release(); throw error }
    }
    private func performTranscription(_ file:URL, sessionID:String, start:Date) async throws -> [TranscriptLine] {
        let model = try await BuiltinModels.shared.require("speech");let executable = try Self.runtime("whisper","whisper-cli")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rewind-speech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:temporary)}
        let wave = temporary.appendingPathComponent("input.wav")
        let conversion = Task.detached(priority:.utility) { try Self.convertAudio(file,to:wave) }
        try await withTaskCancellationHandler(operation:{ try await conversion.value },onCancel:{ conversion.cancel() })
        try Task.checkCancellation()
        let output = temporary.appendingPathComponent("transcript");let process = Process();process.executableURL = executable
        process.arguments = ["-m",model.path,"-f",wave.path,"-l","auto","-oj","-of",output.path,"-t",String(max(1,min(2,ProcessInfo.processInfo.activeProcessorCount / 2))),"-np"]
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice;try process.run();speech = process
        defer {if process.isRunning {process.terminate()};speech = nil}
        let deadline = Date().addingTimeInterval(900)
        while process.isRunning {try Task.checkCancellation();guard Date() < deadline else {throw RewindError.message("Transcription timed out. Your audio remains saved for retry.")};try await Task.sleep(for:.milliseconds(150))}
        guard process.terminationStatus == 0 else {throw RewindError.message("Local transcription failed. Your audio remains saved for retry.")}
        let data = try Data(contentsOf:output.appendingPathExtension("json"))
        return try Self.parseTranscript(data,sessionID:sessionID,start:start)
    }
    static func parseTranscript(_ data: Data,sessionID: String,start: Date) throws -> [TranscriptLine] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],let rows = root["transcription"] as? [[String:Any]] else {throw RewindError.message("Invalid local transcript.")}
        return rows.compactMap {row in guard let text = row["text"] as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return nil};let offsets = row["offsets"] as? [String:Double];return TranscriptLine(sessionID:sessionID,timestamp:start.addingTimeInterval((offsets?["from"] ?? 0)/1000),speaker:"Audio",text:text.trimmingCharacters(in:.whitespacesAndNewlines))}
    }
    static func convertAudio(_ input: URL,to output: URL) throws {
        let file = try AVAudioFile(forReading:input)
        let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
        guard let converter = AVAudioConverter(from:file.processingFormat,to:format) else {throw RewindError.message("Cannot convert recorded audio.")}
        let writer = try AVAudioFile(forWriting:output,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false],commonFormat:.pcmFormatFloat32,interleaved:false)
        let source = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096)!,destination = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
        var readError: Error?, stalled = 0
        while true {
            try Task.checkCancellation()
            let position = file.framePosition
            destination.frameLength = 0
            var conversionError: NSError?
            let state = converter.convert(to:destination,error:&conversionError) {count,status in
                do {guard file.framePosition < file.length else {status.pointee = .endOfStream;return nil};try file.read(into:source,frameCount:min(count,source.frameCapacity,AVAudioFrameCount(file.length-file.framePosition)));status.pointee = source.frameLength > 0 ? .haveData:.endOfStream;return source.frameLength > 0 ? source:nil} catch {readError = error;status.pointee = .endOfStream;return nil}
            }
            if let readError {throw readError};if let conversionError {throw conversionError}
            if destination.frameLength > 0 {try writer.write(from:destination)}
            if state == .endOfStream {break};if state == .error {throw RewindError.message("Audio conversion failed.")}
            stalled = destination.frameLength == 0 && position == file.framePosition ? stalled + 1 : 0
            guard stalled < 8 else { throw RewindError.message("Audio conversion stopped making progress. The original recording is preserved.") }
        }
    }
}
