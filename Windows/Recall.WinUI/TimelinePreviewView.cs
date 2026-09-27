using Microsoft.UI.Xaml.Automation;

namespace Recall;

/// <summary>The timeline keeps one image surface and one set of actions while scrubbing.</summary>
internal sealed class TimelinePreviewView : Grid
{
    readonly AppRuntime runtime;
    readonly FrameSurface surface;
    readonly Grid imageArea = new();
    readonly Border imageShell;
    readonly Border header;
    readonly Border badge = new() { Width = 24, Height = 24 };
    readonly TextBlock recorded = Design.Text("Loading recorded image", 11, color: Design.Ink);
    readonly TextBlock title = Design.Text("", 12, true);
    readonly TextBlock status = Design.Text("", 12, true);
    readonly Button star;
    readonly Action<MemoryFrame> open;
    FrameworkElement? widthHost;
    MemoryFrame? displayed;
    MemoryFrame? failedTarget;

    public TimelinePreviewView(AppRuntime runtime, MemoryFrame initial, Action<MemoryFrame> open,
        Action showSearch, bool hasSearch)
    {
        this.runtime = runtime;
        this.open = open;
        Width = MaxWidth = 1600;
        HorizontalAlignment = HorizontalAlignment.Center;
        Loaded += (_, _) => AttachWidthHost();
        Unloaded += (_, _) => DetachWidthHost();
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        RowSpacing = 10;

        title.MaxWidth = 210;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.MaxLines = 1;
        var metadata = Design.Stack(2, recorded, title);
        metadata.VerticalAlignment = VerticalAlignment.Center;
        star = ActionButton("\uE734", "Star this memory", Star);
        var copy = ActionButton("\uE8C8", "Copy all recognized text", () =>
        {
            if (displayed is { } frame) FrameSurface.ClipboardText(frame.Text);
        });
        var details = ActionButton("\uE8A7", "Recording, meeting and transcript", () =>
        {
            if (displayed is { } frame) this.open(frame);
        });
        var contents = Design.Row(6, badge, metadata,
            new Border { Width = 1, Height = 20, Margin = new(5, 0, 3, 0), Background = Design.Brush(Design.Muted), Opacity = .5 },
            star, copy, details);
        if (hasSearch)
            contents.Children.Add(ActionButton("\uE71D", "Back to search results", showSearch));
        contents.VerticalAlignment = VerticalAlignment.Center;
        header = Design.Card(contents, 26, 6);
        header.HorizontalAlignment = HorizontalAlignment.Center;
        header.Height = 52;
        header.Padding = new(12, 4, 12, 4);
        GlassMaterial.SetAccent(header, Design.Dark
            ? Color.FromArgb(255, 34, 39, 48) : Color.FromArgb(255, 247, 248, 250));
        Children.Add(header);

        surface = new FrameSurface(runtime.Store, initial);
        surface.Presented += Present;
        surface.Failed += Fail;
        surface.ImageSizeChanged += FitImage;
        imageShell = Design.Card(surface, 22, 7);
        imageShell.BorderThickness = new(1.5);
        imageShell.BorderBrush = Design.Brush(Design.Dark
            ? Color.FromArgb(205, 216, 232, 252) : Color.FromArgb(245, 255, 255, 255));
        imageShell.HorizontalAlignment = HorizontalAlignment.Center;
        imageShell.VerticalAlignment = VerticalAlignment.Center;
        imageShell.Translation = new(0, 0, 28);
        imageArea.Children.Add(imageShell);
        status.TextWrapping = TextWrapping.Wrap;
        var statusCard = Design.Card(status, 15, 9);
        statusCard.HorizontalAlignment = HorizontalAlignment.Center;
        statusCard.VerticalAlignment = VerticalAlignment.Bottom;
        statusCard.MaxWidth = 500;
        statusCard.Margin = new(12, 0, 12, 8);
        statusCard.Visibility = Visibility.Collapsed;
        failureBanner = statusCard;
        imageArea.Children.Add(statusCard);
        imageArea.SizeChanged += (_, _) => FitImage();
        Grid.SetRow(imageArea, 1);
        Children.Add(imageArea);
        AutomationProperties.SetName(this, "Timeline image preview and memory actions");
    }

