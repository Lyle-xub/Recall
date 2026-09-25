using Windows.Media.Core;
using Windows.Media.Playback;
using Microsoft.UI.Xaml.Hosting;
using System.Numerics;
using Microsoft.UI.Composition;
namespace Recall;

internal sealed class OnboardingView : Grid
{
    readonly AppRuntime runtime; readonly Action finished; readonly MediaPlayer sound = new() { Volume = .5, AutoPlay = false }; readonly CancellationTokenSource lifetime = new(); bool started, skipped, muted; int step;
    public OnboardingView(AppRuntime runtime, Action finished)
    {
        this.runtime = runtime;
        this.finished = finished;
        Loaded += async (_, _) => { if (started) return; started = true; if (!runtime.Settings.LaunchFilmSeen && Design.Motion) await Film(); else Guide(); };
        Unloaded += (_, _) => { lifetime.Cancel(); sound.Pause(); sound.Dispose(); };
    }
    async Task Film()
    {
        runtime.MarkOnboarding();
        Children.Clear();
        Background = Design.Brush(Color.FromArgb(255, 9, 11, 13));
        double width = ActualWidth, height = ActualHeight;
        bool compact = height < 720;
        var stage = new Grid();
        Children.Add(stage);
        var ambient = new Grid { Opacity = 0, IsHitTestVisible = false };
        stage.Children.Add(ambient);
        var texture = Design.Asset("Glass.png", width * 1.1);
        texture.Height = height * 1.1;
        texture.Stretch = Stretch.UniformToFill;
        texture.Opacity = .2;
        ambient.Children.Add(texture);
        ambient.Children.Add(new Border { Background = new AcrylicBrush { TintColor = Microsoft.UI.Colors.Black, TintOpacity = .7, FallbackColor = Color.FromArgb(180, 15, 17, 20) } });
        var panes = new List<FrameworkElement>();
        for (var i = 0; i < 6; i++)
        {
            var image = Design.Asset("Glass.png", width * .18);
            image.Height = height * 1.3;
            image.Stretch = Stretch.UniformToFill;
            var pane = new Border { Child = image, Width = width * .18, Height = height * 1.3, Opacity = .22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransform = new TranslateTransform { X = (i - 2.5) * width * .19 } };
            Design.Rounded(pane, 2);
            ambient.Children.Add(pane);
            panes.Add(pane);
        }
        var flash = new Ellipse { Width = Math.Max(width, height) * 2.6, Height = Math.Max(width, height) * 2.6, Fill = Design.Brush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0 };
        stage.Children.Add(flash);
        double haloWidth = Math.Min(width * .42, compact ? 340 : 460);
        var hero = new Grid { Width = haloWidth, Height = compact ? 254 : 330 };
        var halo = Design.Asset("Halo.png", haloWidth * 1.8);
        halo.Opacity = 0;
        hero.Children.Add(halo);
        var icon = Design.Asset("Recall.png", compact ? 166 : 210);
        icon.Opacity = 0;
        hero.Children.Add(icon);
        var name = Design.Text("Recall", compact ? 54 : 68, true, Microsoft.UI.Colors.White);
        name.TextAlignment = TextAlignment.Center;
        var tagline = Design.Text("Your day. Within reach.", compact ? 16 : 19, color: Color.FromArgb(175, 255, 255, 255));
        tagline.TextAlignment = TextAlignment.Center;
        var copy = Design.Stack(16, name, tagline);
        copy.Opacity = 0;
        var central = Design.Stack(compact ? 22 : 34, hero, copy);
        central.HorizontalAlignment = HorizontalAlignment.Center;
        central.VerticalAlignment = VerticalAlignment.Center;
        central.RenderTransform = new TranslateTransform { Y = compact ? -12 : -28 };
        stage.Children.Add(central);
        var mute = Design.Icon("\uE767", "Mute opening sound", () => { muted = !muted; sound.IsMuted = muted; }, 44);
        mute.HorizontalAlignment = HorizontalAlignment.Left;
        mute.VerticalAlignment = VerticalAlignment.Top;
        mute.Margin = new(32, 38, 0, 0);
        Children.Add(mute);
        var skip = Design.Button("Skip animation", () => { skipped = true; sound.Pause(); Guide(); });
        skip.HorizontalAlignment = HorizontalAlignment.Right;
        skip.VerticalAlignment = VerticalAlignment.Top;
        skip.Margin = new(0, 38, 32, 0);
        Children.Add(skip);
        var caption = Design.Text("A private memory, on your PC.", 11, color: Color.FromArgb(100, 255, 255, 255));
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        caption.VerticalAlignment = VerticalAlignment.Bottom;
        caption.Margin = new(0, 0, 0, 32);
        stage.Children.Add(caption);
        try
        {
            await Task.Delay(120, lifetime.Token);
            sound.Source = MediaSource.CreateFromUri(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Opening.wav")));
            sound.Play();
            ambient.Opacity = 1;
            for (var i = 0; i < panes.Count; i++)
            {
                var pane = panes[i];
                ElementCompositionPreview.SetIsTranslationEnabled(pane, true);
                var v = ElementCompositionPreview.GetElementVisual(pane);
                var a = v.Compositor.CreateVector3KeyFrameAnimation();
                a.InsertKeyFrame(0, new((float)((i - 2.5) * width * .2), (float)((i - 2.5) * 36), 0));
                a.InsertKeyFrame(1, Vector3.Zero);
                a.Duration = TimeSpan.FromMilliseconds(1600);
                v.StartAnimation("Translation", a);
            }
            await Design.Fade(ambient, 1, 1600, 0);
            if (StopFilm())
                return;
            halo.Opacity = 1;
            var h = ElementCompositionPreview.GetElementVisual(halo);
            h.CenterPoint = new((float)halo.Width / 2, (float)halo.Height / 2, 0);
            var scale = h.Compositor.CreateVector3KeyFrameAnimation();
            scale.InsertKeyFrame(0, new(.78f, .78f, 1));
            scale.InsertKeyFrame(1, Vector3.One);
            scale.Duration = TimeSpan.FromMilliseconds(1700);
            h.StartAnimation("Scale", scale);
            var rotation = h.Compositor.CreateScalarKeyFrameAnimation();
            rotation.InsertKeyFrame(0, -22);
            rotation.InsertKeyFrame(1, 0);
            rotation.Duration = scale.Duration;
            h.StartAnimation("RotationAngleInDegrees", rotation);
            await Design.Fade(halo, 1, 1700, 0);
            if (StopFilm())
                return;
            copy.Opacity = 1;
            await Design.Fade(copy, 1, 750, 0);
            await Task.Delay(650, lifetime.Token);
            if (StopFilm())
                return;
            flash.Opacity = 1;
            var f = ElementCompositionPreview.GetElementVisual(flash);
            f.CenterPoint = new((float)flash.Width / 2, (float)flash.Height / 2, 0);
            var reveal = f.Compositor.CreateVector3KeyFrameAnimation();
            reveal.InsertKeyFrame(0, new(.001f, .001f, 1));
            reveal.InsertKeyFrame(1, Vector3.One, f.Compositor.CreateCubicBezierEasingFunction(new(.4f, 0), new(.2f, 1)));
            reveal.Duration = TimeSpan.FromMilliseconds(1400);
            f.StartAnimation("Scale", reveal);
            name.Foreground = Design.Brush(Design.Ink);
            tagline.Foreground = Design.Brush(Design.Muted);
            caption.Foreground = Design.Brush(Design.Muted);
            icon.Opacity = 1;
            await Task.WhenAll(Design.Fade(halo, 0, 1400), Design.Fade(icon, 1, 1400, 0));
            await Task.Delay(1000, lifetime.Token);
            if (StopFilm())
                return;
            sound.Pause();
            Guide();
        }
        catch (OperationCanceledException) { }
    }
    bool StopFilm() => skipped || lifetime.IsCancellationRequested;
    void Guide()
    {
        if (lifetime.IsCancellationRequested)
            return;
        Children.Clear();
        Background = Design.Brush(Color.FromArgb(30, 255, 255, 255));
        var shell = new Grid { Width = Math.Min(840, Math.Max(600, ActualWidth - 72)), Height = Math.Min(706, Math.Max(520, ActualHeight - 64)), Padding = new(32, 16, 32, 26), CornerRadius = new(36), Background = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(1, 1), GradientStops = { new() { Offset = 0, Color = Color.FromArgb(255, 236, 249, 248) }, new() { Offset = .4, Color = Microsoft.UI.Colors.White }, new() { Offset = 1, Color = Color.FromArgb(255, 253, 241, 241) } } }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        Design.Rounded(shell, 36);
        Children.Add(shell);
        shell.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        shell.RowDefinitions.Add(new()
        {
            Height = new(1, GridUnitType.Star)
        });
        shell.RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        var top = new Grid();
        top.Children.Add(Design.Text("◯  Recall", 14, true));
        var skip = Design.Button("Skip introduction", () => { runtime.MarkOnboarding(true); finished(); });
        skip.HorizontalAlignment = HorizontalAlignment.Right;
        skip.Background = Design.Brush(Microsoft.UI.Colors.Transparent);
        skip.BorderThickness = new(0);
        top.Children.Add(skip);
        shell.Children.Add(top);
        var content = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 550 };
        Grid.SetRow(content, 1);
        shell.Children.Add(content);
        if (step is 0 or 4)
        {
            var hero = new Grid { Height = step == 0 ? 224 : 176, Width = 360 };
            for (int i = 0; i < 3; i++)
            {
                var card = new Border { Width = 160, Height = 160, CornerRadius = new(37), Background = Design.Brush(Color.FromArgb(160, 233, (byte)(i == 0 ? 246 : 236), 245)), BorderBrush = Design.Brush(Microsoft.UI.Colors.White), BorderThickness = new(1), RenderTransformOrigin = new(.5, .5), RenderTransform = new CompositeTransform { Rotation = (i - 1) * 15, TranslateX = (i - 1) * 72, TranslateY = 12 } };
                hero.Children.Add(card);
            }
            hero.Children.Add(Design.Asset("Recall.png", step == 0 ? 216 : 164));
            content.Children.Add(hero);
        }
        else if (step == 1)
        {
            var sample = Design.Card(Design.Stack(12, Design.Text("A moment from your day", 17, true), new Border { Height = 5, Width = 300, CornerRadius = new(3), Background = Design.Brush(Design.Pastels[1]) }, new Border { Height = 5, Width = 210, CornerRadius = new(3), HorizontalAlignment = HorizontalAlignment.Left, Background = Design.Brush(Design.Pastels[2]) }), 24, 25);
            var slider = new Slider { Minimum = 0, Maximum = 100, Value = 65, Width = 380 };
            content.Children.Add(Design.Stack(20, sample, slider));
        }
        else
        {
            var symbol = Design.Symbol(step == 2 ? "\uE72E" : "\uE945", 50, Design.Pastels[2]);
            symbol.Margin = new(0, 25, 0, 25);
            content.Children.Add(symbol);
        }
        var titles = new[] { "Your day.\nWithin reach.", "Find your way back.", "Only what you choose.", "A little more insight.", "Ready for your next idea." };
        var descriptions = new[] { "A private, searchable memory of the things you see and hear.", "Slide back to a moment, search a word, and pick up where you left off.", "Choose what Recall can capture. You can change this at any time.", "Download a model for private answers and transcription on this PC.", "Recall stays in your system tray, ready whenever you need it." };
        var title = Design.Text(titles[step], step == 0 ? 46 : 34, true);
        title.TextAlignment = TextAlignment.Center;
        var description = Design.Text(descriptions[step], 15, color: Design.Muted);
        description.TextAlignment = TextAlignment.Center;
        description.MaxWidth = 480;
        content.Children.Add(title);
        content.Children.Add(description);
        if (step == 2)
        {
            foreach (var option in new[] { ("System audio", runtime.Settings.SystemAudio, (Action<bool>)(v => runtime.Settings.SystemAudio = v)), ("Microphone", runtime.Settings.Microphone, (Action<bool>)(v => runtime.Settings.Microphone = v)), ("Automatic transcription", runtime.Settings.TranscriptionEnabled, (Action<bool>)(v => runtime.Settings.TranscriptionEnabled = v)) })
            {
                var toggle = new CheckBox { Content = option.Item1, IsChecked = option.Item2 };
                toggle.Checked += (_, _) => option.Item3(true);
                toggle.Unchecked += (_, _) => option.Item3(false);
                content.Children.Add(toggle);
            }
            content.Children.Add(Design.Button("Microphone settings", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"))));
        }
        if (step == 3)
            foreach (var model in runtime.Models.Catalog)
            {
                var status = Design.Text(runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel), 12, color: Design.Muted);
                var button = Design.Button(runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download " + model.Title, async () => { if (runtime.Models.Busy(model.Id)) runtime.Models.Pause(model.Id); else await runtime.Models.Download(model); });
                void Update()
                {
                    DispatcherQueue.TryEnqueue(() => { status.Text = runtime.Models.Status.GetValueOrDefault(model.Id, model.SizeLabel); button.Content = Design.Text(runtime.Models.Busy(model.Id) ? "Pause" : runtime.Models.Installed.Contains(model.Id) ? "Installed" : "Download " + model.Title, 14, true); });
                }
                runtime.Models.Changed += Update;
                button.Unloaded += (_, _) => runtime.Models.Changed -= Update;
                content.Children.Add(Design.Row(18, button, status));
            }
        if (step == 4)
        {
            var shortcut = Design.Text(runtime.Settings.Shortcuts.Toggle.Label, 21, true);
            shortcut.HorizontalAlignment = HorizontalAlignment.Center;
            content.Children.Add(shortcut);
        }
        if (step == 0 || step == 1)
        {
            var caption = Design.Text(step == 0 ? "Saved on your PC. Controlled by you." : "Drag the timeline to try it", 12, color: Design.Muted);
            caption.HorizontalAlignment = HorizontalAlignment.Center;
            content.Children.Add(caption);
        }
        var footer = new Grid();
        var back = Design.Icon("\uE72B", "Previous step", () => { step = Math.Max(0, step - 1); Guide(); }, 44);
        back.Visibility = step == 0 ? Visibility.Collapsed : Visibility.Visible;
        back.HorizontalAlignment = HorizontalAlignment.Left;
        footer.Children.Add(back);
        var dots = Design.Row(7);
        dots.HorizontalAlignment = HorizontalAlignment.Center;
        dots.VerticalAlignment = VerticalAlignment.Center;
        for (int i = 0; i < 5; i++)
            dots.Children.Add(new Border { Width = i == step ? 22 : 6, Height = 6, CornerRadius = new(3), Background = Design.Brush(i == step ? Design.Pastels[2] : Color.FromArgb(50, 60, 70, 90)) });
        footer.Children.Add(dots);
        var next = Design.Button(step == 0 ? "Let’s begin" : step == 4 ? "Start recording" : "Continue", () => { if (step < 4) { step++; Guide(); } else { runtime.MarkOnboarding(true); runtime.Recording.Request(true); finished(); } }, true);
        next.Background = Design.Brush(Design.Ink);
        next.HorizontalAlignment = HorizontalAlignment.Right;
        footer.Children.Add(next);
        Grid.SetRow(footer, 2);
        shell.Children.Add(footer);
        Design.Spring(shell, 16, .96f);
    }
}
