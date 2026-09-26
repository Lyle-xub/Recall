import Foundation
import CryptoKit
import CSQLite

/// Reuse small catalog/segment page caches between card requests. Decoding is
/// outside the lock; only the short SQLite lookup/copy is serialized.
final class TilePackReader:NSObject {
    private static let cache:NSCache<NSString,TilePackReader> = {
        let cache=NSCache<NSString,TilePackReader>();cache.countLimit=2;cache.totalCostLimit=18*1024*1024;return cache
    }()
    private let store:TilePackStore
    private let lock=NSLock()
    private init(root:URL)throws {store=try TilePackStore(root:root,writable:false)}
    static func cached(root:URL)->TilePackReader? {
        let key=root.resolvingSymlinksInPath().standardizedFileURL.path as NSString
        if let reader=cache.object(forKey:key) {return reader}
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/packs/catalog.sqlite").path),
              let reader=try? TilePackReader(root:root) else {return nil}
        cache.setObject(reader,forKey:key,cost:9*1024*1024);return reader
    }
    static func discardSegment(_ id:Int,root:URL) {
        let key=root.resolvingSymlinksInPath().standardizedFileURL.path as NSString
        if let reader=cache.object(forKey:key) {reader.lock.withLock {reader.store.discardSegment(id)}}
    }
    func read(_ path:String)throws->Data? {try lock.withLock {try store.read(path)}}
}

/// Immutable, content-addressed image bytes in bounded SQLite segments. The
/// catalog publishes a location only after the segment transaction is durable.
/// No image decoding or re-encoding occurs here.
final class TilePackStore {
    static let payloadLimit = 32*1024*1024
    private let directory:URL
    private let root:URL
    private let catalog:TilePackDatabase
    private let writable:Bool
    private let limit:Int
    private var readers:[Int:TilePackDatabase] = [:]
    private var readerOrder:[Int] = []

