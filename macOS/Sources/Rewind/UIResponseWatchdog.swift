import Foundation
import OSLog

/// Collect a bounded local thread sample if the UI queue stops responding. A
/// compositor hitch report alone cannot explain a later, sustained freeze.
final class UIResponseWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label:"studio.recall.ui-response",qos:.utility)
    private var timer: DispatchSourceTimer?
    private var awaitingSince:TimeInterval?
    private var sampledThisDelay = false
    private var lastSample = -Double.infinity
    private let logger = Logger(subsystem:"studio.rewind.replica",category:"UIResponsiveness")
    private let root:URL
    init(root:URL) {
        self.root = root
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+2,repeating:2,leeway:.milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer;timer.resume()
    }
    deinit { timer?.cancel() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let since = awaitingSince {
            if now-since >= 6,!sampledThisDelay,now-lastSample >= 60 {
                sampledThisDelay = true;lastSample = now
                collectSample(delay:now-since)
            }
            return
        }
        awaitingSince = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { self.awaitingSince = nil;self.sampledThisDelay = false }
        }
    }
    private func collectSample(delay:TimeInterval) {
        let directory = root.appendingPathComponent("diagnostics",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let reports = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
                .filter { $0.lastPathComponent.hasPrefix("ui-delay-") && $0.pathExtension == "sample" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in reports.prefix(max(0,reports.count-2)) { try? FileManager.default.removeItem(at:old) }
            let output = directory.appendingPathComponent("ui-delay-\(Int(Date().timeIntervalSince1970)).sample")
            let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/sample")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier),"2","20","-file",output.path]
            process.qualityOfService = .utility;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
            try process.run()
            logger.warning("Main queue response delayed \(Int(delay),privacy:.public)s; collecting local thread sample")
        } catch { logger.error("Could not collect UI delay sample; code=\((error as NSError).code,privacy:.public)") }
    }
}
