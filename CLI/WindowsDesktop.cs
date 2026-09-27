using Rewind;

namespace Recall.Cli;

internal static class WindowsDesktop
{
    internal static string? Discover(bool? windows = null, string? localApplicationData = null, string? configured = null)
    {
        if (!(windows ?? OperatingSystem.IsWindows())) return null;
        configured ??= Environment.GetEnvironmentVariable("RECALL_WINDOWS_APP");
        var explicitPath = !string.IsNullOrWhiteSpace(configured);
        var candidate = explicitPath ? configured! : Path.Combine(localApplicationData ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Recall", "Recall.exe");
        if (!Path.IsPathFullyQualified(candidate) || !File.Exists(candidate))
        {
            if (explicitPath) throw new RecallException("engine_missing", "RECALL_WINDOWS_APP must be the absolute path to the installed Windows Recall desktop executable.");
            return null;
        }
        candidate = Path.GetFullPath(candidate);
        // CLI and desktop executables differ only by case on some packages.
        // Do not recursively invoke the CLI when an override selects it.
        var cliHost = Path.ChangeExtension(typeof(CliApplication).Assembly.Location, ".exe");
        var assembly = Path.ChangeExtension(candidate, ".dll");
        var cliAssembly = false;
        if (File.Exists(assembly))
        {
            try { cliAssembly = System.Reflection.AssemblyName.GetAssemblyName(assembly).Name == typeof(CliApplication).Assembly.GetName().Name; }
            catch (Exception e) when (e is BadImageFormatException or FileLoadException) { }
        }
        if (candidate.Equals(Environment.ProcessPath, StringComparison.OrdinalIgnoreCase) || candidate.Equals(cliHost, StringComparison.OrdinalIgnoreCase) || cliAssembly)
            throw new RecallException("engine_missing", "RECALL_WINDOWS_APP points to the CLI. Select the Windows desktop Recall.exe instead.");
        return candidate;
    }
    internal static string[] Arguments(string root) => ["--background", "--cli-service", "--data-dir", Path.GetFullPath(root)];
}
