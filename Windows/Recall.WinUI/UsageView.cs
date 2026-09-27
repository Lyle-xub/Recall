namespace Recall;

internal sealed class UsageView : Grid
{
    static readonly Color[] lightAccents =
    [
        Color.FromArgb(255, 50, 105, 163), Color.FromArgb(255, 39, 119, 111),
        Color.FromArgb(255, 151, 83, 50), Color.FromArgb(255, 111, 79, 158)
    ];
    static readonly Color[] darkAccents =
    [
        Color.FromArgb(255, 146, 194, 245), Color.FromArgb(255, 117, 210, 188),
        Color.FromArgb(255, 247, 180, 134), Color.FromArgb(255, 194, 164, 239)
    ];

    readonly AppRuntime runtime;
    readonly StackPanel body = new() { Spacing = 18 };
    readonly StackPanel appCards = new() { Spacing = 10 };
    readonly TextBox filter = Design.Input("Search apps", height: 46);
    FrameworkElement? widthHost;
    DateTime day = DateTime.Today;
    UsageReport? report;
    long revision;
    CancellationTokenSource? loadCancellation;
    bool detached = true;

    public UsageView(AppRuntime runtime)
    {
        this.runtime = runtime;
        Width = MaxWidth = 1050;
        HorizontalAlignment = HorizontalAlignment.Center;
        Background = Design.Brush(Design.Dark ? Color.FromArgb(255, 32, 32, 32) : Color.FromArgb(255, 243, 243, 243));
        CornerRadius = new(12);
        Padding = new(28);
        Design.Rounded(this, 12);
        Children.Add(Design.Scroll(body));
        filter.Width = 260;
        filter.TextChanged += (_, _) => RenderApps();
        Loaded += (_, _) =>
        {
            detached = false;
            AttachWidthHost();
            _ = Load();
        };
        Unloaded += (_, _) =>
        {
            detached = true;
            ++revision;
            loadCancellation?.Cancel();
            DetachWidthHost();
        };
    }

    void AttachWidthHost()
    {
        if (Parent is not FrameworkElement host) return;
        if (ReferenceEquals(widthHost, host)) return;
        DetachWidthHost();
        widthHost = host;
        host.SizeChanged += HostSizeChanged;
        UpdateWidth(host.ActualWidth);
    }

    void DetachWidthHost()
    {
        if (widthHost != null) widthHost.SizeChanged -= HostSizeChanged;
        widthHost = null;
    }

    void HostSizeChanged(object sender, SizeChangedEventArgs e) => UpdateWidth(e.NewSize.Width);

    void UpdateWidth(double parentWidth)
    {
        var available = parentWidth - Margin.Left - Margin.Right;
        if (available > 0) Width = Math.Min(MaxWidth, available);
    }

    async Task Load()
    {
        var token = ++revision;
        var previous = loadCancellation;
        var cancellation = new CancellationTokenSource();
        loadCancellation = cancellation;
        previous?.Cancel();
        var date = day;
        var start = date.AddDays(-(int)date.DayOfWeek);
        try
        {
            var intervals = await Task.Run(() => runtime.Store.Usage(new DateTimeOffset(start), new DateTimeOffset(start.AddDays(7))), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            var data = await Task.Run(() => UsageReport.Build(date, intervals), cancellation.Token);
            if (cancellation.IsCancellationRequested || token != revision || detached) return;
            report = data;
            Render();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(loadCancellation, cancellation)) loadCancellation = null;
            cancellation.Dispose();
        }
    }

    void ChangeDay(DateTime date)
    {
        day = date.Date > DateTime.Today ? DateTime.Today : date.Date;
        _ = Load();
    }

