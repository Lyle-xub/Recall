using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
namespace Recall.Cli;

/// .NET 10's Windows Process.Start inherits every inheritable handle, including
/// the caller's original stdout pipe even when new standard pipes are supplied.
/// A background owner must inherit none of those handles or console lifetime.
[SupportedOSPlatform("windows")]
public static class WindowsDetachedProcess
{
    public static Process Start(string executable,IEnumerable<string> arguments)
    {
        executable=Path.GetFullPath(executable);
        var commandLine=new StringBuilder(Quote(executable));
        foreach(var argument in arguments)commandLine.Append(' ').Append(Quote(argument));
        var startup=new StartupInfo { Size=(uint)Marshal.SizeOf<StartupInfo>() };
        var started=CreateProcess(executable,commandLine,IntPtr.Zero,IntPtr.Zero,false,0x00000008,IntPtr.Zero,null,ref startup,out var created);
        var error=started?0:Marshal.GetLastWin32Error();
        try
        {
            if(!started)throw new Win32Exception(error,"Could not start the detached Recall service.");
            var process=Process.GetProcessById((int)created.ProcessId);
            try
            {
                // Keep our own query/wait handle before closing CreateProcess's
                // handles, including when an early startup error exits the child.
                _=process.SafeHandle;
                return process;
            }
            catch {process.Dispose();throw;}
        }
        finally
        {
            if(created.Thread!=IntPtr.Zero)CloseHandle(created.Thread);
            if(created.Process!=IntPtr.Zero)CloseHandle(created.Process);
        }
    }
    static string Quote(string argument)
    {
        if(argument.Contains('\0'))throw new ArgumentException("Process arguments cannot contain NUL.",nameof(argument));
        var result=new StringBuilder("\"");var slashes=0;
        foreach(var character in argument)
        {
            if(character=='\\') {slashes++;continue;}
            // Windows' argv parser consumes pairs of backslashes before a
            // quote; preserve literal quotes and trailing directory separators.
            result.Append('\\',character=='"'?slashes*2+1:slashes).Append(character);
            slashes=0;
        }
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo
    {
        public uint Size;
        public IntPtr Reserved,Desktop,Title;
        public uint X,Y,XSize,YSize,XCountChars,YCountChars,FillAttribute,Flags;
        public ushort ShowWindow,ReservedSize;
        public IntPtr ReservedBytes,Input,Output,Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation
    {
        public IntPtr Process,Thread;
        public uint ProcessId,ThreadId;
    }
    [DllImport("kernel32.dll",EntryPoint="CreateProcessW",CharSet=CharSet.Unicode,SetLastError=true,ExactSpelling=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcess(string applicationName,[In,Out] StringBuilder commandLine,IntPtr processAttributes,IntPtr threadAttributes,[MarshalAs(UnmanagedType.Bool)] bool inheritHandles,uint creationFlags,IntPtr environment,string? currentDirectory,ref StartupInfo startupInfo,out ProcessInformation processInformation);
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);
}
