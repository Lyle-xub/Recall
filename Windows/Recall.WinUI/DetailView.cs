using Windows.Media.Core;
using Windows.Media.Playback;
namespace Recall;

internal sealed class DetailView : Grid, IDisposable
{
    readonly AppRuntime runtime; MemoryFrame frame; readonly Action<MemoryFrame> open; readonly Grid visual = new(); readonly StackPanel transcript = new() { Spacing = 10 }; readonly Border textStatus = Design.Card(Design.Text(""), 18, 9), speechStatus = Design.Card(Design.Text(""), 18, 9); readonly TextBox find = Design.Input("Find in transcript");
    readonly MediaPlayer video = new() { AutoPlay = false }; readonly List<(MediaPlayer Player, double Offset)> audio = []; readonly Microsoft.UI.Dispatching.DispatcherQueueTimer sync; List<TranscriptLine> lines = []; string? transcriptVersion; bool playing, refreshing, disposed;
    public DetailView(AppRuntime runtime, MemoryFrame frame, Action<MemoryFrame> open)
    {
        this.runtime = runtime;
        this.frame = frame;
        this.open = open;
        ColumnDefinitions.Add(new()
        {
            Width = new(3, GridUnitType.Star)
        });
        ColumnDefinitions.Add(new()
        {
            Width = new(1.2, GridUnitType.Star),
            MinWidth = 300
        });
        ColumnSpacing = 24;
        var left = new Grid();
        left.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        left.RowDefinitions.Add(new()
        {
            Height = new(1, GridUnitType.Star)
        });
        left.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        Children.Add(left);
        var header = Design.Row(12, AppIcons.View(AppIcons.Identity(frame), 28), Design.Stack(3, Design.Text(frame.AppName, 15, true), Design.Text(frame.TimeLabel, 12, color: Design.Muted)));
        header.Margin = new(8, 0, 0, 12);
        left.Children.Add(header);
        visual.Children.Add(new FrameSurface(runtime.Store, frame));
        Grid.SetRow(visual, 1);
        left.Children.Add(visual);
        Button? star = null, trash = null;
        star = Design.Icon(frame.Starred ? "\uE735" : "\uE734", "Star memory", () =>
        {
            runtime.Store.Star(this.frame.Id);
            this.frame = runtime.Store.Frame(this.frame.Id) ?? this.frame;
            star!.Content = Design.Symbol(this.frame.Starred ? "\uE735" : "\uE734");
        });
        trash = Design.Icon(frame.DeletedAt == null ? "\uE74D" : "\uE777", frame.DeletedAt == null ? "Move to Trash" : "Restore memory", () =>
        {
            if (this.frame.DeletedAt == null)
                runtime.Store.Trash(this.frame);
            else
                runtime.Store.Restore(this.frame);
            this.frame = runtime.Store.Frame(this.frame.Id) ?? this.frame;
            trash!.Content = Design.Symbol(this.frame.DeletedAt == null ? "\uE74D" : "\uE777");
            var title = this.frame.DeletedAt == null ? "Move to Trash" : "Restore memory";
            ToolTipService.SetToolTip(trash, title);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(trash, title);
        });
        var controls = Design.Row(8, Design.Icon("\uE7C4", "Copy all recognized text", () => FrameSurface.ClipboardText(this.frame.Text)), star, trash, Design.Icon("\uE8A7", "Export memory", Export));
        if (frame.SessionId is { } id && runtime.Store.Session(id) is { } session && File.Exists(runtime.Store.SafePath(session.VideoPath)))
        {
            controls.Children.Add(Design.Button("Play video", () => Play(session)));
            controls.Children.Add(Design.Button("Image", () => { Stop(); visual.Children.Clear(); visual.Children.Add(new FrameSurface(runtime.Store, this.frame)); }));
        }
        if (frame.MeetingImagePath != null)
            controls.Children.Add(Design.Button("Meeting", () => { Stop(); visual.Children.Clear(); visual.Children.Add(new FrameSurface(runtime.Store, this.frame, meeting: true)); }));
        var more = new MenuFlyout();
        void Menu(string name, Action action)
        {
            var item = new MenuFlyoutItem { Text = name };
            item.Click += (_, _) => action();
            more.Items.Add(item);
        }
        Menu("Retry text recognition", () => runtime.Capture.Retry(this.frame));
        if (frame.SessionId is { } retryID)
            Menu("Retry speech recognition", () => { if (runtime.Store.Session(retryID) is { } s) runtime.QueueSpeech(s); });
        foreach (var link in ModelClient.Links(frame.Text).Take(6))
        {
            var captured = link;
            Menu("Open " + captured, () => _ = Windows.System.Launcher.LaunchUriAsync(captured));
        }
        var menu = Design.Icon("\uE712", "More actions", () => { });
        menu.Flyout = more;
        controls.Children.Add(menu);
        controls.Margin = new(0, 14, 0, 0);
        Grid.SetRow(controls, 2);
        left.Children.Add(controls);
        var right = new Grid();
        right.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        right.RowDefinitions.Add(new()
        {
            Height = new(1, GridUnitType.Star)
        });
        right.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        right.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        Grid.SetColumn(right, 1);
        Children.Add(right);
        right.Children.Add(Design.Text("Transcript", 18, true));
        var scroll = Design.Scroll(transcript);
        scroll.Margin = new(0, 18, 0, 16);
        Grid.SetRow(scroll, 1);
        right.Children.Add(scroll);
        find.Height = 42;
        find.FontSize = 14;
        find.TextChanged += (_, _) => RenderTranscript();
        Grid.SetRow(find, 2);
        right.Children.Add(find);
        var statuses = Design.Row(6, textStatus, speechStatus);
        statuses.Margin = new(0, 12, 0, 0);
        Grid.SetRow(statuses, 3);
        right.Children.Add(statuses);
        sync = DispatcherQueue.CreateTimer();
        sync.Interval = TimeSpan.FromMilliseconds(250);
        sync.Tick += (_, _) => SyncAudio();
        RefreshStatus();
    }
    public async void RefreshStatus()
    {
        if (refreshing || disposed)
            return;
        refreshing = true;
        try
        {
            var id = frame.Id;
            var fresh = await Task.Run(() => runtime.Store.Frame(id));
            if (disposed)
                return;
            if (fresh != null)
                frame = fresh;
            foreach (var surface in visual.Children.OfType<FrameSurface>())
                surface.Update(frame);
            SetPill(textStatus, "Text", frame.TextState, Design.Pastels[1], frame.TextError);
            var session = frame.SessionId == null ? null : await Task.Run(() => runtime.Store.Session(frame.SessionId));
            if (disposed)
                return;
            SetPill(speechStatus, "Speech", session?.SpeechState ?? RecognitionState.Disabled, Design.Pastels[2], session?.SpeechError);
            var version = session?.SpeechState.ToString() + frame.SessionId;
            if (version != transcriptVersion)
            {
                transcriptVersion = version;
                lines = frame.SessionId == null ? [] : TranscriptPresentation.Visible(await Task.Run(() => runtime.Store.Transcript(frame.SessionId)));
                if (!disposed)
                    RenderTranscript();
            }
        }
        catch (ObjectDisposedException) { }
        finally { refreshing = false; }
    }
    static void SetPill(Border pill, string label, RecognitionState state, Color color, string? error)
    {
        var value = state switch
        {
            RecognitionState.Working => "recognizing",
            RecognitionState.Pending => "queued",
            RecognitionState.Complete => "ready",
            RecognitionState.Empty => "no content",
            RecognitionState.Failed => "failed",
            _ => "off"
        };
        var message = label + " · " + value;
        if (pill.Child is TextBlock t && t.Text == message)
            return;
        pill.Child = Design.Text(message, 11, true, Color.FromArgb(255, (byte)(color.R * .65), (byte)(color.G * .65), (byte)(color.B * .65)));
        pill.Background = Design.Brush(Color.FromArgb(65, color.R, color.G, color.B));
        ToolTipService.SetToolTip(pill, error ?? message);
    }
    void RenderTranscript()
    {
        transcript.Children.Clear();
        var filtered = lines.Where(x => find.Text.Length == 0 || MemorySearch.Normalize(x.Text).Contains(MemorySearch.Normalize(find.Text))).ToList();
        var two = TranscriptPresentation.HasDistinctSpeakers(lines);
        var first = lines.FirstOrDefault()?.Speaker;
        foreach (var line in filtered)
        {
            var text = Design.Text(line.Text, 15);
            text.IsTextSelectionEnabled = true;
            var timestamp = Design.Button(line.Timestamp.ToLocalTime().ToString("HH:mm:ss"), () => Seek(line.Timestamp));
            timestamp.MinHeight = 30;
            timestamp.Padding = new(0);
            timestamp.Background = Design.Brush(Microsoft.UI.Colors.Transparent);
            timestamp.BorderThickness = new(0);
            var bubble = Design.Card(Design.Stack(4, text, timestamp), 21, 16);
            bubble.Margin = two && line.Speaker != first ? new(35, 0, 0, 0) : new(0, 0, two ? 35 : 0, 0);
            if (two && line.Speaker != first)
                bubble.Background = Design.Brush(Color.FromArgb(240, 215, 231, 249));
            transcript.Children.Add(bubble);
        }
        if (filtered.Count == 0)
            transcript.Children.Add(Design.Text(lines.Count == 0 ? "No transcript for this recording." : "No matching text.", 14, color: Design.Muted));
    }
    void Play(RecordingSession session)
    {
        Stop();
        visual.Children.Clear();
        var element = new MediaPlayerElement { AreTransportControlsEnabled = true, Stretch = Stretch.Uniform, CornerRadius = new(26), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        element.SetMediaPlayer(video);
        Design.Rounded(element, 26);
        visual.Children.Add(element);
        void Fit()
        {
            if (video.PlaybackSession.NaturalVideoHeight == 0)
                return;
            var aspect = (double)video.PlaybackSession.NaturalVideoWidth / video.PlaybackSession.NaturalVideoHeight;
            var width = Math.Max(1, Math.Min(visual.ActualWidth, visual.ActualHeight * aspect));
            element.Width = width;
            element.Height = width / aspect;
        }
        element.Loaded += (_, _) => Fit();
        visual.SizeChanged += (_, _) => { if (!disposed && visual.Children.Contains(element)) Fit(); };
        video.MediaOpened += Opened;
        video.Source = MediaSource.CreateFromUri(new Uri(runtime.Store.SafePath(session.VideoPath)!));
        void Opened(MediaPlayer sender, object args)
        {
            sender.MediaOpened -= Opened;
            DispatcherQueue.TryEnqueue(() => { if (disposed || !visual.Children.Contains(element)) return; Fit(); video.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Max(0, (frame.Timestamp - session.StartedAt).TotalSeconds)); video.Play(); playing = true; sync.Start(); });
        }
        foreach (var item in new[] { (session.SystemAudioPath, session.SystemAudioOffset), (session.MicrophoneAudioPath, session.MicrophoneAudioOffset) })
            if (item.Item1 != null && runtime.Store.SafePath(item.Item1) is { } path && File.Exists(path))
            {
                var player = new MediaPlayer { AutoPlay = false, Source = MediaSource.CreateFromUri(new Uri(path)) };
                audio.Add((player, item.Item2));
            }
    }
    void SyncAudio()
    {
        if (!playing)
            return;
        var position = video.PlaybackSession.Position;
        var active = video.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
        foreach (var track in audio)
        {
            var target = position - TimeSpan.FromSeconds(track.Offset);
            if (target < TimeSpan.Zero || !active || track.Player.PlaybackSession.NaturalDuration > TimeSpan.Zero && target >= track.Player.PlaybackSession.NaturalDuration)
            {
                track.Player.Pause();
                continue;
            }
            if (Math.Abs((track.Player.PlaybackSession.Position - target).TotalMilliseconds) > 250)
                track.Player.PlaybackSession.Position = target;
            track.Player.PlaybackSession.PlaybackRate = video.PlaybackSession.PlaybackRate;
            track.Player.Play();
        }
    }
    void Seek(DateTimeOffset timestamp)
    {
        if (frame.SessionId is not { } id || runtime.Store.Session(id) is not { } session)
            return;
        if (!playing)
        {
            frame = frame with
            {
                Timestamp = timestamp
            };
            Play(session);
        }
        else
            video.PlaybackSession.Position = timestamp - session.StartedAt;
    }
    async void Export()
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog { Description = "Export this memory and its recording" };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            var destination = dialog.SelectedPath;
            var selected = frame;
            try
            {
                await Task.Run(() => runtime.Store.Export(destination, [selected]));
            }
            catch (Exception ex)
            {
                if (disposed)
                    return;
                var error = new ContentDialog { XamlRoot = XamlRoot, Title = "Export could not finish", Content = ex.Message, CloseButtonText = "Close" };
                await error.ShowAsync();
            }
        }
    }
    public void Stop()
    {
        playing = false;
        sync.Stop();
        video.Pause();
        foreach (var item in audio)
            item.Player.Dispose();
        audio.Clear();
    }
    public void Dispose()
    {
        disposed = true;
        Stop();
        video.Dispose();
    }
}
