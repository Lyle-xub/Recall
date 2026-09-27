using System.Windows;
using Application = System.Windows.Application;
namespace Rewind;
public partial class App : Application {
    public static string DataRoot { get; private set; } = AppPaths.DataRoot;
    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);NativeMotion.Install();
        var index = Array.IndexOf(e.Args, "--data-dir");
        try {
            if (index >= 0 && index + 1 < e.Args.Length) AppPaths.DataRoot = Path.GetFullPath(e.Args[index + 1]);
            DataDirectoryMigration.PrepareDefault();
            DataRoot = AppPaths.DataRoot;
            var window = new MainWindow(e.Args.Contains("--demo")); MainWindow = window; window.Show();
        }
        catch (Exception ex) { System.Windows.MessageBox.Show(ex.Message, "Rewind could not start"); Shutdown(1); }
    }
}
