import Foundation
import Darwin
import CSQLite

/// The lock lives outside both library names. Shared with Recall.Core's flock protocol.
final class LibraryLocationLease {
    private var descriptor:Int32 = -1
    static func access(_ root:URL,locations:DefaultLibrary? = nil,createParent:Bool = false)throws->LibraryLocationLease? {
        let pair=locations ?? DefaultLibrary.platform
        guard pair.contains(root),createParent || FileManager.default.fileExists(atPath:pair.parent.path) else {return nil}
        return try LibraryLocationLease(parent:pair.parent,exclusive:false)
    }
    init(parent:URL,exclusive:Bool)throws {
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        descriptor=open(parent.appendingPathComponent(".Recall-library-location.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard descriptor >= 0 else {throw CoreCLIError(code:"permission_denied",message:"Cannot open the library location lock.")}
        guard flock(descriptor,(exclusive ? LOCK_EX:LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor);descriptor = -1
            throw CoreCLIError(code:"busy",message:"The default library is in use or being moved. Close other Recall commands and retry.")
        }
    }
    deinit {if descriptor >= 0 {flock(descriptor,LOCK_UN);close(descriptor)}}
}

/// A default-folder rename only. No schema, settings, FTS or receipt conversion.
struct DefaultLibrary {
    let parent:URL
    var current:URL {parent.appendingPathComponent("Recall")}
    var legacy:URL {parent.appendingPathComponent("RewindReplica")}
    func contains(_ root:URL)->Bool {
        let path=root.resolvingSymlinksInPath().standardizedFileURL.path
        return [current,legacy].contains {path.caseInsensitiveCompare($0.resolvingSymlinksInPath().standardizedFileURL.path) == .orderedSame}
    }
    private static func exists(_ url:URL)->Bool {var info=stat();return lstat(url.path,&info) == 0}
    static var platform:DefaultLibrary {DefaultLibrary(parent:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])}
    // Configured before model services are created. Explicit libraries never resolve the default.
    @MainActor static var configuredRoot:URL?
    static func resolve(explicit:URL? = nil)throws->URL {
        if let explicit {return explicit.standardizedFileURL}
        if let value=ProcessInfo.processInfo.environment["RECALL_DATA_DIR"],!value.isEmpty {return URL(fileURLWithPath:value).standardizedFileURL}
        return try platform.resolveDefault()
    }
    func resolveDefault(checkProcesses:(()throws->Void)? = nil)throws->URL {
        let fm=FileManager.default
        guard Self.exists(legacy) else {return current}
        let access=try LibraryLocationLease(parent:parent,exclusive:true)
        defer {withExtendedLifetime(access) {}}
        guard Self.exists(legacy) else {return current}
        guard !Self.exists(current) else {throw CoreCLIError(code:"conflict",message:"Both library directories exist: \(legacy.path) and \(current.path). Neither was changed. Select one with --data-dir; do not merge them automatically.")}
        let values=try legacy.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard values.isSymbolicLink != true,values.isDirectory == true else {throw CoreCLIError(code:"invalid_path",message:"The old default library must be a real directory, not a symbolic link.")}
        try (checkProcesses ?? Self.checkProcesses)()
        let writer=try CoreCLILease(root:legacy,coordinate:false)
        var engines:[CoreCLILease]=[]
        defer {withExtendedLifetime(writer) {};withExtendedLifetime(engines) {}}
        if checkProcesses == nil {
            for engine in ["chat","speech"] where fm.fileExists(atPath:InferenceOwnership.root(engine).path) {
                engines.append(try CoreCLILease(root:InferenceOwnership.root(engine)))
                if let data=try? Data(contentsOf:InferenceOwnership.discovery(engine)),let info=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                    for (pidKey,birthKey) in [("ownerPid","ownerStarted"),("pid","started")] {
                        if let pid=(info[pidKey] as? NSNumber)?.int32Value,let birth=(info[birthKey] as? NSNumber)?.int64Value,InferenceOwnership.matches(pid,birth) {
                            throw CoreCLIError(code:"busy",message:"Close the active Recall model engine before moving the default library.")
                        }
                    }
                }
            }
        }
        if let value=ProcessInfo.processInfo.environment["REWIND_MODEL_ROOT"] {
            let model=URL(fileURLWithPath:value).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            let source=legacy.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            if model == source || model.hasPrefix(source+"/") {throw CoreCLIError(code:"conflict",message:"REWIND_MODEL_ROOT points inside the old default library. Update or remove that override before migration.")}
        }
        try Self.validateMedia(root:legacy)
        // POSIX rename is atomic and refuses cross-volume moves. Never copy gigabytes as fallback.
        guard renamex_np(legacy.path,current.path,UInt32(RENAME_EXCL)) == 0 else {throw CoreCLIError(code:"conflict",message:"Could not atomically rename the default library. The original was retained. Close all Recall processes and check that both paths are on the same volume (errno \(errno)).")}
        return current
    }
    private static func checkProcesses()throws {
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-axo","pid=,comm="];process.standardOutput=pipe
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus == 0 else {throw CoreCLIError(code:"busy",message:"Cannot verify that all old Recall processes have exited.")}
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
            let parts=line.trimmingCharacters(in:.whitespaces).split(maxSplits:1,whereSeparator:{$0 == " " || $0 == "\t"})
            guard parts.count == 2,let pid=Int32(parts[0]),pid != getpid() else {continue}
            let name=URL(fileURLWithPath:String(parts[1]).trimmingCharacters(in:.whitespaces)).lastPathComponent.lowercased()
            var hosted=false
            if name == "dotnet" {
                let host=Process(),output=Pipe();host.executableURL=URL(fileURLWithPath:"/bin/ps");host.arguments=["-p",String(pid),"-o","command="];host.standardOutput=output
                try host.run();let command=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).lowercased();host.waitUntilExit()
                if host.terminationStatus == 0 {hosted=command.contains("recall.dll") || command.contains("rewindreplica.dll")}
            }
            if hosted || ["recall","rewindreplica","recall-macos-core","recall-ocr","recall-headless"].contains(name) {throw CoreCLIError(code:"busy",message:"Close all Recall applications and CLI commands before moving the default library (process \(pid): \(name)).")}
        }
    }
    static func validateMedia(root:URL)throws {
        let path=root.appendingPathComponent("memory.sqlite").path
        guard FileManager.default.fileExists(atPath:path) else {return}
        var db:OpaquePointer?
        guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {sqlite3_close(db);throw CoreCLIError(code:"invalid_data",message:"Cannot inspect the original database; it was not moved.")}
        defer {sqlite3_close(db)}
        func rows(_ sql:String,_ body:([String?])throws->Void)throws {
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else {throw CoreCLIError(code:"invalid_data",message:"Cannot inspect library media references; it was not moved.")}
            defer {sqlite3_finalize(statement)}
            while true {
                let result=sqlite3_step(statement)
                if result == SQLITE_DONE {return}
                guard result == SQLITE_ROW else {throw CoreCLIError(code:"busy",message:"Could not finish reading the original library; it was not moved.")}
                try body((0..<sqlite3_column_count(statement)).map {index in sqlite3_column_text(statement,index).map {String(cString:$0)}})
            }
        }
        try rows("BEGIN") {_ in};defer {try? rows("ROLLBACK") {_ in}}
        var tables:[String:Set<String>]=[:],manifests:Set<String>=[]
        try rows("SELECT m.name,p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type IN ('table','view')") {row in tables[row[0]!,default:[]].insert(row[1]!)}
        func check(_ path:String)throws {
            guard !path.isEmpty else {return}
            guard !path.hasPrefix("/"),!path.hasPrefix("\\"),!path.contains(":"),!path.split(whereSeparator:{$0 == "/" || $0 == "\\"}).contains("..") else {throw CoreCLIError(code:"invalid_path",message:"A persisted media reference is not library-relative: \(path). The original library was not moved. Repair this reference or use --data-dir with the original directory.")}
            var component=root
            for item in path.split(whereSeparator:{$0 == "/" || $0 == "\\"}) {
                component.appendPathComponent(String(item))
                if (try? component.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {throw CoreCLIError(code:"invalid_path",message:"A media reference contains a symbolic link; the original library was not moved: \(path)")}
            }
            if path.hasSuffix(".recallframe") || path.hasSuffix(".recallvideo") {manifests.insert(path)}
        }
        for table in ["frames","sessions"] where tables[table]?.contains("json") == true {
            try rows("SELECT json FROM \(table)") {row in
                guard let text=row[0],let value=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any] else {throw CoreCLIError(code:"invalid_data",message:"Invalid persisted media record; library was not moved.")}
                for (key,value) in value where ["imagepath","meetingimagepath","videopath","systemaudiopath","microphoneaudiopath","supersededvideopath"].contains(key.lowercased()) {if let path=value as? String {try check(path)}}
            }
        }
        for (table,columns) in [("image_paths",["path"]),("image_archives",["source","destination"]),("image_archive_staging",["destination"]),("image_tiles",["image","tile"])] {
            for column in columns where tables[table]?.contains(column) == true {try rows("SELECT \(column) FROM \(table)") {row in if let path=row[0] {try check(path)}}}
        }
        func walk(_ value:Any)throws {
            if let object=value as? [String:Any] {for (key,value) in object {if ["path","video"].contains(key),let path=value as? String {try check(path)} else {try walk(value)}}}
            else if let items=value as? [Any] {for item in items {try walk(item)}}
        }
        var journals:[(URL,String)]=[]
        let control=root.appendingPathComponent(".recall-control")
        if FileManager.default.fileExists(atPath:control.path) {
            journals += try FileManager.default.contentsOfDirectory(at:control,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasPrefix("cleanup-") && $0.pathExtension == "json"}.map {($0,"files")}
        }
        journals += try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasPrefix(".cleanup-")}.map {($0.appendingPathComponent("journal.json"),"paths")}
        for (url,key) in journals where FileManager.default.fileExists(atPath:url.path) {
            if let object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] {
                for (field,value) in object where field.lowercased() == key {if let paths=value as? [String] {for path in paths {try check(path)}}}
            }
        }
        for path in manifests {
            let url=root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath:url.path) {try walk(JSONSerialization.jsonObject(with:Data(contentsOf:url)))}
        }
    }
}
