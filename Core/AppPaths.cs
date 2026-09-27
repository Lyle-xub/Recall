namespace Rewind;

public static class AppPaths
{
    private static string? dataRoot;
    // Explicit assignments never evaluate or migrate the default library.
    public static string DataRoot { get => dataRoot ??= DefaultLibrary.Resolve(); set => dataRoot = Path.GetFullPath(value); }
}
