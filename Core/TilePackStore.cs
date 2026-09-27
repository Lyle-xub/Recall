using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Rewind;

public sealed record TilePayload(string Path, byte[] Data);
public sealed record TileStorageBatch(int Processed, bool More, long SavedBytes);
public sealed record TilePackStatistics(long Tiles, long PayloadBytes, long Segments, long AllocatedBytes);

/// Immutable image bytes in bounded SQLite segments. Segment payloads commit
/// before catalog publication; removal unpublishes before reclaiming bytes.
public sealed class TilePackStore : IDisposable
{
    public const int PayloadLimit = 32 * 1024 * 1024;
    private readonly string root;
    private readonly string directory;
    private readonly SqliteConnection catalog;
    private readonly bool writable;
    private readonly int limit;
    private readonly object gate = new();
    public TilePackStore(string root, bool writable = false, int payloadLimit = PayloadLimit)
    {
        if (payloadLimit is < 1 or > PayloadLimit) throw new ArgumentOutOfRangeException(nameof(payloadLimit));
        this.root = Path.GetFullPath(root); this.writable = writable; limit = payloadLimit;
        var path = ArchivePaths.Owned(this.root, "frames/packs/catalog.sqlite");
        directory = Path.GetDirectoryName(path)!;
        if (writable) Directory.CreateDirectory(directory);
        var isNew = !File.Exists(path);
        catalog = Open(path, writable);
        if (writable)
        {
            if (isNew) Execute(catalog, "PRAGMA auto_vacuum=FULL");
            Execute(catalog, "PRAGMA journal_mode=WAL");
            Execute(catalog, "CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY AUTOINCREMENT,bytes INTEGER NOT NULL)");
            Execute(catalog, "CREATE TABLE IF NOT EXISTS tiles(key BLOB PRIMARY KEY,segment INTEGER NOT NULL,size INTEGER NOT NULL) WITHOUT ROWID");
            Execute(catalog, "CREATE INDEX IF NOT EXISTS tiles_segment ON tiles(segment)");
        }
    }
    public static bool IsTilePath(string path) => path != null && Regex.IsMatch(path, @"^frames/tiles/t1-[A-Fa-f0-9]{64}\.(png|jpg|heic)$", RegexOptions.CultureInvariant);
    public static byte[]? Key(string path)
    {
        if (!IsTilePath(path)) return null;
        var result = new byte[33];
        result[0] = Path.GetExtension(path) switch { ".png" => 0, ".heic" => 1, _ => 2 };
        Convert.FromHexString(path.Substring("frames/tiles/t1-".Length, 64)).CopyTo(result, 1);
        return result;
    }
    private static void Verify(string path, byte[] data)
    {
        var key = Key(path);
        if (key == null || data.Length == 0 || data.Length > PayloadLimit || !SHA256.HashData(data).AsSpan().SequenceEqual(key.AsSpan(1)))
            throw new InvalidDataException("A screenshot block failed its integrity check.");
    }
    public static byte[]? ReadTile(string root, string path)
    {
        if (!IsTilePath(path)) throw new InvalidDataException("Invalid screenshot tile path.");
        var catalogPath = ArchivePaths.Owned(root, "frames/packs/catalog.sqlite");
        if (File.Exists(catalogPath))
        {
            using var packs = new TilePackStore(root);
            if (packs.Read(path) is { } packed) return packed;
        }
        var loose = ArchivePaths.Owned(root, path);
        if (!File.Exists(loose)) return null;
        if (new FileInfo(loose).Length is <= 0 or > PayloadLimit) throw new InvalidDataException("Invalid screenshot block size.");
        var data = File.ReadAllBytes(loose);
        Verify(path, data);
        return data;
    }
    public byte[]? Read(string path)
    {
        lock (gate)
        {
            var key = Key(path);
            if (key == null) return null;
            var row = Location(key);
            if (row == null) return null;
            if (row.Value.Size is <= 0 or > PayloadLimit) throw new InvalidDataException("Invalid screenshot block size.");
            using var segment = Open(SegmentPath(row.Value.Segment), false);
            using var cmd = Command(segment, "SELECT CASE WHEN length(data)=$p1 THEN data ELSE NULL END FROM tiles WHERE key=$p0", key, row.Value.Size);
            var data = cmd.ExecuteScalar() as byte[] ?? throw new InvalidDataException("A screenshot block is missing or has an invalid length.");
            if (data.Length != row.Value.Size) throw new InvalidDataException("A screenshot block has an invalid length.");
            Verify(path, data);
            return data;
        }
    }
    public byte[]? ReadTile(string path)
    {
        if (Read(path) is { } data) return data;
        return ReadLoose(root, path);
    }
    private static byte[]? ReadLoose(string root, string path)
    {
        if (!IsTilePath(path)) throw new InvalidDataException("Invalid screenshot tile path.");
        var loose = ArchivePaths.Owned(root, path);
        if (!File.Exists(loose)) return null;
        if (new FileInfo(loose).Length is <= 0 or > PayloadLimit) throw new InvalidDataException("Invalid screenshot block size.");
        var data = File.ReadAllBytes(loose); Verify(path, data); return data;
    }
    /// <summary>At most two segment handles live during a batch. Dispose the enumerator before cleanup; no decoder handles survive between images.</summary>
    public IEnumerable<TilePayload> ReadTiles(IEnumerable<string> paths)
    {
        var readers = new Dictionary<int, SqliteConnection>();
        var order = new Queue<int>();
        try
        {
            foreach (var path in paths)
            {
                byte[] data;
                lock (gate)
                {
                    var key = Key(path) ?? throw new InvalidDataException("Invalid screenshot tile path.");
                    var row = Location(key);
                    if (row == null) data = ReadLoose(root, path) ?? throw new FileNotFoundException("A screenshot block is missing.", path);
                    else
                    {
                        if (row.Value.Size is <= 0 or > PayloadLimit) throw new InvalidDataException("Invalid screenshot block size.");
                        if (!readers.TryGetValue(row.Value.Segment, out var reader))
                        {
                            if (readers.Count == 2) { var oldest = order.Dequeue(); readers[oldest].Dispose(); readers.Remove(oldest); }
                            reader = Open(SegmentPath(row.Value.Segment), false); readers.Add(row.Value.Segment, reader); order.Enqueue(row.Value.Segment);
                        }
                        using var cmd = Command(reader, "SELECT CASE WHEN length(data)=$p1 THEN data ELSE NULL END FROM tiles WHERE key=$p0", key, row.Value.Size);
                        data = cmd.ExecuteScalar() as byte[] ?? throw new InvalidDataException("A screenshot block is missing or has an invalid length.");
                        Verify(path, data);
                    }
                }
                yield return new(path, data);
            }
        }
        finally { foreach (var reader in readers.Values) reader.Dispose(); }
    }
    public long Size(string path)
    {
        lock (gate) { var key = Key(path); return key == null ? 0 : Location(key)?.Size ?? 0; }
    }
    private (int Segment, long Size)? Location(byte[] key)
    {
        using var cmd = Command(catalog, "SELECT segment,size FROM tiles WHERE key=$p0", key);
        using var reader = cmd.ExecuteReader();
        return reader.Read() ? (checked((int)reader.GetInt64(0)), reader.GetInt64(1)) : null;
    }
    public void Install(IEnumerable<TilePayload> tiles)
    {
        if (!writable) throw new InvalidOperationException("Screenshot storage is read-only.");
        lock (gate)
        {
            Execute(catalog, "BEGIN IMMEDIATE");
            try
            {
                var pending = new Dictionary<string, TilePayload>(StringComparer.Ordinal);
                foreach (var tile in tiles)
                {
                    Verify(tile.Path, tile.Data);
                    if (tile.Data.Length > limit) throw new InvalidDataException("A screenshot block exceeds the segment limit.");
                    if (Read(tile.Path) is { } previous)
                    {
                        if (!previous.AsSpan().SequenceEqual(tile.Data)) throw new InvalidDataException("A screenshot block changed unexpectedly.");
                    }
                    else pending.TryAdd(Convert.ToHexString(Key(tile.Path)!), tile);
                }
                var remaining = new Queue<TilePayload>(pending.Values);
                while (remaining.Count > 0)
                {
                    int id = 0; long bytes = 0;
                    using (var cmd = Command(catalog, "SELECT id,bytes FROM segments ORDER BY id DESC LIMIT 1"))
                    using (var reader = cmd.ExecuteReader())
                        if (reader.Read()) { id = checked((int)reader.GetInt64(0)); bytes = reader.GetInt64(1); }
                    if (bytes is < 0 or > PayloadLimit) throw new InvalidDataException("Invalid screenshot segment payload size.");
                    var isNew = id == 0 || bytes + remaining.Peek().Data.Length > limit;
                    if (isNew)
                    {
                        Execute(catalog, "INSERT INTO segments(bytes) VALUES(0)");
                        using var cmd = Command(catalog, "SELECT last_insert_rowid()");
                        id = checked((int)(long)cmd.ExecuteScalar()!); bytes = 0;
                    }
                    var batch = new List<TilePayload>();
                    while (remaining.Count > 0 && bytes + remaining.Peek().Data.Length <= limit)
                    {
                        var tile = remaining.Dequeue(); batch.Add(tile); bytes += tile.Data.Length;
                    }
                    using (var segment = Open(SegmentPath(id), true))
                    {
                        if (isNew) Execute(segment, "PRAGMA page_size=65536");
                        Execute(segment, "PRAGMA auto_vacuum=FULL");
                        Execute(segment, "CREATE TABLE IF NOT EXISTS tiles(key BLOB PRIMARY KEY NOT NULL,data BLOB NOT NULL)");
                        Execute(segment, "BEGIN IMMEDIATE");
                        try
                        {
                            // A rolled-back catalog may reuse this segment ID.
                            if (isNew) Execute(segment, "DELETE FROM tiles");
                            foreach (var tile in batch)
                            {
                                var key = Key(tile.Path)!;
                                using var query = Command(segment, "SELECT data FROM tiles WHERE key=$p0", key);
                                if (query.ExecuteScalar() is byte[] previous)
                                {
                                    if (!previous.AsSpan().SequenceEqual(tile.Data)) throw new InvalidDataException("A screenshot segment could not be verified.");
                                }
                                else Execute(segment, "INSERT INTO tiles VALUES($p0,$p1)", key, tile.Data);
                            }
                            Execute(segment, "COMMIT");
                        }
                        catch { Execute(segment, "ROLLBACK"); throw; }
                    }
                    foreach (var tile in batch) Execute(catalog, "INSERT INTO tiles VALUES($p0,$p1,$p2)", Key(tile.Path)!, id, tile.Data.Length);
                    Execute(catalog, "UPDATE segments SET bytes=$p0 WHERE id=$p1", bytes, id);
                }
                Execute(catalog, "COMMIT");
            }
            catch { Execute(catalog, "ROLLBACK"); throw; }
        }
    }
    public void Remove(IEnumerable<string> paths)
    {
        if (!writable) throw new InvalidOperationException("Screenshot storage is read-only.");
        lock (gate)
        {
            var segments = new HashSet<int>();
            Execute(catalog, "BEGIN IMMEDIATE");
            try
            {
                foreach (var path in paths)
                {
                    if (Key(path) is not { } key || Location(key) is not { } row) continue;
                    segments.Add(row.Segment);
                    Execute(catalog, "DELETE FROM tiles WHERE key=$p0", key);
                    Execute(catalog, "UPDATE segments SET bytes=bytes-$p0 WHERE id=$p1", row.Size, row.Segment);
                }
                Execute(catalog, "COMMIT");
            }
            catch { Execute(catalog, "ROLLBACK"); throw; }
            foreach (var id in segments) ReclaimSegment(id);
        }
    }
    public void ReclaimSegment(int id)
    {
        if (!writable) throw new InvalidOperationException("Screenshot storage is read-only.");
        lock (gate)
        {
            Execute(catalog, "BEGIN IMMEDIATE");
            try
            {
                var path = SegmentPath(id);
                if (File.Exists(path))
                {
                    using var segment = Open(path, true);
                    Execute(segment, "ATTACH DATABASE $p0 AS catalog", ArchivePaths.Owned(root, "frames/packs/catalog.sqlite"));
                    Execute(segment, "DELETE FROM tiles WHERE key NOT IN (SELECT key FROM catalog.tiles WHERE segment=$p0)", id);
                }
                using var cmd = Command(catalog, "SELECT count(*) FROM tiles WHERE segment=$p0", id);
                if ((long)cmd.ExecuteScalar()! == 0)
                {
                    // No persistent segment handles: Windows can unlink safely.
                    if (File.Exists(path)) File.Delete(path);
                    Execute(catalog, "DELETE FROM segments WHERE id=$p0", id);
                }
                Execute(catalog, "COMMIT");
            }
            catch { Execute(catalog, "ROLLBACK"); throw; }
        }
    }
    public TilePackStatistics Statistics()
    {
        lock (gate)
        {
            using var cmd = Command(catalog, "SELECT count(*),coalesce(sum(size),0),(SELECT count(*) FROM segments) FROM tiles");
            using var reader = cmd.ExecuteReader(); reader.Read();
            return new(reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2), AllocatedBytes());
        }
    }
    public int[] SegmentIds() => Directory.EnumerateFiles(directory, "segment-*.sqlite")
        .Select(Path.GetFileName).Select(name => int.TryParse(name![8..^7], out var id) ? id : 0).Where(id => id > 0).Order().ToArray();
    public long AllocatedBytes() => Directory.EnumerateFiles(directory).Sum(path => new FileInfo(path).Length);
    public void Checkpoint() { lock (gate) Execute(catalog, "PRAGMA wal_checkpoint(TRUNCATE)"); }
    private string SegmentPath(int id) => id > 0 ? ArchivePaths.Owned(root, $"frames/packs/segment-{id}.sqlite") : throw new InvalidDataException("Invalid screenshot segment.");
    private static SqliteConnection Open(string path, bool writable)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = writable ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 15 }.ToString());
        connection.Open();
        Execute(connection, "PRAGMA cache_size=-1024");
        if (writable) Execute(connection, "PRAGMA synchronous=FULL");
        return connection;
    }
    private static SqliteCommand Command(SqliteConnection connection, string sql, params object[] values)
    {
        var cmd = connection.CreateCommand(); cmd.CommandText = sql;
        for (var i = 0; i < values.Length; i++) cmd.Parameters.AddWithValue("$p" + i, values[i]);
        return cmd;
    }
    private static void Execute(SqliteConnection connection, string sql, params object[] values)
    {
        using var cmd = Command(connection, sql, values); cmd.ExecuteNonQuery();
    }
    public void Dispose() { lock (gate) catalog.Dispose(); }
}
