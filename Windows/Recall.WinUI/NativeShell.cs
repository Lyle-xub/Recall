using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using WinRT.Interop;
using Forms = System.Windows.Forms;
namespace Recall;

internal sealed class NativeShell : IDisposable
{
    readonly Window window; readonly nint handle; readonly WndProc callback; readonly nint previous; readonly Forms.NotifyIcon tray;
    bool quitting; readonly Action toggle; readonly Action settings; readonly Func<Task> quit; ShortcutSettings shortcuts = new(); nint restoreWindow;
    const int GwlStyle = -16, GwlExStyle = -20; const uint SwpNoActivate = 0x10, SwpShowWindow = 0x40; const int ToggleMessage = 0x8000 + 81;
    public NativeShell(Window window, Action toggle, Action record, Action settings, Func<Task> quit)
    {
        this.window = window;
        this.toggle = toggle;
        this.settings = settings;
        this.quit = quit;
        handle = WindowNative.GetWindowHandle(window);
        SetWindowText(handle, "Recall.Native.Overlay");
        SetWindowLongPtr(handle, GwlStyle, unchecked((nint)0x80000000L));
        var margins = new Margins(-1, -1, -1, -1);
        DwmExtendFrameIntoClientArea(handle, ref margins);
        int enabled = 1;
        DwmSetWindowAttribute(handle, 33, ref enabled, 4);
        DwmSetWindowAttribute(handle, 17, ref enabled, 4);
        DwmSetWindowAttribute(handle, 38, ref enabled, 4);
        SetWindowDisplayAffinity(handle, Environment.GetCommandLineArgs().Contains("--smoke-test") ? 0u : 0x11u);
        callback = Dispatch;
        previous = SetWindowLongPtr(handle, -4, Marshal.GetFunctionPointerForDelegate(callback));
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Recall", null, (_, _) => toggle());
        menu.Items.Add("Start / pause recording", null, (_, _) => record());
        menu.Items.Add("Settings", null, (_, _) => settings());
        menu.Items.Add("Quit Recall", null, async (_, _) => await quit());
        tray = new()
        {
            Icon = new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Recall.ico")),
            Text = "Recall",
            Visible = true,
            ContextMenuStrip = menu
        };
        tray.DoubleClick += (_, _) => toggle();
        window.AppWindow.Closing += (_, e) => { if (quitting) return; e.Cancel = true; toggle(); };
    }
    public string? Configure(ShortcutSettings settings, bool showTaskbar)
    {
        settings.Validate();
        UnregisterHotKey(handle, 1);
        UnregisterHotKey(handle, 2);
        var ok1 = RegisterHotKey(handle, 1, settings.Toggle.Modifiers | 0x4000, settings.Toggle.Key);
        var ok2 = RegisterHotKey(handle, 2, settings.Alternate.Modifiers | 0x4000, settings.Alternate.Key);
        if (!ok1 || !ok2)
        {
            UnregisterHotKey(handle, 1);
            UnregisterHotKey(handle, 2);
            RegisterHotKey(handle, 1, shortcuts.Toggle.Modifiers | 0x4000, shortcuts.Toggle.Key);
            RegisterHotKey(handle, 2, shortcuts.Alternate.Modifiers | 0x4000, shortcuts.Alternate.Key);
            return "That global shortcut is used by another application. The previous shortcuts are still active.";
        }
        shortcuts = settings;
        var style = GetWindowLongPtr(handle, GwlExStyle).ToInt64();
        style = showTaskbar ? (style & ~0x80L) | 0x40000L : (style & ~0x40000L) | 0x80L;
        SetWindowLongPtr(handle, GwlExStyle, (nint)style);
        return null;
    }
    public void Show()
    {
        restoreWindow = NativeWindows.GetForegroundWindow();
        var screen = Forms.Screen.FromPoint(Forms.Cursor.Position);
        var b = screen.Bounds;
        SetWindowPos(handle, new nint(-1), b.X, b.Y, b.Width, b.Height, SwpShowWindow);
        ShowWindow(handle, 5);
        window.Activate();
        SetForegroundWindow(handle);
    }
    public void Hide()
    {
        ShowWindow(handle, 0);
        if (restoreWindow != handle && restoreWindow != 0)
            SetForegroundWindow(restoreWindow);
    }
    public void Status(bool active, bool paused) => tray.Text = active ? "Recall · Recording" : paused ? "Recall · Paused while open" : "Recall · Not recording";
    nint Dispatch(nint h, uint msg, nint w, nint l)
    {
        if (msg == 0x312 || msg == ToggleMessage)
        {
            window.DispatcherQueue.TryEnqueue(() => toggle());
            return 0;
        }
        if (msg == 0x0010)
        {
            window.DispatcherQueue.TryEnqueue(() => toggle());
            return 0;
        }
        return CallWindowProc(previous, h, msg, w, l);
    }
    public static void SignalExisting()
    {
        var h = FindWindow(null, "Recall.Native.Overlay");
        if (h != 0)
            PostMessage(h, ToggleMessage, 0, 0);
    }
    public void Dispose()
    {
        quitting = true;
        UnregisterHotKey(handle, 1);
        UnregisterHotKey(handle, 2);
        tray.Visible = false;
        tray.Dispose();
        SetWindowLongPtr(handle, -4, previous);
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Margins
    {
        public int Left, Right, Top, Bottom; public Margins(int left, int right, int top, int bottom)
        {
            Left = left;
            Right = right;
            Top = top;
            Bottom = bottom;
        }
    }
    delegate nint WndProc(nint h, uint m, nint w, nint l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowText(nint h, string text);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern nint SetWindowLongPtr(nint h, int index, nint value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint h, int index);
    [DllImport("user32.dll")] static extern nint CallWindowProc(nint p, nint h, uint m, nint w, nint l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(nint h, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(nint h, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint h);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(nint h, uint value);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(nint h, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(nint h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint FindWindow(string? c, string text);
    [DllImport("user32.dll")] static extern bool PostMessage(nint h, int message, nint w, nint l);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(nint h, ref Margins margins);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint h, int attr, ref int value, int size);
}