    static Color Accent(int index) => (Design.Dark ? darkAccents : lightAccents)[index % lightAccents.Length];
    static Color Track => Design.Dark ? Color.FromArgb(90, 188, 205, 226) : Color.FromArgb(75, 86, 109, 139);
    static Color OtherBar => Design.Dark ? Color.FromArgb(255, 114, 134, 157) : Color.FromArgb(255, 150, 164, 182);
    static string Duration(double seconds) => seconds <= 0 ? "0 min" : seconds < 60 ? $"{Math.Max(1, (int)Math.Round(seconds))} sec" : Design.Time(seconds);
    static string ShortDuration(double seconds) => seconds <= 0 ? "0" : seconds < 60 ? "<1m" : seconds < 3600 ? $"{Math.Max(1, (int)Math.Round(seconds / 60))}m" : $"{seconds / 3600:0.#}h";

    void Render()
    {
        if (report == null) return;
        if (filter.Parent is Panel oldParent) oldParent.Children.Remove(filter);
        body.Children.Clear();
        body.Children.Add(Summary());
        body.Children.Add(Divider());
        var trends = new Grid { ColumnSpacing = 16, RowSpacing = 16 };
        var week = TrendSection("WEEKLY PATTERN", "Day by day", "Select a day to inspect its activity", WeekChart());
        var hours = TrendSection("TIME OF DAY", "Hourly activity", HourlyDescription(), HourChart());
        trends.Children.Add(week); trends.Children.Add(hours);
        ResponsivePair(trends, week, hours, 760, equalWidth: true);
        body.Children.Add(trends);
        body.Children.Add(Divider());

        var heading = new Grid { ColumnSpacing = 16, RowSpacing = 12 };
        var label = Design.Stack(3, Design.Text("Applications", 20, true), Design.Text($"{report.Apps.Count} apps · selected day", 12, color: Design.Muted));
        heading.Children.Add(label); heading.Children.Add(filter);
        ResponsivePair(heading, label, filter, 590);
        body.Children.Add(heading); body.Children.Add(appCards);
        RenderApps();
    }

    static Border Divider() => new()
    {
        Height = 1,
        Background = Design.Brush(Design.Dark ? Color.FromArgb(255, 67, 70, 76) : Color.FromArgb(255, 217, 222, 228))
    };

    FrameworkElement Summary()
    {
        var overview = Design.Stack(5,
            Design.Text("App usage", 26, true),
            Design.Text("SELECTED DAY", 11, true, Accent(0)),
            Design.Text(Duration(report!.TotalSeconds), 39, true),
            Design.Text(report.TotalSeconds > 0
                ? $"Focused time across {report.Apps.Count} {(report.Apps.Count == 1 ? "application" : "applications")}, {day:dddd, MMM d}"
                : $"No activity recorded on {day:dddd, MMM d}", 13, color: Design.Muted));
        var next = Design.Icon("\uE76C", "Next day", () => ChangeDay(day.AddDays(1)), 44);
        next.IsEnabled = day < DateTime.Today;
        var navigation = Design.Row(7,
            Design.Icon("\uE76B", "Previous day", () => ChangeDay(day.AddDays(-1)), 44),
            Design.Button(day == DateTime.Today ? "Today" : day.ToString("MMM d, yyyy"), Calendar), next);
        var layout = new Grid { ColumnSpacing = 18, RowSpacing = 14 };
        layout.Children.Add(overview); layout.Children.Add(navigation);
        ResponsivePair(layout, overview, navigation, 680);
        return layout;
    }

    static FrameworkElement TrendSection(string eyebrow, string title, string description, FrameworkElement chart) =>
        Design.Stack(13,
            Design.Stack(4, Design.Text(eyebrow, 11, true, Design.Muted), Design.Text(title, 19, true), Design.Text(description, 12, color: Design.Muted)),
            chart);

