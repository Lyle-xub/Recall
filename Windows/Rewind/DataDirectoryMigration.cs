namespace Rewind;

public enum DataDirectoryMigrationResult
{
    ExplicitRoot,
    NoLegacyDirectory,
    AlreadyAtDestination,
    Moved
}

public static class DataDirectoryMigration
{
    public static DataDirectoryMigrationResult PrepareDefault()
    {
        if (!AppPaths.UsesDefaultDataRoot)
        {
            if (string.IsNullOrWhiteSpace(AppPaths.DataRoot))
                throw new IOException("RECALL_DATA_DIR must name a data directory. No library was opened.");
            return DataDirectoryMigrationResult.ExplicitRoot;
        }
        return MoveLegacy(AppPaths.LegacyDataRoot, AppPaths.DefaultDataRoot);
    }

    // Only a whole-directory rename is allowed. It keeps SQLite, WAL files,
    // media, models, settings and protected account keys together on one volume.
    // An occupied destination is never merged with, or overwritten by, legacy.
    public static DataDirectoryMigrationResult MoveLegacy(string legacyRoot, string destinationRoot)
    {
        var source = Path.TrimEndingDirectorySeparator(Path.GetFullPath(legacyRoot));
        var destination = Path.TrimEndingDirectorySeparator(Path.GetFullPath(destinationRoot));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (string.Equals(source, destination, comparison) ||
            source.StartsWith(destination + Path.DirectorySeparatorChar, comparison) ||
            destination.StartsWith(source + Path.DirectorySeparatorChar, comparison))
            throw new IOException($"Recall cannot migrate between overlapping data directories: '{source}' and '{destination}'. No library was opened.");

        if (!Directory.Exists(source))
            return Directory.Exists(destination)
                ? DataDirectoryMigrationResult.AlreadyAtDestination
                : DataDirectoryMigrationResult.NoLegacyDirectory;

        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException($"Recall found data at both '{source}' and '{destination}'. Neither library was changed. Choose which directory to keep before starting Recall; automatic merging or replacement is unsafe.");

        try
        {
            if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"The old Recall directory '{source}' is a link. Move it manually so its contents can be verified. No library was opened.");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            // Directory.Move is atomic on the normal same-volume LocalAppData
            // layout. If it cannot rename, fail instead of copying some files.
            Directory.Move(source, destination);
            return DataDirectoryMigrationResult.Moved;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new IOException($"Recall could not move its data from '{source}' to '{destination}'. No new database was opened. Check both locations and close any process using the old library before retrying. Details: {error.Message}", error);
        }
    }
}
