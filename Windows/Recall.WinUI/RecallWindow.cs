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
    readonly RhineArchiveView archive; readonly Button back; readonly Grid toolbar = new(); readonly TextBox search = Design.Input("Search anything you’ve seen, said, or heard", height: 72); readonly StackPanel actions = new() { Orientation = Orientation.Horizontal, Spacing = 16 };
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
        Design.SetDark(runtime.Settings.DarkAppearance);
        root.RequestedTheme = runtime.Settings.DarkAppearance ? ElementTheme.Dark : ElementTheme.Light;
        shell = new(this, Toggle, () => { runtime.Recording.Request(!runtime.Recording.State.Requested); UpdateStatus(); }, () => Navigate("settings"), Quit);
        search.SizeChanged += (_, _) => Backdrop();
        var error = shell.Configure(runtime.Settings.Shortcuts, runtime.Settings.ShowTaskbarIcon);
        if (error != null)
            notice.Text = error;
        timeline = new(runtime, Preview);
        archive = new(runtime, OpenFrame);
        archive.ExpansionChanged += open => toolbar.Visibility = open || mode is "settings" or "onboarding" ? Visibility.Collapsed : Visibility.Visible;
        archive.TimelineRequested += () => { timeline.SetActive(true); archive.SetTimeline(true); };
        back = Design.Icon("\uE72B", "Back", () => Navigate("home"), 56);
        back.HorizontalAlignment = HorizontalAlignment.Left; back.VerticalAlignment = VerticalAlignment.Top; back.Margin = new(28, 16, 0, 0);
        BuildToolbar();
        root.PointerPressed += (_, e) => { if (ReferenceEquals(e.OriginalSource, root) || ReferenceEquals(e.OriginalSource, page)) { _ = Hide(); e.Handled = true; } };
        root.KeyDown += Keys;
        runtime.Error += message => DispatcherQueue.TryEnqueue(() => notice.Text = message);
        runtime.Changed += () => DispatcherQueue.TryEnqueue(UpdateStatus);
        statusTimer = DispatcherQueue.CreateTimer();
        statusTimer.Interval = TimeSpan.FromMilliseconds(800);
        statusTimer.Tick += (_, _) => { if (IsShown) detail?.RefreshStatus(); };
        SizeChanged += (_, _) => LayoutToolbar();
        root.SizeChanged += (_, _) => { LayoutToolbar(); Backdrop(); };
        toolbar.LayoutUpdated += (_, _) => Backdrop();
        Compose();
    }
    void Backdrop()
    {
        if (mode == "material" || !IsShown || root.ActualWidth <= 0)
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
        backdrop.Update(mode != "home" || runtime.Settings.RhineLabMode, root.ActualWidth, root.ActualHeight, rect, circles);
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
        archive.SetActive(false);
        timeline.SetActive(false);
        await Design.Fade(root, 0, 180);
        shell.Hide();
        IsShown = false;
        statusTimer.Stop();
        detail?.Dispose();
        detail = null;
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
        search.BorderBrush = Design.RimBrush;
        search.BorderThickness = new(1.3);
        search.CornerRadius = new(38);
        var glass = new Grid();

        Design.Rounded(glass, 38);
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
    void LayoutToolbar()
    {
        var top = mode != "home" || runtime.Settings.RhineLabMode || selected != null;
        var width = Math.Max(230, Math.Min(1020, root.ActualWidth - 196));
        search.Width = expanded ? Math.Max(230, width - 400) : Math.Min(860, Math.Max(230, root.ActualWidth - 196));
        search.MaxWidth = search.Width;
        search.Height = search.MinHeight = expanded ? 64 : 72;
        search.FontSize = expanded ? 20 : 22;
        search.PlaceholderText = expanded ? "Search memories" : "Search anything you’ve seen, said, or heard";
        search.CornerRadius = new(search.Height / 2);
        toolbar.Margin = new(24, top ? 11 : Math.Max(72, root.ActualHeight * .425 - 36), 24, 0);
    }
    void Expand()
    {
        expanded = true;
        actions.Visibility = Visibility.Visible;
        LayoutToolbar();
    }
    void Collapse()
    {
        searchAnimation?.Stop(); searchAnimation = null;
        expanded = false; actions.Visibility = Visibility.Collapsed;
        LayoutToolbar();
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
        else if (!runtime.Settings.RhineLabMode)
            Collapse();
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
        // Keep the native editor attached across navigation and composition.
        // Reparenting a focused TextBox destroys the IME surface and flashes it.
        if (root.Children.Count == 0)
        {
            root.Children.Add(archive); root.Children.Add(page);
            root.Children.Add(timeline); root.Children.Add(toolbar);
            root.Children.Add(back); root.Children.Add(notice);
        }
        page.Children.Clear();
        notice.Visibility = Visibility.Visible;
        var night = mode != "settings" && runtime.Settings.DarkAppearance;
        Design.SetDark(night); root.RequestedTheme = night ? ElementTheme.Dark : ElementTheme.Light;
        root.Background = Design.Brush(Color.FromArgb(1, 255, 255, 255));
        var rhine = runtime.Settings.RhineLabMode && mode == "home";
        archive.SetActive(rhine);
        if (rhine) { Expand(); _ = archive.Refresh(); }
        timeline.SetActive(mode == "home" && !rhine);
        back.Visibility = mode == "home" ? Visibility.Collapsed : Visibility.Visible;
        toolbar.Visibility = mode is "onboarding" or "settings" ? Visibility.Collapsed : Visibility.Visible;
        notice.HorizontalAlignment = HorizontalAlignment.Center;
        notice.VerticalAlignment = VerticalAlignment.Bottom; notice.Margin = new(200, 0, 200, 10); notice.IsHitTestVisible = false;
        LayoutToolbar();
        switch (mode)
        {
            case "onboarding": page.Children.Add(new OnboardingView(runtime, () => Navigate("home"))); break;
            case "search": _ = Search(); break;
            case "detail": if (selected != null) { detail = new(runtime, selected, OpenFrame); Place(detail); } break;
            case "ask": Place(new AskView(runtime, OpenFrame)); break;
            case "settings": Place(new SettingsView(runtime, ApplySettings, () => Navigate("home"))); break;
            case "usage": Place(new UsageView(runtime)); break;
        }
    }
    internal async Task ValidationState(bool? rhine, bool? dark, string? target, string? query, string? app, string? frame, DateTime? day, string? settingsTab, bool showTimeline)
    {
        if (rhine.HasValue) runtime.Settings.RhineLabMode = rhine.Value;
        if (dark.HasValue) runtime.Settings.DarkAppearance = dark.Value;
        appFilter = app;
        if (query != null) search.Text = query;
        Navigate(target ?? "home");
        if (runtime.Settings.RhineLabMode && mode == "home") { await archive.Refresh(day); if (frame != null) archive.Open(frame); }
        if (showTimeline) { timeline.SetActive(true); archive.SetTimeline(true); }
        else archive.SetTimeline(false);
        if (settingsTab != null) page.Children.OfType<SettingsView>().FirstOrDefault()?.SelectTab(settingsTab);
    }
    internal void ValidationMaterial(bool dark, bool desktop)
    {
        mode = "material"; Design.SetDark(dark); root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        archive.SetActive(false); timeline.SetActive(false); page.Children.Clear();
        toolbar.Visibility = back.Visibility = notice.Visibility = Visibility.Collapsed;
        root.Background = Design.Brush(Color.FromArgb(1, 255, 255, 255));
        page.Children.Add(new MaterialReferenceView(desktop));
        backdrop.Update(desktop, root.ActualWidth, root.ActualHeight, new Rect(), []);
    }
    internal object ValidationDiagnostics => new { mode, query = search.Text, appFilter, rhine = archive.Diagnostics };
    internal void ValidationAction(string? action) { if (action == "collapse") archive.Collapse(); }
    internal void ValidationRetarget(int step) => archive.ValidationRetarget(step);
    void Place(FrameworkElement element)
    {
        element.Margin = mode == "settings" ? new(40, 8, 40, 8) : new(42, 120, 42, 36);
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
        if (runtime.Settings.RhineLabMode && mode == "home") { if (frame != null) archive.Seek(frame); return; }
        if (runtime.Settings.RhineLabMode || mode != "home" || frame != null && selected?.Id == frame.Id)
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
            var result = await Task.Run(() => (Frames: runtime.Store.Frames(query, filter, stars, deleted, since: since, limit: 180), Apps: runtime.Store.AppNames()), ct);
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
            foreach (var name in result.Apps)
            {
                var chip = Design.Button(name, () => { appFilter = appFilter == name ? null : name; _ = Search(); });
                chip.Content = Design.Row(10, AppIcons.View(AppIcons.Identity(frames.FirstOrDefault(f => f.AppName == name) ?? new MemoryFrame { AppName = name }), 24), Design.Text(name, 14, true));
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
        var card = new GridViewItem { Content = Design.Card(stack, 29, 10), Tag = frame, Margin = new(13, 0, 13, 28), Padding = new(0), CornerRadius = new(29), Template = Design.ResultTemplate, UseSystemFocusVisuals = false };
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
            if (runtime.Settings.RhineLabMode && mode == "home" && timeline.Visibility == Visibility.Visible)
            { timeline.SetActive(false); archive.SetTimeline(false); e.Handled = true; return; }
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
