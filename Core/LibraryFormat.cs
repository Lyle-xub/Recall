using Microsoft.Data.Sqlite;
namespace Rewind;

public enum LibraryFormat { Missing, Windows, MacOS, Unknown }

public static class LibraryFormats
{
    public static LibraryFormat Detect(string root)
    {
        var path = Path.Combine(root, "memory.sqlite");
        if (!File.Exists(path)) return LibraryFormat.Missing;
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        db.Open();
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT name FROM pragma_table_info('ocr_payloads')";
        using (var rows = cmd.ExecuteReader())
        {
            var names = new HashSet<string>();
            while (rows.Read()) names.Add(rows.GetString(0));
            if (names.Contains("key")) return LibraryFormat.MacOS;
            if (names.Contains("id") && names.Contains("regions")) return LibraryFormat.Windows;
        }
        cmd.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='frames'";
        if (Convert.ToInt32(cmd.ExecuteScalar()) == 0) return LibraryFormat.Unknown;
        cmd.CommandText = "SELECT json FROM frames LIMIT 1";
        if (cmd.ExecuteScalar() is string json)
        {
            using var frame = System.Text.Json.JsonDocument.Parse(json);
            if (frame.RootElement.TryGetProperty("Timestamp", out _)) return LibraryFormat.Windows;
            if (frame.RootElement.TryGetProperty("timestamp", out _)) return LibraryFormat.MacOS;
        }
        // Empty legacy databases are ambiguous; never guess a writer format.
        return LibraryFormat.Unknown;
    }
}
