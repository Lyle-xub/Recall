import Foundation

struct StorageCategory: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case screenshots, video, audio, models, index, other
        var label:String { switch self { case .screenshots:"Screenshots";case .video:"Video";case .audio:"Audio";case .models:"Models";case .index:"Search index";case .other:"Other" } }
    }
    let kind: Kind
    var bytes: Int64
    var id: String { kind.rawValue }
}
struct StorageUsage: Sendable {
    var categories: [StorageCategory]
    var availableBytes: Int64?
    var capacityBytes: Int64?
    var unreadableFiles: Int
    var measuredAt = Date()
    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    static func formatted(_ bytes:Int64)->String { bytes == 0 ? "0 KB":ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
}

enum StorageUsageReader {
    static func scan(root:URL,modelRoot:URL) throws -> StorageUsage {
        var counts = Dictionary(uniqueKeysWithValues:StorageCategory.Kind.allCases.map { ($0,Int64(0)) })
        var unreadable = 0
        let root = root.resolvingSymlinksInPath().standardizedFileURL,modelRoot = modelRoot.resolvingSymlinksInPath().standardizedFileURL
        let keys:Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey,.fileSizeKey]
        let fm = FileManager.default
        func collect(_ folder:URL,modelsOnly:Bool) throws {
            guard fm.fileExists(atPath:folder.path) else { return }
            guard let iterator = fm.enumerator(at:folder,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{ _,_ in unreadable += 1; return true }) else { unreadable += 1; return }
            while let file = iterator.nextObject() as? URL {
                try Task.checkCancellation()
                do {
                    let values = try file.resourceValues(forKeys:keys)
                    if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                    guard values.isRegularFile == true else { continue }
                    let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                    // Enumerator URLs can expand /var to /private/var; its level
                    // gives the relative path without depending on either spelling.
                    let relative = file.pathComponents.suffix(iterator.level).joined(separator:"/")
                    let relativeModel = modelRoot.path.hasPrefix(root.path + "/") ? String(modelRoot.path.dropFirst(root.path.count+1)) + "/":nil
                    let kind:StorageCategory.Kind
                    if modelsOnly || relativeModel.map({ relative.hasPrefix($0) }) == true || relative.hasPrefix("models/") { kind = .models }
                    else if relative.hasPrefix("frames/") { kind = .screenshots }
                    else if relative.hasPrefix("recordings/") { kind = ["m4a","wav","mp3","aac","caf"].contains(file.pathExtension.lowercased()) ? .audio:.video }
                    else if file.lastPathComponent.hasPrefix("memory.sqlite") { kind = .index }
                    else { kind = .other }
                    counts[kind,default:0] += max(0,bytes)
                } catch is CancellationError { throw CancellationError() }
                catch { unreadable += 1 }
            }
        }
        try collect(root,modelsOnly:false)
        if modelRoot != root,!modelRoot.path.hasPrefix(root.path + "/") { try collect(modelRoot,modelsOnly:true) }
        let disk = try? root.resourceValues(forKeys:[.volumeAvailableCapacityKey,.volumeTotalCapacityKey])
        return StorageUsage(categories:StorageCategory.Kind.allCases.map { StorageCategory(kind:$0,bytes:counts[$0] ?? 0) },availableBytes:disk?.volumeAvailableCapacity.map(Int64.init),capacityBytes:disk?.volumeTotalCapacity.map(Int64.init),unreadableFiles:unreadable)
    }
}
