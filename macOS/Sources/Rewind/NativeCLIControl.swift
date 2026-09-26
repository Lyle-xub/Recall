import Foundation
import Darwin

/// Event-driven, per-user file RPC shared with Recall.Core. One desktop owns
/// capture/index/maintenance; clients never launch a second recording engine.
@MainActor final class NativeCLIControl {
    private let lease:CoreCLILease
    private let instance = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    private var source:DispatchSourceFileSystemObject?
    private var descriptor:Int32 = -1
    private var task:Task<Void,Never>?
    private var stopped = false
    private let handler:(String,[String:Any]) async throws -> Any
    init(lease:CoreCLILease,handler:@escaping (String,[String:Any]) async throws -> Any) throws {
        self.lease = lease;self.handler = handler
        descriptor = open(lease.directory.path,O_EVTONLY)
        guard descriptor >= 0 else { throw CoreCLIError(code:"permission_denied",message:"Cannot watch the control directory.") }
        let descriptor = self.descriptor
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor:descriptor,eventMask:.write,queue:.main)
        watcher.setEventHandler { [weak self] in self?.drain() }
        watcher.setCancelHandler { close(descriptor) };source = watcher;watcher.resume()
        try write(["protocol":1,"pid":getpid(),"instance":instance,"backend":"macos"],to:lease.directory.appendingPathComponent("owner.json"))
    }
    private func write(_ value:Any,to url:URL)throws {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func drain() {
        guard !stopped,task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return };defer { task = nil }
            while !stopped && !Task.isCancelled {
                let requests = ((try? FileManager.default.contentsOfDirectory(at:lease.directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey])) ?? []).filter { file in let id = file.lastPathComponent.replacingOccurrences(of:".request.json",with:"");return file.lastPathComponent.hasSuffix(".request.json") && id.count == 32 && id.allSatisfy({$0.isHexDigit}) }.prefix(32)
                guard !requests.isEmpty else { break }
                for file in requests {
                    guard !stopped else { break }
                    let id = file.lastPathComponent.replacingOccurrences(of:".request.json",with:"")
                    guard id.count == 32,id.allSatisfy({$0.isHexDigit}) else { continue }
                    var response:[String:Any]
                    do {
                        let attributes = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
                        guard attributes.isSymbolicLink != true,(attributes.fileSize ?? Int.max) <= 2_000_000,
                              let request = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],request["instance"] as? String == instance,
                              let operation = request["operation"] as? String,let args = request["args"] as? [String:Any] else { throw CoreCLIError(code:"invalid_request",message:"Invalid or stale control request.") }
                        response = ["ok":true,"result":try await handler(operation,args)]
                    } catch { response = ["ok":false,"error":["code":(error as? CoreCLIError)?.code ?? "operation_failed","message":error.localizedDescription]] }
                    try? write(response,to:lease.directory.appendingPathComponent(id+".response.json"))
                    try? FileManager.default.removeItem(at:file)
                }
            }
        }
    }
    func stop() async {
        stopped = true
        source?.cancel();source = nil
        await task?.value
        try? FileManager.default.removeItem(at:lease.directory.appendingPathComponent("owner.json"))
    }
    deinit { source?.cancel() }
}
