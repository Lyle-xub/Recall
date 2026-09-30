import Foundation
import CoreGraphics
import Darwin

/// Persistent local inference worker. No screenshot or recognized text leaves
/// this Mac; bounded IPC also makes a hung model recoverable without UI work.
final class NeuralOCR: @unchecked Sendable {
    static let shared = NeuralOCR()
    static var root:URL? {
        var roots = [Bundle.main.resourceURL?.appendingPathComponent("runtimes/neural-ocr")].compactMap{$0}
        #if DEBUG
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        roots.append(project.appendingPathComponent("native-runtimes/macos-arm64/neural-ocr"))
        #endif
        return roots.first {FileManager.default.isExecutableFile(atPath:$0.appendingPathComponent("recall-ocr").path) && FileManager.default.fileExists(atPath:$0.appendingPathComponent("rec.onnx").path)}
    }
    private let lock = NSLock()
    private var process:Process?
    private var input:FileHandle?
    private var output:FileHandle?
    private var retryAfter = Date.distantPast
    private func reset() {
        try? input?.close();input = nil
        if let process,process.isRunning {process.terminate()}
        try? output?.close();output = nil;process = nil
    }
    deinit {reset()}
    private func start(_ root:URL) throws {
        if process?.isRunning == true {return}
        reset()
        let worker = Process(),inPipe = Pipe(),outPipe = Pipe()
        worker.executableURL = root.appendingPathComponent("recall-ocr");worker.arguments = [root.path]
        worker.standardInput = inPipe;worker.standardOutput = outPipe;worker.standardError = FileHandle.nullDevice
        // Utility QoS can confine inference to efficiency cores under load,
        // extending the same bounded job far beyond the capture interval.
        // User-interactive UI work still outranks this serial two-thread worker;
        // the foreground gate and thermal/inter-job budgets remain in the owner.
        worker.qualityOfService = .userInitiated
        // Bound Accelerate helpers too; ONNX's own pool is capped in the worker.
        worker.environment = ProcessInfo.processInfo.environment.merging(["VECLIB_MAXIMUM_THREADS":"2"]) { _,limit in limit }
        try worker.run();process = worker;input = inPipe.fileHandleForWriting;output = outPipe.fileHandleForReading
    }
    func recognize(_ image:CGImage,source:URL? = nil) throws -> (String,[TextRegion]) {
        if let source {return try recognize(source:source)}
        try lock.withLock {
            try Task.checkCancellation()
            guard Date() >= retryAfter,Self.root != nil else {throw RewindError.message("Neural text recognition is temporarily unavailable.")}
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recall-neural-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = folder.appendingPathComponent("source.png")
        try ScreenArchive.saveSource(image,to:url)
        return try recognize(source:url)
    }
    /// The worker decodes the durable PNG itself; avoid decoding it again in Swift.
    func recognize(source:URL) throws -> (String,[TextRegion]) {
        try lock.withLock {
            try Task.checkCancellation()
            guard Date() >= retryAfter,let root = Self.root else {throw RewindError.message("Neural text recognition is temporarily unavailable.")}
            do {
                try start(root)
                guard let input,let output else {throw RewindError.message("The text-recognition worker did not start.")}
                var request = try JSONSerialization.data(withJSONObject:["image":source.path]);request.append(10)
                try input.write(contentsOf:request)
                var response = Data();let deadline = Date().addingTimeInterval(45)
                while response.last != 10 {
                    try Task.checkCancellation()
                    guard Date() < deadline,response.count < 2_000_000 else {throw RewindError.message("Text recognition timed out. The original screenshot has been kept.")}
                    var descriptor = pollfd(fd:output.fileDescriptor,events:Int16(POLLIN),revents:0)
                    let ready = poll(&descriptor,1,100)
                    if ready < 0,errno == EINTR {continue}
                    guard ready >= 0 else {throw RewindError.message("The text-recognition worker disconnected.")}
                    if ready == 0 {continue}
                    var buffer = [UInt8](repeating:0,count:65536)
                    let count = Darwin.read(output.fileDescriptor,&buffer,buffer.count)
                    if count < 0,errno == EINTR {continue}
                    guard count > 0 else {throw RewindError.message("The text-recognition worker stopped.")}
                    response.append(contentsOf:buffer.prefix(count))
                }
                struct Region:Decodable {let text:String;let x:Double;let y:Double;let width:Double;let height:Double}
                struct Reply:Decodable {let regions:[Region]}
                let regions = try JSONDecoder().decode(Reply.self,from:response).regions.filter {
                    !$0.text.isEmpty && $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0 && $0.x+$0.width <= 1.001 && $0.y+$0.height <= 1.001
                }
                let indexed = regions.enumerated().map {index,row in
                    TextRegion(id:"r\(index)",text:row.text,x:row.x,y:row.y,width:row.width,height:row.height)
                }
                return (indexed.map(\.text).joined(separator:"\n"),indexed)
            } catch {
                reset();retryAfter = error is CancellationError ? .distantPast:Date().addingTimeInterval(60)
                throw error
            }
        }
    }
}
