import Foundation

/// Back off from a failing system accelerator without losing the original
/// screenshot or treating a recognition failure as an empty successful result.
final class OCRRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private var compatibleUntil:Date
    private let defaults:UserDefaults?
    private static let key = "ocrCompatibleUntil"
    init(defaults:UserDefaults? = nil) {
        self.defaults = defaults
        compatibleUntil = Date(timeIntervalSince1970:defaults?.double(forKey:Self.key) ?? 0)
    }
    var usesCompatibility:Bool { lock.withLock { Date() < compatibleUntil } }
    func recognize<T>(at now:Date = Date(),primary:() throws -> T,compatible:() throws -> T) throws -> T {
        if lock.withLock({now < compatibleUntil}) { return try compatible() }
        do { return try primary() }
        catch {
            let error = error as NSError
            guard error.domain.contains("TextRecognition") || error.domain.contains("E5RT") else { throw error }
            lock.withLock {
                compatibleUntil = now.addingTimeInterval(3600)
                defaults?.set(compatibleUntil.timeIntervalSince1970,forKey:Self.key)
            }
            return try compatible()
        }
    }
}

/// Vision can wait indefinitely for a system compiler. A deadline frees the
/// indexing queue to use the bundled recognizer while the cancelled call unwinds.
enum BoundedOCRWork {
    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var result:Result<T,Error>?
    }
    static func run<T>(timeout:TimeInterval,cancel:()->Void,operation:@escaping () throws -> T) throws -> T {
        let box = Box<T>(),done = DispatchSemaphore(value:0)
        DispatchQueue.global(qos:.utility).async {
            let result = Result {try operation()}
            box.lock.withLock {box.result = result};done.signal()
        }
        guard done.wait(timeout:.now()+timeout) == .success else {
            cancel();throw NSError(domain:"TextRecognition.Timeout",code:1)
        }
        return try box.lock.withLock {try box.result!.get()}
    }
}
