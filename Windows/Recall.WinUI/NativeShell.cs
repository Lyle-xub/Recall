using System.Runtime.InteropServices;
using System.Diagnostics;
using Microsoft.UI.Windowing;
using WinRT.Interop;
using Forms = System.Windows.Forms;
namespace Recall;

internal sealed class NativeShell : IDisposable
{
    readonly Window window; readonly nint handle; readonly WndProc callback; readonly nint previous; readonly Forms.NotifyIcon tray; readonly Forms.ToolStripItem recordingMenuItem;
    bool quitting; readonly Action toggle; readonly Action settings; readonly Func<Task> quit; ShortcutSettings shortcuts = new(); nint restoreWindow;
    const int GwlStyle = -16, GwlExStyle = -20; const uint SwpNoActivate = 0x10, SwpShowWindow = 0x40; const int ToggleMessage = 0x8000 + 81;
    int hostBackdropResult;
    bool hostBackdropEnabled = true;
    double maxMessageMs, lastSlowMessageMs;
    uint maxMessage, lastSlowMessage;
    long slowMessages;
    internal object Diagnostics
    {
        get { GetWindowDisplayAffinity(handle, out var affinity); return new { windowVisible = IsWindowVisible(handle), foreground = NativeWindows.GetForegroundWindow() == handle, hostBackdropEnabled, hostBackdropResult, captureAffinity = affinity, trayStatus = tray.Text, recordingAction = recordingMenuItem.Text, maxMessageMs, maxMessage, lastSlowMessageMs, lastSlowMessage, slowMessages }; }
    }
    public NativeShell(Window window, Action toggle, Action record, Action settings, Func<Task> quit)
    {
        this.window = window;
        this.toggle = toggle;
        this.settings = settings;
        this.quit = quit;
        handle = WindowNative.GetWindowHandle(window);
        SetWindowText(handle, "Recall.Native.Overlay");
        SetWindowLongPtr(handle, GwlStyle, unchecked((nint)0x80000000L));
        ConfigureTransparency();
        int enabled = 1;
        DwmSetWindowAttribute(handle, 33, ref enabled, 4);
        hostBackdropResult = DwmSetWindowAttribute(handle, 17, ref enabled, 4);
        DwmSetWindowAttribute(handle, 38, ref enabled, 4);
        var arguments = Environment.GetCommandLineArgs();
        SetWindowDisplayAffinity(handle, arguments.Contains("--validate-capture-excluded") || !arguments.Any(a => a is "--smoke-test" or "--visual-parity") ? 0x11u : 0u);
        callback = Dispatch;
        previous = SetWindowLongPtr(handle, -4, Marshal.GetFunctionPointerForDelegate(callback));
        var dc = GetDC(handle);
        try { ClearBackground(dc); } finally { if (dc != 0) ReleaseDC(handle, dc); }
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Recall", null, (_, _) => toggle());
        recordingMenuItem = menu.Items.Add("Start recording", null, (_, _) => record());
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
        if (Environment.GetCommandLineArgs().Contains("--visual-parity")) return null; // A synthetic window must not compete with the running app for hotkeys.
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
    public void PrepareBackdrop()
    {
        ConfigureTransparency();
        int enabled = 1; hostBackdropResult = DwmSetWindowAttribute(handle,17,ref enabled,4); hostBackdropEnabled = true;
    }
    public void Show()
    {
        if (!hostBackdropEnabled) PrepareBackdrop();
        restoreWindow = NativeWindows.GetForegroundWindow();
        var screen = Forms.Screen.FromPoint(Forms.Cursor.Position);
        // Keep the bottom timeline above a visible taskbar.
        var b = screen.WorkingArea;
        // An auto-hidden taskbar reports the full monitor as its working area,
        // then covers the bottom controls as soon as the pointer reveals it.
        // Reserve one taskbar row on the primary display in that configuration.
        if (b == screen.Bounds && IsTaskbarAutoHidden())
        {
            var inset = (int)Math.Ceiling(52 * GetDpiForWindow(handle) / 96d);
            b = new(b.X, b.Y, b.Width, Math.Max(1, b.Height - inset));
        }
        SetWindowPos(handle, new nint(-1), b.X, b.Y, b.Width, b.Height, SwpShowWindow);
        ShowWindow(handle, 5);
        window.Activate();
        SetForegroundWindow(handle);
    }
    public void Hide()
    {
        ShowWindow(handle, 0);
        // Release the native host as well as the XAML brush; never leave the
        // desktop compositor presenting a cached blur rectangle after dismissal.
        int enabled = 0; hostBackdropResult = DwmSetWindowAttribute(handle,17,ref enabled,4); hostBackdropEnabled = false;
        var blur = new BlurBehind { Flags = 1, Enabled = 0 };
        DwmEnableBlurBehindWindow(handle,ref blur);
        if (restoreWindow != handle && restoreWindow != 0)
            SetForegroundWindow(restoreWindow);
    }
    public void Status(RecordingState state)
    {
        tray.Text = state switch
        {
            { Terminated: true } => "Recall · Not recording",
            { CaptureFaulted: true } => "Recall · Recording interrupted",
            { Requested: true, InterfaceVisible: true } => "Recall · Paused while open",
            { Active: true } => "Recall · Recording",
            { Requested: true } => "Recall · Starting recording",
            _ => "Recall · Not recording"
        };
        recordingMenuItem.Text = state.Requested
            ? state.CaptureFaulted ? "Retry recording" : "Pause recording"
            : "Start recording";
    }
    nint Dispatch(nint h, uint msg, nint w, nint l)
    {
        var started = Stopwatch.GetTimestamp();
        try { return DispatchCore(h,msg,w,l); }
        finally
        {
            var elapsed = (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency;
            if (elapsed > maxMessageMs) { maxMessageMs = elapsed; maxMessage = msg; }
            if (elapsed > 50) { lastSlowMessageMs = elapsed; lastSlowMessage = msg; slowMessages++; }
        }
    }
    nint DispatchCore(nint h, uint msg, nint w, nint l)
    {
        // Without a zero-alpha GDI backing store, transparent portions of the
        // composition mask expose the window class's opaque white background.
        if (msg == 0x0014 && ClearBackground(w)) return 1; // WM_ERASEBKGND
        if (msg == 0x031E) ConfigureTransparency(); // WM_DWMCOMPOSITIONCHANGED
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
    void ConfigureTransparency()
    {
        var margins = new Margins(0, 0, 0, 0);
        DwmExtendFrameIntoClientArea(handle, ref margins);
        // Enable composition alpha without applying an OS blur to the whole
        // desktop. The actual host blur stays inside ClearBackdrop's mask.
        var region = CreateRectRgn(-2, -2, -1, -1);
        try
        {
            var blur = new BlurBehind { Flags = 3, Enabled = 1, Region = region };
            DwmEnableBlurBehindWindow(handle, ref blur);
        }
        finally { if (region != 0) DeleteObject(region); }
    }
    bool ClearBackground(nint dc)
    {
        if (dc == 0 || !GetClientRect(handle, out var rect)) return false;
        return FillRect(dc, ref rect, GetStockObject(4)) != 0; // BLACK_BRUSH: zero-alpha RGB backing
    }
    static bool IsTaskbarAutoHidden()
    {
        var data = new AppBarData { Size = (uint)Marshal.SizeOf<AppBarData>() };
        return (SHAppBarMessage(4, ref data).ToUInt64() & 1) != 0; // ABM_GETSTATE / ABS_AUTOHIDE
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
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct AppBarData { public uint Size; public nint Window; public uint CallbackMessage; public uint Edge; public NativeRect Rect; public nint Parameter; }
    [StructLayout(LayoutKind.Sequential)] struct BlurBehind { public uint Flags; public int Enabled; public nint Region; public int TransitionOnMaximized; }
    [DllImport("dwmapi.dll")] static extern int DwmEnableBlurBehindWindow(nint h, ref BlurBehind blur);
    [DllImport("gdi32.dll")] static extern nint CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint value);
    [DllImport("gdi32.dll")] static extern nint GetStockObject(int index);
    [DllImport("user32.dll")] static extern bool GetClientRect(nint h, out NativeRect rect);
    [DllImport("user32.dll")] static extern int FillRect(nint dc, ref NativeRect rect, nint brush);
    [DllImport("user32.dll")] static extern nint GetDC(nint h);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint h, nint dc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowText(nint h, string text);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern nint SetWindowLongPtr(nint h, int index, nint value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint h, int index);
    [DllImport("user32.dll")] static extern nint CallWindowProc(nint p, nint h, uint m, nint w, nint l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(nint h, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(nint h);
    [DllImport("user32.dll")] static extern bool ShowWindow(nint h, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint h);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(nint h);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(nint h, uint value);
    [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(nint h, out uint value);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(nint h, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(nint h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint FindWindow(string? c, string text);
    [DllImport("user32.dll")] static extern bool PostMessage(nint h, int message, nint w, nint l);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(nint h, ref Margins margins);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint h, int attr, ref int value, int size);
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
}
