using System.Windows;
using Application = System.Windows.Application;
namespace Rewind;
public partial class App : Application {
    public static string DataRoot => AppPaths.DataRoot;
    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);NativeMotion.Install();
        try {
            var index = Array.IndexOf(e.Args, "--data-dir");
            if (index >= 0) {
                if (index + 1 >= e.Args.Length) throw new ArgumentException("--data-dir requires a path.");
                AppPaths.DataRoot = Path.GetFullPath(e.Args[index + 1]);
            }
            var window = new MainWindow(e.Args.Contains("--demo")); MainWindow = window; window.Show();
        }
        catch (Exception ex) { System.Windows.MessageBox.Show(ex.Message, "Recall could not start"); Shutdown(1); }
    }
}
