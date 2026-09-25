using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
namespace Recall;

internal static class Program
{
    private static Mutex? single;
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Contains("--ocr"))
        {
            Recall.Ocr.OcrWorker.Run(args.Contains("--fallback"));
            return;
        }
        if (args.Contains("--smoke-test"))
            AppPaths.DataRoot = Path.Combine(Path.GetTempPath(), "Recall-Smoke-" + Guid.NewGuid());
        single = new Mutex(true, args.Contains("--smoke-test") ? "Local\\Recall.Native.Windows.Smoke" : "Local\\Recall.Native.Windows", out var first);
        if (!first)
        {
            NativeShell.SignalExisting();
            return;
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ => { DispatcherQueue.GetForCurrentThread().EnsureSystemDispatcherQueue(); SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread())); new App(args); });
    }
}
internal sealed class App : Application
{
    public static RecallWindow? CurrentWindow
    {
        get; private set;
    }
    private readonly string[] arguments;
    public App(string[] args)
    {
        arguments = args;
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        UnhandledException += (_, e) => { Directory.CreateDirectory(AppPaths.DataRoot); File.AppendAllText(Path.Combine(AppPaths.DataRoot, "errors.log"), DateTimeOffset.Now + " " + e.Exception + Environment.NewLine); };
    }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var runtime = await Task.Run(() => new AppRuntime());
        var smoke = Array.IndexOf(arguments, "--smoke-test");
        if (smoke >= 0)
        {
            runtime.Settings.OnboardingComplete = true;
            runtime.Settings.LaunchFilmSeen = true;
        }
        CurrentWindow = new(runtime);
        if (smoke >= 0)
        {
            _ = SmokeRunner.Run(CurrentWindow, runtime, arguments[smoke + 1]);
            return;
        }
        if (!arguments.Contains("--background"))
            CurrentWindow.Show();
    }
}
