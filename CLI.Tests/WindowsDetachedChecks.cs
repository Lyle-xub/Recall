using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.Json;
using Recall.Cli;

[SupportedOSPlatform("windows")]
static class WindowsDetachedChecks
{
    public static FileStream InheritableFile(string path)
    {
        var file=new FileStream(path,FileMode.Create,FileAccess.ReadWrite,FileShare.Read);
        if(SetHandleInformation(file.SafeFileHandle.DangerousGetHandle(),1,1))return file;
        var error=new Win32Exception(Marshal.GetLastWin32Error());file.Dispose();throw error;
    }
    public static async Task Arguments(string root,Action<bool,string> assert)
    {
        var output=Path.Combine(root,"detached 参数 result.json");
        var executable=Environment.ProcessPath!;
        var arguments=new List<string>();
        if(Path.GetFileNameWithoutExtension(executable).Equals("dotnet",StringComparison.OrdinalIgnoreCase))arguments.Add(typeof(WindowsDetachedChecks).Assembly.Location);
        string[] expected=["", "has spaces", "中文路径", "embedded\"quote", "backslash\\\"quote", @"C:\synthetic folder\", @"ends\\"];
        arguments.AddRange(["--detached-argument-probe",output]);arguments.AddRange(expected);
        using var process=WindowsDetachedProcess.Start(executable,arguments);
        try
        {
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await process.WaitForExitAsync(timeout.Token);
            assert(process.ExitCode==0 && JsonSerializer.Deserialize<string[]>(File.ReadAllText(output))!.SequenceEqual(expected),"Detached Windows argv preserves Unicode, empty arguments, literal quotes and trailing backslashes");
        }
        finally {if(!process.HasExited){process.Kill(true);process.WaitForExit();}}
    }
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
}
