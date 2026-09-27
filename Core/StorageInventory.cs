namespace Rewind;

public record StorageInventory(Dictionary<string, long> Buckets, long TotalBytes, int Files, int Skipped)
{
    public ArchiveStorageInventory Archives { get; init; } = new(0, 0, 0, 0, 0, 0, 0);
}
// References/tiles are logical media counts. PackBytes and the bucket totals
// count physical files once, including SQLite's allocation and WAL overhead.
public record ArchiveStorageInventory(int VideoReferences, int TileReferences, int LooseTiles, long PackedTiles, long PackedPayloadBytes, int PackFiles, long PackBytes);
public static class LibraryStorage
{
    public static StorageInventory Measure(string root, CancellationToken ct = default)
    {
        var buckets = new Dictionary<string, long> { ["images"] = 0, ["video"] = 0, ["audio"] = 0, ["models"] = 0, ["index"] = 0, ["other"] = 0 };
        int count = 0, skipped = 0, videoReferences = 0, tileReferences = 0, looseTiles = 0, packFiles = 0;
        long packBytes = 0, packedTiles = 0, packedPayloadBytes = 0;
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint };
        foreach (var file in new DirectoryInfo(root).EnumerateFiles("*", options))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var relative = Path.GetRelativePath(root, file.FullName).Replace(Path.DirectorySeparatorChar, '/');
                var packed = relative.StartsWith("frames/packs/", StringComparison.Ordinal);
                var extension = file.Extension.ToLowerInvariant();
                if (extension == ".recallvideo") videoReferences++;
                if (extension == ".recallframe") tileReferences++;
                if (TilePackStore.IsTilePath(relative)) looseTiles++;
                if (packed) { packFiles++; packBytes += file.Length; }
                var category = relative.StartsWith("models/", StringComparison.Ordinal) ? "models" : relative.StartsWith("memory.sqlite", StringComparison.Ordinal) ? "index" : packed ? "images" : extension switch { ".jpg" or ".jpeg" or ".png" or ".bmp" or ".webp" or ".heic" or ".recallframe" or ".recallvideo" => "images", ".mp4" or ".mov" => "video", ".wav" or ".m4a" => "audio", _ => "other" };
                buckets[category] += file.Length; count++;
            }
            catch (IOException) { skipped++; }
        }
        if (File.Exists(Path.Combine(root, "frames", "packs", "catalog.sqlite")))
        {
            try { using var packs = new TilePackStore(root); var stats = packs.Statistics(); packedTiles = stats.Tiles; packedPayloadBytes = stats.PayloadBytes; }
            catch (Exception e) when (e is IOException or Microsoft.Data.Sqlite.SqliteException) { skipped++; }
        }
        return new(buckets, buckets.Values.Sum(), count, skipped) { Archives = new(videoReferences, tileReferences, looseTiles, packedTiles, packedPayloadBytes, packFiles, packBytes) };
    }
}
