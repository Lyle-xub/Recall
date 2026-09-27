using System.Diagnostics;
namespace Rewind;

public static class LibrarySafety
{
    static bool LegacyAssembly(string executable)
    {
        foreach(var path in new[]{executable,Path.ChangeExtension(executable,".dll")})
            try {if(System.Reflection.AssemblyName.GetAssemblyName(path).Name=="RewindReplica")return true;}
            catch(Exception e) when(e is IOException or BadImageFormatException or UnauthorizedAccessException) {}
        return false;
    }
    public static void CheckLegacyDefaultOwner(string root)
    {
        if(OperatingSystem.IsLinux() || LibraryControlClient.Owner(root)!=null) return;
        var defaultRoot=OperatingSystem.IsMacOS() ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Library","Application Support","RewindReplica") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RewindReplica");
        if(!Path.GetFullPath(root).Equals(defaultRoot,OperatingSystem.IsWindows()?StringComparison.OrdinalIgnoreCase:StringComparison.Ordinal))return;
        foreach(var process in new[]{"Recall","RewindReplica"}.SelectMany(Process.GetProcessesByName))
        {
            using(process)
            {
                if(process.Id==Environment.ProcessId)continue;
                string? file;
                try {file=process.MainModule?.FileName;} catch {continue;}
                if(file!=null && (file.Contains(".app/Contents/MacOS/") || File.Exists(Path.Combine(Path.GetDirectoryName(file)!,"Microsoft.UI.Xaml.dll")) || OperatingSystem.IsWindows() && LegacyAssembly(file)))
                    throw new RecallException("legacy_owner","An older Recall desktop is running without the shared-library protocol. Close it or upgrade it before CLI writes to the default library. Read commands remain available.");
            }
        }
    }
}
