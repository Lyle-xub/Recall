using Windows.Media.Core;
using Windows.Media.Playback;
namespace Recall;

internal sealed class DetailView : Grid, IDisposable
{
    readonly AppRuntime runtime; MemoryFrame frame; readonly Action<MemoryFrame> open; readonly Grid visual = new(); readonly StackPanel transcript = new() { Spacing = 10 }; readonly TextBox find = Design.Input("Find in transcript");
    readonly Grid mediaViewport = new(); readonly Border mediaShell = new() { CornerRadius = new(22) }; readonly Grid transcriptPanel = new();
    readonly ColumnDefinition transcriptColumn = new() { Width = new(0) }; readonly TextBlock appTitle;
    FrameSurface? poster; Grid? videoHost; Action? videoReadyHandler; Button? starButton, trashButton, ocrButton;
    Slider? seekSlider; TextBlock? currentTime, totalTime; Button? pauseButton, speedButton; bool updatingSeek; bool? renderedPlaying; long lastSeekInputTicks;
    readonly Border speechStatus = new(); readonly TextBlock speechLabel = Design.Text("No speech", 11, true);
    bool transcriptVisible, posterVisible = true, meetingImage, videoCompleted;
    VideoSurface? videoSurface;
    int orientationCorrection;
    VideoOrientation.MatchResult? orientationMatch;
    bool manualRotationUsed;
    double matchedAspect;
    MediaPlayer? video; MediaPlayerElement? videoElement; MediaSource? videoSource; int playbackRevision, rotationSteps; string? playbackError, sourceOrientation; readonly List<(MediaPlayer Player, double Offset)> audio = []; readonly Microsoft.UI.Dispatching.DispatcherQueueTimer sync; List<TranscriptLine> lines = []; bool playing, refreshing, disposed;
    public DetailView(AppRuntime runtime, MemoryFrame frame, Action<MemoryFrame> open)
    {
        this.runtime = runtime;
        this.frame = frame;
        this.open = open;
        ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        ColumnDefinitions.Add(transcriptColumn);
        var left = new Grid();
        left.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        left.RowDefinitions.Add(new() { Height = GridLength.Auto });
        Children.Add(left);
        mediaShell.Child = visual;
        mediaShell.Background = Design.Brush(Design.Dark ? Color.FromArgb(255, 34, 38, 45) : Color.FromArgb(255, 232, 236, 241));
        mediaShell.BorderBrush = Design.RimBrush;
        mediaShell.BorderThickness = new(1);
        mediaShell.HorizontalAlignment = HorizontalAlignment.Center;
        mediaShell.VerticalAlignment = VerticalAlignment.Center;
        mediaShell.Shadow = new ThemeShadow();
        mediaShell.Translation = new(0, 0, 12);
        Design.Rounded(mediaShell, 22);
        mediaViewport.Children.Add(mediaShell);
        mediaViewport.SizeChanged += (_, _) => FitMedia();
        SizeChanged += (_, _) => UpdateTranscriptWidth();
        left.Children.Add(mediaViewport);
        ShowPoster();
        starButton = ActionIcon(frame.Starred ? "\uE735" : "\uE734", "Star memory", () =>
        {
            runtime.Store.Star(this.frame.Id);
            this.frame = runtime.Store.Frame(this.frame.Id) ?? this.frame;
            starButton!.Content = Design.Symbol(this.frame.Starred ? "\uE735" : "\uE734", 19);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(starButton, this.frame.Starred ? "Remove star" : "Star memory");
        });
        trashButton = ActionIcon(frame.DeletedAt == null ? "\uE74D" : "\uE777", frame.DeletedAt == null ? "Move to Trash" : "Restore memory", () =>
        {
            if (this.frame.DeletedAt == null)
                runtime.Store.Trash(this.frame);
            else
                runtime.Store.Restore(this.frame);
            this.frame = runtime.Store.Frame(this.frame.Id) ?? this.frame;
            trashButton!.Content = Design.Symbol(this.frame.DeletedAt == null ? "\uE74D" : "\uE777", 19);
            var title = this.frame.DeletedAt == null ? "Move to Trash" : "Restore memory";
            ToolTipService.SetToolTip(trashButton, title);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(trashButton, title);
        });
        var footer = new Grid { Margin = new(0, 15, 0, 0) };
        footer.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        appTitle = Design.Text(frame.AppName, 13, true);
        appTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        var identity = Design.Row(10, AppIcons.View(AppIcons.Identity(frame), 24), appTitle);
        identity.VerticalAlignment = VerticalAlignment.Center;
        appTitle.MaxWidth = 180;
        footer.Children.Add(identity);
        var controls = Design.Row(5);
        ocrButton = ActionIcon("\uE8D2", "Show recognized text", ShowRecognizedText);
        controls.Children.Add(ocrButton);
        controls.Children.Add(ActionIcon("\uE7C4", "Copy all recognized text", () => FrameSurface.ClipboardText(this.frame.Text)));
        controls.Children.Add(starButton);
        if (frame.SessionId is { } id && runtime.Store.Session(id) is { } session && File.Exists(runtime.Store.SafePath(session.VideoPath)))
            controls.Children.Add(ActionIcon("\uE768", "Play video", () => Play(session)));
        speechStatus.Child = Design.Row(6, Design.Symbol("\uE720", 15), speechLabel);
        speechStatus.CornerRadius = new(16);
        speechStatus.Background = Design.Brush(Design.Dark ? Color.FromArgb(88, 65, 72, 85) : Color.FromArgb(105, 210, 215, 222));
        speechStatus.Padding = new(10, 5, 10, 5);
        speechStatus.VerticalAlignment = VerticalAlignment.Center;
        controls.Children.Add(speechStatus);
        controls.Children.Add(trashButton);
        var more = Design.Menu();
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
        Menu("Export memory", Export);
        if (frame.SessionId is { } videoId && runtime.Store.Session(videoId) is { } videoSession && File.Exists(runtime.Store.SafePath(videoSession.VideoPath)))
        {
            Menu("Show recorded image", () => { Stop(); meetingImage = false; ShowPoster(); });
            Menu("Rotate video 90 degrees", RotateVideo);
        }
        if (frame.MeetingImagePath != null)
            Menu("Show meeting image", () => { Stop(); meetingImage = true; ShowPoster(); });
        var menu = ActionIcon("\uE712", "More actions", () => { });
        menu.Flyout = more;
        controls.Children.Add(menu);
        Grid.SetColumn(controls, 1);
        footer.Children.Add(controls);
        Grid.SetRow(footer, 1);
        left.Children.Add(footer);
        transcriptPanel.RowDefinitions.Add(new() { Height = GridLength.Auto });
        transcriptPanel.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        transcriptPanel.RowDefinitions.Add(new() { Height = GridLength.Auto });
        transcriptPanel.Margin = new(22, 0, 0, 0);
        transcriptPanel.Visibility = Visibility.Collapsed;
        Grid.SetColumn(transcriptPanel, 1);
        Children.Add(transcriptPanel);
        transcriptPanel.Children.Add(Design.Text("Transcript", 14, true));
        var scroll = Design.Scroll(transcript);
        scroll.Margin = new(0, 18, 0, 16);
        Grid.SetRow(scroll, 1);
        transcriptPanel.Children.Add(scroll);
        find.Height = 42;
        find.FontSize = 14;
        find.TextChanged += (_, _) => RenderTranscript();
        Grid.SetRow(find, 2);
        transcriptPanel.Children.Add(find);
        sync = DispatcherQueue.CreateTimer();
        sync.Interval = TimeSpan.FromMilliseconds(250);
        sync.Tick += (_, _) => SyncAudio();
        Unloaded += (_, _) => Dispose();
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
            poster?.Update(frame);
            appTitle.Text = frame.AppName;
            var textState = StateDescription("Text", frame.TextState);
            if (ocrButton != null)
            {
                ToolTipService.SetToolTip(ocrButton, frame.TextError ?? textState);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ocrButton, "Show recognized text. " + textState);
            }
            var session = frame.SessionId == null ? null : await Task.Run(() => runtime.Store.Session(frame.SessionId));
            if (disposed)
                return;
            var speechState = session?.SpeechState ?? RecognitionState.Disabled;
            var speechDescription = session?.SpeechError ?? StateDescription("Speech", speechState);
            speechLabel.Text = speechState switch
            {
                RecognitionState.Complete => "Speech ready",
                RecognitionState.Working => "Recognizing",
                RecognitionState.Pending => "Speech queued",
                RecognitionState.Failed => "Speech failed",
                RecognitionState.Empty => "No speech",
                _ => session == null ? "No recording" : "Speech off"
            };
            ToolTipService.SetToolTip(speechStatus, speechDescription);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(speechStatus, speechDescription);
            var updated = speechState == RecognitionState.Complete && frame.SessionId != null
                ? TranscriptPresentation.Visible(await Task.Run(() => runtime.Store.Transcript(frame.SessionId))).Where(line => !string.IsNullOrWhiteSpace(line.Text)).ToList()
                : [];
            if (disposed)
                return;
            var visible = speechState == RecognitionState.Complete && updated.Count > 0;
            if (!lines.SequenceEqual(updated)) { lines = updated; RenderTranscript(); }
            if (visible != transcriptVisible)
            {
                transcriptVisible = visible;
                transcriptPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
                UpdateTranscriptWidth();
            }
        }
        catch (ObjectDisposedException) { }
        finally { refreshing = false; }
    }
    static string StateDescription(string label, RecognitionState state)
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
        return label + " · " + value;
    }
    void RenderTranscript()
    {
        transcript.Children.Clear();
        var filtered = lines.Where(x => find.Text.Length == 0 || MemorySearch.Normalize(x.Text).Contains(MemorySearch.Normalize(find.Text))).ToList();
        var two = TranscriptPresentation.HasDistinctSpeakers(lines);
        var first = lines.FirstOrDefault()?.Speaker;
        foreach (var line in filtered)
        {
            var text = Design.Text(line.Text, 13);
            text.IsTextSelectionEnabled = true;
            var timestamp = new Button { Content = line.Timestamp.ToLocalTime().ToString("HH:mm:ss"), FontSize = 11 };
            timestamp.Click += (_, _) => Seek(line.Timestamp);
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
        if (filtered.Count == 0 && lines.Count > 0)
            transcript.Children.Add(Design.Text("No matching text.", 14, color: Design.Muted));
    }
    void UpdateTranscriptWidth() => transcriptColumn.Width = new(transcriptVisible ? (ActualWidth < 840 ? 220 : 267) : 0);
    void FitMedia()
    {
        var availableWidth = mediaViewport.ActualWidth;
        var availableHeight = mediaViewport.ActualHeight;
        if (availableWidth <= 0 || availableHeight <= 0) return;
        var aspect = videoSurface?.IsReady == true && !posterVisible ? videoSurface.DisplayAspect : poster?.ImageAspect ?? 1.6;
        if (!double.IsFinite(aspect) || aspect <= 0) aspect = 1.6;
        mediaShell.Width = Math.Max(1, Math.Min(availableWidth, availableHeight * aspect));
        mediaShell.Height = Math.Max(1, mediaShell.Width / aspect);
    }
    void ShowPoster()
    {
        if (poster != null && visual.Children.Contains(poster) && meetingImage == posterMeetingImage)
        {
            foreach (var child in visual.Children.ToArray())
                if (child != poster) visual.Children.Remove(child);
            videoHost = null;
            poster.Opacity = 1; poster.IsHitTestVisible = true; posterVisible = true; poster.Update(frame); FitMedia(); return;
        }
        visual.Children.Clear();
        videoHost = null;
        poster = new FrameSurface(runtime.Store, frame, meeting: meetingImage);
        posterMeetingImage = meetingImage;
        poster.ImageSizeChanged += FitMedia;
        visual.Children.Add(poster);
        posterVisible = true;
        FitMedia();
    }
    bool posterMeetingImage;
    static Button ActionIcon(string glyph, string label, Action action)
    {
        var button = new Button { Content = Design.Symbol(glyph, 19), Width = 40, Height = 40, MinWidth = 40, MinHeight = 40,
            Padding = new(0), BorderThickness = new(0), Background = Design.Brush(Microsoft.UI.Colors.Transparent),
            CornerRadius = new(20), UseSystemFocusVisuals = true };
        ToolTipService.SetToolTip(button, label);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action();
        return button;
    }
    void ShowRecognizedText()
    {
        if (ocrButton == null) return;
        var text = Design.Text(string.IsNullOrWhiteSpace(frame.Text) ? "No recognized text for this image." : frame.Text, 14);
        text.IsTextSelectionEnabled = true;
        text.TextWrapping = TextWrapping.Wrap;
        var scroll = Design.Scroll(text);
        scroll.MaxHeight = 360; scroll.Width = 350;
        new Flyout { Content = scroll }.ShowAt(ocrButton);
    }
    Border CreateTransport(MediaPlayer player)
    {
        var layout = new Grid { RowSpacing = 2 };
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var top = new Grid();
        top.ColumnDefinitions.Add(new() { Width = new(112) });
        top.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new() { Width = new(58) });
        var volume = new Slider { Minimum = 0, Maximum = 1, Value = player.Volume, StepFrequency = .01, SmallChange = .05,
            Width = 68, Height = 30, VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(volume, "Volume");
        volume.ValueChanged += (_, e) =>
        {
            if (video != player) return;
            player.Volume = e.NewValue;
            foreach (var track in audio) track.Player.Volume = e.NewValue;
        };
        var mute = new Button { Content = Design.Symbol("\uE767", 15), Width = 30, Height = 30, Padding = new(0),
            BorderThickness = new(0), Background = Design.Brush(Microsoft.UI.Colors.Transparent), CornerRadius = new(15) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(mute, "Mute");
        mute.Click += (_, _) =>
        {
            if (video != player) return;
            player.IsMuted = !player.IsMuted;
            foreach (var track in audio) track.Player.IsMuted = player.IsMuted;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(mute, player.IsMuted ? "Unmute" : "Mute");
            ToolTipService.SetToolTip(mute, player.IsMuted ? "Unmute" : "Mute");
        };
        var volumeRow = Design.Row(2, mute, volume);
        volumeRow.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(volumeRow);
        var back = ActionIcon("\uE892", "Skip back 10 seconds", () => SeekBy(player, -10));
        pauseButton = ActionIcon("\uE769", "Pause video", () =>
        {
            if (video != player) return;
            if (player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) player.Pause();
            else
            {
                if (videoCompleted || player.PlaybackSession.NaturalDuration > TimeSpan.Zero &&
                    player.PlaybackSession.Position >= player.PlaybackSession.NaturalDuration)
                    player.PlaybackSession.Position = TimeSpan.Zero;
                videoCompleted = false; player.Play();
            }
            UpdateTransport();
        });
        var ahead = ActionIcon("\uE893", "Skip forward 10 seconds", () => SeekBy(player, 10));
        var playbackRow = Design.Row(4, back, pauseButton, ahead);
        playbackRow.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetColumn(playbackRow, 1); top.Children.Add(playbackRow);
        speedButton = new Button { Content = "1×", Width = 54, Height = 32, Padding = new(0), BorderThickness = new(0),
            Background = Design.Brush(Microsoft.UI.Colors.Transparent), FontSize = 12, CornerRadius = new(16) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(speedButton, "Playback speed");
        speedButton.Click += (_, _) =>
        {
            if (video != player) return;
            var next = player.PlaybackSession.PlaybackRate switch { < 1.24 => 1.25, < 1.49 => 1.5, < 1.99 => 2, _ => 1 };
            player.PlaybackSession.PlaybackRate = next;
            speedButton.Content = next.ToString("0.##") + "×";
        };
        Grid.SetColumn(speedButton, 2); top.Children.Add(speedButton);
        layout.Children.Add(top);
        var bottom = new Grid { ColumnSpacing = 8, Margin = new(5, 0, 5, 0) };
        bottom.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        bottom.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        bottom.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        currentTime = Design.Text("0:00", 11, true);
        currentTime.VerticalAlignment = VerticalAlignment.Center;
        bottom.Children.Add(currentTime);
        seekSlider = new Slider { Minimum = 0, Maximum = 1, StepFrequency = .1, SmallChange = 1, LargeChange = 10,
            VerticalAlignment = VerticalAlignment.Center, Height = 26 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(seekSlider, "Playback position");
        seekSlider.ValueChanged += (_, e) =>
        {
            if (updatingSeek || video != player) return;
            var duration = player.PlaybackSession.NaturalDuration.TotalSeconds;
            if (duration <= 0) return;
            var requested = Math.Clamp(e.NewValue, 0, duration);
            lastSeekInputTicks = System.Diagnostics.Stopwatch.GetTimestamp();
            player.PlaybackSession.Position = TimeSpan.FromSeconds(requested);
            if (currentTime != null) currentTime.Text = Clock(TimeSpan.FromSeconds(requested));
        };
        Grid.SetColumn(seekSlider, 1); bottom.Children.Add(seekSlider);
        totalTime = Design.Text("0:00", 11, true);
        totalTime.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(totalTime, 2); bottom.Children.Add(totalTime);
        Grid.SetRow(bottom, 1); layout.Children.Add(bottom);
        var transport = Design.Card(layout, 18, 7);
        transport.HorizontalAlignment = HorizontalAlignment.Center;
        transport.VerticalAlignment = VerticalAlignment.Bottom;
        transport.Margin = new(0, 0, 0, 12);
        return transport;
    }
    static string Clock(TimeSpan time) => time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
    void SeekBy(MediaPlayer player, double seconds)
    {
        if (video != player) return;
        var duration = player.PlaybackSession.NaturalDuration.TotalSeconds;
        if (duration <= 0) return;
        player.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Clamp(player.PlaybackSession.Position.TotalSeconds + seconds, 0, duration));
        UpdateTransport();
    }
    void UpdateTransport()
    {
        if (video == null) return;
        var session = video.PlaybackSession;
        var duration = Math.Max(0, session.NaturalDuration.TotalSeconds);
        var position = Math.Clamp(session.Position.TotalSeconds, 0, duration);
        updatingSeek = true;
        try
        {
            if (seekSlider != null)
            {
                seekSlider.Maximum = Math.Max(1, duration);
                // Seeking is asynchronous. Keep the thumb at the user's target
                // until the playback session has had time to catch up.
                if (System.Diagnostics.Stopwatch.GetElapsedTime(lastSeekInputTicks).TotalMilliseconds > 750)
                    seekSlider.Value = position;
            }
        }
        finally { updatingSeek = false; }
        if (currentTime != null && System.Diagnostics.Stopwatch.GetElapsedTime(lastSeekInputTicks).TotalMilliseconds > 750)
            currentTime.Text = Clock(TimeSpan.FromSeconds(position));
        if (totalTime != null) totalTime.Text = Clock(TimeSpan.FromSeconds(duration));
        if (pauseButton != null)
        {
            var isPlaying = session.PlaybackState == MediaPlaybackState.Playing;
            if (renderedPlaying != isPlaying)
            {
                renderedPlaying = isPlaying;
                pauseButton.Content = Design.Symbol(isPlaying ? "\uE769" : "\uE768", 19);
                var label = isPlaying ? "Pause video" : "Play video";
                ToolTipService.SetToolTip(pauseButton, label);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(pauseButton, label);
            }
        }
    }
    internal object Diagnostics => new { playing, disposed, playbackError, hasPlayer = video != null, hasVideoElement = videoElement != null,
        transcriptVisible, transcriptLines = lines.Count, videoReady = videoSurface?.IsReady == true, posterVisible,
        mediaBounds = new { width = mediaShell.ActualWidth, height = mediaShell.ActualHeight, viewportWidth = mediaViewport.ActualWidth, viewportHeight = mediaViewport.ActualHeight },
        sourceOrientation, orientationCorrectionDegrees = orientationCorrection * 90, manualRotationDegrees = rotationSteps * 90, rotationDegrees = ((orientationCorrection + rotationSteps) % 4) * 90,
        orientationMatch, orientationMatchError = videoSurface?.MatchError, surface = videoSurface?.Diagnostics,
        position = video?.PlaybackSession.Position.TotalSeconds, duration = video?.PlaybackSession.NaturalDuration.TotalSeconds,
        width = video?.PlaybackSession.NaturalVideoWidth, height = video?.PlaybackSession.NaturalVideoHeight };
    internal void ValidationPlay() { if (frame.SessionId is { } id && runtime.Store.Session(id) is { } session) Play(session); }
    internal void RotateVideo()
    {
        manualRotationUsed = true;
        videoSurface?.CancelOrientationMatch();
        rotationSteps = (rotationSteps + 1) % 4;
        videoSurface?.SetOrientation(orientationCorrection + rotationSteps, matchedAspect, rotationSteps);
        FitMedia();
    }
    void PlaybackNotice(string message)
    {
        Stop(); ShowPoster();
        var text = Design.Text(message, 14); text.IsTextSelectionEnabled = true;
        var notice = new Border { Child = text, Padding = new(16), CornerRadius = new(8), Background = Design.Brush(Design.Dark ? Color.FromArgb(255,43,43,43) : Color.FromArgb(255,245,245,245)), VerticalAlignment = VerticalAlignment.Bottom, Margin = new(16) };
        visual.Children.Add(notice);
    }
    async void Play(RecordingSession session)
    {
        Stop(); ShowPoster(); playbackError = null; orientationCorrection = 0; orientationMatch = null; matchedAspect = 0; manualRotationUsed = false; videoCompleted = false;
        session = runtime.Store.Session(session.Id) ?? session;
        if (session.EndedAt == null) { PlaybackNotice("This recording is still being finalized. Try Play video again shortly."); return; }
        var revision = playbackRevision;
        try
        {
            var path = runtime.Store.SafePath(session.VideoPath);
            if (path == null || !File.Exists(path)) throw new FileNotFoundException("The recording file is no longer available.");
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            var properties = await file.Properties.GetVideoPropertiesAsync();
            (byte[] Pixels, int Width, int Height)? stillReference = null;
            try
            {
                var imagePath = frame.ImagePath;
                stillReference = await Task.Run(() => LoadOrientationReference(runtime.Store, imagePath));
            }
            catch { /* An unavailable still leaves metadata and manual rotation intact. */ }
            var stillAspect = stillReference is { } still ? (double)still.Width / still.Height : 0;
            if (disposed || revision != playbackRevision) return;
            sourceOrientation = properties.Orientation.ToString();
            var player = new MediaPlayer { AutoPlay = false };
            video = player;
            var host = new Grid { Background = Design.Brush(Microsoft.UI.Colors.Black), CornerRadius = new(22), Opacity = 0, IsHitTestVisible = false };
            var surface = new VideoSurface(player, error =>
            {
                if (disposed || revision != playbackRevision) return;
                playbackError = error.Message; PlaybackNotice("Video could not play. " + error.Message);
            }, stillReference, match =>
            {
                if (disposed || revision != playbackRevision) return;
                orientationMatch = match;
                if (!match.Confident || manualRotationUsed) return;
                orientationCorrection = match.SelectedSteps;
                matchedAspect = stillAspect;
                videoSurface?.SetOrientation(orientationCorrection + rotationSteps, matchedAspect, rotationSteps);
            });
            videoSurface = surface;
            surface.SetOrientation(rotationSteps, 0, rotationSteps);
            videoReadyHandler = () =>
            {
                if (disposed || revision != playbackRevision || video != player || videoSurface != surface || videoHost != host || videoCompleted) return;
                var playback = player.PlaybackSession;
                if (playback.NaturalDuration > TimeSpan.Zero && playback.Position >= playback.NaturalDuration) return;
                // The still remains on screen until the corrected first video frame exists.
                if (poster != null) { poster.Opacity = 0; poster.IsHitTestVisible = false; }
                posterVisible = false;
                FitMedia();
                host.Opacity = 1; host.IsHitTestVisible = true;
            };
            surface.Ready += videoReadyHandler;
            host.Children.Add(surface);
            var transport = CreateTransport(player);
            host.Children.Add(transport);
            host.SizeChanged += (_, _) => transport.Width = Math.Max(1, Math.Min(460, host.ActualWidth - 24));
            Design.Rounded(host, 22);
            videoHost = host;
            visual.Children.Add(host);
            player.MediaOpened += (sender, _) => DispatcherQueue.TryEnqueue(() =>
            {
                if (disposed || revision != playbackRevision || video != sender) return;
                try
                {
                    var metadataDegrees = properties.Orientation == Windows.Storage.FileProperties.VideoOrientation.Rotate90 ? 90 : properties.Orientation == Windows.Storage.FileProperties.VideoOrientation.Rotate270 ? 270 : 0;
                    var playback = sender.PlaybackSession;
                    orientationCorrection = VideoOrientation.Correction(metadataDegrees, stillAspect, playback.NaturalVideoHeight > 0 ? (double)playback.NaturalVideoWidth / playback.NaturalVideoHeight : 0);
                    videoSurface?.SetOrientation(orientationCorrection + rotationSteps, matchedAspect, rotationSteps);
                    videoSurface?.ConfirmFallbackOrientation();
                    var duration = sender.PlaybackSession.NaturalDuration.TotalSeconds;
                    var seconds = Math.Max(0, (frame.Timestamp - session.StartedAt).TotalSeconds);
                    var seekTo = TimeSpan.FromSeconds(duration > 0 ? Math.Min(seconds, Math.Max(0, duration - .05)) : 0);
                    if (seekTo > TimeSpan.FromMilliseconds(50))
                    {
                        sender.PlaybackSession.SeekCompleted += (_, _) => DispatcherQueue.TryEnqueue(() =>
                        {
                            if (!disposed && revision == playbackRevision && video == sender && !manualRotationUsed)
                                videoSurface?.ArmOrientationMatch(seekTo);
                        });
                        sender.PlaybackSession.Position = seekTo;
                    }
                    else if (!manualRotationUsed)
                        videoSurface?.ArmOrientationMatch(seekTo);
                    sender.Play(); playing = true; sync.Start(); UpdateTransport();
                }
                catch (Exception error) { playbackError = error.Message; PlaybackNotice("Video could not play. " + error.Message); }
            });
            player.MediaFailed += (sender, args) =>
            {
                var error = $"{args.ErrorMessage} (0x{args.ExtendedErrorCode.HResult:X8})";
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (disposed || revision != playbackRevision || video != sender) return;
                    playbackError = error; PlaybackNotice("Video could not play. " + error);
                });
            };
            player.MediaEnded += (_, _) => DispatcherQueue.TryEnqueue(() =>
            {
                if (revision != playbackRevision || disposed) return;
                videoCompleted = true; playing = false; sync.Stop();
                foreach (var track in audio) track.Player.Pause();
                UpdateTransport();
                if (videoSurface?.IsReady != true) { Stop(); ShowPoster(); }
            });
            player.PlaybackSession.PlaybackStateChanged += (_, _) => DispatcherQueue.TryEnqueue(() =>
            {
                if (disposed || revision != playbackRevision || video != player) return;
                playing = player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
                if (playing) sync.Start();
                else { sync.Stop(); foreach (var track in audio) track.Player.Pause(); }
                UpdateTransport();
            });
            videoSource = MediaSource.CreateFromStorageFile(file); player.Source = videoSource;
            foreach (var item in new[] { (session.SystemAudioPath, session.SystemAudioOffset), (session.MicrophoneAudioPath, session.MicrophoneAudioOffset) })
                if (item.Item1 != null && runtime.Store.SafePath(item.Item1) is { } audioPath && File.Exists(audioPath))
                    audio.Add((new MediaPlayer { AutoPlay = false, Source = MediaSource.CreateFromUri(new Uri(audioPath)) }, item.Item2));
        }
        catch (Exception error)
        {
            if (disposed || revision != playbackRevision) return;
            playbackError = error.Message; PlaybackNotice("Video could not play. " + error.Message);
        }
    }
    private static (byte[] Pixels, int Width, int Height) LoadOrientationReference(MemoryStore store, string path)
    {
        using var original = ImageArchive.Load(store.Root, path, 192);
        var scale = Math.Min(1, 192d / Math.Max(original.Width, original.Height));
        var width = Math.Max(1, (int)Math.Round(original.Width * scale));
        var height = Math.Max(1, (int)Math.Round(original.Height * scale));
        using var thumbnail = new System.Drawing.Bitmap(original, new System.Drawing.Size(width, height));
        var pixels = new byte[width * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var color = thumbnail.GetPixel(x, y);
                pixels[y * width + x] = (byte)((77 * color.R + 150 * color.G + 29 * color.B) >> 8);
            }
        return (pixels, width, height);
    }
    void SyncAudio()
    {
        UpdateTransport();
        if (!playing || video == null || videoSurface?.IsReady != true)
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
            track.Player.Volume = video.Volume;
            track.Player.IsMuted = video.IsMuted;
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
        else if (video != null)
            video.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Clamp((timestamp - session.StartedAt).TotalSeconds, 0, Math.Max(0, video.PlaybackSession.NaturalDuration.TotalSeconds - .05)));
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
        playbackRevision++; playing = false; sync.Stop();
        if (videoSurface != null && videoReadyHandler != null) videoSurface.Ready -= videoReadyHandler;
        videoReadyHandler = null;
        videoSurface?.Dispose(); videoSurface = null;
        // Detach the native video surface before removing XAML or closing HWND.
        if (videoElement != null) { videoElement.SetMediaPlayer(null); videoElement = null; }
        if (video != null) { video.Pause(); video.Source = null; video.Dispose(); video = null; }
        videoSource?.Dispose(); videoSource = null;
        foreach (var item in audio) { item.Player.Pause(); item.Player.Source = null; item.Player.Dispose(); }
        audio.Clear();
        if (videoHost != null) visual.Children.Remove(videoHost);
        videoHost = null;
        seekSlider = null; currentTime = totalTime = null; pauseButton = speedButton = null; renderedPlaying = null; lastSeekInputTicks = 0;
        if (poster != null && visual.Children.Contains(poster)) { poster.Opacity = 1; poster.IsHitTestVisible = true; posterVisible = true; FitMedia(); }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; Stop(); visual.Children.Clear();
    }
}
