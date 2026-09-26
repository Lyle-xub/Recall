using Microsoft.UI.Input;
using Windows.System;
using System.Text.Json;
namespace Recall;

internal sealed class SettingsView : Grid
{
    readonly AppRuntime runtime; readonly Func<AppSettings, Task> save; readonly AppSettings draft; readonly StackPanel sections = new() { Spacing = 20 }; readonly TextBlock message = Design.Text("Changes apply when you save.", 12, color: Design.Muted); readonly Dictionary<string, PasswordBox> secrets = []; CancellationTokenSource? optimization;
    readonly Dictionary<string, Button> tabButtons = [];
    public SettingsView(AppRuntime runtime, Func<AppSettings, Task> save, Action close)
    {
        this.runtime = runtime;
        this.save = save;
        draft = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(runtime.Settings))!;
        MaxWidth = 660;
        Width = 660;
        HorizontalAlignment = HorizontalAlignment.Center;
        Background = Design.Brush(Microsoft.UI.Colors.White);
        CornerRadius = new(30);
        Padding = new(28);
        Design.Rounded(this, 30);
        RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        RowDefinitions.Add(new()
        {
            Height = new(1, GridUnitType.Star)
        });
        RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        var tabs = new Grid { ColumnSpacing = 4 };
        foreach (var name in new[] { "Recording", "Permissions", "Models", "Storage", "Shortcuts" })
        {
            tabs.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            var button = Design.Button(name, () => SelectTab(name));
            button.Padding = new(8); button.MinHeight = 60; button.HorizontalAlignment = HorizontalAlignment.Stretch;
            var glyph = name switch { "Recording" => "\uE7C8", "Permissions" => "\uE72E", "Models" => "\uE945", "Storage" => "\uE7F1", _ => "\uE765" };
            var icon = Design.Symbol(glyph); icon.HorizontalAlignment = HorizontalAlignment.Center;
            var label = Design.Text(name, 12, true); label.HorizontalAlignment = HorizontalAlignment.Center;
            button.Content = Design.Stack(5, icon, label);
            Grid.SetColumn(button, tabs.Children.Count); tabButtons[name] = button;
            tabs.Children.Add(button);
        }
        var tabBar = Design.Card(tabs, 22, 5); tabBar.Background = Design.Brush(Color.FromArgb(255, 247, 250, 255));
        Children.Add(Design.Stack(20, Design.Stack(4, Design.Text("Settings", 24, true), Design.Text("Your memories, under your control.", 13, color: Design.Muted)), tabBar));
        var scroll = Design.Scroll(sections);
        scroll.Margin = new(0, 22, 0, 18);
        Grid.SetRow(scroll, 1);
        Children.Add(scroll);
        SelectTab("Recording");
        var footer = new Grid { ColumnSpacing = 14 };
        footer.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        footer.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        footer.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        footer.Children.Add(message);
        var cancel = Design.Button("Cancel", close);
        Grid.SetColumn(cancel, 1);
        footer.Children.Add(cancel);
        var apply = Design.Button("Save changes", async () => { try { draft.Shortcuts.Validate(); foreach (var item in secrets) SecretStore.Save(item.Key, item.Value.Password); await save(draft); message.Text = "Saved"; } catch (Exception ex) { message.Text = ex.Message; } }, true);
        Grid.SetColumn(apply, 2);
        footer.Children.Add(apply);
        Grid.SetRow(footer, 2);
        Children.Add(footer);
        Unloaded += (_, _) => optimization?.Cancel();
    }
    public void SelectTab(string name)
    {
        optimization?.Cancel();
        foreach (var (key, button) in tabButtons)
        {
            button.Background = Design.Brush(key == name ? Color.FromArgb(255, 224, 235, 254) : Microsoft.UI.Colors.Transparent);
            button.BorderBrush = Design.Brush(key == name ? Color.FromArgb(255, 180, 207, 253) : Microsoft.UI.Colors.Transparent);
        }
        sections.Children.Clear();
        sections.Children.Add(name switch { "Permissions" => Permissions(), "Models" => Models(), "Storage" => Storage(), "Shortcuts" => Shortcuts(), _ => Recording() });
    }
    static Border Section(string title, params UIElement[] children)
    {
        var stack = Design.Stack(18, Design.Text(title, 17, true));
        foreach (var c in children)
            stack.Children.Add(c);
        var card = Design.Card(stack, 24, 22);
        card.Background = Design.Brush(Color.FromArgb(255, 248, 250, 252));
        card.BorderBrush = Design.Brush(Color.FromArgb(255, 235, 240, 245));
        return card;
    }
    static FrameworkElement Row(string label, FrameworkElement control, string? subtitle = null)
    {
        var g = new Grid { ColumnSpacing = 16 };
        g.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        g.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        g.Children.Add(subtitle == null ? Design.Text(label, 14) : Design.Stack(4, Design.Text(label, 14), Design.Text(subtitle, 12, color: Design.Muted)));
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }
    static ToggleSwitch Toggle(bool value, Action<bool> change)
    {
        var t = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 44 };
        t.Toggled += (_, _) => change(t.IsOn);
        return t;
    }
    static ComboBox Choice(string[] options, int selected, Action<int> change)
    {
        var c = new ComboBox { ItemsSource = options, SelectedIndex = Math.Max(0, selected), MinWidth = 150, CornerRadius = new(14), MinHeight = 42 };
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) change(c.SelectedIndex); };
        return c;
    }
    FrameworkElement Recording()
    {
        var screens = System.Windows.Forms.Screen.AllScreens;
        var index = Array.FindIndex(screens, x => x.DeviceName == draft.DisplayName);
        var excluded = Design.Input("Comma-separated app process names", string.Join(", ", draft.ExcludedApps));
        excluded.TextChanged += (_, _) => draft.ExcludedApps = excluded.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var appearance = Row("Appearance", Choice(["Light", "Dark"], draft.DarkAppearance ? 1 : 0, i => draft.DarkAppearance = i == 1));
        appearance.Visibility = draft.RhineLabMode ? Visibility.Visible : Visibility.Collapsed;
        var rhine = Row("Rhine Lab Mode", Toggle(draft.RhineLabMode, v => { draft.RhineLabMode = v; appearance.Visibility = v ? Visibility.Visible : Visibility.Collapsed; }), "A glass archive arranged by day.");
        return Section("Recording", rhine, appearance, Row("Display", Choice(screens.Select((x, i) => $"Display {i + 1} · {x.Bounds.Width} × {x.Bounds.Height}").ToArray(), index, i => draft.DisplayName = screens[i].DeviceName)), Row("System audio", Toggle(draft.SystemAudio, v => draft.SystemAudio = v)), Row("Microphone", Toggle(draft.Microphone, v => draft.Microphone = v)), Row("Automatic transcription", Toggle(draft.TranscriptionEnabled, v => draft.TranscriptionEnabled = v)), Row("Capture interval", Choice(["1 second", "3 seconds", "5 seconds", "10 seconds"], Array.IndexOf(new[] { 1, 3, 5, 10 }, draft.CaptureInterval), i => draft.CaptureInterval = new[] { 1, 3, 5, 10 }[i])), Row("Open at sign-in", Toggle(draft.LaunchAtLogin, v => draft.LaunchAtLogin = v)), Row("Show taskbar icon", Toggle(draft.ShowTaskbarIcon, v => draft.ShowTaskbarIcon = v), "Recall remains available in the system tray."), Design.Stack(7, Design.Text("Excluded apps", 14), excluded, Design.Text("Capture pauses while an excluded app is visible. Private activity is not named in the timeline.", 12, color: Design.Muted)), Design.Text("Capture pauses while Recall is open. Images use the original screen for text recognition, then save at 50% quality. Video uses 720 pixels, 1 fps and 100 kbps.", 12, color: Design.Muted));
    }
    FrameworkElement Permissions()
    {
        var mic = Design.Text("Not checked", 12, color: Design.Muted);
        var button = Design.Button("Check microphone", async () => { try { using var capture = new Windows.Media.Capture.MediaCapture(); await capture.InitializeAsync(new Windows.Media.Capture.MediaCaptureInitializationSettings { StreamingCaptureMode = Windows.Media.Capture.StreamingCaptureMode.Audio }); mic.Text = "Microphone available"; } catch (Exception ex) { mic.Text = "Microphone unavailable: " + ex.Message; } });
        return Section("Permissions", Row("Screen recording", Design.Text("Available when recording starts", 12, color: Design.Muted)), Row("Microphone", button), mic, Design.Button("Open microphone privacy settings", () => _ = Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"))), Design.Text("Allow desktop apps to access your microphone in Windows Settings. Recall uses your selected display; protected windows may appear blank.", 12, color: Design.Muted));
    }
    FrameworkElement Models()
    {
        var content = Design.Stack(16);
        foreach (var model in runtime.Models.Catalog)
        {
            var status = Design.Text(runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel + " · Download to use offline"), 12, color: Design.Muted);
            var progress = new ProgressBar { Maximum = 1, Value = runtime.Models.Progress.GetValueOrDefault(model.Id), Height = 4, CornerRadius = new(2) };
            var download = Design.Button(runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download", async () => { if (runtime.Models.Busy(model.Id)) runtime.Models.Pause(model.Id); else await runtime.Models.Download(model); });
            var remove = Design.Button("Remove", async () => { if (await Confirm("Remove " + model.Title + "?", "Your memories remain stored. You can download this model again.", "Remove")) runtime.Models.Remove(model); });
            var row = Design.Stack(8, Row(model.Title, Design.Row(8, download, remove)), status, progress);
            void Update()
            {
                DispatcherQueue.TryEnqueue(() => { status.Text = runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel); progress.Value = runtime.Models.Progress.GetValueOrDefault(model.Id); download.Content = Design.Text(runtime.Models.Busy(model.Id) ? "Pause" : runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download", 14, true); });
            }
            runtime.Models.Changed += Update;
            row.Unloaded += (_, _) => runtime.Models.Changed -= Update;
            content.Children.Add(row);
        }
        content.Children.Add(Profile("Ask Recall", draft.Chat, "chat"));
        content.Children.Add(Profile("Speech recognition", draft.Speech, "speech"));
        content.Children.Add(Design.Text("Built-in models run on this PC. Online providers receive only the memories or audio needed for your request.", 12, color: Design.Muted));
        return Section("Models", content);
    }
    FrameworkElement Profile(string title, ModelProfile profile, string account)
    {
        var provider = Choice(["Built-in model", "Existing local model", "Online API"], profile.IsBuiltin ? 0 : profile.IsLocal ? 1 : 2, i => { profile.Provider = i == 0 ? "Built-in" : i == 1 ? "Local" : "Online"; profile.IsLocal = i != 2; });
        var url = Design.Input("OpenAI-compatible API URL", profile.BaseUrl);
        url.TextChanged += (_, _) => profile.BaseUrl = url.Text;
        var model = Design.Input("Model ID", profile.Model);
        model.TextChanged += (_, _) => profile.Model = model.Text;
        var key = new PasswordBox { Password = SecretStore.Read(account), PlaceholderText = "API key", CornerRadius = new(20), Padding = new(16, 10, 16, 10) };
        secrets[account] = key;
        var status = Design.Text("", 12, color: Design.Muted);
        var check = Design.Button("Test connection", async () => { try { status.Text = profile.IsBuiltin ? "Download the built-in model above." : string.Join(", ", await ModelClient.Models(profile, key.Password)); } catch (Exception ex) { status.Text = ex.Message; } });
        return Design.Stack(10, Row(title, provider), url, model, key, check, status);
    }
    FrameworkElement Storage()
    {
        var content = Design.Stack(18);
        var reportHost = new Grid();
        content.Children.Add(reportHost);
        var refresh = Design.Button("Refresh", async () => await Measure(true));
        content.Children.Add(refresh);
        async Task Measure(bool refresh = false)
        {
            var report = await StorageService.Measure(runtime.Store, refresh);
            reportHost.Children.Clear();
            var grid = new Grid { ColumnSpacing = 28 };
            grid.ColumnDefinitions.Add(new()
            {
                Width = new(210)
            });
            grid.ColumnDefinitions.Add(new()
            {
                Width = new(1, GridUnitType.Star)
            });
            var donut = new Grid { Width = 200, Height = 200 };
            donut.Children.Add(new Ellipse { Stroke = Design.Brush(Color.FromArgb(255, 232, 238, 243)), StrokeThickness = 17, Margin = new(12) });
            double angle = -90;
            foreach (var bucket in report.Buckets.Where(b => b.Bytes > 0))
            {
                var sweep = 360.0 * bucket.Bytes / Math.Max(1, report.Total);
                var shape = Arc(angle, Math.Min(359.99, sweep), bucket.Color);
                donut.Children.Add(shape);
                angle += sweep;
            }
            var total = Design.Stack(4, Design.Text(Design.Size(report.Total), 25, true), Design.Text("used on this PC", 12, color: Design.Muted));
            total.HorizontalAlignment = HorizontalAlignment.Center;
            total.VerticalAlignment = VerticalAlignment.Center;
            donut.Children.Add(total);
            grid.Children.Add(donut);
            var legend = Design.Stack(10);
            foreach (var bucket in report.Buckets)
                legend.Children.Add(Row(bucket.Name, Design.Text(Design.Size(bucket.Bytes), 13, color: bucket.Color)));
            Grid.SetColumn(legend, 1);
            grid.Children.Add(legend);
            reportHost.Children.Add(Design.Stack(16, grid, Design.Text($"{Design.Size(report.Free)} available of {Design.Size(report.Capacity)}", 12, color: Design.Muted), new ProgressBar { Maximum = report.Capacity, Value = report.Capacity - report.Free, Height = 5, Foreground = Design.Brush(Design.Pastels[0]), CornerRadius = new(3) }));
        }
        _ = Measure();
        content.Children.Add(Row("Keep history", Choice(["7 days", "30 days", "90 days", "Forever"], Array.IndexOf(new[] { 7, 30, 90, 0 }, draft.RetentionDays), i => draft.RetentionDays = new[] { 7, 30, 90, 0 }[i])));
        var optimize = Design.Button("Optimize images and video", async () => { if (optimization != null) { optimization.Cancel(); return; } optimization = new(); try { var saved = await StorageService.Optimize(runtime.Store, new Progress<string>(s => message.Text = s), optimization.Token); message.Text = "Freed " + Design.Size(saved); await Measure(true); } catch (OperationCanceledException) { message.Text = "Optimization stopped. Completed items were kept."; } catch (Exception ex) { message.Text = ex.Message; } finally { optimization.Dispose(); optimization = null; } });
        content.Children.Add(optimize);
        var scope = CleanupScope.Trash;
        var keep = true;
        content.Children.Add(Row("Clear", Choice(["Trash", "Older than 30 days", "Older than 7 days", "All memories"], 0, i => scope = (CleanupScope)i)));
        content.Children.Add(Row("Keep starred memories", Toggle(true, v => keep = v)));
        content.Children.Add(Design.Button("Review cleanup", async () => { var plan = await Task.Run(() => runtime.Store.CleanupPreview(scope, keep)); if (plan.Ids.Length == 0) { message.Text = "No memories match this cleanup."; return; } if (await Confirm("Clear these memories?", $"{plan.Ids.Length} memories · up to {Design.Size(plan.Bytes)}. This permanently removes their unshared files and text. Active recordings and saved models are kept.", "Clear memories")) { var removed = await Task.Run(() => runtime.Store.Cleanup(plan)); message.Text = $"Cleared {removed} memories"; await Measure(true); } }));
        return Section("Storage", content);
    }
    static Microsoft.UI.Xaml.Shapes.Path Arc(double angle, double sweep, Color color)
    {
        Point At(double a) => new(100 + 80 * Math.Cos(a * Math.PI / 180), 100 + 80 * Math.Sin(a * Math.PI / 180));
        var figure = new PathFigure { StartPoint = At(angle) };
        figure.Segments.Add(new ArcSegment { Point = At(angle + sweep), Size = new(80, 80), SweepDirection = SweepDirection.Clockwise, IsLargeArc = sweep > 180 });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return new()
        {
            Data = geometry,
            Stroke = Design.Brush(color),
            StrokeThickness = 17
        };
    }
    FrameworkElement Shortcuts()
    {
        var list = Design.Stack(12);
        void Add(string name, Func<ShortcutBinding> get, Action<ShortcutBinding> set)
        {
            bool capture = false;
            var button = Design.Button(get().Label, () => { });
            button.Click += (_, _) => { capture = true; button.Content = Design.Text("Press a shortcut…", 13); button.Focus(FocusState.Keyboard); };
            button.KeyDown += (_, e) => { if (!capture) return; e.Handled = true; uint mods = 0; foreach (var pair in new[] { (VirtualKey.Control, 2u), (VirtualKey.Menu, 1u), (VirtualKey.Shift, 4u), (VirtualKey.LeftWindows, 8u) }) if ((InputKeyboardSource.GetKeyStateForCurrentThread(pair.Item1) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0) mods |= pair.Item2; var binding = new ShortcutBinding((uint)e.Key, mods); if (!binding.IsValid) return; set(binding); capture = false; button.Content = Design.Text(binding.Label, 14, true); };
            list.Children.Add(Row(name, button));
        }
        Add("Open Recall", () => draft.Shortcuts.Toggle, b => draft.Shortcuts.Toggle = b);
        Add("Alternate shortcut", () => draft.Shortcuts.Alternate, b => draft.Shortcuts.Alternate = b);
        Add("Search", () => draft.Shortcuts.Search, b => draft.Shortcuts.Search = b);
        Add("Settings", () => draft.Shortcuts.Settings, b => draft.Shortcuts.Settings = b);
        Add("Back / close", () => draft.Shortcuts.Back, b => draft.Shortcuts.Back = b);
        Add("Previous memory", () => draft.Shortcuts.Previous, b => draft.Shortcuts.Previous = b);
        Add("Next memory", () => draft.Shortcuts.Next, b => draft.Shortcuts.Next = b);
        return Section("Shortcuts", list);
    }
    async Task<bool> Confirm(string title, string text, string primary)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = Design.Text(text, 15), PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
