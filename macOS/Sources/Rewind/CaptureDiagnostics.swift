import Foundation
import OSLog
import CoreGraphics

/// Lifecycle metadata only: never write screenshot text, audio, model prompts or keys.
@MainActor final class CaptureDiagnostics {
    private let url: URL
    private let logger = Logger(subsystem:"studio.rewind.replica",category:"Capture")
    init(root: URL) { url = root.appendingPathComponent("capture-diagnostics.log") }
    func write(_ message: String) {
        logger.notice("\(message,privacy:.public)")
        let data = Data("\(Date().ISO8601Format()) \(message)\n".utf8)
        do {
            let size = (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if size > 256_000 || !FileManager.default.fileExists(atPath:url.path) { try data.write(to:url,options:.atomic) }
            else { let handle = try FileHandle(forWritingTo:url); defer {try? handle.close()}; try handle.seekToEnd(); try handle.write(contentsOf:data) }
        } catch { logger.error("Could not save capture diagnostics") }
    }
}

struct CaptureDimensions: Equatable {
    let width: Int
    let height: Int
    static func native(width: Double,height: Double,scale: Double,fallbackWidth: Int,fallbackHeight: Int) -> CaptureDimensions {
        let w = width * scale, h = height * scale
        // SCContentFilter metadata may not be populated yet during display changes.
        let valid = w.isFinite && h.isFinite && w >= 2 && h >= 2 && w <= 32768 && h <= 32768
        return CaptureDimensions(width:max(2,valid ? Int(w)/2*2:fallbackWidth/2*2),height:max(2,valid ? Int(h)/2*2:fallbackHeight/2*2))
    }
}

enum CaptureDisplaySelection {
    static func choose(available: [UInt32], preferred: UInt32?, main: UInt32) -> UInt32? {
        if let preferred { return available.contains(preferred) ? preferred:nil }
        return available.contains(main) ? main:available.first
    }
}

enum CaptureWindowIDs {
    static func valid(_ values:[Int])->Set<CGWindowID> {
        Set(values.compactMap {value in value > 0 ? CGWindowID(exactly:value):nil})
    }
}