    init(root:URL,writable:Bool,limit:Int = TilePackStore.payloadLimit) throws {
        self.root = root
        directory = try CleanupFiles.ownedURL("frames/packs/catalog.sqlite",root:root).deletingLastPathComponent()
        self.writable = writable;self.limit = limit
        if writable { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
        let newCatalog = !FileManager.default.fileExists(atPath:directory.appendingPathComponent("catalog.sqlite").path)
        catalog = try TilePackDatabase(directory.appendingPathComponent("catalog.sqlite"),writable:writable)
        if writable {
            if newCatalog {try catalog.execute("PRAGMA auto_vacuum=FULL")}
            try catalog.execute("PRAGMA journal_mode=WAL")
            try catalog.execute("CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY AUTOINCREMENT,bytes INTEGER NOT NULL)")
            try catalog.execute("CREATE TABLE IF NOT EXISTS tiles(key BLOB PRIMARY KEY,segment INTEGER NOT NULL,size INTEGER NOT NULL) WITHOUT ROWID")
            try catalog.execute("CREATE INDEX IF NOT EXISTS tiles_segment ON tiles(segment)")
        }
    }
    static func key(_ path:String)->Data? {
        let prefix = "frames/tiles/t1-"
        guard path.hasPrefix(prefix),path.hasSuffix(".png") || path.hasSuffix(".heic") else {return nil}
        let hash = String(path.dropFirst(prefix.count).split(separator:".").first ?? "")
        let ext = path.hasSuffix(".png") ? ".png":".heic"
        guard hash.count == 64,path == prefix+hash+ext else {return nil}
        var bytes = Data([ext == ".png" ? 0:1]),index = hash.startIndex
        for _ in 0..<32 {
            let end = hash.index(index,offsetBy:2)
            guard let byte = UInt8(hash[index..<end],radix:16) else {return nil}
            bytes.append(byte);index = end
        }
        return bytes
    }
    private func segmentURL(_ id:Int)throws->URL {
        guard id > 0 else {throw RewindError.message("Invalid screenshot segment.")}
        return try CleanupFiles.ownedURL("frames/packs/segment-\(id).sqlite",root:root)
    }
    private func segmentReader(_ id:Int)throws->TilePackDatabase {
        if let reader = readers[id] {return reader}
        let reader = try TilePackDatabase(segmentURL(id),writable:false)
        readers[id] = reader;readerOrder.append(id)
        if readerOrder.count > 8 {readers.removeValue(forKey:readerOrder.removeFirst())}
        return reader
    }
    fileprivate func discardSegment(_ id:Int) {readers[id] = nil;readerOrder.removeAll {$0 == id}}
    func read(_ path:String)throws->Data? {
        guard let key = Self.key(path),let row = try catalog.integers("SELECT segment,size FROM tiles WHERE key=?",[key]).first else {return nil}
        guard let data = try segmentReader(row[0]).blob("SELECT data FROM tiles WHERE key=?",[key]),data.count == row[1],
              Data(SHA256.hash(data:data)) == key.dropFirst() else {throw RewindError.message("A screenshot block failed its integrity check.")}
        return data
    }
    func size(_ path:String)throws->Int64 {
        guard let key = Self.key(path) else {return 0}
        return Int64(try catalog.integers("SELECT size FROM tiles WHERE key=?",[key]).first?.first ?? 0)
    }
    /// Callers serialize mutations for a library. The catalog write transaction
    /// additionally coordinates separate connections/processes.
    func install(_ tiles:[ScreenTile])throws {
        guard writable else {throw RewindError.message("Screenshot storage is read-only.")}
        try catalog.execute("BEGIN IMMEDIATE")
        do {
            var pending:[(Data,Data)] = []
            for tile in tiles {
                try Task.checkCancellation()
                guard let key = Self.key(tile.path),Data(SHA256.hash(data:tile.data)) == key.dropFirst(),tile.data.count <= limit else {throw RewindError.message("Invalid screenshot block.")}
                if let previous = try read(tile.path) {
                    guard previous == tile.data else {throw RewindError.message("A screenshot block changed unexpectedly.")}
                } else {pending.append((key,tile.data))}
            }
            while !pending.isEmpty {
                try Task.checkCancellation()
                var segment = try catalog.integers("SELECT id,bytes FROM segments ORDER BY id DESC LIMIT 1").first
                let newSegment = segment == nil || segment![1]+pending[0].1.count > limit
                if newSegment {
                    try catalog.execute("INSERT INTO segments(bytes) VALUES(0)")
                    segment = try catalog.integers("SELECT last_insert_rowid(),0").first
                }
                let id = segment![0]
                var size = segment![1],batch:[(Data,Data)] = []
                while let first = pending.first,size+first.1.count <= limit {
                    size += first.1.count;batch.append(pending.removeFirst())
                }
                let file = try TilePackDatabase(segmentURL(id),writable:true)
                // Tile payloads are typically several KiB. Larger data pages
                // pack multiple tiles together instead of rounding each BLOB
                // up to one or two 4 KiB pages. The catalog stays on small pages.
                if newSegment {try file.execute("PRAGMA page_size=65536")}
                try file.execute("PRAGMA auto_vacuum=FULL")
                // Large BLOBs need table-leaf payload capacity. WITHOUT ROWID
                // uses index pages and wastes overflow pages for 4–8 KiB tiles.
                try file.execute("CREATE TABLE IF NOT EXISTS tiles(key BLOB PRIMARY KEY NOT NULL,data BLOB NOT NULL)")
                // AUTOINCREMENT rolls back with the catalog transaction. A
                // previous interrupted creation may therefore own this name.
                if newSegment {try file.execute("DELETE FROM tiles")}
                try file.execute("BEGIN IMMEDIATE")
                do {
                    for (key,data) in batch {
                        try Task.checkCancellation()
                        // A crash before catalog commit may have left this exact
                        // key in the segment. Verify it instead of duplicating it.
                        if let previous = try file.blob("SELECT data FROM tiles WHERE key=?",[key]) {
                            guard previous == data else {throw RewindError.message("A screenshot segment could not be verified.")}
                        } else {try file.execute("INSERT INTO tiles VALUES(?,?)",[key,data])}
                    }
                    try file.execute("COMMIT")
                } catch {try? file.execute("ROLLBACK");throw error}
                for (key,data) in batch {try catalog.execute("INSERT INTO tiles VALUES(?,?,?)",[key,id,data.count])}
                try catalog.execute("UPDATE segments SET bytes=? WHERE id=?",[size,id])
            }
            try catalog.execute("COMMIT")
        } catch {try? catalog.execute("ROLLBACK");throw error}
    }
    /// Delete mappings only after the owning frame transaction commits. Bytes
    /// are then reclaimed in each bounded segment; empty segments are unlinked.
    func remove(_ paths:[String])throws {
        guard writable else {return}
        try catalog.execute("BEGIN IMMEDIATE")
        do {
            var groups:[Int:[Data]] = [:]
            for path in paths {
                guard let key = Self.key(path),let row = try catalog.integers("SELECT segment,size FROM tiles WHERE key=?",[key]).first else {continue}
                groups[row[0],default:[]].append(key)
                try catalog.execute("DELETE FROM tiles WHERE key=?",[key])
                try catalog.execute("UPDATE segments SET bytes=bytes-? WHERE id=?",[row[1],row[0]])
            }
            // Catalog commits first. A crash can leave unreachable bytes, never
            // a published key pointing at a deleted block.
            try catalog.execute("COMMIT")
            // Re-read reachability under a fresh writer lock. A concurrent
            // installer may have republished a key since the deletion commit.
            for id in groups.keys {try reclaimSegment(id)}
        } catch {try? catalog.execute("ROLLBACK");throw error}
    }
    /// Bounded maintenance repairs the harmless orphan bytes left by an
    /// interrupted publish/delete. A catalog writer lock excludes installs.
    func reclaimSegment(_ id:Int)throws {
        guard writable else {return}
        try catalog.execute("BEGIN IMMEDIATE")
        do {
            let exists = try catalog.integers("SELECT id FROM segments WHERE id=?",[id]).first != nil
            let url = try segmentURL(id)
            if FileManager.default.fileExists(atPath:url.path) {
                let file = try TilePackDatabase(url,writable:true)
                try file.execute("ATTACH DATABASE ? AS catalog",[directory.appendingPathComponent("catalog.sqlite").path])
                try file.execute("DELETE FROM tiles WHERE key NOT IN (SELECT key FROM catalog.tiles WHERE segment=?)",[id])
            }
            let count = try catalog.integers("SELECT count(*) FROM tiles WHERE segment=?",[id]).first![0]
            if count == 0 {
                if exists {try catalog.execute("DELETE FROM segments WHERE id=?",[id])}
                // A reader already holding an open file can finish on macOS.
                // New readers cannot discover this now-unreferenced segment.
                if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
                discardSegment(id)
                TilePackReader.discardSegment(id,root:root)
            }
            try catalog.execute("COMMIT")
        } catch {try? catalog.execute("ROLLBACK");throw error}
    }
    func segmentIDs()throws->[Int] {
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("segment-"),name.hasSuffix(".sqlite") else {return nil}
            return Int(name.dropFirst(8).dropLast(7))
        }.sorted()
    }
    func allocatedBytes()throws->Int64 {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).reduce(0) {$0 + (try CleanupFiles.size($1))}
    }
    func checkpoint()throws {try catalog.execute("PRAGMA wal_checkpoint(TRUNCATE)")}
}

