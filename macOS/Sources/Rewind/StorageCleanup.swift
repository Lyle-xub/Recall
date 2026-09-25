import Foundation

enum StorageCleanupScope:String,CaseIterable,Identifiable,Sendable {
    case trash, older30, older7, all
    var id:String { rawValue }
    var title:String { switch self { case .trash:"Trash only";case .older30:"Older than 30 days";case .older7:"Older than 7 days";case .all:"All recorded memories" } }
    func cutoff(at date:Date) -> Date? {
        switch self { case .older30:Calendar.current.date(byAdding:.day,value:-30,to:date);case .older7:Calendar.current.date(byAdding:.day,value:-7,to:date);default:nil }
    }
}
struct StorageCleanupPlan:Sendable {
    let scope:StorageCleanupScope
    let keepStarred:Bool
    let preparedAt:Date
    let frameIDs:Set<String>
    let sessionIDs:Set<String>
    let paths:[String]
    let bytes:Int64
    let skippedActive:Int
    let skippedStarred:Int
}
struct StorageCleanupResult:Sendable {
    let memories:Int
    let recordings:Int
    let bytes:Int64
    let pendingFileRemoval:Bool
}
struct CleanupFrameRecord:Decodable {
    let id:String
    let time:Double
    let image:String
    let meeting:String?
    let session:String?
    let starred:Int
    let deleted:Double?
    var paths:[String] { [image,meeting].compactMap { $0 }.filter { !$0.isEmpty } }
}
struct CleanupJournal:Codable {
    let frameIDs:[String]
    let paths:[String]
}

enum CleanupFiles {
    static func ownedURL(_ path:String,root:URL) throws -> URL {
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        guard !path.hasPrefix("/"),parts.count > 1,["frames","recordings"].contains(String(parts[0])),
              !parts.contains(".."),!parts.contains(".") else {
            throw RewindError.message("A memory has an invalid media path. Nothing was cleared.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let original = base.appendingPathComponent(path).standardizedFileURL
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.path+"/"+parts[0]+"/"),
              (try? original.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw RewindError.message("A memory points outside its media folder. Nothing was cleared.")
        }
        return resolved
    }
    static func size(_ url:URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath:url.path) else { return 0 }
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey,.fileSizeKey])
        guard values.isRegularFile == true else { throw RewindError.message("A media file could not be validated. Nothing was cleared.") }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}
