using Microsoft.UI.Input;
using Windows.System;
using System.Text.Json;
namespace Recall;

internal sealed class SettingsView : Grid
{
    readonly AppRuntime runtime; readonly Func<AppSettings, Task> save; readonly AppSettings draft; readonly StackPanel sections = new() { Spacing = 16 }; readonly TextBlock message = Design.Text("Changes apply when you save.", 11, color: Design.Muted); readonly TextBlock subtitle = Design.Text("Choose what Recall remembers.", 12, color: Design.Muted); readonly Dictionary<string, PasswordBox> secrets = []; CancellationTokenSource? optimization;
    readonly Dictionary<string, Button> tabButtons = [];
    readonly ScrollViewer scroll;
    readonly Button saveButton;
    long saveRevision;
    public SettingsView(AppRuntime runtime, Func<AppSettings, Task> save, Action close)
    {
        this.runtime = runtime;
        this.save = save;
        foreach (var key in new[] { "ComboBoxDropDownBackground", "ContentDialogBackground", "ToolTipBackground" })
            Resources[key] = Design.Brush(Design.Dark ? Color.FromArgb(255, 44, 44, 44) : Color.FromArgb(255, 249, 249, 249));
        draft = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(runtime.Settings))!;
        Width = 660;
        HorizontalAlignment = HorizontalAlignment.Center;
        Background = Design.Brush(Design.Dark ? Color.FromArgb(255,32,32,32) : Microsoft.UI.Colors.White);
        CornerRadius = new(12);
        Design.Rounded(this, 12);
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        var header = new Grid { Margin = new(24, 20, 24, 16), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(Design.Stack(4, Design.Text("Settings", 23, true), subtitle));
        var dismiss = Design.Icon("\uE8BB", "Close settings", close, 44);
        Grid.SetColumn(dismiss, 1);
        header.Children.Add(dismiss);
        Children.Add(header);
        var tabs = new Grid { ColumnSpacing = 4 };
        foreach (var name in new[] { "Recording", "Permissions", "Models", "Storage", "Shortcuts" })
        {
            tabs.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            var button = Design.Button(name, () => SelectTab(name));
            button.Padding = new(8); button.MinHeight = 60; button.HorizontalAlignment = HorizontalAlignment.Stretch;
            var glyph = TabGlyph(name);
            var icon = Design.Symbol(glyph); icon.HorizontalAlignment = HorizontalAlignment.Center;
            var label = Design.Text(name, 11, true); label.HorizontalAlignment = HorizontalAlignment.Center;
            button.Content = Design.Stack(5, icon, label);
            Grid.SetColumn(button, tabs.Children.Count); tabButtons[name] = button;
            tabs.Children.Add(button);
        }
        var tabBar = Design.Card(tabs, 21, 5);
        tabBar.Margin = new(24, 0, 24, 4);
        Grid.SetRow(tabBar, 1);
        Children.Add(tabBar);
        scroll = Design.Scroll(new Border { Padding = new(24, 18, 24, 24), Child = sections });
        Grid.SetRow(scroll, 2);
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
        var cancel = NativeButton("Cancel", close);
        Grid.SetColumn(cancel, 1);
        footer.Children.Add(cancel);
        saveButton = NativeButton("Save changes", () => _ = SaveSettings(), true);
        Grid.SetColumn(saveButton, 2);
        footer.Children.Add(saveButton);
        var footerFrame = new Border { Child = footer, Padding = new(24, 16, 24, 16), BorderThickness = new(0, 1, 0, 0), BorderBrush = Design.Brush(Design.Dark ? Color.FromArgb(255, 58, 58, 58) : Color.FromArgb(255, 240, 240, 240)) };
        Grid.SetRow(footerFrame, 3);
        Children.Add(footerFrame);
        Unloaded += (_, _) => optimization?.Cancel();
    }
    internal object Diagnostics => new { message = message.Text, saveEnabled = saveButton.IsEnabled };
    internal void ValidationSave() => _ = SaveSettings();
    async Task SaveSettings()
    {
        var revision = ++saveRevision;
        saveButton.IsEnabled = false;
        message.Text = "Saving…";
        try
        {
            draft.Shortcuts.Validate();
            foreach (var item in secrets) SecretStore.Save(item.Key, item.Value.Password);
            await save(draft);
            message.Text = "Saved";
            await Task.Delay(1800);
            if (revision == saveRevision && IsLoaded) message.Text = "Changes apply when you save.";
        }
        catch (Exception ex) { message.Text = ex.Message; }
        finally { if (revision == saveRevision && IsLoaded) saveButton.IsEnabled = true; }
    }
    static Button NativeButton(string title, Action click, bool primary = false)
    {
        var button = new Button { Content = title, MinHeight = 32, FontFamily = Design.BodyFont };
        if (primary && Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style)) button.Style = (Style)style;
        button.Click += (_, _) => click(); return button;
    }
    static TextBox NativeInput(string placeholder, string value = "") => new() { PlaceholderText = placeholder, Text = value, MinHeight = 32, FontFamily = Design.BodyFont };
    static string TabGlyph(string name) => name switch { "Recording" => "\uE7C8", "Permissions" => "\uE72E", "Models" => "\uE945", "Storage" => "\uE7F1", _ => "\uE765" };
    static string TabSubtitle(string name) => name switch { "Recording" => "Choose what Recall remembers.", "Permissions" => "Control access to your screen and microphone.", "Models" => "Intelligence that works your way.", "Storage" => "Your memories, under your control.", _ => "A quick way back to any moment." };
    public void SelectTab(string name)
    {
        optimization?.Cancel();
        subtitle.Text = TabSubtitle(name);
        foreach (var (key, button) in tabButtons)
        {
            GlassMaterial.SetAccent(button, key == name ? Design.Dark ? Color.FromArgb(255, 52, 68, 92) : Color.FromArgb(255, 224, 235, 254) : null);
            button.BorderBrush = Design.Brush(key == name ? Color.FromArgb(255, 180, 207, 253) : Microsoft.UI.Colors.Transparent);
            var icon = Design.Symbol(TabGlyph(key), 17, key == name ? Design.Blue : Design.Muted); icon.HorizontalAlignment = HorizontalAlignment.Center;
            var label = Design.Text(key, 11, key == name, key == name ? Design.Blue : Design.Muted); label.HorizontalAlignment = HorizontalAlignment.Center;
            button.Content = Design.Stack(5, icon, label);
        }
        sections.Children.Clear();
        sections.Children.Add(name switch { "Permissions" => Permissions(), "Models" => Models(), "Storage" => Storage(), "Shortcuts" => Shortcuts(), _ => Recording() });
        scroll.ChangeView(null, 0, null, true);
    }
    static Border Section(string title, string symbol, params UIElement[] children)
    {
        var stack = Design.Stack(14);
        if (title.Length > 0)
            stack.Children.Add(Design.Row(9, Design.Symbol(symbol, 17, Design.Blue), Design.Text(title, 15, true)));
        foreach (var c in children)
            stack.Children.Add(c);
        var card = new Border { Child = stack, Padding = new(18), CornerRadius = new(16), Background = Design.Brush(Design.Dark ? Color.FromArgb(255,43,43,43) : Microsoft.UI.Colors.White), BorderBrush = Design.Brush(Design.Dark ? Color.FromArgb(255,58,58,58) : Color.FromArgb(255,229,232,238)), BorderThickness = new(1) };

        return card;
    }
    static Border Divider() => new() { Height = 1, Background = Design.Brush(Design.Dark ? Color.FromArgb(255, 57, 57, 57) : Color.FromArgb(255, 240, 240, 240)) };
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
        t.FontFamily = Design.BodyFont;
        t.Toggled += (_, _) => change(t.IsOn);
        return t;
    }
    static ComboBox Choice(string[] options, int selected, Action<int> change)
    {
        var c = new ComboBox { ItemsSource = options, SelectedIndex = Math.Max(0, selected), MinWidth = 150, MinHeight = 32 };
        c.FontFamily = Design.BodyFont;
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) change(c.SelectedIndex); };
        return c;
    }
    FrameworkElement Recording()
    {
        var screens = System.Windows.Forms.Screen.AllScreens;
        var index = Array.FindIndex(screens, x => x.DeviceName == draft.DisplayName);
        var excluded = NativeInput("One process name per line", string.Join(Environment.NewLine, draft.ExcludedApps));
        excluded.AcceptsReturn = true;
        excluded.TextWrapping = TextWrapping.Wrap;
        excluded.Height = 100;
        excluded.TextChanged += (_, _) => draft.ExcludedApps = excluded.Text.Split(new[] { ',', '\r', '\n' }, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var appearance = Row("Appearance", Choice(["Light", "Dark"], draft.DarkAppearance ? 1 : 0, i => draft.DarkAppearance = i == 1));
        appearance.Visibility = draft.RhineLabMode ? Visibility.Visible : Visibility.Collapsed;
        var rhine = Row("Rhine Lab Mode", Toggle(draft.RhineLabMode, v => { draft.RhineLabMode = v; appearance.Visibility = v ? Visibility.Visible : Visibility.Collapsed; }), "A glass archive arranged by day.");
        var statusTitle = Design.Text("", 15, true);
        var statusDetail = Design.Text("", 11, color: Design.Muted);
        var recordingAction = NativeButton("Start recording", () => { var state = runtime.Recording.State; runtime.Recording.Request(state.CaptureFaulted || !state.Requested); });
        var statusRow = new Grid { ColumnSpacing = 14 };
        statusRow.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        statusRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        statusRow.Children.Add(Design.Row(14, Design.Symbol("\uE7C8", 26), Design.Stack(4, statusTitle, statusDetail)));
        Grid.SetColumn(recordingAction, 1);
        statusRow.Children.Add(recordingAction);
        var recordingCard = Section("", "", statusRow);
        void UpdateRecording()
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var state = runtime.Recording.State;
                statusTitle.Text = state.CaptureFaulted && state.Requested ? "Recording interrupted" : state.Requested ? "Recording is on" : "Recording paused";
                statusDetail.Text = state.CaptureFaulted && state.Requested ? "Retry when you close Recall." : state.Requested ? "Capture pauses while Recall is open." : "Start recording to remember new moments.";
                recordingAction.Content = state.CaptureFaulted && state.Requested ? "Retry recording" : state.Requested ? "Pause recording" : "Start recording";
            });
        }
        void OnRecordingChanged(RecordingState _) => UpdateRecording();
        runtime.Recording.Changed += OnRecordingChanged;
        recordingCard.Unloaded += (_, _) => runtime.Recording.Changed -= OnRecordingChanged;
        UpdateRecording();
        return Design.Stack(16,
            recordingCard,
            Section("Appearance", "\uE71D", rhine, appearance, Divider(), Row("Show taskbar icon", Toggle(draft.ShowTaskbarIcon, v => draft.ShowTaskbarIcon = v), "Recall remains available in the system tray.")),
            Section("Screen capture", "\uE714", Row("Capture interval", Choice(["1 second", "3 seconds", "5 seconds", "10 seconds"], Array.IndexOf(new[] { 1, 3, 5, 10 }, draft.CaptureInterval), i => draft.CaptureInterval = new[] { 1, 3, 5, 10 }[i]), "How often a screen is saved."), Divider(), Row("Display", Choice(screens.Select((x, i) => $"Display {i + 1} · {x.Bounds.Width} × {x.Bounds.Height}").ToArray(), index, i => draft.DisplayName = screens[i].DeviceName)), Divider(), Row("Open at sign-in", Toggle(draft.LaunchAtLogin, v => draft.LaunchAtLogin = v), "Recording stays paused until you start it.")),
            Section("Audio", "\uE767", Row("System audio", Toggle(draft.SystemAudio, v => draft.SystemAudio = v), "Remember meetings and audio playing on this PC."), Divider(), Row("Microphone", Toggle(draft.Microphone, v => draft.Microphone = v), "Include your voice in recordings."), NativeButton("Manage permissions", () => SelectTab("Permissions")), Design.Text("Audio stays on this PC. Automatic transcription is configured in Models.", 11, color: Design.Muted)),
            Section("Excluded applications", "\uE7ED", Design.Text("One process name per line, without .exe. Capture pauses while an excluded app is visible.", 11, color: Design.Muted), excluded),
            Design.Text("Cards keep the screen’s original resolution and share their recording after text recognition. Video records at 1 fps, using hardware HEVC when available or compatible H.264.", 11, color: Design.Muted));
    }
    FrameworkElement Permissions()
    {
        var mic = Design.Text("Not checked", 12, color: Design.Muted);
        var button = NativeButton("Check microphone", async () => { try { using var capture = new Windows.Media.Capture.MediaCapture(); await capture.InitializeAsync(new Windows.Media.Capture.MediaCaptureInitializationSettings { StreamingCaptureMode = Windows.Media.Capture.StreamingCaptureMode.Audio }); mic.Text = "Microphone available"; } catch (Exception ex) { mic.Text = "Microphone unavailable: " + ex.Message; } });
        return Design.Stack(16,
            Section("Screen & system audio", "\uE714", Design.Text("Capture the selected display and, when enabled in Recording, system audio playing on this PC.", 12, color: Design.Muted), Row("Screen recording", Design.Text("Available when recording starts", 12, color: Design.Muted)), Design.Text("Protected windows may appear blank.", 11, color: Design.Muted)),
            Section("Microphone", "\uE720", Design.Text("Allow access to record your voice. Choose whether to include it in Recording settings.", 12, color: Design.Muted), Design.Stack(4, Design.Text("Access status", 13), mic), Design.Row(10, button, NativeButton("Open Windows privacy settings", () => _ = Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone")))), Design.Text("Allow desktop apps to access your microphone in Windows Settings.", 11, color: Design.Muted)),
            Design.Text("System permissions apply immediately.", 11, color: Design.Muted));
    }
    FrameworkElement Models()
    {
        var offlineModels = Design.Stack(16);
        foreach (var model in runtime.Models.Catalog)
        {
            var status = Design.Text(runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel + " · Download to use offline"), 12, color: Design.Muted);
            var progress = new ProgressBar { Maximum = 1, Value = runtime.Models.Progress.GetValueOrDefault(model.Id), Height = 4, CornerRadius = new(2) };
            var download = NativeButton(runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download", async () => { if (runtime.Models.Busy(model.Id)) runtime.Models.Pause(model.Id); else await runtime.Models.Download(model); });
            var remove = NativeButton("Remove", async () => { if (await Confirm("Remove " + model.Title + "?", "Your memories remain stored. You can download this model again.", "Remove")) runtime.Models.Remove(model); });
            var row = Design.Stack(8, Row(model.Title, Design.Row(8, download, remove)), status, progress);
            void Update()
            {
                DispatcherQueue.TryEnqueue(() => { status.Text = runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel); progress.Value = runtime.Models.Progress.GetValueOrDefault(model.Id); download.Content = Design.Text(runtime.Models.Busy(model.Id) ? "Pause" : runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download", 14, true); });
            }
            runtime.Models.Changed += Update;
            row.Unloaded += (_, _) => runtime.Models.Changed -= Update;
            offlineModels.Children.Add(row);
        }
        var speechFields = Design.Stack(12, Divider(), Profile(draft.Speech, "speech"), Design.Text("Local recognition stays on this PC. An online speech provider receives recorded audio segments while transcription is enabled.", 11, color: Design.Muted));
        speechFields.Visibility = draft.TranscriptionEnabled ? Visibility.Visible : Visibility.Collapsed;
        return Design.Stack(16,
            Section("Ask Recall", "\uE945", Profile(draft.Chat, "chat"), Design.Text("Local mode keeps your memory text on this computer. Online providers receive matching screen text and transcripts when you ask; screenshots stay on this PC.", 11, color: Design.Muted)),
            Section("Meeting transcription", "\uE8F2", Row("Transcribe recorded audio", Toggle(draft.TranscriptionEnabled, v => { draft.TranscriptionEnabled = v; speechFields.Visibility = v ? Visibility.Visible : Visibility.Collapsed; }), "Turn conversations into searchable memories."), speechFields),
            Section("Built-in models", "\uE945", offlineModels, Design.Text("Built-in models run on this PC. Download or remove them without changing your saved memories.", 11, color: Design.Muted)));
    }
    FrameworkElement Profile(ModelProfile profile, string account)
    {
        var fields = Design.Stack(10);
        var provider = Choice(["Built-in model", "Existing local model", "Online API"], profile.IsBuiltin ? 0 : profile.IsLocal ? 1 : 2, i => { profile.Provider = i == 0 ? "Built-in" : i == 1 ? "Local" : "Online"; profile.IsLocal = i != 2; fields.Visibility = profile.IsBuiltin ? Visibility.Collapsed : Visibility.Visible; });
        var url = NativeInput("OpenAI-compatible API URL", profile.BaseUrl);
        url.TextChanged += (_, _) => profile.BaseUrl = url.Text;
        var model = NativeInput("Model ID", profile.Model);
        model.TextChanged += (_, _) => profile.Model = model.Text;
        var key = new PasswordBox { Password = SecretStore.Read(account), PlaceholderText = "API key", MinHeight = 32 };
        key.FontFamily = Design.BodyFont;
        secrets[account] = key;
        var status = Design.Text("", 12, color: Design.Muted);
        var check = NativeButton("Test connection", async () => { try { status.Text = profile.IsBuiltin ? "Download the built-in model above." : string.Join(", ", await ModelClient.Models(profile, key.Password)); } catch (Exception ex) { status.Text = ex.Message; } });
        fields.Children.Add(Divider());
        fields.Children.Add(Design.Stack(6, Design.Text("API base URL", 11, color: Design.Muted), url));
        fields.Children.Add(Design.Stack(6, Design.Text("Model name", 11, color: Design.Muted), model));
        fields.Children.Add(Design.Stack(6, Design.Text("API key", 11, color: Design.Muted), key));
        fields.Children.Add(check);
        fields.Children.Add(status);
        fields.Visibility = profile.IsBuiltin ? Visibility.Collapsed : Visibility.Visible;
        return Design.Stack(10, Row("Provider", provider), fields);
    }
    FrameworkElement Storage()
    {
        var reportHost = new Grid();
        reportHost.Children.Add(Design.Text("Measuring storage in the background…", 12, color: Design.Muted));
        var refresh = NativeButton("Refresh", async () => await Measure(true));
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
                legend.Children.Add(Row(bucket.Name, Design.Row(8, new Ellipse { Width = 8, Height = 8, Fill = Design.Brush(bucket.Color), VerticalAlignment = VerticalAlignment.Center }, Design.Text(Design.Size(bucket.Bytes), 13))));
            Grid.SetColumn(legend, 1);
            grid.Children.Add(legend);
            reportHost.Children.Add(Design.Stack(16, grid, Design.Text($"{Design.Size(report.Free)} available of {Design.Size(report.Capacity)}", 12, color: Design.Muted), new ProgressBar { Maximum = report.Capacity, Value = report.Capacity - report.Free, Height = 5, Foreground = Design.Brush(Design.Pastels[0]), CornerRadius = new(3) }));
        }
        _ = Measure();
        var optimize = NativeButton("Optimize images and video", async () => { if (optimization != null) { optimization.Cancel(); return; } optimization = new(); try { var saved = await StorageService.Optimize(runtime.Store, new Progress<string>(s => message.Text = s), optimization.Token); message.Text = "Freed " + Design.Size(saved); await Measure(true); } catch (OperationCanceledException) { message.Text = "Optimization stopped. Completed items were kept."; } catch (Exception ex) { message.Text = ex.Message; } finally { optimization.Dispose(); optimization = null; } });
        var scope = CleanupScope.Trash;
        var keep = true;
        var cleanup = NativeButton("Review cleanup", async () => { try { var plan = await Task.Run(() => runtime.Store.CleanupPreview(scope, keep)); if (plan.Ids.Length == 0) { message.Text = "No memories match this cleanup."; return; } if (await Confirm("Clear these memories?", $"{plan.Ids.Length} memories · up to {Design.Size(plan.Bytes)}. This permanently removes their unshared files and text. Active recordings and saved models are kept.", "Clear memories")) { var removed = await StorageService.Maintain(() => Task.Run(() => runtime.Store.Cleanup(plan))); message.Text = $"Cleared {removed} memories"; await Measure(true); } } catch (Exception ex) { message.Text = ex.Message; } });
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(Design.Row(9, Design.Symbol("\uE7F1", 17, Design.Blue), Design.Text("Storage on this PC", 15, true)));
        Grid.SetColumn(refresh, 1);
        heading.Children.Add(refresh);
        return Design.Stack(16,
            Section("", "", heading, reportHost, Divider(), Design.Text("Review and clear old memories and recordings from the cleanup options below.", 11, color: Design.Muted)),
            Section("Optimize storage", "\uE9D9", Design.Text("Repack images and video to free space while keeping your memories available.", 11, color: Design.Muted), optimize),
            Section("Memory library", "\uE7F1", Row("Keep history", Choice(["7 days", "30 days", "90 days", "Forever"], Array.IndexOf(new[] { 7, 30, 90, 0 }, draft.RetentionDays), i => draft.RetentionDays = new[] { 7, 30, 90, 0 }[i])), Design.Text("Older unstarred memories move to Trash. Starred memories are retained.", 11, color: Design.Muted), Divider(), Design.Text(runtime.Store.Root, 11, color: Design.Muted), NativeButton("Open data folder", () => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(runtime.Store.Root) { UseShellExecute = true }); } catch (Exception ex) { message.Text = ex.Message; } })),
            Section("Trash and cleanup", "\uE74D", Design.Text("Review what will be removed before deleting memories permanently.", 11, color: Design.Muted), Row("Clear", Choice(["Trash", "Older than 30 days", "Older than 7 days", "All memories"], 0, i => scope = (CleanupScope)i)), Row("Keep starred memories", Toggle(true, v => keep = v)), cleanup));
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
        var global = Design.Stack(12);
        var within = Design.Stack(12);
        var recorders = new List<(Button Button, Func<ShortcutBinding> Get)>();
        void Add(StackPanel group, string name, Func<ShortcutBinding> get, Action<ShortcutBinding> set)
        {
            bool capture = false;
            var button = NativeButton(get().Label, () => { });
            button.Click += (_, _) => { capture = true; button.Content = Design.Text("Press a shortcut…", 13); button.Focus(FocusState.Keyboard); };
            button.KeyDown += (_, e) => { if (!capture) return; e.Handled = true; uint mods = 0; foreach (var pair in new[] { (VirtualKey.Control, 2u), (VirtualKey.Menu, 1u), (VirtualKey.Shift, 4u), (VirtualKey.LeftWindows, 8u) }) if ((InputKeyboardSource.GetKeyStateForCurrentThread(pair.Item1) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0) mods |= pair.Item2; var binding = new ShortcutBinding((uint)e.Key, mods); if (!binding.IsValid) return; set(binding); capture = false; button.Content = Design.Text(binding.Label, 14, true); message.Text = "Shortcut updated. Save to apply."; };
            group.Children.Add(Row(name, button));
            recorders.Add((button, get));
        }
        Add(global, "Open Recall", () => draft.Shortcuts.Toggle, b => draft.Shortcuts.Toggle = b);
        Add(global, "Alternate shortcut", () => draft.Shortcuts.Alternate, b => draft.Shortcuts.Alternate = b);
        Add(within, "Search", () => draft.Shortcuts.Search, b => draft.Shortcuts.Search = b);
        Add(within, "Previous memory", () => draft.Shortcuts.Previous, b => draft.Shortcuts.Previous = b);
        Add(within, "Next memory", () => draft.Shortcuts.Next, b => draft.Shortcuts.Next = b);
        Add(within, "Back / close", () => draft.Shortcuts.Back, b => draft.Shortcuts.Back = b);
        Add(within, "Settings", () => draft.Shortcuts.Settings, b => draft.Shortcuts.Settings = b);
        return Design.Stack(16,
            Section("Open Recall from any app", "\uE765", global, Design.Text("Click a shortcut, then press your preferred combination. Global shortcuts need at least one modifier.", 11, color: Design.Muted), Design.Text("Recall must be running in the system tray. Shortcuts work when its window is closed.", 11, color: Design.Muted)),
            Section("Within Recall", "\uE765", within),
            NativeButton("Restore default shortcuts", () => { draft.Shortcuts = new ShortcutSettings(); foreach (var (button, get) in recorders) button.Content = Design.Text(get().Label, 14, true); message.Text = "Defaults restored. Save to apply."; }));
    }
    async Task<bool> Confirm(string title, string text, string primary)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = Design.Text(text, 15), PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        dialog.RequestedTheme = Design.Dark ? ElementTheme.Dark : ElementTheme.Light;
        dialog.Resources["ContentDialogBackground"] = Design.Brush(Design.Dark ? Color.FromArgb(255,44,44,44) : Color.FromArgb(255,249,249,249));
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
