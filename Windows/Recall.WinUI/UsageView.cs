namespace Recall;

internal sealed class UsageView : Grid
{
    readonly AppRuntime runtime; readonly StackPanel body = new() { Spacing = 22 }; readonly TextBox filter = Design.Input("Search apps"); DateTime day = DateTime.Today; UsageReport? report; long revision;
    public UsageView(AppRuntime runtime)
    {
        this.runtime = runtime;
        MaxWidth = 1050;
        HorizontalAlignment = HorizontalAlignment.Center;
        Children.Add(Design.Scroll(body));
        filter.TextChanged += (_, _) => Render();
        _ = Load();
    }
    async Task Load()
    {
        var token = ++revision;
        var date = day;
        var start = date.AddDays(-(int)date.DayOfWeek);
        var intervals = await Task.Run(() => runtime.Store.Usage(new DateTimeOffset(start), new DateTimeOffset(start.AddDays(7))));
        var data = await Task.Run(() => UsageReport.Build(date, intervals));
        if (token != revision)
            return;
        report = data;
        Render();
    }
    void ChangeDay(DateTime date)
    {
        day = date.Date > DateTime.Today ? DateTime.Today : date.Date;
        _ = Load();
    }
    void Render()
    {
        if (report == null)
            return;
        body.Children.Clear();
        var head = new Grid();
        head.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        head.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        head.Children.Add(Design.Stack(5, Design.Text("App usage", 28, true), Design.Text("This PC", 13, color: Design.Muted)));
        var dates = Design.Row(4, Design.Icon("\uE76B", "Previous day", () => ChangeDay(day.AddDays(-1)), 44), Design.Button(day == DateTime.Today ? "Today" : day.ToString("MMM d, yyyy"), Calendar), Design.Icon("\uE76C", "Next day", () => ChangeDay(day.AddDays(1)), 44));
        Grid.SetColumn(dates, 1);
        head.Children.Add(dates);
        body.Children.Add(head);
        var charts = Design.Stack(18, Design.Text("Time used", 14, color: Design.Muted), Design.Text(Design.Time(report.TotalSeconds), 38, true), Chart(report.Week, false), Chart(report.Hours, true));
        body.Children.Add(Design.Card(charts, 28, 26));
        var list = Design.Stack(12);
        var row = new Grid();
        row.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        row.ColumnDefinitions.Add(new()
        {
            Width = new(230)
        });
        row.Children.Add(Design.Text("Applications", 18, true));
        if (filter.Parent is Panel parent)
            parent.Children.Remove(filter);
        Grid.SetColumn(filter, 1);
        row.Children.Add(filter);
        list.Children.Add(row);
        foreach (var app in report.Apps.Where(x => MemorySearch.Normalize(x.App.Name).Contains(MemorySearch.Normalize(filter.Text))))
        {
            var line = new Grid { Padding = new(12), CornerRadius = new(16), Background = Design.Brush(Color.FromArgb(230, 246, 248, 250)) };
            line.ColumnDefinitions.Add(new()
            {
                Width = new(1, GridUnitType.Star)
            });
            line.ColumnDefinitions.Add(new()
            {
                Width = GridLength.Auto
            });
            line.Children.Add(Design.Row(12, AppIcons.View(app.App, 28), Design.Text(app.App.Name, 15)));
            var time = Design.Text(Design.Time(app.Seconds), 15, true);
            Grid.SetColumn(time, 1);
            line.Children.Add(time);
            list.Children.Add(line);
        }
        if (report.Apps.Count == 0)
            list.Children.Add(Design.Text("No app activity recorded on this day.", 15, color: Design.Muted));
        body.Children.Add(Design.Card(list, 28, 24));
    }
    FrameworkElement Chart(double[] values, bool hourly)
    {
        var grid = new Grid { Height = hourly ? 130 : 180, ColumnSpacing = hourly ? 6 : 18 };
        var max = Math.Max(hourly ? 3600 : 7200, values.Max());
        for (var i = 0; i < values.Length; i++)
        {
            grid.ColumnDefinitions.Add(new()
            {
                Width = new(1, GridUnitType.Star)
            });
            var value = values[i];
            var index = i;
            var column = new Grid();
            column.RowDefinitions.Add(new()
            {
                Height = new(1, GridUnitType.Star)
            });
            column.RowDefinitions.Add(new()
            {
                Height = new(22)
            });
            var bar = new Border { Height = Math.Max(2, value / max * (hourly ? 100 : 150)), VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new(5, 5, 0, 0), Background = Design.Brush(!hourly && i != (int)day.DayOfWeek ? Color.FromArgb(255, 209, 216, 226) : Design.Pastels[0]) };
            column.Children.Add(bar);
            var label = Design.Text(hourly ? i % 6 == 0 ? $"{i}:00" : "" : new[] { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }[i], 11, color: Design.Muted);
            Grid.SetRow(label, 1);
            column.Children.Add(label);
            ToolTipService.SetToolTip(column, Design.Time(value));
            if (!hourly)
                column.Tapped += (_, e) => { ChangeDay(day.AddDays(-(int)day.DayOfWeek + index)); e.Handled = true; };
            Grid.SetColumn(column, i);
            grid.Children.Add(column);
        }
        return grid;
    }
    void Calendar()
    {
        var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, MaxDate = DateTimeOffset.Now, IsTodayHighlighted = true, CornerRadius = new(22), BorderThickness = new(0) };
        calendar.SetDisplayDate(new(day));
        calendar.SelectedDates.Add(new(day));
        var popup = new Flyout { Content = calendar };
        calendar.SelectedDatesChanged += (_, e) => { if (e.AddedDates.Count > 0) { ChangeDay(e.AddedDates[0].DateTime); popup.Hide(); } };
        popup.ShowAt(body.Children[0] as FrameworkElement);
    }
}