private final class TilePackDatabase {
    private var db:OpaquePointer?
    private var statements:[String:OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(_ url:URL,writable:Bool)throws {
        let flags = (writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE:SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path,&db,flags,nil) == SQLITE_OK else {sqlite3_close(db);db = nil;throw RewindError.message("Could not open screenshot storage.")}
        sqlite3_busy_timeout(db,5000)
        if writable {try execute("PRAGMA synchronous=FULL")}
        try execute("PRAGMA cache_size=-1024")
    }
    deinit {statements.values.forEach {sqlite3_finalize($0)};sqlite3_close(db)}
    private func statement(_ sql:String,_ values:[Any])throws->OpaquePointer {
        let stmt:OpaquePointer
        if let cached=statements[sql] {stmt=cached}
        else {
            var prepared:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&prepared,nil) == SQLITE_OK,let prepared else {throw error()}
            if statements.count >= 32,let first=statements.first {sqlite3_finalize(first.value);statements.removeValue(forKey:first.key)}
            statements[sql]=prepared;stmt=prepared
        }
        for (offset,value) in values.enumerated() {
            let index = Int32(offset+1)
            if let data = value as? Data {_ = data.withUnsafeBytes {sqlite3_bind_blob(stmt,index,$0.baseAddress,Int32($0.count),transient)}}
            else if let value = value as? Int {sqlite3_bind_int64(stmt,index,Int64(value))}
            else if let value = value as? String {sqlite3_bind_text(stmt,index,value,-1,transient)}
        }
        return stmt
    }
    private func error()->RewindError {.message("Screenshot storage: "+String(cString:sqlite3_errmsg(db)))}
    private func release(_ stmt:OpaquePointer) {sqlite3_reset(stmt);sqlite3_clear_bindings(stmt)}
    func execute(_ sql:String,_ values:[Any] = [])throws {
        let stmt = try statement(sql,values);defer {release(stmt)}
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {throw error()}
    }
    func integers(_ sql:String,_ values:[Any] = [])throws->[[Int]] {
        let stmt = try statement(sql,values);defer {release(stmt)}
        var rows:[[Int]] = [],result = sqlite3_step(stmt)
        while result == SQLITE_ROW {rows.append((0..<sqlite3_column_count(stmt)).map {Int(sqlite3_column_int64(stmt,$0))});result = sqlite3_step(stmt)}
        guard result == SQLITE_DONE else {throw error()};return rows
    }
    func blob(_ sql:String,_ values:[Any] = [])throws->Data? {
        let stmt = try statement(sql,values);defer {release(stmt)}
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE {return nil}
        guard result == SQLITE_ROW,let bytes = sqlite3_column_blob(stmt,0) else {throw error()}
        return Data(bytes:bytes,count:Int(sqlite3_column_bytes(stmt,0)))
    }
}
