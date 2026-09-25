using Microsoft.UI.Input;
using Windows.System;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Hosting;
using System.Numerics;
namespace Recall;

internal sealed class RecallWindow : Window
{
    readonly ClearBackdrop backdrop = new(); readonly AppRuntime runtime; readonly NativeShell shell; readonly Grid root = new(), page = new(); readonly TimelineView timeline;
    readonly Grid toolbar = new(); readonly TextBox search = Design.Input("Search anything you’ve seen, said, or heard", height: 72); readonly StackPanel actions = new() { Orientation = Orientation.Horizontal, Spacing = 18 };
    readonly TextBlock notice = Design.Text("", 13, color: Design.Muted); readonly Microsoft.UI.Dispatching.DispatcherQueueTimer statusTimer;
    Storyboard? searchAnimation; CancellationTokenSource? queryCancellation; DetailView? detail; bool expanded, animating, quitting; string mode = "home"; string? appFilter; bool starred, trash; MemoryFrame? selected; string? lastSearchSignature; DateTimeOffset? searchSince;
    public bool IsShown
    {
        get; private set;
    }
    public RecallWindow(AppRuntime runtime)
    {
        this.runtime = runtime;
        Title = "Recall";
        SystemBackdrop = backdrop;
        Content = root;
        root.Background = Design.Brush(Color.FromArgb(1, 255, 255, 255));
        root.RequestedTheme = ElementTheme.Light;
        shell = new(this, Toggle, () => { runtime.Recording.Request(!runtime.Recording.State.Requested); UpdateStatus(); }, () => Navigate("settings"), Quit);
        search.SizeChanged += (_, _) => Backdrop();
        var error = shell.Configure(runtime.Settings.Shortcuts, runtime.Settings.ShowTaskbarIcon);
        if (error != null)
            notice.Text = error;
        timeline = new(runtime, Preview);
        BuildToolbar();
        root.PointerPressed += (_, e) => { if (ReferenceEquals(e.OriginalSource, root) || ReferenceEquals(e.OriginalSource, page)) { _ = Hide(); e.Handled = true; } };
        root.KeyDown += Keys;
        runtime.Error += message => DispatcherQueue.TryEnqueue(() => notice.Text = message);
        runtime.Changed += () => DispatcherQueue.TryEnqueue(UpdateStatus);
        statusTimer = DispatcherQueue.CreateTimer();
        statusTimer.Interval = TimeSpan.FromMilliseconds(800);
        statusTimer.Tick += (_, _) => { if (IsShown) detail?.RefreshStatus(); };
        SizeChanged += (_, _) => { search.MaxWidth = Math.Max(230, Math.Min(expanded ? 640 : 860, root.ActualWidth - (expanded ? 576 : 196))); if (mode == "home") toolbar.Margin = new(24, Math.Max(72, root.ActualHeight * .425 - 36), 24, 0); };
        root.SizeChanged += (_, _) => Backdrop();
        toolbar.LayoutUpdated += (_, _) => Backdrop();
        Compose();
    }
    void Backdrop()
    {
        if (!IsShown || root.ActualWidth <= 0)
            return;
        var p = search.TransformToVisual(root).TransformPoint(new(0, 0));
        var rect = new Rect(p.X, p.Y, search.ActualWidth, search.ActualHeight);
        var circles = new List<Rect>();
        if (expanded)
            foreach (FrameworkElement item in actions.Children)
            {
                var point = item.TransformToVisual(root).TransformPoint(new(0, 0));
                circles.Add(new(point.X, point.Y, item.ActualWidth, item.ActualHeight));
            }
        backdrop.Update(mode != "home", root.ActualWidth, root.ActualHeight, rect, circles);
    }
    public void Show()
    {
        if (IsShown)
            return;
        IsShown = true;
        root.Opacity = 1;
        ElementCompositionPreview.GetElementVisual(root).Opacity = 1;
        runtime.Recording.SetVisible(true);
        if (!runtime.Settings.OnboardingComplete && !runtime.HasMemories)
            mode = "onboarding";
        Compose();
        shell.Show();
        statusTimer.Start();
        Design.Spring(root, 20, .985f);
    }
    public void Toggle()
    {
        if (IsShown)
            _ = Hide();
        else
            Show();
    }
    public async Task Hide()
    {
        if (!IsShown || animating)
            return;
        animating = true;
        queryCancellation?.Cancel();
        detail?.Stop();
        await Design.Fade(root, 0, 180);
        shell.Hide();
        IsShown = false;
        statusTimer.Stop();
        detail?.Dispose();
        detail = null;
        root.Children.Clear();
        page.Children.Clear();
        mode = "home";
        selected = null;
        Collapse();
        runtime.Recording.SetVisible(false);
        animating = false;
    }
    public void FinishSmoke()
    {
        quitting = true;
        statusTimer.Stop();
        root.Children.Clear();
        shell.Dispose();
    }
    async Task Quit()
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
        search.Background = Design.Brush(Color.FromArgb(220, 255, 255, 255));
        search.BorderBrush = Design.Brush(Color.FromArgb(220, 255, 255, 255));
        search.BorderThickness = new(1.3);
        search.CornerRadius = new(38);
        var glass = new Grid();
        glass.Children.Add(new Border { CornerRadius = new(38), Child = new DesktopBlur() });
        Design.Rounded(glass, 38);
        glass.Children.Add(search);
        var magnify = new FontIcon { Glyph = "\uE721", Foreground = Design.Brush(Design.Ink), FontSize = 25, HorizontalAlignment = HorizontalAlignment.Left, Margin = new(20, 0, 0, 0), IsHitTestVisible = false };
        glass.Children.Add(magnify);
        toolbar.Children.Add(glass);
        var buttons = new[] { Design.Icon("\uE71D", "Filter applications", Apps, 58), Design.Icon("\uE734", "Starred memories", () => { starred = !starred; Navigate("search"); }, 58), Design.Icon("\uE945", "Ask Recall", () => Navigate("ask"), 58), Design.Icon("\uE9D9", "App usage", () => Navigate("usage"), 58), Design.Icon("\uE713", "Settings", () => Navigate("settings"), 58) };
        foreach (var button in buttons)
            actions.Children.Add(button);
        Grid.SetColumn(actions, 1);
        actions.Margin = new(18, 0, 0, 0);
        actions.VerticalAlignment = VerticalAlignment.Center;
        actions.Visibility = Visibility.Collapsed;
        toolbar.Children.Add(actions);
        toolbar.PointerPressed += (_, e) => e.Handled = true;
        search.GotFocus += (_, _) => Expand();
        search.TextChanged += (_, _) => { if (search.Text.Length > 0 && mode == "home") Navigate("search"); if (mode == "search") _ = Search(); };
        search.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { Navigate("search"); e.Handled = true; } };
    }
    void Expand()
    {
        if (expanded)
            return;
        expanded = true;
        actions.Visibility = Visibility.Visible;
        search.MinHeight = 58;
        search.FontSize = 19;
        search.CornerRadius = new(30);
        var storyboard = new Storyboard();
        searchAnimation = storyboard;
        var squeeze = new DoubleAnimation { From = search.ActualWidth > 0 ? search.ActualWidth : 860, To = Math.Clamp(Math.Min(1020, root.ActualWidth - 196) - 380, 230, 640), Duration = TimeSpan.FromMilliseconds(430), EnableDependentAnimation = true, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        Storyboard.SetTarget(squeeze, search);
        Storyboard.SetTargetProperty(squeeze, "Width");
        storyboard.Children.Add(squeeze);
        if (Design.Motion)
            storyboard.Begin();
        else
            search.Width = Math.Clamp(Math.Min(1020, root.ActualWidth - 196) - 380, 230, 640);
        for (var i = 0; i < actions.Children.Count; i++)
        {
            var child = actions.Children[i];
            Design.Spring(child, 9, .55f, i * 42);
            var v = ElementCompositionPreview.GetElementVisual(child);
            var a = v.Compositor.CreateVector3KeyFrameAnimation();
            a.InsertKeyFrame(0, new(-70 * (i + 1), 0, 0));
            a.InsertKeyFrame(.7f, new(7, 0, 0));
            a.InsertKeyFrame(1, Vector3.Zero);
            a.Duration = TimeSpan.FromMilliseconds(620 + i * 35);
            if (Design.Motion)
                v.StartAnimation("Translation", a);
        }
    }
    void Collapse()
    {
        searchAnimation?.Stop();
        searchAnimation = null;
        expanded = false;
        actions.Visibility = Visibility.Collapsed;
        search.Width = 860;
        search.MinHeight = 72;
        search.FontSize = 22;
        search.CornerRadius = new(36);
    }
    public void Navigate(string target)
    {
        if (!IsShown)
            Show();
        detail?.Dispose();
        detail = null;
        queryCancellation?.Cancel();
        mode = target;
        lastSearchSignature = null;
        if (target != "home")
            Expand();
        Compose();
        if (target == "home")
        {
            var previousFrame = selected;
            selected = null;
            Preview(previousFrame);
        }
    }
    void Compose()
    {
        root.Children.Clear();
        page.Children.Clear();
        root.Children.Add(page);
        if (mode != "home")
        {
            page.Children.Add(new DesktopBlur());
            page.Children.Add(new Border { Background = Design.Brush(Color.FromArgb(174, 247, 248, 251)), IsHitTestVisible = false });
        }
        if (mode == "onboarding")
        {
            var onboarding = new OnboardingView(runtime, () => Navigate("home"));
            page.Children.Add(onboarding);
            return;
        }
        root.Children.Add(toolbar);
        toolbar.Margin = mode == "home" ? new(24, Math.Max(72, root.ActualHeight * .425 - 36), 24, 0) : new(24, 28, 24, 0);
        if (mode == "home")
        {
            root.Children.Add(timeline);
            var record = Design.Button(runtime.Recording.State.Requested ? "Pause recording" : "Start recording", () => { runtime.Recording.Request(!runtime.Recording.State.Requested); Compose(); });
            record.HorizontalAlignment = HorizontalAlignment.Left;
            record.VerticalAlignment = VerticalAlignment.Bottom;
            record.Margin = new(24, 0, 0, 18);
            root.Children.Add(record);
        }
        else
        {
            var close = Design.Icon("\uE711", "Back to timeline", () => Navigate("home"));
            close.Margin = new(22, 30, 0, 0);
            close.HorizontalAlignment = HorizontalAlignment.Left;
            close.VerticalAlignment = VerticalAlignment.Top;
            root.Children.Add(close);
        }
        notice.HorizontalAlignment = HorizontalAlignment.Center;
        notice.VerticalAlignment = VerticalAlignment.Bottom;
        notice.Margin = new(200, 0, 200, 10);
        notice.IsHitTestVisible = false;
        root.Children.Add(notice);
        switch (mode)
        {
            case "search":
                _ = Search();
                break;
            case "detail":
                if (selected != null)
                {
                    detail = new(runtime, selected, OpenFrame);
                    Place(detail);
                }
                ;
                break;
            case "ask":
                Place(new AskView(runtime, OpenFrame));
                break;
            case "settings":
                Place(new SettingsView(runtime, ApplySettings, () => Navigate("home")));
                break;
            case "usage":
                Place(new UsageView(runtime));
                break;
        }
    }
    void Place(FrameworkElement element)
    {
        element.Margin = new(40, 112, 40, 36);
        page.Children.Add(element);
        element.PointerPressed += (_, e) => e.Handled = true;
        Design.Spring(element, 12, .99f);
    }
    async void UpdateStatus()
    {
        if (quitting)
            return;
        var state = runtime.Recording.State;
        shell.Status(state.Active, state.AutomaticallyPaused);
        if (state.AutomaticallyPaused && mode == "home")
            notice.Text = "Recording will resume when you close Recall.";
        else if (notice.Text.StartsWith("Recording will"))
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
                foreach (var surface in page.Children.OfType<FrameSurface>())
                    surface.Update(fresh);
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
        notice.Text = "Settings saved";
    }
    void Preview(MemoryFrame? frame)
    {
        if (mode != "home" || frame != null && selected?.Id == frame.Id)
            return;
        selected = frame;
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
        var image = new FrameSurface(runtime.Store, frame);
        image.Margin = new(90, 108, 90, 246);
        image.MaxWidth = root.ActualWidth * .84;
        image.HorizontalAlignment = HorizontalAlignment.Center;
        toolbar.Margin = new(24, 14, 24, 0);
        page.Children.Add(image);
        image.PointerPressed += (_, e) => e.Handled = true;
        var open = Design.Button("Open memory · " + frame.Timestamp.ToLocalTime().ToString("HH:mm:ss"), () => OpenFrame(frame));
        open.HorizontalAlignment = HorizontalAlignment.Right;
        open.VerticalAlignment = VerticalAlignment.Top;
        open.Margin = new(0, 46, 106, 0);
        page.Children.Add(open);
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
            var frames = await Task.Run(() => runtime.Store.Frames(query, filter, stars, deleted, since: since, limit: 180), ct);
            if (ct.IsCancellationRequested || mode != "search")
                return;
            var signature = query + appFilter + starred + trash + searchSince + string.Join("/", frames.Select(x => x.Id));
            if (signature == lastSearchSignature)
                return;
            lastSearchSignature = signature;
            while (page.Children.Count > 2)
                page.Children.RemoveAt(page.Children.Count - 1);
            var content = new Grid();
            content.RowDefinitions.Add(new()
            {
                Height = GridLength.Auto
            });
            content.RowDefinitions.Add(new()
            {
                Height = new(1, GridUnitType.Star)
            });
            var header = Design.Row(14, Design.Text(trash ? "Trash" : starred ? "Starred" : "Memories", 20, true), Design.Text(frames.Count == 180 ? "180+ results" : $"{frames.Count} results", 13, color: Design.Muted));
            if (appFilter != null)
                header.Children.Add(Design.Button(appFilter + " ×", () => { appFilter = null; _ = Search(); }));
            header.Margin = new(8, 0, 0, 18);
            content.Children.Add(header);
            var grid = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Padding = new(0), HorizontalAlignment = HorizontalAlignment.Stretch };
            ScrollViewer.SetVerticalScrollBarVisibility(grid, ScrollBarVisibility.Hidden);
            ScrollViewer.SetHorizontalScrollBarVisibility(grid, ScrollBarVisibility.Disabled);
            foreach (var frame in frames)
                grid.Items.Add(ResultItem(frame));
            if (frames.Count == 180)
            {
                int offset = 180;
                Button? more = null;
                more = Design.Button("Load more memories", async () =>
                {
                    more!.IsEnabled = false;
                    try
                    {
                        var next = await Task.Run(() => runtime.Store.Frames(query, filter, stars, deleted, since: since, limit: 180, offset: offset));
                        if (quitting || mode != "search" || signature != lastSearchSignature)
                            return;
                        foreach (var f in next)
                            grid.Items.Add(ResultItem(f));
                        offset += next.Count;
                        if (next.Count < 180)
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
        var stack = new StackPanel { Spacing = 10, Width = Math.Clamp((root.ActualWidth - 150) / 3, 250, 440) };
        var photo = new Image { Height = 180, Stretch = Stretch.UniformToFill };
        photo.Loaded += async (_, _) => { try { photo.Source = await MemoryImages.Load(runtime.Store, frame.ImagePath, 600); } catch { } };
        photo.Unloaded += (_, _) => photo.Source = null;
        var preview = new Grid();
        preview.Children.Add(photo);
        var marks = new Canvas { IsHitTestVisible = false };
        preview.Children.Add(marks);
        void Highlight()
        {
            marks.Children.Clear();
            if (photo.Source is not BitmapImage bitmap || bitmap.PixelWidth == 0 || preview.ActualWidth == 0)
                return;
            var scale = Math.Max(preview.ActualWidth / bitmap.PixelWidth, 180.0 / bitmap.PixelHeight);
            var w = bitmap.PixelWidth * scale;
            var h = bitmap.PixelHeight * scale;
            var x = (preview.ActualWidth - w) / 2;
            var y = (180 - h) / 2;
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
        var border = new Border { Child = preview, CornerRadius = new(20), Background = Design.Brush(Color.FromArgb(240, 237, 240, 246)) };
        Design.Rounded(border, 20);
        stack.Children.Add(border);
        var label = Design.Text(frame.Title, 14, true);
        label.MaxLines = 1;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        stack.Children.Add(Design.Row(10, AppIcons.View(AppIcons.Identity(frame), 25), Design.Stack(3, label, Design.Text(frame.TimeLabel, 12, color: Design.Muted))));
        var card = new GridViewItem { Content = stack, Tag = frame, Margin = new(6, 6, 12, 20), Padding = new(8), CornerRadius = new(24) };
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
        var menu = new MenuFlyout();
        foreach (var name in await Task.Run(() => runtime.Store.AppNames()))
        {
            var item = new MenuFlyoutItem { Text = name };
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
        uint modifiers = 0;
        foreach (var pair in new[] { (VirtualKey.Control, 2u), (VirtualKey.Menu, 1u), (VirtualKey.Shift, 4u), (VirtualKey.LeftWindows, 8u), (VirtualKey.RightWindows, 8u) })
            if ((InputKeyboardSource.GetKeyStateForCurrentThread(pair.Item1) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0)
                modifiers |= pair.Item2;
        var key = new ShortcutBinding((uint)e.Key, modifiers);
        var shortcuts = runtime.Settings.Shortcuts;
        if (key == shortcuts.Back)
        {
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
