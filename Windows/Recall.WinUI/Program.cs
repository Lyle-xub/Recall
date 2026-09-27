using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
namespace Recall;

internal static class Program
{
    private static Mutex? single;
    static string? startupLog;
    internal static void TraceStartup(string stage)
    {
        if (startupLog == null) return;
        try { File.AppendAllText(startupLog, $"{DateTimeOffset.UtcNow:O} [{Environment.CurrentManagedThreadId}] {stage}{Environment.NewLine}"); }
        catch (IOException) { }
    }
    [STAThread]
    public static void Main(string[] args)
    {
        // Recall's interface is English; this does not change the Windows
        // input language or the language of recorded content.
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
        System.Globalization.CultureInfo.DefaultThreadCurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
        if (args.Contains("--ocr"))
        {
            Recall.Ocr.OcrWorker.Run(args.Contains("--fallback"));
            return;
        }
        var data = Array.IndexOf(args, "--data-dir");
        if (data >= 0)
        {
            if (data + 1 >= args.Length) throw new ArgumentException("--data-dir requires a path.");
            AppPaths.DataRoot = Path.GetFullPath(args[data + 1]);
        }
        if (args.Contains("--smoke-test"))
            AppPaths.DataRoot = Path.Combine(Path.GetTempPath(), "Recall-Smoke-" + Guid.NewGuid());
        var parity = Array.IndexOf(args, "--visual-parity");
        if (parity >= 0)
        {
            if (parity + 1 >= args.Length) throw new ArgumentException("A visual-parity output directory is required.");
            AppPaths.DataRoot = Path.Combine(Path.GetFullPath(args[parity + 1]), "library");
            Directory.CreateDirectory(Path.GetDirectoryName(AppPaths.DataRoot)!);
            startupLog = Path.Combine(Path.GetDirectoryName(AppPaths.DataRoot)!, "startup.log");
            TraceStartup("Main entered; session=" + System.Diagnostics.Process.GetCurrentProcess().SessionId);
            AppDomain.CurrentDomain.UnhandledException += (_, e) => TraceStartup("Unhandled: " + e.ExceptionObject);
        }
        var explicitRoot = data >= 0 || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("RECALL_DATA_DIR"));
        var mutexName = args.Contains("--smoke-test") || parity >= 0 ? "Local\\Recall.Native.Windows.Validation" : "Local\\Recall.Native.Windows";
        if (explicitRoot && !args.Contains("--smoke-test") && parity < 0)
            mutexName += "." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(AppPaths.DataRoot.ToUpperInvariant())))[..16];
        single = new Mutex(true, mutexName, out var first);
        if (!first)
        {
            TraceStartup("An existing validation instance owns the mutex");
            NativeShell.SignalExisting();
            return;
        }
        try
        {
            TraceStartup("Initialize COM wrappers");
            WinRT.ComWrappersSupport.InitializeComWrappers();
            TraceStartup("Application.Start");
            Application.Start(_ =>
            {
                TraceStartup("Application initialization callback");
                DispatcherQueue.GetForCurrentThread().EnsureSystemDispatcherQueue();
                TraceStartup("System dispatcher initialized");
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                new App(args);
            });
        }
        catch (Exception error) { TraceStartup("Startup failure: " + error); throw; }
    }
}
internal sealed class App : Application, Microsoft.UI.Xaml.Markup.IXamlMetadataProvider
{
    // Code-built views still need the WinUI metadata provider for control
    // templates and resources; no App.xaml is generated in this project.
    Microsoft.UI.Xaml.XamlTypeInfo.XamlControlsXamlMetaDataProvider? metadata;
    Microsoft.UI.Xaml.XamlTypeInfo.XamlControlsXamlMetaDataProvider Metadata => metadata ??= new();
    public Microsoft.UI.Xaml.Markup.IXamlType GetXamlType(Type type) => Metadata.GetXamlType(type);
    public Microsoft.UI.Xaml.Markup.IXamlType GetXamlType(string name) => Metadata.GetXamlType(name);
    public Microsoft.UI.Xaml.Markup.XmlnsDefinition[] GetXmlnsDefinitions() => Metadata.GetXmlnsDefinitions();
    public static RecallWindow? CurrentWindow
    {
        get; private set;
    }
    private readonly string[] arguments;
    public App(string[] args)
    {
        arguments = args;
        Program.TraceStartup("Application constructor");
        UnhandledException += (_, e) => { Program.TraceStartup("XAML unhandled: " + e.Exception); };
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="MessageBoxW", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int StartupMessage(IntPtr owner, string text, string caption, uint type);
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        Program.TraceStartup("OnLaunched");
        // Resource lookup requires the fully constructed Application and its
        // metadata provider. Loading here avoids the native constructor fail-fast.
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        Resources["ContentControlThemeFontFamily"] = Design.BodyFont;
        foreach (var key in new[] { "ComboBoxDropDownBackground", "ContentDialogBackground", "ToolTipBackground" }) Resources[key] = Design.PopupBrush;
        Program.TraceStartup("XAML resources initialized");
        AppRuntime runtime;
        try { runtime = await Task.Run(() => new AppRuntime()); }
        catch (Exception error)
        {
            // Startup may fail before a safe data root exists; do not resolve it again to log the error.
            Program.TraceStartup("Library startup failed: " + error);
            StartupMessage(IntPtr.Zero, error.Message, "Recall could not open your library", 0x10);
            Exit(); return;
        }
        Program.TraceStartup("Runtime initialized");
        var smoke = Array.IndexOf(arguments, "--smoke-test");
        var parity = Array.IndexOf(arguments, "--visual-parity");
        if (smoke >= 0 || parity >= 0)
        {
            runtime.Settings.OnboardingComplete = true;
            runtime.Settings.LaunchFilmSeen = true;
        }
        CurrentWindow = new(runtime);
        runtime.RegisterServiceExit(() => CurrentWindow.DispatcherQueue.TryEnqueue(async () => await CurrentWindow.Quit()));
        Program.TraceStartup("Window constructed");
        if (parity >= 0)
        {
            await VisualParitySession.Start(CurrentWindow, runtime, arguments[parity + 1]);
            return;
        }
        if (smoke >= 0)
        {
            _ = SmokeRunner.Run(CurrentWindow, runtime, arguments[smoke + 1]);
            return;
        }
        if (!arguments.Contains("--background") && !arguments.Contains("--cli-service"))
            CurrentWindow.Show();
    }
}
