using System.Text.Json;

namespace Rewind;

/// A reference to the exact encoded sample captured for a card. Ticks are media
/// presentation timestamps, never offsets estimated from a wall clock.
/// Width/Height are the original native extent. Windows encoders may replicate
/// the right/bottom edge to even dimensions; readers accept only that exact
/// derived extent and crop the padding without scaling the original pixels.
public sealed record VisualArchive(int Version, string Video, long Ticks, int Width, int Height, int Timescale = 10_000_000)
{
    public const string FileExtension = "recallvideo";
    [System.Text.Json.Serialization.JsonIgnore] public double Seconds => (double)Ticks / Timescale;
    public static VisualArchive Read(string path)
    {
        if (new FileInfo(path).Length is <= 0 or > 4096)
            throw new InvalidDataException("Invalid visual archive reference size.");
        return Parse(File.ReadAllText(path));
    }
    public static VisualArchive Parse(string json)
    {
        if (json.Length is <= 0 or > 4096) throw new InvalidDataException("Invalid visual archive reference size.");
        try
        {
            using var document = JsonDocument.Parse(json);
            var value = JsonSerializer.Deserialize<VisualArchive>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidDataException("Invalid visual archive reference.");
            // Existing macOS manifests use the fixed CMTime timescale 600.
            if (!document.RootElement.EnumerateObject().Any(p => p.Name.Equals("Timescale", StringComparison.OrdinalIgnoreCase)))
                value = value with { Timescale = document.RootElement.TryGetProperty("video", out _) ? 600 : 10_000_000 };
            value.ValidateFields();
            return value;
        }
        catch (JsonException error) { throw new InvalidDataException("Invalid visual archive reference.", error); }
    }
    private void ValidateFields()
    {
        if (Version != 1 || Ticks < 0 || Timescale is <= 0 or > 1_000_000_000 || Width is < 1 or > 16000 || Height is < 1 or > 16000 ||
            (long)Width * Height > 40_000_000 || string.IsNullOrEmpty(Video) || !Video.StartsWith("recordings/", StringComparison.Ordinal) || !Video.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Invalid visual archive reference.");
        ArchivePaths.ValidateRelative(Video);
    }
    public string Validate(string root)
    {
        ValidateFields();
        return ArchivePaths.Owned(root, Video);
    }
}

internal static class ArchivePaths
{
    internal static IEqualityComparer<string> MediaComparer { get; } = new MediaPathComparer();
    private sealed class MediaPathComparer : IEqualityComparer<string>
    {
        private static readonly StringComparer Files = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        public bool Equals(string? x, string? y) => Files.Equals(x, y) ||
            (x != null && y != null && TilePackStore.IsTilePath(x) && TilePackStore.IsTilePath(y) && StringComparer.OrdinalIgnoreCase.Equals(x, y));
        public int GetHashCode(string value) => (TilePackStore.IsTilePath(value) ? StringComparer.OrdinalIgnoreCase : Files).GetHashCode(value);
    }
    internal static void ValidateRelative(string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || relative.Contains('\\') || relative.Contains(':') || Path.IsPathRooted(relative) ||
            relative.Split('/').Any(part => part is "" or "." or "..") ||
            !(relative.StartsWith("frames/", StringComparison.Ordinal) || relative.StartsWith("recordings/", StringComparison.Ordinal)))
            throw new InvalidDataException("Invalid archive media path.");
    }
    internal static string Owned(string root, string relative)
    {
        ValidateRelative(relative);
        root = Path.GetFullPath(root);
        var cursor = root;
        foreach (var part in relative.Split('/'))
        {
            cursor = Path.Combine(cursor, part);
            // File.GetAttributes also detects dangling links on supported hosts.
            try
            {
                if ((File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Archive media paths must not contain symbolic links.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
        return cursor;
    }
}
