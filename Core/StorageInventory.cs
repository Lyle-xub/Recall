namespace Rewind;

public record StorageInventory(Dictionary<string, long> Buckets, long TotalBytes, int Files, int Skipped);
public static class LibraryStorage
{
    public static StorageInventory Measure(string root, CancellationToken ct = default)
    {
        var buckets = new Dictionary<string, long> { ["images"] = 0, ["video"] = 0, ["audio"] = 0, ["models"] = 0, ["index"] = 0, ["other"] = 0 };
        int count = 0, skipped = 0;
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint };
        foreach (var file in new DirectoryInfo(root).EnumerateFiles("*", options))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var relative = Path.GetRelativePath(root, file.FullName);
                var category = relative.StartsWith("models" + Path.DirectorySeparatorChar) ? "models" : relative.StartsWith("memory.sqlite") ? "index" : file.Extension.ToLowerInvariant() switch { ".jpg" or ".png" or ".heic" or ".recallframe" => "images", ".mp4" or ".mov" => "video", ".wav" or ".m4a" => "audio", _ => "other" };
                buckets[category] += file.Length; count++;
            }
            catch (IOException) { skipped++; }
        }
        return new(buckets, buckets.Values.Sum(), count, skipped);
    }
}
