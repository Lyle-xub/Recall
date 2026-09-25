namespace Rewind;

public static class AppPaths
{
    // Keep the existing location so upgrading does not orphan records or models.
    public static string DataRoot { get; set; } = Environment.GetEnvironmentVariable("RECALL_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RewindReplica");
}
