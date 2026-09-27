namespace Rewind;

public static class AppPaths
{
    private static readonly string? environmentRoot = Environment.GetEnvironmentVariable("RECALL_DATA_DIR");
    private static string dataRoot = environmentRoot ?? DefaultDataRoot;
    private static bool explicitlySet = environmentRoot != null;

    public static string DefaultDataRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recall", "Data");
    public static string LegacyDataRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RewindReplica");

    // The environment variable and the test/CLI setter are deliberate roots;
    // neither should inspect or migrate the user's default library.
    public static bool UsesDefaultDataRoot => !explicitlySet;
    public static string DataRoot
    {
        get => dataRoot;
        set
        {
            dataRoot = value ?? throw new ArgumentNullException(nameof(value));
            explicitlySet = true;
        }
    }
}
