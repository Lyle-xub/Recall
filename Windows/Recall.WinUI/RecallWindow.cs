using Microsoft.UI.Input;
using Windows.System;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Hosting;
using System.Numerics;
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
namespace Recall;

internal sealed class RecallWindow : Window
{
    const int SearchPageSize = 60;
    readonly ClearBackdrop backdrop = new(); readonly AppRuntime runtime; readonly NativeShell shell; readonly Grid root = new(), page = new(); readonly TimelineView timeline;
    readonly Image desktopScene = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    readonly Image desktopBlurScene = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    WriteableBitmap? desktopBlurSource, desktopTimelineBlurSource;
    int desktopSceneRevision;
    readonly RhineArchiveView archive; readonly Button back, topMenu; readonly AccessibilityGrid toolbar = new(); readonly TextBox search = Design.Input("Search anything you’ve seen, said, or heard", height: 72, externalGlass: true); readonly StackPanel actions = new() { Orientation = Orientation.Horizontal, Spacing = 16 };
    readonly TextBlock notice = Design.Text("", 13, color: Design.Muted); readonly Microsoft.UI.Dispatching.DispatcherQueueTimer statusTimer;
    readonly Border noticeHost = new() { CornerRadius = new(16), Padding = new(16, 9, 16, 9), MaxWidth = 680, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
    readonly Button archiveClose;
    readonly Border searchGlass = new() { CornerRadius = new(38), IsHitTestVisible = false };
    Microsoft.UI.Dispatching.DispatcherQueueTimer? toolbarTimer;
    (double Width, double Height, double Top, double Actions) toolbarTarget;
    double archiveSafeTop, archiveSafeBottom;
    CancellationTokenSource? queryCancellation; DetailView? detail; DetailView? transitioningDetail; int detailTransitionRevision; bool expanded, quitting; string mode = "home"; string? appFilter; bool starred, trash; MemoryFrame? selected; string? lastSearchSignature; DateTimeOffset? searchSince;
    public bool IsShown
    {
        get; private set;
    }
    public RecallWindow(AppRuntime runtime)
    {
        this.runtime = runtime;
        Title = "Recall";
        Content = root;
        backdrop.SetVisible(false);
        root.Background = Design.Brush(Color.FromArgb(1, 255, 255, 255));
        Design.SetDark(runtime.Settings.DarkAppearance);
        root.RequestedTheme = runtime.Settings.DarkAppearance ? ElementTheme.Dark : ElementTheme.Light;
        notice.MaxLines = 2;
        notice.TextTrimming = TextTrimming.CharacterEllipsis;
        notice.TextAlignment = TextAlignment.Center;
        noticeHost.Child = notice;
        GlassMaterial.Attach(noticeHost, 16);
        notice.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => LayoutNotice());
        shell = new(this, Toggle, () => { var state = runtime.Recording.State; runtime.Recording.Request(state.CaptureFaulted || !state.Requested); UpdateStatus(); }, () => Navigate("settings"), Quit);
        search.SizeChanged += (_, _) => { if (!GlassMaterial.EffectsAvailable) QueueBackdrop(); };
        var error = shell.Configure(runtime.Settings.Shortcuts, runtime.Settings.ShowTaskbarIcon);
        if (error != null)
            notice.Text = error;
        timeline = new(runtime, Preview);
        archive = new(runtime, OpenFrame);
        timeline.Committed += frame =>
        {
            if (!runtime.Settings.RhineLabMode || mode != "home") return;
            if (frame != null) archive.Seek(frame, true);
        };
        archive.TimelineRequested += ShowArchiveTimeline;
        archive.DockSizeChanged += UpdateArchiveSafeArea;
        timeline.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => UpdateArchiveSafeArea());
        back = Design.Icon("\uE72B", "Back", () => Navigate("home"), 56);
        back.HorizontalAlignment = HorizontalAlignment.Left; back.VerticalAlignment = VerticalAlignment.Top; back.Margin = new(28, 16, 0, 0);
        topMenu = Design.Icon("\uE712", "Recall menu", () => { }, 56);
        topMenu.HorizontalAlignment = HorizontalAlignment.Right; topMenu.VerticalAlignment = VerticalAlignment.Top; topMenu.Margin = new(0, 16, 28, 0);
        topMenu.Flyout = MainMenu();
        archiveClose = Design.Icon("\uE711", "Close Recall", () =>
        {
            if (archive.IsExpanded) archive.Collapse();
            else _ = Hide();
        }, 56);
        archiveClose.HorizontalAlignment = HorizontalAlignment.Left; archiveClose.VerticalAlignment = VerticalAlignment.Top;
        archive.ExpansionChanged += open =>
        {
            if (open) archive.Focus(FocusState.Programmatic);
            SetToolbarVisible(mode is not ("settings" or "onboarding" or "usage"));
            archiveClose.Visibility = mode == "home" && runtime.Settings.RhineLabMode
                ? Visibility.Visible : Visibility.Collapsed;
            topMenu.Visibility = mode == "onboarding" ? Visibility.Collapsed : Visibility.Visible;
            archiveClose.Content = Design.Symbol(open ? "\uE72B" : "\uE711");
            AutomationProperties.SetName(archiveClose, open ? "Back to archive" : "Close Recall");
            StyleArchiveGlyph(archiveClose, 16);
            UpdateArchiveSafeArea();
        };
        BuildToolbar();
        root.PointerPressed += (_, e) => { if (ReferenceEquals(e.OriginalSource, root) || ReferenceEquals(e.OriginalSource, page)) { _ = Hide(); e.Handled = true; } };
        root.PointerMoved += (_, e) =>
        {
            UpdateArchiveTimelineForPointer(e.GetCurrentPoint(root).Position.Y,
                archive.IsOverDayControls(e.GetCurrentPoint(archive).Position));
        };
        root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Keys), true);
        runtime.Error += message => DispatcherQueue.TryEnqueue(() => notice.Text = message);
        runtime.Changed += () => DispatcherQueue.TryEnqueue(UpdateStatus);
        runtime.LibraryChanged += () => DispatcherQueue.TryEnqueue(() => { if (mode == "search") _ = Search(); else if (mode == "home") _ = archive.Refresh(); detail?.RefreshStatus(); });
        statusTimer = DispatcherQueue.CreateTimer();
        statusTimer.Interval = TimeSpan.FromMilliseconds(800);
        statusTimer.Tick += (_, _) => { if (IsShown) detail?.RefreshStatus(); };
        SizeChanged += (_, _) => LayoutToolbar();
        root.SizeChanged += (_, _) => { LayoutToolbar(); UpdateArchiveSafeArea(); Backdrop(); };
        // The liquid brushes follow compositor transforms on their own. Rebuilding
        // the native graph on every layout/spring frame caused long UI stalls.
        root.LayoutUpdated += (_, _) => layoutUpdates++;
        UpdateStatus();
    }
    bool materialDesktop, nativeBackdropActive;
    long layoutUpdates, backdropUpdates;
    double maxBackdropMs, lastDesktopSnapshotMs, lastDesktopCaptureMs, lastShowMs;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? backdropLayoutTimer;
    void QueueBackdrop()
    {
        if (backdropLayoutTimer == null)
        {
            backdropLayoutTimer = DispatcherQueue.CreateTimer(); backdropLayoutTimer.Interval = TimeSpan.FromMilliseconds(33); backdropLayoutTimer.IsRepeating = false;
            backdropLayoutTimer.Tick += (_, _) => Backdrop();
        }
        if (!backdropLayoutTimer.IsRunning) backdropLayoutTimer.Start();
    }
    void Backdrop()
    {
        var started = Stopwatch.GetTimestamp();
        try { BackdropCore(); }
        finally { backdropUpdates++; maxBackdropMs = Math.Max(maxBackdropMs,(Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency); }
    }
    void BackdropCore()
    {
        if (!IsShown || !nativeBackdropActive || root.ActualWidth <= 0)
            return;
        if (mode == "material") { backdrop.Update(materialDesktop, root.ActualWidth, root.ActualHeight, new Rect(), [], GlassMaterial.DesktopSurfaces(root)); return; }
        var rect = new Rect();
        var circles = new List<Rect>();
        var surfaces = new List<ControlBackdrop.Surface>();
        // LiquidGlassWinUI already owns the normal control lenses. Build the
        // duplicate native masks only when that effect has fallen back.
        if (!GlassMaterial.EffectsAvailable)
        {
            var p = search.TransformToVisual(root).TransformPoint(new(0, 0));
            rect = new Rect(p.X, p.Y, search.ActualWidth, search.ActualHeight);
            if (expanded)
                foreach (FrameworkElement item in actions.Children)
                {
                    var point = item.TransformToVisual(root).TransformPoint(new(0, 0));
                    circles.Add(new(point.X, point.Y, item.ActualWidth, item.ActualHeight));
                }
            surfaces = GlassMaterial.DesktopSurfaces(root);
        }
        backdrop.Update(mode != "home" || runtime.Settings.RhineLabMode, root.ActualWidth, root.ActualHeight, rect, circles, surfaces);
    }
    public void Show()
    {
        var showStarted = Stopwatch.GetTimestamp();
        if (IsShown)
        {
            shell.Show();
            lastShowMs = (Stopwatch.GetTimestamp()-showStarted)*1000.0/Stopwatch.Frequency;
            return;
        }
        // The hidden window keeps the last desktop texture warm. Opening must
        // never wait for CopyFromScreen, which can take over a second in a VM.
        desktopSceneRevision++;
        IsShown = true; root.IsHitTestVisible = true; shell.PrepareBackdrop();
        ConfigureNativeBackdrop();
        root.Opacity = 1;
        ElementCompositionPreview.GetElementVisual(root).Opacity = 1;
        runtime.SetInterfaceVisible(true);
        if (!runtime.Settings.OnboardingComplete && !runtime.HasMemories)
            mode = "onboarding";
        Compose();
        shell.Show();
        lastShowMs = (Stopwatch.GetTimestamp()-showStarted)*1000.0/Stopwatch.Frequency;
        statusTimer.Start();
        Design.Spring(root, 20, .985f, response: .64);
        _ = ActivateGlassAfterFirstFrame();
        _ = RecordMaterialDiagnostics();
    }
    public void PrimeHiddenState()
    {
        if (IsShown) return;
        CaptureDesktopScene();
        if (runtime.Settings.RhineLabMode) _ = archive.Refresh();
    }
    async Task ActivateGlassAfterFirstFrame()
    {
        // Connecting the custom effect from a XAML Loaded callback can race
        // WinUI's first composition commit on a populated library. Let the
        // native fallback present the first frame, then connect all lenses on
        // the UI thread after the visual tree is stable.
        await Task.Delay(350);
        if (!IsShown) return;
        GlassMaterial.ActivateEffects();
        ConfigureNativeBackdrop();
    }
    void CaptureDesktopScene()
    {
        // Capture only while Recall is hidden. The bitmap is transient and
        // supplies the real desktop texture to LiquidGlassWinUI's in-window
        // shader; it is never persisted, indexed or sent to a model.
        if (IsShown) return;
        var bounds = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
        var started = Stopwatch.GetTimestamp();
        var revision = ++desktopSceneRevision;
        _ = PrepareDesktopScene(bounds,revision,started);
    }
    async Task PrepareDesktopScene(System.Drawing.Rectangle bounds, int revision, long started)
    {
        System.Drawing.Bitmap? bitmap = null;
        try
        {
            bitmap = await Task.Run(() =>
            {
                var captured = new System.Drawing.Bitmap(bounds.Width,bounds.Height,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                try
                {
                    using var graphics = System.Drawing.Graphics.FromImage(captured);
                    graphics.CopyFromScreen(bounds.Location,System.Drawing.Point.Empty,bounds.Size);
                    return captured;
                }
                catch { captured.Dispose(); throw; }
            });
            lastDesktopSnapshotMs = (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency;
            var textures = await Task.Run(() =>
            {
                using (bitmap)
                using (var scene = ResizeDesktop(bitmap,Math.Max(1,bounds.Width/2),Math.Max(1,bounds.Height/2)))
                using (var blurred = BlurDesktop(bitmap))
                    return (Scene: BitmapPixels(scene), Blur: BitmapPixels(blurred), Timeline: BitmapPixels(blurred,true));
            });
            bitmap = null;
            if (IsShown || revision != desktopSceneRevision) return;
            desktopScene.Source = BitmapSource(textures.Scene);
            desktopBlurSource = BitmapSource(textures.Blur);
            desktopTimelineBlurSource = BitmapSource(textures.Timeline);
            desktopBlurScene.Source = mode == "home" && !runtime.Settings.RhineLabMode ? desktopTimelineBlurSource : desktopBlurSource;
            lastDesktopCaptureMs = (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.ExternalException or ArgumentException or OutOfMemoryException)
        {
            bitmap?.Dispose();
        }
    }
    static System.Drawing.Bitmap BlurDesktop(System.Drawing.Bitmap source)
    {
        // A deliberately low-frequency texture is the blur. Keep it small and
        // let the compositor stretch it instead of upscaling it on the UI thread
        // and then uploading millions of indistinguishable pixels.
        const int factor = 10;
        var smallWidth = Math.Max(1, source.Width / factor);
        var smallHeight = Math.Max(1, source.Height / factor);
        return ResizeDesktop(source,smallWidth,smallHeight);
    }
    static System.Drawing.Bitmap ResizeDesktop(System.Drawing.Bitmap source, int width, int height)
    {
        var result = new System.Drawing.Bitmap(width,height,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (var graphics = System.Drawing.Graphics.FromImage(result))
        {
            graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            graphics.CompositingQuality = System.Drawing.Drawing2D.CompositingQuality.HighSpeed;
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
            graphics.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighSpeed;
            graphics.DrawImage(source,new System.Drawing.Rectangle(0,0,width,height));
        }
        return result;
    }
    static (byte[] Pixels,int Width,int Height) BitmapPixels(System.Drawing.Bitmap bitmap, bool timelineMask = false)
    {
        var area = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var locked = bitmap.LockBits(area, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        byte[] pixels;
        try
        {
            var stride = Math.Abs(locked.Stride);
            var source = new byte[stride * bitmap.Height];
            System.Runtime.InteropServices.Marshal.Copy(locked.Scan0, source, 0, source.Length);
            pixels = new byte[bitmap.Width * bitmap.Height * 4];
            for (var y = 0; y < bitmap.Height; y++)
                Buffer.BlockCopy(source, (locked.Stride > 0 ? y : bitmap.Height - 1 - y) * stride,
                    pixels, y * bitmap.Width * 4, bitmap.Width * 4);
            if (timelineMask)
                for (var y = 0; y < bitmap.Height; y++)
                {
                    var progress = Math.Clamp((y / Math.Max(1d, bitmap.Height - 1) - .66) / .34, 0, 1);
                    var alpha = (byte)Math.Round(255 * GlassProfile.TimelineOpacity(progress));
                    var row = y * bitmap.Width * 4;
                    for (var x = 0; x < bitmap.Width; x++)
                    {
                        var pixel = row + x * 4;
                        pixels[pixel] = (byte)(pixels[pixel] * alpha / 255);
                        pixels[pixel + 1] = (byte)(pixels[pixel + 1] * alpha / 255);
                        pixels[pixel + 2] = (byte)(pixels[pixel + 2] * alpha / 255);
                        pixels[pixel + 3] = alpha;
                    }
                }
        }
        finally { bitmap.UnlockBits(locked); }
        return (pixels,bitmap.Width,bitmap.Height);
    }
    static WriteableBitmap BitmapSource((byte[] Pixels,int Width,int Height) source)
    {
        var scene = new WriteableBitmap(source.Width,source.Height);
        using (var stream = scene.PixelBuffer.AsStream()) stream.Write(source.Pixels);
        scene.Invalidate();
        return scene;
    }
    async Task RecordMaterialDiagnostics()
    {
        await Task.Delay(2000);
        // Normal launches need the same observability as the fixture harness.
        // This contains rendering state only: no queries, records or screenshots.
        try
        {
            var report = new { capturedAt = DateTimeOffset.UtcNow, processPath = Environment.ProcessPath,
                mode, dark = Design.Dark, rhine = runtime.Settings.RhineLabMode,
                scale = root.XamlRoot?.RasterizationScale, native = shell.Diagnostics,
                glass = GlassMaterial.Diagnostics, backdrop = backdrop.Diagnostics };
            await File.WriteAllTextAsync(Path.Combine(AppPaths.DataRoot, "material-diagnostics.json"),
                System.Text.Json.JsonSerializer.Serialize(report, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    public void Toggle()
    {
        if (IsShown)
            _ = Hide();
        else
            Show();
    }
    public Task Hide()
    {
        IsShown = false;
        try
        {
            root.IsHitTestVisible = false;
            statusTimer.Stop(); toolbarTimer?.Stop(); backdropLayoutTimer?.Stop();
            // Remove the native overlay before media or content cleanup. Even
            // a disconnected popup must not keep the interface pause alive.
            try
            {
                try { DismissPopups(); }
                finally
                {
                    try { backdrop.SetVisible(false); }
                    finally { SystemBackdrop = null; nativeBackdropActive = false; }
                }
            }
            finally { shell.Hide(); }
            root.Opacity = 0;
            queryCancellation?.Cancel(); archive.SetActive(false); timeline.SetActive(false);
            detail?.Dispose(); detail = null; page.Children.Clear();
            mode = "home"; selected = null; Collapse();
            LiquidMotion.Cancel(root); toolbarTimer?.Stop(); backdropLayoutTimer?.Stop(); root.Opacity = 0;
        }
        finally
        {
            runtime.SetInterfaceVisible(false);
            // Refresh the desktop texture after the overlay is gone. The work
            // is entirely off the opening path and is ready for the next show.
            CaptureDesktopScene();
        }
        return Task.CompletedTask;
    }
    public void FinishSmoke()
    {
        quitting = true;
        statusTimer.Stop();
        root.Children.Clear();
        shell.Dispose();
    }
    internal async Task Quit()
    {
        quitting = true;
        statusTimer.Stop();
        root.Children.Clear();
        detail?.Dispose();
        shell.Dispose();
        await runtime.Shutdown();
        Application.Current.Exit();
    }
    void BuildToolbar()
    {
        toolbar.HorizontalAlignment = HorizontalAlignment.Center;
        toolbar.VerticalAlignment = VerticalAlignment.Top;
        toolbar.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        toolbar.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        search.Width = 860;
        search.MaxWidth = 860;
        search.FontSize = 22;
        search.Padding = new(54, 15, 20, 15);
        search.BorderBrush = Design.RimBrush;
        search.BorderThickness = new(1.3);
        search.CornerRadius = new(38);
        var glass = new Grid();
        // A sibling surface samples the scene outside the native editor's
        // intermediate texture, retaining blur without rectangular focus feedback.
        GlassMaterial.Attach(searchGlass, 38);
        search.SizeChanged += (_, _) => searchGlass.CornerRadius = search.CornerRadius;
        glass.Children.Add(searchGlass);
        glass.Children.Add(search);
        var magnify = new FontIcon { Glyph = "\uE721", Foreground = Design.Brush(Design.Ink), FontSize = 25, HorizontalAlignment = HorizontalAlignment.Left, Margin = new(20, 0, 0, 0), IsHitTestVisible = false };
        glass.Children.Add(magnify);
        toolbar.Children.Add(glass);
        var buttons = new[] { Design.Icon("\uE71D", "Filter applications", Apps, 64), Design.Icon("\uE734", "Starred memories", () => { starred = !starred; Navigate("search"); }, 64), Design.Icon("\uE945", "Ask Recall", () => Navigate("ask"), 64), Design.Icon("\uE9D9", "App usage", () => Navigate("usage"), 64), Design.Icon("\uE713", "Settings", () => Navigate("settings"), 64) };
        foreach (var button in buttons)
            actions.Children.Add(button);
        Grid.SetColumn(actions, 1);
        actions.Margin = new(16, 0, 0, 0);
        actions.VerticalAlignment = VerticalAlignment.Center;
        actions.Visibility = Visibility.Collapsed;
        toolbar.Children.Add(actions);
        toolbar.PointerPressed += (_, e) => e.Handled = true;
        search.GotFocus += (_, _) => Expand();
        search.TextChanged += (_, _) => { if (search.Text.Length > 0 && mode == "home") Navigate("search"); if (mode == "search") _ = Search(); };
        search.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { Navigate("search"); e.Handled = true; } };
    }
    void LayoutToolbar(bool immediate = false)
    {
        var top = mode != "home" || runtime.Settings.RhineLabMode || selected != null;
        var rhine = mode == "home" && runtime.Settings.RhineLabMode;
        // The reference Mac window is 1512 points wide. Scale the complete
        // 1020-point toolbar as one unit so its viewport proportions survive
        // the narrower 1374-point Windows test desktop.
        var rhineScale = rhine ? Math.Clamp(root.ActualWidth / 1512, .72, 1) : 1;
        var compactRhine = rhine && root.ActualWidth < 1216;
        var size = rhine ? 64 * rhineScale : 64;
        actions.Spacing = rhine ? 16 * rhineScale : 16;
        var actionGap = rhine ? 16 * rhineScale : 16;
        Color? toolbarTint = null;
        GlassMaterial.SetAccent(searchGlass, toolbarTint);
        GlassMaterial.SetDesktopSampling(searchGlass, false);
        GlassMaterial.SetDesktopSurface(searchGlass, true);
        GlassMaterial.SetAccent(archiveClose, toolbarTint);
        GlassMaterial.SetDesktopSampling(archiveClose, false);
        GlassMaterial.SetDesktopSurface(archiveClose, true);
        archiveClose.Translation = new(0,0,rhine ? 10 : 8);
        GlassMaterial.SetAccent(topMenu, toolbarTint);
        GlassMaterial.SetDesktopSampling(topMenu, false);
        GlassMaterial.SetDesktopSurface(topMenu, true);
        topMenu.Translation = new(0,0,rhine ? 10 : 8);
        search.Translation = new(0,0,rhine ? 12 : 16);
        foreach (var button in actions.Children.OfType<Button>())
        {
            button.Width = button.Height = size; button.CornerRadius = new(size / 2);
            GlassMaterial.SetAccent(button, toolbarTint);
            GlassMaterial.SetDesktopSampling(button, false);
            GlassMaterial.SetDesktopSurface(button, true);
            button.Translation = new(0,0,rhine ? 10 : 8);
            button.BorderBrush = Design.RimBrush;
            button.BorderThickness = new(1);
            if (button.Content is FontIcon glyph)
            {
                glyph.FontSize = rhine ? 20 * rhineScale : 21;
                glyph.Foreground = Design.Brush(rhine
                    ? Design.Dark ? Color.FromArgb(255,190,192,198) : Color.FromArgb(255,105,106,107)
                    : Design.Ink);
            }
        }
        search.BorderBrush = Design.RimBrush;
        search.BorderThickness = new(rhine ? 1 : 1.3);
        archiveClose.BorderBrush = topMenu.BorderBrush = Design.RimBrush;
        archiveClose.BorderThickness = topMenu.BorderThickness = new(1);
        archiveClose.Width = archiveClose.Height = rhine ? 56 * rhineScale : 56;
        archiveClose.CornerRadius = new(archiveClose.Width / 2);
        archiveClose.Margin = new(28, rhine ? 36 : 16, 0, 0);
        topMenu.Width = topMenu.Height = rhine ? 56 * rhineScale : 56;
        topMenu.CornerRadius = new(topMenu.Width / 2);
        topMenu.Margin = new(0, rhine ? 36 : 16, 28, 0);
        if (rhine)
        {
            StyleArchiveGlyph(archiveClose, 16);
            StyleArchiveGlyph(topMenu, 17);
        }
        else if (topMenu.Content is FontIcon menuGlyph)
        {
            menuGlyph.FontSize = 21;
            menuGlyph.Foreground = Design.Brush(Design.Ink);
        }
        LayoutNotice();
        var width = Math.Max(230, Math.Min(1020, root.ActualWidth - 196));
        var actionWidth = expanded ? 5 * size + 4 * actions.Spacing : 0.0;
        var rhineSearchWidth = Math.Max(230, 620 * rhineScale);
        var target = (Width: rhine ? rhineSearchWidth : expanded ? Math.Max(230, width - 400) : Math.Min(860, Math.Max(230, root.ActualWidth - 196)),
            Height: rhine ? size : expanded ? 64.0 : 72.0, Top: rhine ? 32.0 : top ? 11.0 : Math.Max(72, root.ActualHeight * .425 - 36), Actions: actionWidth);
        if (target == toolbarTarget) return;
        toolbarTarget = target;
        UpdateArchiveSafeArea();
        toolbarTimer?.Stop();
        search.MaxWidth = double.PositiveInfinity;
        search.FontSize = rhine ? 20 * rhineScale : expanded ? 20 : 23;
        search.PlaceholderText = expanded ? "Search memories" : "Search anything you’ve seen, said, or heard";
        var from = (Width: search.ActualWidth, Height: search.ActualHeight, Top: toolbar.Margin.Top, Actions: actions.ActualWidth);
        void Apply(double p)
        {
            double Mix(double x, double y) => x + (y - x) * p;
            search.Width = Math.Max(230, Mix(from.Width, target.Width));
            search.Height = search.MinHeight = Mix(from.Height, target.Height);
            search.CornerRadius = new(search.Height / 2);
            actions.Width = Math.Max(0, Mix(from.Actions, target.Actions));
            actions.Margin = new(actionGap * Math.Min(1, actions.Width / Math.Max(1,target.Actions)), 0, 0, 0);
            toolbar.Margin = new(24, Mix(from.Top, target.Top), 24, 0);
        }
        if (immediate || compactRhine || !Design.Motion || !IsShown || !search.IsLoaded || from.Width < 1 || from.Height < 1) { Apply(1); actions.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; QueueBackdrop(); return; }
        actions.Visibility = Visibility.Visible;
        var watch = System.Diagnostics.Stopwatch.StartNew();
        toolbarTimer = DispatcherQueue.CreateTimer(); toolbarTimer.Interval = TimeSpan.FromMilliseconds(16);
        var timer = toolbarTimer;
        timer.Tick += (_, _) =>
        {
            if (target != toolbarTarget) { timer.Stop(); return; }
            if (watch.Elapsed.TotalSeconds >= .9 || !IsShown || !Design.Motion)
            { timer.Stop(); Apply(1); actions.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; Backdrop(); }
            else Apply(LiquidMotion.Progress(watch.Elapsed.TotalSeconds, .58, .64));
        };
        toolbarTimer.Start();
    }
    void StyleArchiveGlyph(Button button, double macSize)
    {
        if (button.Content is not FontIcon glyph) return;
        var scale = Math.Clamp(root.ActualWidth / 1512, .72, 1);
        glyph.FontSize = macSize * scale;
        glyph.Foreground = Design.Brush(Design.Dark
            ? Color.FromArgb(255,190,192,198) : Color.FromArgb(255,105,106,107));
    }
    void UpdateArchiveSafeArea()
    {
        if (root.ActualWidth <= 0 || root.ActualHeight <= 0) return;
        var top = Math.Max(toolbarTarget.Top + toolbarTarget.Height,
            Math.Max(archiveClose.Margin.Top + archiveClose.Height,
                topMenu.Margin.Top + topMenu.Height)) + 20;
        var timelineReserve = Math.Max(timeline.ActualHeight, timeline.Height) + 12;
        // Rhine cards must have one presentation size. Reserving the timeline
        // in both states prevents an open card from shrinking when it appears.
        var bottom = mode == "home" && runtime.Settings.RhineLabMode
            ? Math.Max(timelineReserve, archive.DateDockReserve + 12)
            : archive.DateDockReserve + 12;
        if (mode == "home" && runtime.Settings.RhineLabMode && archive.IsExpanded)
        {
            // ArchiveViewportLayout uses 116/180 insets in the 972-point Mac
            // reference window. Preserve those proportions on the shorter VM.
            var referenceScale = root.ActualHeight / 972;
            top = Math.Max(top, 116 * referenceScale);
            bottom = Math.Max(bottom,180 * referenceScale);
        }
        archiveSafeTop = top; archiveSafeBottom = bottom;
        archive.SetExpandedSafeArea(top, bottom);
    }
    void ShowArchiveTimeline()
    {
        if (mode != "home" || !runtime.Settings.RhineLabMode || archive.IsExpanded) return;
        timeline.SetActive(true);
        archive.SetTimeline(true);
        UpdateArchiveSafeArea();
    }
    void UpdateArchiveTimelineForPointer(double y, bool overDayControls)
    {
        if (mode != "home" || !runtime.Settings.RhineLabMode) return;
        if (timeline.IsActive)
        {
            var timelineTop = Math.Max(0, root.ActualHeight-
                Math.Max(timeline.ActualHeight,timeline.Height));
            if (!timeline.IsInteracting && y <= timelineTop+8) HideArchiveTimeline();
            return;
        }
        if (!archive.IsExpanded && !overDayControls && y >= root.ActualHeight-88) ShowArchiveTimeline();
    }
    void HideArchiveTimeline()
    {
        if (mode != "home" || !runtime.Settings.RhineLabMode) return;
        timeline.SetActive(false);
        archive.SetTimeline(false);
        UpdateArchiveSafeArea();
    }
    void Expand()
    {
        var entering = !expanded;
        expanded = true; actions.Visibility = Visibility.Visible;
        LayoutToolbar();
        if (entering) for (int i = 0; i < actions.Children.Count; i++) LiquidMotion.Emerge((FrameworkElement)actions.Children[i], i);
    }
    void Collapse()
    {
        if (expanded && Design.Motion)
            for (int i = 0; i < actions.Children.Count; i++) LiquidMotion.Dismiss((FrameworkElement)actions.Children[i], i);
        expanded = false; LayoutToolbar();
    }
    public void Navigate(string target)
    {
        if (!IsShown)
            Show();
        DismissPopups();
        var connectedArchive = target == "detail" && mode == "home" && runtime.Settings.RhineLabMode && archive.IsActive;
        var connectedDetail = target == "detail" && mode != "detail" && selected != null && IsShown &&
            (page.Children.Count != 0 || connectedArchive)
            ? page.Children.OfType<FrameworkElement>().ToArray() : null;
        var outgoing = target != "detail" && mode != target && page.Children.Count != 0
            ? page.Children.OfType<FrameworkElement>().ToArray() : null;
        var outgoingDetail = outgoing == null ? null : detail;
        detailTransitionRevision++;
        transitioningDetail = null;
        if (outgoingDetail != null) outgoingDetail.PrepareForExit();
        else detail?.Dispose();
        detail = null;
        queryCancellation?.Cancel();
        mode = target;
        lastSearchSignature = null;
        if (target != "home")
            Expand();
        else if (!runtime.Settings.RhineLabMode)
            Collapse();
        Compose(connectedDetail ?? outgoing,connectedArchive);
        if (outgoing != null) StartPageExit(outgoing,outgoingDetail);
        else if (target == "detail" && connectedDetail == null) QueueChromeGlassRefresh();
        if (target == "home")
        {
            var previousFrame = selected;
            selected = null;
            if (outgoing != null) _ = PreviewAfterPageExit(previousFrame);
            else Preview(previousFrame);
        }
        // Apply the page's full or local desktop mask in this navigation turn.
        Backdrop();
    }
    void StartPageExit(FrameworkElement[] outgoing, DetailView? outgoingDetail)
    {
        foreach (var item in outgoing)
        {
            item.IsHitTestVisible = false;
            _ = LiquidMotion.Disappear(item,14,.28,.9,170);
        }
        _ = RemoveExitedPage(outgoing,outgoingDetail);
    }
    async Task RemoveExitedPage(FrameworkElement[] outgoing, DetailView? outgoingDetail)
    {
        await Task.Delay(170);
        foreach (var item in outgoing)
            if (page.Children.Contains(item)) page.Children.Remove(item);
        outgoingDetail?.Dispose();
    }
    async Task PreviewAfterPageExit(MemoryFrame? frame)
    {
        await Task.Delay(175);
        if (mode == "home" && IsShown) Preview(frame);
    }
    void LayoutNotice()
    {
        // The archive date, hover time and timeline share a responsive bottom
        // dock. Status/error text belongs below the toolbar, outside that dock.
        noticeHost.Visibility = mode == "material" || string.IsNullOrWhiteSpace(notice.Text) ? Visibility.Collapsed : Visibility.Visible;
        var rhine = mode == "home" && runtime.Settings.RhineLabMode;
        var scale = Math.Clamp(root.ActualWidth / 1979, .65, 1);
        noticeHost.Margin = new(100, rhine ? 136 * scale + 16 : mode is "settings" or "usage" ? 84 : 88, 100, 0);
    }
    MenuFlyout MainMenu()
    {
        var menu = Design.Menu();
        menu.Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight;
        menu.MenuFlyoutPresenterStyle.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, 210d));
        menu.MenuFlyoutPresenterStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(8)));
        void Add(string name, Action action)
        {
            var item = new MenuFlyoutItem { Text = name };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("Search memories", () => { Navigate("search"); search.Focus(FocusState.Programmatic); });
        Add("Ask Recall", () => Navigate("ask"));
        Add("App usage", () => Navigate("usage"));
        Add("Settings", () => Navigate("settings"));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Hide Recall", () => _ = Hide());
        Add("Quit Recall", () => _ = Quit());
        return menu;
    }
    void DismissPopups()
    {
        if (root.XamlRoot is not { } xamlRoot) return;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot).ToArray()) popup.IsOpen = false;
    }
    void Compose(FrameworkElement[]? connectedDetail = null, bool connectedArchive = false)
    {
        // Keep the native editor attached across navigation and composition.
        // Reparenting a focused TextBox destroys the IME surface and flashes it.
        if (root.Children.Count == 0)
        {
            root.Children.Add(desktopScene); root.Children.Add(desktopBlurScene); root.Children.Add(archive); root.Children.Add(page);
            root.Children.Add(timeline); root.Children.Add(toolbar);
            root.Children.Add(back); root.Children.Add(archiveClose); root.Children.Add(noticeHost); root.Children.Add(topMenu);
        }
        if (connectedDetail == null && page.Children.Count != 0) page.Children.Clear();
        var night = runtime.Settings.DarkAppearance;
        if (Design.Dark != night) Design.SetDark(night);
        var theme = night ? ElementTheme.Dark : ElementTheme.Light;
        if (root.RequestedTheme != theme) root.RequestedTheme = theme;
        var rhine = runtime.Settings.RhineLabMode && mode == "home";
        UpdateDesktopScenePresentation(rhine);
        if (!connectedArchive) archive.SetActive(rhine && IsShown);
        if (rhine) { Expand(); if (IsShown) _ = archive.Refresh(); }
        timeline.SetActive(mode == "home" && !rhine);
        if (rhine) archive.SetTimeline(false);
        back.Visibility = mode == "home" ? Visibility.Collapsed : Visibility.Visible;
        topMenu.Visibility = mode == "onboarding" ? Visibility.Collapsed : Visibility.Visible;
        archiveClose.Visibility = rhine ? Visibility.Visible : Visibility.Collapsed;
        SetToolbarVisible(mode is not ("onboarding" or "settings" or "usage"));
        LayoutNotice();
        LayoutToolbar();
        switch (mode)
        {
            case "onboarding": page.Children.Add(new OnboardingView(runtime, () => Navigate("home"))); break;
            case "search": _ = Search(); break;
            case "detail":
                if (selected != null)
                {
                    detail = new(runtime, selected, OpenFrame);
                    if (connectedDetail != null)
                    {
                        detail.Opacity = 0;
                        Place(detail,animate: false);
                        StartDetailTransition(detail,connectedDetail,connectedArchive);
                    }
                    else Place(detail);
                }
                break;
            case "ask":
                Place(new AskView(runtime, OpenFrame, () => (appFilter, searchSince),
                    () => { appFilter = null; searchSince = null; },
                    () => { Navigate("settings"); page.Children.OfType<SettingsView>().FirstOrDefault()?.SelectTab("Models"); }));
                break;
            case "settings": Place(new SettingsView(runtime, ApplySettings, () => Navigate("home"))); break;
            case "usage": Place(new UsageView(runtime)); break;
        }
    }
    void UpdateDesktopScenePresentation(bool rhine)
    {
        var classicHome = mode == "home" && !rhine;
        desktopScene.Visibility = classicHome ? Visibility.Visible : Visibility.Collapsed;
        desktopBlurScene.Visibility = Visibility.Visible;
        desktopBlurScene.Source = classicHome ? desktopTimelineBlurSource : desktopBlurSource;
        desktopBlurScene.Opacity = 1;
        if (IsShown) ConfigureNativeBackdrop();
    }
    void ConfigureNativeBackdrop(bool force = false)
    {
        var sceneReady = desktopScene.Source != null && desktopBlurSource != null && desktopTimelineBlurSource != null;
        var enabled = force || !sceneReady || !GlassMaterial.EffectsAvailable;
        if (enabled == nativeBackdropActive) return;
        nativeBackdropActive = enabled;
        if (enabled)
        {
            SystemBackdrop = backdrop;
            backdrop.SetVisible(true);
            Backdrop();
        }
        else
        {
            backdrop.SetVisible(false);
            SystemBackdrop = null;
        }
    }
    void SetToolbarVisible(bool visible)
    {
        toolbar.ExposeChildren = visible;
        var view = visible ? AccessibilityView.Content : AccessibilityView.Raw;
        AutomationProperties.SetAccessibilityView(toolbar, view);
        search.IsEnabled = search.IsTabStop = visible;
        AutomationProperties.SetAccessibilityView(search, view);
        foreach (var button in actions.Children.OfType<Button>())
        {
            button.IsEnabled = button.IsTabStop = visible;
            AutomationProperties.SetAccessibilityView(button, view);
        }
        if (runtime.Settings.RhineLabMode && mode == "home")
        {
            toolbar.Visibility = Visibility.Visible;
            toolbar.Opacity = visible ? 1 : 0;
            toolbar.IsHitTestVisible = visible;
        }
        else
        {
            toolbar.Opacity = 1;
            toolbar.IsHitTestVisible = visible;
            toolbar.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        }
    }
    internal async Task ValidationState(bool? rhine, bool? dark, string? target, string? query, string? app, string? frame, DateTime? day, string? settingsTab, bool showTimeline)
    {
        if (rhine.HasValue) runtime.Settings.RhineLabMode = rhine.Value;
        if (dark.HasValue) runtime.Settings.DarkAppearance = dark.Value;
        appFilter = app;
        if (query != null) search.Text = query;
        if (target == "detail" && frame != null) selected = runtime.Store.Frame(frame);
        Navigate(target ?? "home");
        if (runtime.Settings.RhineLabMode && mode == "home") { await archive.Refresh(day); if (frame != null) archive.Open(frame); }
        if (showTimeline)
        {
            timeline.SetActive(true); archive.SetTimeline(true);
            if (runtime.Store.Frame(frame ?? "parity-0-4") is { } fixture)
            {
                timeline.ValidationSelect(fixture);
                if (!runtime.Settings.RhineLabMode) Preview(fixture);
            }
        }
        else archive.SetTimeline(false);
        UpdateArchiveSafeArea();
        if (settingsTab != null) page.Children.OfType<SettingsView>().FirstOrDefault()?.SelectTab(settingsTab);
    }
    internal void ValidationMaterial(bool dark, bool desktop)
    {
        materialDesktop = desktop; mode = "material"; Design.SetDark(dark); root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        desktopScene.Visibility = desktopBlurScene.Visibility = Visibility.Collapsed;
        ConfigureNativeBackdrop(force: true);
        archive.SetActive(false); timeline.SetActive(false); page.Children.Clear();
        toolbar.Visibility = back.Visibility = topMenu.Visibility = noticeHost.Visibility = Visibility.Collapsed;
        root.Background = Design.Brush(Color.FromArgb(1, 255, 255, 255));
        page.Children.Add(new MaterialReferenceView(desktop));
        backdrop.Update(desktop, root.ActualWidth, root.ActualHeight, new Rect(), []);
    }
    internal void ValidationShowArchiveTimeline() => ShowArchiveTimeline();
    internal void ValidationMoveArchivePointerToTop() => UpdateArchiveTimelineForPointer(
        root.ActualHeight-Math.Max(timeline.ActualHeight,timeline.Height)-1,false);
    internal void ValidationBeginTimelineDrag() { ShowArchiveTimeline(); timeline.ValidationBeginDrag(); }
    internal void ValidationTimelineDrag(int step) => timeline.ValidationDrag(step);
    internal Task ValidationEndTimelineDrag() => timeline.ValidationEndDrag();
    internal async Task ValidationCommitArchiveTimeline(string id)
    {
        var frame = runtime.Store.Frame(id) ?? throw new InvalidOperationException("Timeline fixture is missing: " + id);
        ShowArchiveTimeline();
        await timeline.ValidationCommit(frame);
    }
    object ChromeDiagnostics()
    {
        static object Bounds(FrameworkElement element, Grid root)
        {
            if (element.XamlRoot == null || root.XamlRoot == null) return new { x = 0d, y = 0d, width = 0d, height = 0d };
            var bounds = element.TransformToVisual(root).TransformBounds(new Rect(0,0,element.ActualWidth,element.ActualHeight));
            return new { x = bounds.X, y = bounds.Y, width = bounds.Width, height = bounds.Height };
        }
        return new { toolbarVisible = toolbar.Visibility == Visibility.Visible && toolbar.Opacity > .5,
            toolbarHitTestVisible = toolbar.IsHitTestVisible, toolbarBounds = Bounds(toolbar,root),
            searchBounds = Bounds(search,root), closeBounds = Bounds(archiveClose,root),
            menuBounds = Bounds(topMenu,root), timelineVisible = timeline.Visibility == Visibility.Visible,
            timelineBounds = Bounds(timeline,root),
            safeArea = new { top = archiveSafeTop, bottom = root.ActualHeight - archiveSafeBottom,
                left = 0d, right = root.ActualWidth } };
    }
    internal object ValidationDiagnostics => new { shown = IsShown, buttons = actions.Children.OfType<FrameworkElement>().Select(x => new { label = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x), bounds = x.TransformToVisual(root).TransformBounds(new Rect(0,0,x.ActualWidth,x.ActualHeight)).ToString(), offset = x.ActualOffset.ToString(), opacity = x.Opacity, hitTestVisible = x.IsHitTestVisible }).ToArray(), mode, query = search.Text, appFilter, motion = new { enabled = Design.Motion, expanded, toolbarAnimating = toolbarTimer?.IsRunning ?? false, detailTransitioning = transitioningDetail != null, searchWidth = search.ActualWidth, targetWidth = toolbarTarget.Width }, chrome = ChromeDiagnostics(), uiThread = new { layoutUpdates, backdropUpdates, maxBackdropMs, lastShowMs, lastDesktopSnapshotMs, lastDesktopCaptureMs }, recording = new { state = runtime.Recording.State, fake = runtime.ValidationCaptureDiagnostics }, native = shell.Diagnostics, glass = GlassMaterial.Diagnostics, popupGlass = PopupGlassBackdrop.Diagnostics, popupTree = Design.PopupDiagnostics, backdrop = backdrop.Diagnostics, rhine = archive.Diagnostics, timeline = timeline.Diagnostics, preview = page.Children.OfType<TimelinePreviewView>().FirstOrDefault()?.Diagnostics(root), notice = new { visible = noticeHost.Visibility == Visibility.Visible, bounds = noticeHost.TransformToVisual(root).TransformBounds(new Rect(0, 0, noticeHost.ActualWidth, noticeHost.ActualHeight)) }, settings = page.Children.OfType<SettingsView>().FirstOrDefault()?.Diagnostics, media = detail?.Diagnostics, imageCache = MemoryImages.Diagnostics, ask = page.Children.OfType<AskView>().FirstOrDefault()?.Diagnostics };
    internal object? ValidationPreviewDiagnostics => page.Children.OfType<TimelinePreviewView>().FirstOrDefault()?.Diagnostics(root);
    internal object? ValidationMediaDiagnostics => detail?.Diagnostics;
    internal object ValidationArchiveDiagnostics => archive.Diagnostics;
    internal void ValidationAction(string? action)
    {
        if (action == "play-video-seek")
        {
            if (selected?.Id.StartsWith("parity-video-", StringComparison.Ordinal) != true ||
                selected.SessionId is not { } videoSession || runtime.Store.Session(videoSession) is not { } recording)
                throw new InvalidOperationException("Seek fixture requires a synthetic selected video.");
            runtime.Store.SaveSession(recording with { StartedAt = selected.Timestamp.AddSeconds(-3) });
            detail?.ValidationPlay();
            return;
        }
        if (action is "transcript-working" or "transcript-ready" or "transcript-empty")
        {
            if (selected?.Id.StartsWith("parity-", StringComparison.Ordinal) != true ||
                selected.SessionId is not { } sessionId || runtime.Store.Session(sessionId) is not { } fixture)
                throw new InvalidOperationException("Transcript fixtures require a synthetic selected recording.");
            var state = action == "transcript-working" ? RecognitionState.Working
                : action == "transcript-ready" ? RecognitionState.Complete : RecognitionState.Empty;
            runtime.Store.ReplaceTranscript(sessionId, action == "transcript-empty" ? [] :
            [
                new("parity-line-1", sessionId, fixture.StartedAt, "System", "We reviewed the settings layout and the video playback controls."),
                new("parity-line-2", sessionId, fixture.StartedAt.AddSeconds(3), "Microphone", "The first visible video frame should already have the correct orientation.")
            ]);
            runtime.Store.SaveSession(fixture with { HasAudio = true, SpeechState = state, SpeechError = null });
            return;
        }
        if (action == "ask-new")
        {
            page.Children.OfType<AskView>().FirstOrDefault()?.NewConversation();
            return;
        }
        if (action == "ask-sample")
        {
            var sources = new[] { "parity-0-0", "parity-0-1", "parity-0-2" }
                .Select(runtime.Store.Frame).OfType<MemoryFrame>().ToList();
            page.Children.OfType<AskView>().FirstOrDefault()?.ValidationConversation(sources);
            return;
        }
        if (action == "hide") _ = Hide();
        else if (action == "show") Show();
        else if (action == "hide-show") { _ = Hide(); Show(); }
        else if (action == "back") Navigate("home");
        else if (action == "collapse") archive.Collapse();
        else if (action == "expand-search") Expand();
        else if (action == "collapse-search") Collapse();
        else if (action == "open-menu") topMenu.Flyout?.ShowAt(topMenu);
        else if (action == "save-settings") page.Children.OfType<SettingsView>().FirstOrDefault()?.ValidationSave();
        else if (action == "timeline-zoom-in") timeline.ValidationZoom(true);
        else if (action == "timeline-zoom-out") timeline.ValidationZoom(false);
        else if (action == "open-first") archive.Open("parity-0-0");
        else if (action == "play-video") detail?.ValidationPlay();
        else if (action == "play-and-rotate") { detail?.ValidationPlay(); detail?.RotateVideo(); }
        else if (action == "rotate-video") detail?.RotateVideo();
        else if (action == "recording-on") runtime.ValidationRequestRecording(true);
        else if (action == "recording-off") runtime.ValidationRequestRecording(false);
        else if (action == "recording-fail-next") runtime.ValidationFailNextCaptureStart();
        else if (action == "recording-interrupt") runtime.ValidationInterruptCapture();
    }
    internal void ValidationRetarget(int step) => archive.ValidationRetarget(step);
    internal void ValidationDrag(int step) => archive.ValidationDrag(step);
    internal void ValidationEndDrag() => archive.ValidationEndDrag();
    internal void ValidationSeekArchive(string id)
    {
        if (!runtime.Settings.RhineLabMode || mode != "home") throw new InvalidOperationException("Archive seek requires Rhine home.");
        archive.Seek(runtime.Store.Frame(id) ?? throw new InvalidOperationException("Unknown synthetic frame: " + id));
    }
    internal void ValidationSelectFrame(string id)
    {
        if (runtime.Settings.RhineLabMode || mode != "home")
            throw new InvalidOperationException("Timeline frame selection requires the classic home page.");
        var frame = runtime.Store.Frame(id) ?? throw new InvalidOperationException("Unknown validation frame: " + id);
        timeline.Select(frame);
        Preview(frame);
    }
    void Place(FrameworkElement element, bool animate = true)
    {
        element.Margin = mode is "settings" or "usage" ? new(40, 8, 40, 8)
            : mode == "detail" ? new(28, 116, 28, 20) : new(42, 120, 42, 36);
        page.Children.Add(element);
        element.PointerPressed += (_, e) => e.Handled = true;
        if (animate) Design.Spring(element, 12, .99f);
    }
    void StartDetailTransition(DetailView target, FrameworkElement[] previous, bool connectedArchive)
    {
        var revision = ++detailTransitionRevision;
        transitioningDetail = target;
        Action ready = null!;
        ready = () =>
        {
            target.PosterReady -= ready;
            _ = BeginDetailTransitionAfterImageCommit(target,previous,connectedArchive,revision);
        };
        target.PosterReady += ready;
        if (target.IsPosterReady) ready();
    }
    async Task BeginDetailTransitionAfterImageCommit(DetailView target, FrameworkElement[] previous,
        bool connectedArchive, int revision)
    {
        // BitmapImage decoding has completed; give XAML one composition turn to
        // bind those pixels before the destination begins gaining opacity.
        await Task.Delay(32);
        BeginDetailTransition(target,previous,connectedArchive,revision);
    }
    void BeginDetailTransition(DetailView target, FrameworkElement[] previous, bool connectedArchive, int revision)
    {
        if (transitioningDetail != target || revision != detailTransitionRevision || detail != target || mode != "detail") return;
        transitioningDetail = null;
        // Keep the selected image beneath the destination until its poster is
        // decoded. The opposing scale/vertical motion reads as one surface
        // moving forward instead of a fade through the white desktop layer.
        Design.Spring(target,24,.965f,response:.44,damping:.82);
        foreach (var item in previous)
            _ = LiquidMotion.Disappear(item,-18,.3,.88,190);
        _ = RemoveTransitionSources(previous,target,connectedArchive,revision);
    }
    async Task RemoveTransitionSources(FrameworkElement[] previous, DetailView target, bool connectedArchive, int revision)
    {
        await Task.Delay(190);
        if (revision != detailTransitionRevision || detail != target) return;
        foreach (var item in previous)
            if (page.Children.Contains(item)) page.Children.Remove(item);
        if (connectedArchive) archive.SetActive(false);
        QueueChromeGlassRefresh();
    }
    void QueueChromeGlassRefresh()
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (!IsShown || mode != "detail") return;
            // A retained Rhine surface changes the sampled visual tree after the
            // page transition. Recreate the small toolbar graphs in one UI turn
            // so none keeps a stale or disconnected backdrop source.
            LayoutToolbar(immediate: true);
            foreach (var surface in actions.Children.OfType<FrameworkElement>()
                         .Concat(new FrameworkElement[] { searchGlass, back, topMenu }))
            {
                GlassMaterial.SetEnabled(surface,false);
                GlassMaterial.SetEnabled(surface,true);
            }
            Backdrop();
        });
    }
    async void UpdateStatus()
    {
        if (quitting)
            return;
        var state = runtime.Recording.State;
        archive.UpdateStatus();
        shell.Status(state);
        if (state.CaptureFaulted && state.Requested)
            notice.Text = "Recording interrupted. Close Recall to retry, or use Retry recording in the tray.";
        else if (notice.Text is "Recording will resume when you close Recall." or
            "Recording interrupted. Close Recall to retry, or use Retry recording in the tray.")
            notice.Text = "";
        if (mode == "home" && selected != null)
        {
            var id = selected.Id;
            MemoryFrame? fresh;
            try
            {
                fresh = await Task.Run(() => runtime.Store.Frame(id));
            }
            catch (ObjectDisposedException) when (quitting) { return; }
            if (quitting)
                return;
            if (mode == "home" && selected?.Id == id && fresh != null)
            {
                foreach (var surface in page.Children.OfType<FrameSurface>())
                    surface.Update(fresh);
                foreach (var preview in page.Children.OfType<TimelinePreviewView>())
                    preview.ShowFrame(fresh);
            }
        }
        if (mode == "search" && search.Text.Length > 0)
            _ = Search();
    }
    async Task ApplySettings(AppSettings settings)
    {
        var error = shell.Configure(settings.Shortcuts, settings.ShowTaskbarIcon);
        if (error != null)
            throw new InvalidOperationException(error);
        await Task.Run(() => runtime.Save(settings));
        if (notice.Text == "Settings saved") notice.Text = "";
    }
    void Preview(MemoryFrame? frame)
    {
        if (runtime.Settings.RhineLabMode && mode == "home") { if (frame != null) archive.Seek(frame); return; }
        if (runtime.Settings.RhineLabMode || mode != "home" || frame != null && selected?.Id == frame.Id)
            return;
        selected = frame;
        LayoutToolbar(immediate: true);
        if (frame != null && page.Children.OfType<TimelinePreviewView>().FirstOrDefault() is { } existing)
        {
            existing.ShowFrame(frame);
            return;
        }
        while (page.Children.Count > 0)
            page.Children.RemoveAt(page.Children.Count - 1);
        if (frame == null)
        {
            if (!timeline.IsLive)
            {
                var empty = Design.Card(Design.Text("No screen captured at this time", 13), 20, 14);
                empty.HorizontalAlignment = HorizontalAlignment.Center;
                empty.VerticalAlignment = VerticalAlignment.Center;
                empty.Margin = new(0, 130, 0, 0);
                page.Children.Add(empty);
            }
            return;
        }
        var preview = new TimelinePreviewView(runtime, frame, OpenFrame, () => Navigate("search"), search.Text.Length > 0);
        preview.Margin = new(90, 94, 90, 246);
        preview.MaxWidth = 1600;
        preview.HorizontalAlignment = HorizontalAlignment.Center;
        page.Children.Add(preview);
        preview.PointerPressed += (_, e) => e.Handled = true;
    }
    void OpenFrame(MemoryFrame frame)
    {
        selected = frame;
        Navigate("detail");
    }
    async Task Search()
    {
        queryCancellation?.Cancel();
        queryCancellation = new();
        var ct = queryCancellation.Token;
        var query = search.Text;
        try
        {
            await Task.Delay(160, ct);
            var filter = appFilter;
            var stars = starred;
            var deleted = trash;
            var since = searchSince;
            var result = await Task.Run(() => (Frames: runtime.Store.Frames(query, filter, stars, deleted, since: since, limit: SearchPageSize),
                Apps: runtime.Store.AppNames().Select(name => (Name: name, Frame: runtime.Store.Frames("", name, limit: 1).FirstOrDefault())).ToArray()), ct);
            if (ct.IsCancellationRequested || mode != "search")
                return;
            var frames = result.Frames;
            var signature = query + appFilter + starred + trash + searchSince + string.Join("/", frames.Select(x => x.Id));
            if (signature == lastSearchSignature)
                return;
            lastSearchSignature = signature;
            page.Children.Clear();
            var content = new Grid();
            content.RowDefinitions.Add(new()
            {
                Height = GridLength.Auto
            });
            content.RowDefinitions.Add(new()
            {
                Height = new(1, GridUnitType.Star)
            });
            var header = Design.Row(12);
            var starsButton = Design.Button("Starred", () => { starred = !starred; _ = Search(); });
            starsButton.Content = Design.Row(10, Design.Symbol("\uE735", 20, Color.FromArgb(255, 0, 180, 206)), Design.Text("Starred", 14, true));
            header.Children.Add(starsButton);
            foreach (var app in result.Apps)
            {
                var name = app.Name;
                var chip = Design.Button(name, () => { appFilter = appFilter == name ? null : name; _ = Search(); });
                chip.Content = Design.Row(10, AppIcons.View(AppIcons.Identity(app.Frame ?? new MemoryFrame { AppName = name }), 24), Design.Text(name, 14, true));
                header.Children.Add(chip);
            }
            foreach (Button chip in header.Children) { chip.Height = 47; chip.MinWidth = 134; chip.CornerRadius = new(20); }
            header.Margin = new(6, 6, 6, 37);
            content.Children.Add(header);
            var grid = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Padding = new(0), Margin = new(-13, 0, -13, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
            ScrollViewer.SetVerticalScrollBarVisibility(grid, ScrollBarVisibility.Hidden);
            ScrollViewer.SetHorizontalScrollBarVisibility(grid, ScrollBarVisibility.Disabled);
            foreach (var frame in frames)
                grid.Items.Add(ResultItem(frame));
            if (frames.Count == SearchPageSize)
            {
                int offset = SearchPageSize;
                Button? more = null;
                more = Design.Button("Load more memories", async () =>
                {
                    more!.IsEnabled = false;
                    try
                    {
                        var next = await Task.Run(() => runtime.Store.Frames(query, filter, stars, deleted, since: since, limit: SearchPageSize, offset: offset));
                        if (quitting || mode != "search" || signature != lastSearchSignature)
                            return;
                        foreach (var f in next)
                            grid.Items.Add(ResultItem(f));
                        offset += next.Count;
                        if (next.Count < SearchPageSize)
                            grid.Footer = null;
                    }
                    catch (Exception ex) { if (!quitting) notice.Text = ex.Message; }
                    finally { more.IsEnabled = true; }
                });
                grid.Footer = more;
            }
            grid.ItemClick += (_, e) => { var item = e.ClickedItem as GridViewItem; if (item?.Tag is MemoryFrame frame) OpenFrame(frame); };
            Grid.SetRow(grid, 1);
            content.Children.Add(grid);
            if (frames.Count == 0)
            {
                var empty = Design.Text(query.Length > 0 ? "No matching memories. Try fewer words or another app." : "Your captured memories will appear here.", 18);
                empty.HorizontalAlignment = HorizontalAlignment.Center;
                empty.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetRow(empty, 1);
                content.Children.Add(empty);
            }
            Place(content);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { notice.Text = ex.Message; }
    }
    GridViewItem ResultItem(MemoryFrame frame)
    {
        // Integer widths leave room for all three columns after XAML's layout
        // rounding. Half-gaps at the edges are offset by the grid's margin.
        var cardWidth = Math.Max(200, Math.Floor((root.ActualWidth - 84 - 52) / 3) - 1);
        var stack = new StackPanel { Spacing = 12, Width = cardWidth - 22 };
        var photoHeight = (cardWidth - 22) / 1.6;
        var photo = new Image { Height = photoHeight, Stretch = Stretch.Uniform, Opacity = Design.Dark ? .78 : 1 };
        CancellationTokenSource? imageLoad = null;
        photo.Loaded += async (_, _) =>
        {
            imageLoad?.Cancel(); imageLoad?.Dispose(); imageLoad = new(); var token = imageLoad.Token;
            try { var bitmap = await MemoryImages.Load(runtime.Store, frame.ImagePath, 600, token); if (!token.IsCancellationRequested) photo.Source = bitmap; } catch { }
        };
        photo.Unloaded += (_, _) => { imageLoad?.Cancel(); photo.Source = null; };
        var preview = new Grid();
        preview.Children.Add(photo);
        var marks = new Canvas { IsHitTestVisible = false };
        preview.Children.Add(marks);
        void Highlight()
        {
            marks.Children.Clear();
            if (photo.Source is not BitmapImage bitmap || bitmap.PixelWidth == 0 || preview.ActualWidth == 0)
                return;
            var scale = Math.Min(preview.ActualWidth / bitmap.PixelWidth, photoHeight / bitmap.PixelHeight);
            var w = bitmap.PixelWidth * scale;
            var h = bitmap.PixelHeight * scale;
            var x = (preview.ActualWidth - w) / 2;
            var y = (photoHeight - h) / 2;
            var terms = MemorySearch.Terms(search.Text);
            if (terms.Length == 0)
                return;
            foreach (var region in frame.Regions.Where(r => terms.Any(t => MemorySearch.Normalize(r.Text).Contains(t))))
            {
                var mark = new Border { Width = region.Width * w, Height = region.Height * h, CornerRadius = new(3), BorderThickness = new(1.5), BorderBrush = Design.Brush(Color.FromArgb(245, 240, 192, 91)), Background = Design.Brush(Color.FromArgb(28, 250, 206, 95)) };
                Canvas.SetLeft(mark, x + region.X * w);
                Canvas.SetTop(mark, y + region.Y * h);
                marks.Children.Add(mark);
            }
        }
        photo.ImageOpened += (_, _) => Highlight();
        preview.SizeChanged += (_, _) => Highlight();
        var border = new Border { Child = preview, CornerRadius = new(19), Background = Design.Brush(Microsoft.UI.Colors.Black) };
        Design.Rounded(border, 19);
        stack.Children.Add(border);
        var label = Design.Text(frame.Title, 13, true);
        label.MaxLines = 1;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        stack.Children.Add(Design.Row(10, AppIcons.View(AppIcons.Identity(frame), 29), Design.Stack(3, label, Design.Text(frame.TimeLabel, 11, color: Design.Muted))));
        var card = new GridViewItem { Content = Design.Card(stack, 29, 10), Tag = frame, Margin = new(13, 0, 13, 28), Padding = new(0), CornerRadius = new(29), Template = Design.ResultTemplate, UseSystemFocusVisuals = true };
        LiquidMotion.Interactive(card);
        return card;
    }
    async void Import()
    {
        using var dialog = new System.Windows.Forms.OpenFileDialog { Title = "Import images", Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff", Multiselect = true };
        if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK)
            return;
        foreach (var file in dialog.FileNames)
            try
            {
                await runtime.Capture.Import(file);
            }
            catch (Exception ex) { notice.Text = ex.Message; }
        Navigate("search");
    }
    async void Apps()
    {
        var menu = Design.Menu();
        foreach (var name in await Task.Run(() => runtime.Store.AppNames()))
        {
            var item = new MenuFlyoutItem { Text = AppDisplayName.For(name) };
            item.Click += (_, _) => { appFilter = name; Navigate("search"); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var all = new MenuFlyoutItem { Text = "All applications" };
        all.Click += (_, _) => { appFilter = null; Navigate("search"); };
        menu.Items.Add(all);
        var deleted = new MenuFlyoutItem { Text = trash ? "Leave Trash" : "Trash" };
        deleted.Click += (_, _) => { trash = !trash; Navigate("search"); };
        menu.Items.Add(deleted);
        var import = new MenuFlyoutItem { Text = "Import images…" };
        import.Click += (_, _) => Import();
        menu.Items.Add(import);
        var recent = new MenuFlyoutSubItem { Text = "Date range" };
        foreach (var days in new[] { 0, 1, 7, 30 })
        {
            var dateItem = new MenuFlyoutItem { Text = days == 0 ? "All time" : days == 1 ? "Today" : $"Last {days} days" };
            dateItem.Click += (_, _) => { searchSince = days == 0 ? null : new DateTimeOffset(DateTime.Today).AddDays(1 - days); Navigate("search"); };
            recent.Items.Add(dateItem);
        }
        menu.Items.Add(recent);
        menu.ShowAt(actions.Children[0] as FrameworkElement);
    }
    async void Keys(object sender, KeyRoutedEventArgs e)
    {
        // Escape exits the overlay from every page. The archive handles its
        // own non-Escape navigation and search shortcuts remain available.
        if (e.Key == VirtualKey.Escape)
        {
            // Let native menus, flyouts and their submenus consume Escape first.
            if (root.XamlRoot is { } xamlRoot && VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot).Any(popup => popup.IsOpen)) return;
            e.Handled = true; await Hide(); return;
        }
        if (e.Handled) return;
        uint modifiers = 0;
        foreach (var pair in new[] { (VirtualKey.Control, 2u), (VirtualKey.Menu, 1u), (VirtualKey.Shift, 4u), (VirtualKey.LeftWindows, 8u), (VirtualKey.RightWindows, 8u) })
            if ((InputKeyboardSource.GetKeyStateForCurrentThread(pair.Item1) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0)
                modifiers |= pair.Item2;
        var key = new ShortcutBinding((uint)e.Key, modifiers);
        var shortcuts = runtime.Settings.Shortcuts;
        if (key == shortcuts.Back)
        {
            if (runtime.Settings.RhineLabMode && mode == "home" && timeline.Visibility == Visibility.Visible)
            { HideArchiveTimeline(); e.Handled = true; return; }
            if (mode == "home")
                _ = Hide();
            else
                Navigate("home");
            e.Handled = true;
        }
        else if (key == shortcuts.Search)
        {
            search.Focus(FocusState.Keyboard);
            e.Handled = true;
        }
        else if (key == shortcuts.Settings)
        {
            Navigate("settings");
            e.Handled = true;
        }
        else if (e.OriginalSource is not TextBox && selected != null && (key == shortcuts.Previous || key == shortcuts.Next))
        {
            var date = selected.Timestamp;
            var frame = await Task.Run(() => runtime.Store.Step(date, key == shortcuts.Previous ? -1 : 1));
            if (frame != null)
            {
                if (mode == "home")
                {
                    timeline.Select(frame);
                    Preview(frame);
                }
                else
                    OpenFrame(frame);
            }
            e.Handled = true;
        }
    }
}
