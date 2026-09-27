using Microsoft.UI.Input;
using Windows.System;
namespace Recall;

internal sealed class TimelineView : Grid
{
    readonly AppRuntime runtime; readonly Action<MemoryFrame?> preview; readonly Canvas track = new(); readonly TextBlock label = Design.Text("Now", 14, true), rangeLabel = Design.Text(TimelineMath.Duration(300), 14, true); readonly Border timePill; readonly Button zoomOut, zoomIn, rangeButton; readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer, settle;
    public event Action<MemoryFrame?>? Committed;
    DateTimeOffset center = DateTimeOffset.Now; double span = 300; bool live = true, dragging, active; double startX; DateTimeOffset startTime; long revision; bool refreshing, refreshAgain, previewAgain;
    readonly LinearGradientBrush tint = new() { StartPoint = new(0, 0), EndPoint = new(0, 1), GradientStops = { new() { Color = Microsoft.UI.Colors.Transparent, Offset = 0 }, new() { Color = Color.FromArgb(20, 255, 255, 255), Offset = 1 } } };
    public TimelineView(AppRuntime runtime, Action<MemoryFrame?> preview)
    {
        this.runtime = runtime;
        this.preview = preview;
        settle = DispatcherQueue.CreateTimer(); settle.Interval = TimeSpan.FromMilliseconds(250); settle.IsRepeating = false;
        settle.Tick += async (_, _) =>
        {
            var date = center; var frame = await Task.Run(() => runtime.Store.At(date));
            if (active && !live && date == center) Committed?.Invoke(frame);
        };
        Height = 234; Visibility = Visibility.Collapsed;
        VerticalAlignment = VerticalAlignment.Bottom;
        Children.Add(new DesktopBlur(true));
        Children.Add(new Border { Background = tint, IsHitTestVisible = false });
        track.Height = 116;
        track.VerticalAlignment = VerticalAlignment.Bottom;
        track.Margin = new(74, 0, 74, 8);
        track.Background = Design.Brush(Microsoft.UI.Colors.Transparent);
        Children.Add(track);
        timePill = Design.Card(label, 22, 12);
        timePill.HorizontalAlignment = HorizontalAlignment.Center;
        timePill.VerticalAlignment = VerticalAlignment.Bottom;
        timePill.Margin = new(0, 0, 0, 134);
        Children.Add(timePill);
        timePill.Tapped += (_, e) => { JumpToDate(); e.Handled = true; };
        Children.Add(new Border { Width = 4, Height = 128, CornerRadius = new(2), Background = Design.Brush(Microsoft.UI.Colors.White), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false });
        rangeButton = Design.Button("", () => { });
        rangeButton.Content = rangeLabel; rangeButton.Width = 100; rangeButton.Height = 44; rangeButton.Padding = new(0);
        rangeLabel.HorizontalAlignment = HorizontalAlignment.Center;
        rangeLabel.TextAlignment = TextAlignment.Center;
        var rangeMenu = Design.Menu();
        var presets = TimelineMath.Presets.Select(seconds =>
        {
            var item = new RadioMenuFlyoutItem { Text = TimelineMath.Duration(seconds), GroupName = "Timeline range" };
            item.Click += (_, _) => { span = seconds; UpdateRange(); _ = Refresh(true); };
            rangeMenu.Items.Add(item);
            return item;
        }).ToArray();
        rangeMenu.Opening += (_, _) =>
        {
            for (var i = 0; i < presets.Length; i++) presets[i].IsChecked = Math.Abs(span - TimelineMath.Presets[i]) < .01;
        };
        rangeButton.Flyout = rangeMenu;
        zoomOut = Design.Icon("\uE71F", "Zoom out · wider time range", () => Zoom(2), 44);
        zoomIn = Design.Icon("\uE8A3", "Zoom in · narrower time range", () => Zoom(.5), 44);
        var controls = Design.Row(6, zoomOut, rangeButton, zoomIn);
        UpdateRange();
        controls.Margin = new(22, 0, 0, 128);
        controls.HorizontalAlignment = HorizontalAlignment.Left;
        controls.VerticalAlignment = VerticalAlignment.Bottom;
        Children.Add(controls);
        var now = Design.Icon("\uE72A", "Return to now", () => { live = true; center = DateTimeOffset.Now; preview(null); _ = Refresh(); }, 48);
        now.HorizontalAlignment = HorizontalAlignment.Right;
        now.VerticalAlignment = VerticalAlignment.Bottom;
        now.Margin = new(0, 0, 24, 32);
        Children.Add(now);
        track.PointerPressed += (_, e) => { if (e.Handled) return; dragging = true; live = false; startX = e.GetCurrentPoint(track).Position.X; startTime = center; track.CapturePointer(e.Pointer); e.Handled = true; };
        track.PointerMoved += (_, e) => { if (!dragging) return; center = startTime.AddSeconds(-(e.GetCurrentPoint(track).Position.X - startX) / Math.Max(1, track.ActualWidth) * span); if (center > DateTimeOffset.Now) center = DateTimeOffset.Now; _ = Refresh(true); e.Handled = true; };
        track.PointerReleased += (_, e) => { dragging = false; track.ReleasePointerCaptures(); _ = Refresh(true); e.Handled = true; };
        track.PointerCaptureLost += (_, _) => dragging = false;
        PointerWheelChanged += (_, e) => { var delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta; if ((InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0) Zoom(delta > 0 ? .8 : 1.25); else { live = false; center = center.AddSeconds(-delta / 120.0 * span / 18); if (center > DateTimeOffset.Now) center = DateTimeOffset.Now; _ = Refresh(true); } e.Handled = true; };
        PointerPressed += (_, e) => e.Handled = true;
        SizeChanged += (_, _) => _ = Refresh();
        Loaded += (_, _) => _ = Refresh();
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.Tick += (_, _) => { if (Visibility != Visibility.Visible) return; if (live) center = DateTimeOffset.Now; _ = Refresh(); };
        Loaded += (_, _) => { if (active) timer.Start(); };
        Unloaded += (_, _) => timer.Stop();
    }
    public bool IsLive => live;
    internal object Diagnostics => new { spanSeconds = span, rangeText = rangeLabel.Text, zoomOutEnabled = zoomOut.IsEnabled, zoomInEnabled = zoomIn.IsEnabled };
    internal void ValidationZoom(bool zoomIn) => Zoom(zoomIn ? .5 : 2);
    internal void ValidationSelect(MemoryFrame frame) { span = 1800; UpdateRange(); Select(frame); }
    int visibilityRevision;
    public void SetActive(bool value)
    {
        tint.GradientStops[1].Color = Design.Dark ? Color.FromArgb(20, 0, 0, 0) : Color.FromArgb(20, 255, 255, 255);
        if (active == value) return;
        active = value; var token = ++visibilityRevision;
        if (value)
        {
            Visibility = Visibility.Visible; Design.Spring(this, 55, 1, response: .38);
            timer.Start(); _ = Refresh();
        }
        else
        {
            timer.Stop(); settle.Stop(); Interlocked.Increment(ref revision); refreshAgain = previewAgain = false;
            if (!Design.Motion || !IsLoaded) { Visibility = Visibility.Collapsed; return; }
            _ = HideAfterFade(token);
        }
    }
    async Task HideAfterFade(int token)
    {
        await LiquidMotion.Disappear(this, 55, .24, .9, 180);
        if (token == visibilityRevision && !active) Visibility = Visibility.Collapsed;
    }

    public void Select(MemoryFrame f)
    {
        live = false;
        center = f.Timestamp;
        _ = Refresh();
    }
    void JumpToDate()
    {
        var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, MaxDate = DateTimeOffset.Now, CornerRadius = new(20) };
        calendar.SetDisplayDate(center);
        calendar.SelectedDates.Add(center);
        var time = new TimePicker { Time = center.LocalDateTime.TimeOfDay, ClockIdentifier = "24HourClock" };
        var popup = Design.Flyout();
        popup.Content = Design.Stack(10, calendar, time, Design.Button("Go to moment", () => { if (calendar.SelectedDates.Count == 0) return; center = new DateTimeOffset(calendar.SelectedDates[0].Date + time.Time); if (center > DateTimeOffset.Now) center = DateTimeOffset.Now; live = false; popup.Hide(); _ = Refresh(true); }, true));
        popup.ShowAt(timePill);
    }
    void Zoom(double factor)
    {
        span = TimelineMath.Clamp(span * factor);
        UpdateRange();
        _ = Refresh(true);
    }
    void UpdateRange()
    {
        rangeLabel.Text = TimelineMath.Duration(span);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(rangeButton, "Time range: " + rangeLabel.Text + ". Choose preset");
        zoomOut.IsEnabled = span < 86400;
        zoomIn.IsEnabled = span > 60;
    }
    async Task Refresh(bool updatePreview = false)
    {
        if (!active) return;
        previewAgain |= updatePreview;
        if (refreshing)
        {
            // Invalidate the in-flight database/icon lookup immediately. The
            // queued refresh must be the only one allowed to paint the track.
            Interlocked.Increment(ref revision);
            refreshAgain = true;
            return;
        }
        refreshing = true;
        try
        {
            do
            {
                refreshAgain = false;
                var update = previewAgain;
                previewAgain = false;
                await RefreshCore(update);
                // A timer/layout refresh may invalidate a scrubbing request
                // while it awaits icons. Carry its preview intent forward.
                if (refreshAgain) previewAgain |= update;
                await Task.Delay(30);
            } while (refreshAgain && IsLoaded && active);
        }
        finally { refreshing = false; }
    }
    async Task RefreshCore(bool updatePreview = false)
    {
        var token = Interlocked.Increment(ref revision);
        var date = center;
        var window = span;
        var wasLive = live;
        bool Current() => active && token == revision && center == date && span == window && live == wasLive;
        var start = date.AddSeconds(-window / 2);
        var end = date.AddSeconds(window / 2);
        var intervals = await Task.Run(() => runtime.Store.Usage(start, end));
        if (!Current())
            return;
        var entries = await Task.WhenAll(intervals.Select(x => AppIcons.Load(x.App)));
        if (!Current())
            return;
        var colors = intervals.Select((x, i) => (x.Id, entries[i].Color)).ToDictionary(x => x.Id, x => x.Color);
        track.Children.Clear();
        var width = track.ActualWidth;
        if (width <= 0)
            return;
        // A neutral continuous underlay communicates periods without captured app data.
        track.Children.Add(new Border { Width = width, Height = 8, CornerRadius = new(4), Background = Design.Brush(Color.FromArgb(80, 170, 179, 190)), Margin = new(0, 66, 0, 0) });
        foreach (var item in intervals)
        {
            var a = Math.Max(0, (item.Start - start).TotalSeconds / window * width);
            var b = Math.Min(width, (item.End - start).TotalSeconds / window * width);
            if (b <= a)
                continue;
            var segment = new Border { Width = Math.Max(1, b - a), Height = 8, CornerRadius = new(Math.Min(4, (b - a) / 2)), Background = Design.Brush(colors[item.Id]) };
            Canvas.SetLeft(segment, a);
            Canvas.SetTop(segment, 66);
            track.Children.Add(segment);
        }
        var clusters = new List<(double X, List<AppInterval> Items)>();
        foreach (var item in intervals.Where(i => i.App.Kind == "application"))
        {
            double x = Math.Clamp(((item.Start + (item.End - item.Start) / 2) - start).TotalSeconds / window * width, 16, width - 16);
            if (clusters.Count > 0 && x - clusters[^1].X < 44)
                clusters[^1].Items.Add(item);
            else
                clusters.Add((x, [item]));
        }
        foreach (var group in clusters)
        {
            var item = group.Items[0];
            var button = Design.Button("", () => { }); button.Content = AppIcons.View(item.App); button.Width = button.Height = 44; button.Padding = new(7); button.CornerRadius = new(14);
            Canvas.SetLeft(button, group.X - 22);
            Canvas.SetTop(button, 48);
            track.Children.Add(button);
            ToolTipService.SetToolTip(button, item.App.Name + " · " + item.Start.ToLocalTime().ToString("HH:mm:ss"));
            button.Click += (_, _) => { if (group.Items.Count == 1) { live = false; center = item.Start; _ = Refresh(true); } else OpenCluster(button, group.Items); };
            if (group.Items.Count > 1)
            {
                var count = Design.Card(Design.Text(group.Items.Count.ToString(), 10, true), 9, 3);
                Canvas.SetLeft(count, group.X + 8);
                Canvas.SetTop(count, 43);
                count.IsHitTestVisible = false;
                track.Children.Add(count);
            }
        }
        var ago = DateTimeOffset.Now - date;
        label.Text = live ? "Now" : ago.TotalSeconds < 60 ? $"{Math.Max(0, (int)ago.TotalSeconds)} seconds ago" : ago.TotalDays < 1 ? $"{(int)ago.TotalMinutes} minutes ago" : date.ToLocalTime().ToString("MMM d · HH:mm");
        ToolTipService.SetToolTip(timePill, date.ToLocalTime().ToString("f") + " · " + TimelineMath.Duration(window) + " visible");
        if (updatePreview)
        {
            var frame = await Task.Run(() => runtime.Store.At(date));
            if (Current()) { preview(frame); settle.Stop(); settle.Start(); }
        }
    }
    void OpenCluster(FrameworkElement target, List<AppInterval> items)
    {
        var content = new StackPanel { Spacing = 2, Width = 230 };
        var flyout = Design.Flyout();
        foreach (var item in items)
        {
            var row = Design.Row(12, AppIcons.View(item.App, 24), Design.Text($"{item.Start.ToLocalTime():HH:mm:ss} – {item.End.ToLocalTime():HH:mm:ss}", 12));
            var button = Design.Button("", () => { flyout.Hide(); live = false; center = item.Start; _ = Refresh(true); });
            button.Content = row;
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.Padding = new(10, 5, 10, 5);
            button.MinHeight = 38;
            button.Background = Design.Brush(Microsoft.UI.Colors.Transparent);
            ToolTipService.SetToolTip(button, item.App.Name);
            content.Children.Add(button);
        }
        var scroller = Design.Scroll(content);
        scroller.MaxHeight = 280;
        flyout.Content = scroller;
        flyout.ShowAt(target);
    }
}
