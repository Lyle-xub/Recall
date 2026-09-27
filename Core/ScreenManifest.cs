using System.Text.Json;
namespace Rewind;

public record ScreenTile(string Path, int X, int Y, int Width, int Height);
public record ScreenManifest(int Version, int Width, int Height, List<ScreenTile> Tiles)
{
    public static ScreenManifest Read(string path)
    {
        if (new FileInfo(path).Length > 2_000_000)
            throw new InvalidDataException("Invalid screenshot manifest size.");
        return Parse(File.ReadAllText(path));
    }
    public static ScreenManifest Parse(string json)
    {
        if (json.Length is <= 0 or > 2_000_000) throw new InvalidDataException("Invalid screenshot manifest size.");
        var value = JsonSerializer.Deserialize<ScreenManifest>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Invalid screenshot manifest.");
        if (value.Version != 1 || value.Width < 1 || value.Height < 1 || value.Width > 16000 || value.Height > 16000 || (long)value.Width * value.Height > 40_000_000 || value.Tiles == null || value.Tiles.Count != ((value.Width + 383) / 384) * ((value.Height + 383) / 384))
            throw new InvalidDataException("Invalid screenshot dimensions.");
        var seen = new HashSet<(int, int)>();
        foreach (var tile in value.Tiles)
        {
            if (tile == null || !TilePackStore.IsTilePath(tile.Path) || tile.X < 0 || tile.Y < 0 || tile.X % 384 != 0 || tile.Y % 384 != 0 || tile.Width != Math.Min(384, value.Width - tile.X) || tile.Height != Math.Min(384, value.Height - tile.Y) || tile.Width < 1 || tile.Height < 1 || !seen.Add((tile.X, tile.Y)))
                throw new InvalidDataException("Invalid screenshot tile.");
        }
        return value;
    }
}