    FrameworkElement WeekChart()
    {
        var values = report!.Week;
        var chart = new Grid { ColumnSpacing = 4 };
        var max = Math.Max(60, values.Max());
        var days = new[] { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        for (var i = 0; i < values.Length; i++)
        {
            var index = i;
            var selected = i == (int)day.DayOfWeek;
            chart.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            var column = new Grid { Height = 166, Padding = new(2) };
            column.RowDefinitions.Add(new() { Height = new(23) });
            column.RowDefinitions.Add(new() { Height = new(116) });
            column.RowDefinitions.Add(new() { Height = new(25) });
            var value = Design.Text(ShortDuration(values[i]), 11, selected, selected ? Accent(0) : Design.Muted);
            value.HorizontalAlignment = HorizontalAlignment.Center; column.Children.Add(value);
            var plot = new Grid();
            plot.Children.Add(new Border
            {
                Width = 20, Height = values[i] <= 0 ? 4 : Math.Max(7, values[i] / max * 104),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
                CornerRadius = new(5, 5, 1, 1), Background = Design.Brush(values[i] <= 0 ? Track : selected ? Accent(0) : OtherBar)
            });
            Grid.SetRow(plot, 1); column.Children.Add(plot);
            var label = Design.Text(days[i], 12, selected, selected ? Accent(0) : Design.Muted);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            Grid.SetRow(label, 2); column.Children.Add(label);
            var button = new Button
            {
                Content = column, Padding = new(0), MinWidth = 0, MinHeight = 0,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                BorderThickness = selected ? new(1) : new(0), BorderBrush = Design.Brush(Accent(0)),
                Background = selected ? Design.Brush(Color.FromArgb(Design.Dark ? (byte)38 : (byte)27, Accent(0).R, Accent(0).G, Accent(0).B)) : Design.Brush(Microsoft.UI.Colors.Transparent),
                CornerRadius = new(12), UseSystemFocusVisuals = true
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, $"{days[i]}, {Duration(values[i])}{(selected ? ", selected day" : "")}");
            ToolTipService.SetToolTip(button, Duration(values[i]));
            button.Click += (_, _) => ChangeDay(day.AddDays(-(int)day.DayOfWeek + index));
            Grid.SetColumn(button, i); chart.Children.Add(button);
        }
        return chart;
    }

    string HourlyDescription()
    {
        var values = report!.Hours;
        var peak = Array.IndexOf(values, values.Max());
        return values[peak] <= 0 ? "No activity on this day" : $"Peak at {peak:00}:00 · {Duration(values[peak])}";
    }

    FrameworkElement HourChart()
    {
        var values = report!.Hours;
        var chart = new Grid { ColumnSpacing = 2 };
        var max = Math.Max(60, values.Max());
        var peak = Array.IndexOf(values, values.Max());
        for (var i = 0; i < values.Length; i++)
        {
            chart.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            var column = new Grid { Height = 166 };
            column.RowDefinitions.Add(new() { Height = new(136) });
            column.RowDefinitions.Add(new() { Height = new(30) });
            var plot = new Grid();
            plot.Children.Add(new Border
            {
                Width = 9, Height = values[i] <= 0 ? 4 : Math.Max(7, values[i] / max * 121),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
                CornerRadius = new(4, 4, 1, 1), Background = Design.Brush(values[i] <= 0 ? Track : i == peak ? Accent(1) : OtherBar)
            });
            column.Children.Add(plot);
            if (i % 6 == 0)
            {
                var label = Design.Text(i.ToString("00"), 11, false, Design.Muted);
                label.HorizontalAlignment = HorizontalAlignment.Center;
                Grid.SetRow(label, 1); column.Children.Add(label);
            }
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(column, $"{i:00}:00, {Duration(values[i])}");
            ToolTipService.SetToolTip(column, $"{i:00}:00 · {Duration(values[i])}");
            Grid.SetColumn(column, i); chart.Children.Add(column);
        }
        return chart;
    }

    void RenderApps()
    {
        if (report == null) return;
        appCards.Children.Clear();
        var query = MemorySearch.Normalize(filter.Text);
        var matching = report.Apps.Where(app => MemorySearch.Normalize(AppDisplayName.For(app.App.Name) + " " + app.App.Name + " " + app.App.Process).Contains(query)).ToArray();
        if (matching.Length == 0)
        {
            appCards.Children.Add(Design.Stack(5,
                Design.Text(report.Apps.Count == 0 ? "No app activity recorded" : "No matching applications", 16, true),
                Design.Text(report.Apps.Count == 0 ? "Choose another day to see app usage." : "Try a different app name.", 13, color: Design.Muted)));
            return;
        }
        for (var i = 0; i < matching.Length; i++)
        {
            if (i > 0) appCards.Children.Add(Divider());
            appCards.Children.Add(AppRow(matching[i], report.Apps.IndexOf(matching[i])));
        }
    }

    FrameworkElement AppRow(UsageApp app, int colorIndex)
    {
        var accent = Accent(Math.Max(0, colorIndex));
        var share = report!.TotalSeconds <= 0 ? 0 : Math.Clamp(app.Seconds / report.TotalSeconds, 0, 1);
        var storedName = string.IsNullOrWhiteSpace(app.App.Name) ? app.App.Process : app.App.Name;
        var name = AppDisplayName.For(storedName);
        var icon = new Border
        {
            Width = 44, Height = 44, CornerRadius = new(12), Padding = new(7),
            Background = Design.Brush(Color.FromArgb(Design.Dark ? (byte)49 : (byte)30, accent.R, accent.G, accent.B)),
            Child = AppIcons.View(app.App, 28)
        };
        var identity = Design.Row(12, icon, Design.Stack(3,
            Design.Text(name, 16, true),
            Design.Text($"{share * 100:0.#}% of selected day", 12, color: Design.Muted)));
        var header = new Grid { ColumnSpacing = 14 };
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(identity);
        var time = Design.Text(Duration(app.Seconds), 16, true);
        time.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(time, 1); header.Children.Add(time);
        var track = new Grid { Height = 7, CornerRadius = new(4), Background = Design.Brush(Track) };
        var fill = new Border { Width = 0, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new(4), Background = Design.Brush(accent) };
        track.Children.Add(fill);
        track.SizeChanged += (_, e) => fill.Width = share <= 0 ? 0 : Math.Max(4, e.NewSize.Width * share);
        var row = new Border { Padding = new(4, 8, 4, 8), Child = Design.Stack(13, header, track) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, $"{name}, {Duration(app.Seconds)}, {share * 100:0.#}% of selected day");
        return row;
    }

    static void ResponsivePair(Grid host, FrameworkElement first, FrameworkElement second, double breakpoint, bool equalWidth = false)
    {
        bool? stacked = null;
        void Arrange(double width)
        {
            var vertical = width < breakpoint;
            if (stacked == vertical) return;
            stacked = vertical;
            host.ColumnDefinitions.Clear(); host.RowDefinitions.Clear();
            host.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            host.RowDefinitions.Add(new() { Height = GridLength.Auto });
            if (vertical) host.RowDefinitions.Add(new() { Height = GridLength.Auto });
            else host.ColumnDefinitions.Add(new() { Width = equalWidth ? new(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetRow(first, 0); Grid.SetColumn(first, 0);
            Grid.SetRow(second, vertical ? 1 : 0); Grid.SetColumn(second, vertical ? 0 : 1);
            second.HorizontalAlignment = equalWidth ? HorizontalAlignment.Stretch : vertical ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        }
        host.SizeChanged += (_, e) => Arrange(e.NewSize.Width);
        Arrange(1050);
    }

    void Calendar()
    {
        var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, MaxDate = DateTimeOffset.Now, IsTodayHighlighted = true, CornerRadius = new(22), BorderThickness = new(0) };
        calendar.SetDisplayDate(new(day));
        calendar.SelectedDates.Add(new(day));
        var popup = Design.Flyout(calendar);
        calendar.SelectedDatesChanged += (_, e) => { if (e.AddedDates.Count > 0) { ChangeDay(e.AddedDates[0].DateTime); popup.Hide(); } };
        popup.ShowAt(body.Children[0] as FrameworkElement);
    }
}
