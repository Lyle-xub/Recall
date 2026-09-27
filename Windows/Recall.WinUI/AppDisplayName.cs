namespace Recall;

/// <summary>Friendly labels for known process names; storage keys stay unchanged.</summary>
internal static class AppDisplayName
{
    internal static string For(string storedName)
    {
        var key = storedName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? storedName[..^4] : storedName;
        return key.ToLowerInvariant() switch
        {
            "msedge" => "Microsoft Edge",
            "explorer" => "File Explorer",
            "notepad" => "Notepad",
            "chrome" => "Chrome",
            "winword" => "Word",
            "excel" => "Excel",
            "powerpnt" => "PowerPoint",
            "mspaint" => "Paint",
            _ => storedName
        };
    }
}