    readonly Border failureBanner;

    internal object Diagnostics(FrameworkElement origin)
    {
        Rect Bounds(FrameworkElement element) => element.TransformToVisual(origin)
            .TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        return new
        {
            displayedId = displayed?.Id,
            requestedId = surface.RequestedFrame?.Id,
            hasImage = surface.HasImage,
            loading = surface.RequestedFrame != null,
            error = surface.LoadError,
            headerTime = recorded.Text,
            imageAspect = surface.ImageAspect,
            headerBounds = Bounds(header),
            frameBounds = Bounds(imageShell),
            imageBounds = Bounds(surface)
        };
    }

    void AttachWidthHost()
    {
        if (Parent is not FrameworkElement host || ReferenceEquals(widthHost, host)) return;
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

    static Button ActionButton(string glyph, string name, Action click)
    {
        var button = new Button
        {
            Content = Design.Symbol(glyph, 18), Width = 40, Height = 40,
            Padding = new(0), CornerRadius = new(20),
            Background = Design.Brush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new(0), UseSystemFocusVisuals = true
        };
        ToolTipService.SetToolTip(button, name);
        AutomationProperties.SetName(button, name);
        button.Click += (_, _) => click();
        return button;
    }

    public void ShowFrame(MemoryFrame frame)
    {
        // Status refreshes must not repeatedly retry a broken image and flash
        // its error banner. A new path or a different selection can load again.
        if (failedTarget?.Id == frame.Id && failedTarget.ImagePath == frame.ImagePath) return;
        failedTarget = null;
        failureBanner.Visibility = Visibility.Collapsed;
        surface.ShowFrame(frame);
    }

    void Present(MemoryFrame frame)
    {
        displayed = frame;
        failedTarget = null;
        recorded.Text = "Recorded · " + frame.Timestamp.ToLocalTime().ToString("HH:mm:ss");
        title.Text = string.IsNullOrWhiteSpace(frame.Title) ? AppDisplayName.For(frame.AppName) : frame.Title;
        badge.Child = AppIcons.View(AppIcons.Identity(frame), 20);
        star.Content = Design.Symbol(frame.Starred ? "\uE735" : "\uE734", 18);
        var starName = frame.Starred ? "Remove star from this memory" : "Star this memory";
        ToolTipService.SetToolTip(star, starName);
        AutomationProperties.SetName(star, starName);
        failureBanner.Visibility = Visibility.Collapsed;
        FitImage();
    }

    void Fail(MemoryFrame requested, Exception _)
    {
        failedTarget = requested;
        var target = requested.Timestamp.ToLocalTime().ToString("HH:mm:ss");
        status.Text = displayed is { } previous
            ? $"Could not load {target}. Showing {previous.Timestamp.ToLocalTime():HH:mm:ss}."
            : $"Could not load the image recorded at {target}.";
        failureBanner.Visibility = Visibility.Visible;
    }

    async void Star()
    {
        if (displayed is not { } frame) return;
        try
        {
            var fresh = await Task.Run(() =>
            {
                runtime.Store.Star(frame.Id);
                return runtime.Store.Frame(frame.Id);
            });
            if (fresh != null && displayed?.Id == frame.Id &&
                (surface.RequestedFrame == null || surface.RequestedFrame.Id == frame.Id))
                surface.ShowFrame(fresh);
        }
        catch (Exception)
        {
            status.Text = "Could not update this memory's star.";
            failureBanner.Visibility = Visibility.Visible;
        }
    }

    void FitImage()
    {
        var width = imageArea.ActualWidth - 4;
        var height = imageArea.ActualHeight - 4;
        if (width <= 16 || height <= 16) return;
        const double rim = 17; // 7px padding + 1.5px border on both sides.
        var aspect = surface.ImageAspect;
        var imageWidth = Math.Min(width - rim, (height - rim) * aspect);
        var imageHeight = imageWidth / aspect;
        imageShell.Width = imageWidth + rim;
        imageShell.Height = imageHeight + rim;
    }
}
