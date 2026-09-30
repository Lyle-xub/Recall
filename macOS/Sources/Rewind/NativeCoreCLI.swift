import Foundation
import AppKit
import Darwin

struct CoreCLIError: LocalizedError {
    let code:String
    let message:String
    var errorDescription:String? { message }
}

/// Same kernel lease as Recall.Core on Unix. Released automatically after crashes.
final class CoreCLILease {
    let directory:URL
    private var descriptor:Int32 = -1
    private let location:LibraryLocationLease?
    init(root:URL,coordinate:Bool = true,locationPair:DefaultLibrary? = nil) throws {
        location = coordinate ? try LibraryLocationLease.access(root,locations:locationPair,createParent:true):nil
        directory = root.appendingPathComponent(".recall-control")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CoreCLIError(code:"invalid_path",message:"The control directory must not be a symbolic link.") }
        let path = directory.appendingPathComponent("lease").path
        descriptor = open(path,O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw CoreCLIError(code:"permission_denied",message:"Cannot open the library control lease.") }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor);descriptor = -1
            throw CoreCLIError(code:"busy",message:"The application or another CLI command owns this library.")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor,LOCK_UN);close(descriptor) } }
}

enum NativeCoreCLI {
    static let writes:Set<String> = ["init","import","star","trash","restore","recognize","compact","cleanup","save-transcript","index-offline","index-one","config-set"]
    static func run() -> Int32 {
        if CommandLine.arguments.contains("--core-session") {
            while let line = readLine() { _ = runRequest(Data(line.utf8)) }
            return 0
        }
        return runRequest(FileHandle.standardInput.readDataToEndOfFile())
    }
    private static func runRequest(_ input:Data)->Int32 {
        do {
            guard input.count <= 2_000_000,let request = try JSONSerialization.jsonObject(with:input) as? [String:Any],let rootPath = request["root"] as? String,let operation = request["operation"] as? String else { throw CoreCLIError(code:"invalid_request",message:"Invalid native core request.") }
            let root = URL(fileURLWithPath:rootPath).standardizedFileURL
            let lease = (writes.contains(operation) || operation == "export") ? try CoreCLILease(root:root):nil
            defer { withExtendedLifetime(lease) {} }
            if operation == "init" {
                guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else { throw CoreCLIError(code:"conflict",message:"A database already exists.") }
            }
            let store = try MemoryStore(root:root,readOnly:!writes.contains(operation),maintenanceOnly:writes.contains(operation) && operation != "init")
            let result = try execute(operation,args:request["args"] as? [String:Any] ?? [:],store:store)
            try emit(["ok":true,"result":result]);return 0
        } catch {
            try? emit(["ok":false,"error":["code":(error as? CoreCLIError)?.code ?? "operation_failed","message":error.localizedDescription]])
            return 1
        }
    }
    static func emit(_ value:Any) throws { FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]));FileHandle.standardOutput.write(Data([10])) }
    static func object<T:Encodable>(_ value:T)throws->Any {
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with:encoder.encode(value),options:[.fragmentsAllowed])
    }
    static func frameObject(_ frame:MemoryFrame)throws->[String:Any] {
        var value = try object(frame) as! [String:Any]
        value["textState"] = frame.indexingComplete == false ? 0:frame.text.isEmpty ? 3:2
        return value
    }
    static func date(_ args:[String:Any],_ name:String)throws->Date? {
        guard let text = args[name] as? String else { return nil }
        let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = formatter.date(from:text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from:text) else { throw CoreCLIError(code:"usage",message:"Invalid ISO date: "+name) };return date
    }
    static func selected(_ args:[String:Any],store:MemoryStore)throws->[MemoryFrame] {
        try store.frames(query:args["query"] as? String ?? "",app:args["app"] as? String,starred:args["starred"] as? Bool ?? false,trash:args["trash"] as? Bool ?? false,since:date(args,"since"),until:date(args,"until"),demo:args["demo"] as? Bool ?? false,limit:args["limit"] as? Int ?? 100,offset:args["offset"] as? Int ?? 0,ascending:args["ascending"] as? Bool ?? false)
    }
    static func required(_ args:[String:Any],store:MemoryStore)throws->MemoryFrame {
        guard let id = args["id"] as? String,let frame = try store.frame(id) else { throw CoreCLIError(code:"not_found",message:"Memory not found.") };return frame
    }
    static func cleanupPlan(_ args:[String:Any],store:MemoryStore)throws->StorageCleanupPlan {
        guard let name = args["scope"] as? String,let scope = StorageCleanupScope(rawValue:name) else { throw CoreCLIError(code:"usage",message:"Scope must be trash, older7, older30 or all.") }
        return try store.cleanupPlan(scope:scope,keepStarred:!(args["includeStarred"] as? Bool ?? false))
    }
    static func configured(_ args:[String:Any],current:AppSettings)throws->AppSettings {
        var next=current
        guard let key=args["key"] as? String,let value=args["value"] as? String else {throw CoreCLIError(code:"usage",message:"A setting key and value are required.")}
        switch key {
        case "capture-interval": guard let number=Int(value),(1...3600).contains(number) else {throw CoreCLIError(code:"usage",message:"capture-interval must be 1–3600 seconds.")};next.captureInterval=Double(number)
        case "retention-days": guard let number=Int(value),(0...36500).contains(number) else {throw CoreCLIError(code:"usage",message:"retention-days must be 0–36500.")};next.retentionDays=number
        case "excluded-apps":
            guard let data=value.data(using:.utf8),let names=try? JSONDecoder().decode([String].self,from:data),names.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {throw CoreCLIError(code:"usage",message:"excluded-apps must be a JSON array of application identifiers.")}
            next.excludedApps=names
        case "system-audio","microphone","transcription-enabled":
            guard let enabled=Bool(value.lowercased()) else {throw CoreCLIError(code:"usage",message:"Use true or false.")}
            if key=="system-audio" {next.systemAudio=enabled} else if key=="microphone" {next.microphone=enabled} else {next.transcriptionEnabled=enabled}
        default:throw CoreCLIError(code:"usage",message:"Unknown setting key.")
        }
        return next
    }
    static func saveConfiguration(_ next:AppSettings,root:URL)throws {
        let file=root.appendingPathComponent("settings.json")
        var merged=(try? JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]) ?? [:]
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(next)) as! [String:Any]
        for (key,value) in encoded {merged[key]=value}
        try JSONSerialization.data(withJSONObject:merged).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func execute(_ operation:String,args:[String:Any],store:MemoryStore)throws->Any {
        switch operation {
        case "config-set":
            let file=store.root.appendingPathComponent("settings.json")
            let current=FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(AppSettings.self,from:Data(contentsOf:file)):AppSettings()
            let next=try configured(args,current:current)
            try saveConfiguration(next,root:store.root)
            if args["key"] as? String == "retention-days" {try store.applyRetention(days:next.retentionDays)}
            return try object(next)
        case "capabilities":return ["screenCapturePermission":CGPreflightScreenCaptureAccess(),"nativeRecording":true,"ocrSession":true]
        case "init","info": return ["root":store.root.path,"format":"macos","count":try store.count()]
        case "list": return try selected(args,store:store).map(frameObject)
        case "get": return try frameObject(required(args,store:store))
        case "retrieve": return try store.retrieve(args["query"] as? String ?? "",since:date(args,"since"),app:args["app"] as? String).map(frameObject)
        case "index-candidates": return try (args["id"] is String ? [required(args,store:store)] : Array(store.pendingIndexFrames().prefix(args["limit"] as? Int ?? 100))).map(frameObject)
        case "apps": return try store.appNames(demo:false,trash:false,since:nil)
        case "sessions": return try object(store.sessions())
        case "transcript": return try object(store.transcript(args["id"] as? String ?? ""))
        case "import":
            guard let path = args["image"] as? String,FileManager.default.fileExists(atPath:path) else { throw CoreCLIError(code:"not_found",message:"Image not found.") }
            let source = URL(fileURLWithPath:path),ext = source.pathExtension.lowercased()
            guard ["png","jpg","jpeg","heic","bmp","webp"].contains(ext) else { throw CoreCLIError(code:"unsupported",message:"Unsupported image format.") }
            let id = UUID().uuidString,relative = "frames/"+UUID().uuidString+"."+ext
            let target = try CleanupFiles.ownedURL(relative,root:store.root),text = args["text"] as? String ?? ""
            let frame = MemoryFrame(id:id,timestamp:try date(args,"timestamp") ?? Date(),appName:args["app"] as? String ?? "Imported",bundleID:"recall.cli.import",title:args["title"] as? String ?? source.deletingPathExtension().lastPathComponent,imagePath:relative,text:text,regions:[],indexingComplete:!text.isEmpty)
            try FileManager.default.copyItem(at:source,to:target)
            do { try store.save(frame) } catch { try? FileManager.default.removeItem(at:target);throw error }
            return try frameObject(frame)
        case "star": let frame = try required(args,store:store);return try frameObject(store.toggleStar(frame.id)!)
        case "trash","restore":
            let frame = try required(args,store:store)
            if operation == "trash" { try store.moveToTrash(frame) } else { try store.restore(frame) }
            return try frameObject(store.frame(frame.id)!)
        case "recognize":
            var frame = try required(args,store:store)
            frame.text = args["text"] as? String ?? "";frame.indexingComplete = true
            frame.regions = (args["regions"] as? [[String:Any]] ?? []).map { TextRegion(text:$0["text"] as? String ?? "",x:$0["x"] as? Double ?? 0,y:$0["y"] as? Double ?? 0,width:$0["width"] as? Double ?? 0,height:$0["height"] as? Double ?? 0) }
            try store.save(frame);return try frameObject(frame)
        case "save-transcript":
            guard let id = args["id"] as? String,try store.session(id) != nil else { throw CoreCLIError(code:"not_found",message:"Session not found.") }
            let lines = try (args["lines"] as? [[String:Any]] ?? []).map { value in
                TranscriptLine(id:value["id"] as? String ?? UUID().uuidString,sessionID:id,timestamp:try date(value,"timestamp") ?? Date(),speaker:value["speaker"] as? String ?? "Audio",text:value["text"] as? String ?? "")
            }
            try store.replaceTranscript(sessionID:id,lines:lines);return ["count":lines.count]
        case "export":
            guard let path = args["output"] as? String else { throw CoreCLIError(code:"usage",message:"An output directory is required.") }
            let destination = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath(),root = store.root.standardizedFileURL.resolvingSymlinksInPath()
            guard destination != root,!destination.path.hasPrefix(root.path+"/"),(try? FileManager.default.contentsOfDirectory(atPath:destination.path).isEmpty) != false else { throw CoreCLIError(code:"conflict",message:"Export to a new or empty directory outside the library.") }
            let frames = try selected(args,store:store)
            for frame in frames { _ = try CleanupFiles.ownedURL(frame.imagePath,root:root);if let path = frame.meetingImagePath { _ = try CleanupFiles.ownedURL(path,root:root) } }
            let sessionIDs = Set(frames.compactMap(\.sessionID))
            for session in try store.sessions() where sessionIDs.contains(session.id) {
                for path in [session.videoPath,session.systemAudioPath,session.microphoneAudioPath].compactMap({$0}) { _ = try CleanupFiles.ownedURL(path,root:root) }
            }
            let staging = URL(fileURLWithPath:destination.path+".partial-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:staging)}
            try store.export(to:staging,frames:frames)
            if FileManager.default.fileExists(atPath:destination.path) {
                guard (try? FileManager.default.contentsOfDirectory(atPath:destination.path).isEmpty)==true else {throw CoreCLIError(code:"conflict",message:"Export destination changed; it was preserved.")}
                guard rmdir(destination.path)==0 else {throw CoreCLIError(code:"conflict",message:"Export destination changed; it was preserved.")}
            }
            try FileManager.default.moveItem(at:staging,to:destination)
            return ["destination":destination.path,"count":frames.count,"format":"macos"]
        case "check": return ["integrity":try store.cliIntegrity()]
        case "compact": try store.compactIndex();return ["compacted":true]
        case "cleanup-preview","cleanup":
            let plan = try cleanupPlan(args,store:store)
            if operation == "cleanup-preview" { return ["count":plan.frameIDs.count,"bytes":plan.bytes,"ids":plan.frameIDs.sorted(),"keepStarred":plan.keepStarred] }
            guard args["confirmed"] as? Bool == true else { throw CoreCLIError(code:"confirmation_required",message:"Permanent cleanup requires --yes.") }
            return cleanupResult(try store.clearStorage(plan))
        case "index-offline","index-one":
            let frames = args["id"] != nil && !(args["id"] is NSNull) ? [try required(args,store:store)] : Array(try store.pendingIndexFrames().prefix(args["limit"] as? Int ?? 100))
            for var frame in frames {
                let source = try CleanupFiles.ownedURL(frame.imagePath,root:store.root)
                let language = args["language"] as? String ?? "eng"
                if ProcessInfo.processInfo.environment["RECALL_TESSERACT"] == nil,
                   ["eng","chi_sim","eng+chi_sim","chi_sim+eng"].contains(language) {
                    let result:(String,[TextRegion])
                    if source.pathExtension == "png" {result = try NativeOCR.recognize(source:source)}
                    else {
                        guard let image = StoredImage.load(source) else {throw CoreCLIError(code:"unsupported_media",message:"The saved image could not be decoded.")}
                        result = try NativeOCR.recognize(image)
                    }
                    _ = try store.updateIndex(frameID:frame.id,text:result.0,regions:result.1)
                    continue
                }
                guard let image = StoredImage.load(source) else { throw CoreCLIError(code:"unsupported_media",message:"The saved image could not be decoded.") }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recall-cli-ocr-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at:folder) }
                let input = folder.appendingPathComponent("input.png"),output = folder.appendingPathComponent("ocr")
                try ScreenArchive.saveSource(image,to:input)
                let process = Process()
                if let engine = ProcessInfo.processInfo.environment["RECALL_TESSERACT"] { process.executableURL = URL(fileURLWithPath:engine);process.arguments = [] }
                else { process.executableURL = URL(fileURLWithPath:"/usr/bin/env");process.arguments = ["tesseract"] }
                process.arguments! += [input.path,output.path,"-l",args["language"] as? String ?? "eng","--psm","11","tsv"]
                process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment;environment["OMP_THREAD_LIMIT"] = "2";process.environment = environment
                try process.run()
                let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier,SIGKILL) } };DispatchQueue.global().asyncAfter(deadline:.now()+60,execute:deadline)
                process.waitUntilExit();deadline.cancel()
                guard process.terminationStatus == 0 else { throw CoreCLIError(code:"ocr_failed",message:"Tesseract failed; check the engine and installed languages.") }
                frame.regions = LocalOCR.parse(try String(contentsOf:output.appendingPathExtension("tsv"),encoding:.utf8),width:image.width,height:image.height)
                _ = try store.updateIndex(frameID:frame.id,text:frame.regions.map(\.text).joined(separator:"\n"),regions:frame.regions)
            }
            return ["completed":frames.count,"owner":"cli"]
        default: throw CoreCLIError(code:"unsupported",message:"Unsupported native library operation: "+operation)
        }
    }
    static func cleanupResult(_ result:StorageCleanupResult)->[String:Any] { ["removed":result.memories,"recordings":result.recordings,"bytes":result.bytes,"pendingFileRemoval":result.pendingFileRemoval] }
}
