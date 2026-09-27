import Foundation
import Darwin

/// Same private per-user lease and model identity as Recall.Core.
enum InferenceOwnership {
    final class Lease {
        let lease:CoreCLILease
        let engine:String
        init(_ engine:String)throws { self.engine=engine;lease=try CoreCLILease(root:InferenceOwnership.root(engine)) }
        deinit {
            let path=InferenceOwnership.discovery(engine)
            if let data=try? Data(contentsOf:path),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],value["ownerPid"] as? Int32 == getpid() {try? FileManager.default.removeItem(at:path)}
        }
    }
    static func root(_ engine:String)->URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".recall-inference-v2/"+engine) }
    static func discovery(_ engine:String)->URL { root(engine).appendingPathComponent(".recall-control/engine.json") }
    static func started(_ pid:Int32)->Int64? {
        var info=kinfo_proc(),size=MemoryLayout<kinfo_proc>.stride
        var mib:[Int32]=[CTL_KERN,KERN_PROC,KERN_PROC_PID,pid]
        guard sysctl(&mib,u_int(mib.count),&info,&size,nil,0)==0,size>0,info.kp_proc.p_stat != SZOMB else {return nil}
        return Int64(info.kp_proc.p_starttime.tv_sec)*1000+Int64(info.kp_proc.p_starttime.tv_usec)/1000
    }
    static func matches(_ pid:Int32,_ birth:Int64)->Bool { guard let actual=started(pid),birth>0 else {return false};return abs(actual-birth)<1000 }
    static func identity(_ model:URL)throws->String {
        let url=model.resolvingSymlinksInPath(),attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        return url.path+"|"+String((attributes[.size] as! NSNumber).int64Value)+"|"+String(Int64((attributes[.modificationDate] as! Date).timeIntervalSince1970*1000))
    }
    static func acquire(_ engine:String)throws->Lease {
        let lease=try Lease(engine)
        if let data=try? Data(contentsOf:discovery(engine)),let old=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           let pid=old["pid"] as? Int32,let birth=old["started"] as? Int64,matches(pid,birth) {
            // Do not terminate a process without independently verifying its path.
            throw CoreCLIError(code:"busy",message:"An orphaned model process may still be running (PID \(pid)). Run a CLI model command to verify and recover it.")
        }
        try? FileManager.default.removeItem(at:discovery(engine));return lease
    }
    static func publish(_ engine:String,process:Process,started:Date,profile:ModelProfile? = nil,key:String = "",model:URL? = nil)throws {
        var value:[String:Any] = ["ownerPid":getpid(),"ownerStarted":self.started(getpid()) ?? 0,"pid":process.processIdentifier,"started":self.started(process.processIdentifier) ?? Int64(started.timeIntervalSince1970*1000),"executable":process.executableURL!.path,"share":profile != nil,"key":key,"modelIdentity":try model.map(identity) ?? ""]
        if let profile { value["profile"] = try NativeCoreCLI.object(profile) }
        let url = discovery(engine)
        try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func wireProfile(_ raw:Any)throws->ModelProfile {
        var value=raw as? [String:Any] ?? [:]
        if value["baseURL"]==nil {value["baseURL"]=value["baseUrl"]}
        return try JSONDecoder().decode(ModelProfile.self,from:JSONSerialization.data(withJSONObject:value))
    }
    static func sharedChat(model:URL) async throws -> (ModelProfile,String)? {
        guard let data=try? Data(contentsOf:discovery("chat")),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],value["share"] as? Bool == true,
              let owner=value["ownerPid"] as? Int32,let ownerStarted=value["ownerStarted"] as? Int64,matches(owner,ownerStarted),
              let pid=value["pid"] as? Int32,let birth=value["started"] as? Int64,matches(pid,birth),
              value["modelIdentity"] as? String == (try identity(model)),let raw=value["profile"],let key=value["key"] as? String else {return nil}
        let profile=try wireProfile(raw)
        guard profile.isLocal,let url=URL(string:profile.baseURL),url.scheme=="http",url.host=="127.0.0.1" else {return nil}
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=3
        let client=URLSession(configuration:configuration);defer {client.invalidateAndCancel()}
        var request=URLRequest(url:try ModelClient.endpoint(profile,path:"models"));request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        guard let (_,response)=try? await client.data(for:request),(response as? HTTPURLResponse)?.statusCode==200 else {return nil}
        return (profile,key)
    }
}
