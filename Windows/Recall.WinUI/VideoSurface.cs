using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.Media.Playback;

namespace Recall;

// Keep video in the XAML image tree: native overlay video planes bypass rounded
// clipping on some adapters and can outlive the closing overlay window.
internal sealed class VideoSurface : Grid, IDisposable
{
    readonly Image display = new() { Stretch = Stretch.Uniform };
    readonly MediaPlayer player;
    readonly Action<Exception> failed;
    readonly (byte[] Pixels, int Width, int Height)? still;
    readonly Action<VideoOrientation.MatchResult> matched;
    CanvasRenderTarget? frame;
    CanvasRenderTarget? orientationPreview;
    CanvasImageSource? image;
    int queued;
    int rotationSteps;
    int manualSteps;
    double alignedAspect;
    int matchAttempts;
    TimeSpan matchPosition;
    bool matchArmed;
    long matchArmedAt;
    VideoOrientation.MatchResult? bestMatch;
    bool disposed;
    bool fallbackConfirmed;
    bool orientationResolved;
    long fallbackConfirmedAt;
    internal bool IsReady { get; private set; }
    internal double DisplayAspect => IsReady && image is { } shown && shown.Size.Height > 0
        ? shown.Size.Width / shown.Size.Height : 0;
    internal event Action? Ready;
    internal string? MatchError { get; private set; }
    internal object Diagnostics
    {
        get
        {
            object? bounds = null;
            if (!disposed && IsReady && image is { } shown && XamlRoot?.Content is UIElement root &&
                ActualWidth > 0 && ActualHeight > 0 && shown.Size.Width > 0 && shown.Size.Height > 0)
            {
                try
                {
                    var origin = TransformToVisual(root).TransformPoint(new(0, 0));
                    var scale = Math.Min(ActualWidth / shown.Size.Width, ActualHeight / shown.Size.Height);
                    var width = shown.Size.Width * scale;
                    var height = shown.Size.Height * scale;
                    bounds = new { x = origin.X + (ActualWidth - width) / 2,
                        y = origin.Y + (ActualHeight - height) / 2, width, height };
                }
                catch (InvalidOperationException) { }
            }
            return new { imageWidth = image?.Size.Width, imageHeight = image?.Size.Height,
                frameWidth = frame?.Size.Width, frameHeight = frame?.Size.Height,
                targetAspect = alignedAspect > 0 ? (manualSteps % 2 == 0 ? alignedAspect : 1 / alignedAspect) :
                    image is { } visible && visible.Size.Height > 0 ? visible.Size.Width / visible.Size.Height : 0,
                attempts = matchAttempts, armed = matchArmed, settled = orientationResolved,
                ready = IsReady, displayAspect = DisplayAspect, fallbackConfirmed,
                bounds };
        }
    }
    public void SetOrientation(int totalSteps, double alignedAspect = 0, int manualSteps = 0)
    {
        rotationSteps = ((totalSteps % 4) + 4) % 4;
        this.alignedAspect = alignedAspect;
        this.manualSteps = manualSteps;
        Render();
    }
    public void ArmOrientationMatch(TimeSpan position)
    {
        if (still == null || disposed || matchAttempts >= 5) return;
        matchPosition = position;
        matchArmed = true;
        matchArmedAt = System.Diagnostics.Stopwatch.GetTimestamp();
    }
    // MediaOpened has supplied the decoder's orientation before any frame may
    // replace the still poster. A reference still additionally requires the
    // pixel match (or its bounded fallback) to settle.
    public void ConfirmFallbackOrientation()
    {
        if (disposed) return;
        if (!fallbackConfirmed)
        {
            fallbackConfirmed = true;
            fallbackConfirmedAt = System.Diagnostics.Stopwatch.GetTimestamp();
        }
        if (still == null || matchAttempts >= 5) orientationResolved = true;
        Render();
    }
    public void CancelOrientationMatch()
    {
        matchArmed = false;
        matchAttempts = 5;
        orientationResolved = fallbackConfirmed;
        // The caller applies the user's new angle with SetOrientation next.
        // Rendering here could release one frame at the old angle first.
    }
    public VideoSurface(MediaPlayer player, Action<Exception> failed,
        (byte[] Pixels, int Width, int Height)? still, Action<VideoOrientation.MatchResult> matched)
    {
        this.player = player; this.failed = failed; this.still = still; this.matched = matched;
        Children.Add(display);
        player.IsVideoFrameServerEnabled = true;
        player.VideoFrameAvailable += FrameAvailable;
    }
    void FrameAvailable(MediaPlayer sender, object args)
    {
        if (Interlocked.Exchange(ref queued, 1) != 0) return;
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref queued, 0);
            if (disposed) return;
            try
            {
                var width = (int)player.PlaybackSession.NaturalVideoWidth;
                var height = (int)player.PlaybackSession.NaturalVideoHeight;
                if (width <= 0 || height <= 0) return;
                if (frame == null || frame.SizeInPixels.Width != width || frame.SizeInPixels.Height != height)
                {
                    display.Source = null; frame?.Dispose(); image = null;
                    var device = CanvasDevice.GetSharedDevice();
                    frame = new CanvasRenderTarget(device, width, height, 96);
                }
                player.CopyFrameToVideoSurface(frame);
                TryMatchOrientation(width, height);
                CheckUnarmedFallback();
                Render();
            }
            catch (Exception error) { if (!disposed) failed(error); }
        })) Interlocked.Exchange(ref queued, 0);
    }
    void TryMatchOrientation(int width, int height)
    {
        if (!fallbackConfirmed || !matchArmed || still is not { } reference || frame == null || matchAttempts >= 5) return;
        var distance = (player.PlaybackSession.Position - matchPosition).TotalSeconds;
        if (distance < -1.5)
        {
            if (System.Diagnostics.Stopwatch.GetElapsedTime(matchArmedAt) >= TimeSpan.FromSeconds(5))
                SettleMatch(bestMatch);
            return;
        }
        if (distance > 2.5)
        {
            SettleMatch(bestMatch);
            return;
        }
        try
        {
            // Downsample on the GPU before readback: even a 4K recording only
            // copies at most 160 pixels along its longest edge to the CPU.
            var scale = Math.Min(1, 160d / Math.Max(width, height));
            var previewWidth = Math.Max(1, (int)Math.Round(width * scale));
            var previewHeight = Math.Max(1, (int)Math.Round(height * scale));
            if (orientationPreview == null || orientationPreview.SizeInPixels.Width != previewWidth ||
                orientationPreview.SizeInPixels.Height != previewHeight)
            {
                orientationPreview?.Dispose();
                orientationPreview = new CanvasRenderTarget(frame.Device, previewWidth, previewHeight, 96);
            }
            using (var drawing = orientationPreview.CreateDrawingSession())
            {
                drawing.Transform = System.Numerics.Matrix3x2.CreateScale((float)previewWidth / width, (float)previewHeight / height);
                drawing.DrawImage(frame);
            }
            var colors = orientationPreview.GetPixelColors();
            var gray = new byte[colors.Length];
            for (var index = 0; index < colors.Length; index++)
            {
                var color = colors[index];
                gray[index] = (byte)((77 * color.R + 150 * color.G + 29 * color.B) >> 8);
            }
            var result = VideoOrientation.Match(reference.Pixels, reference.Width, reference.Height,
                gray, previewWidth, previewHeight, rotationSteps);
            matchAttempts++;
            if (bestMatch is null || result.Score > bestMatch.Value.Score) bestMatch = result;
            if (result.Confident || matchAttempts == 5)
                SettleMatch(result.Confident ? result : bestMatch);
        }
        catch (Exception error)
        {
            MatchError = error.Message;
            SettleMatch(null);
        }
    }
    void SettleMatch(VideoOrientation.MatchResult? result)
    {
        matchArmed = false;
        matchAttempts = 5;
        try { if (result is { } decision) matched(decision); }
        catch (Exception error) { MatchError = error.Message; }
        // The callback can update the angle and fit, but its reentrant Render
        // must not publish a frame. The enclosing FrameAvailable renders once
        // more after this flag is set and only then releases the poster.
        orientationResolved = true;
    }
    void CheckUnarmedFallback()
    {
        if (!fallbackConfirmed || orientationResolved || matchArmed || matchAttempts >= 5 || still == null) return;
        // SeekCompleted normally arms the match. If the media source never
        // reports it, retain the poster briefly, then use the metadata
        // orientation instead of leaving playback hidden forever.
        if (System.Diagnostics.Stopwatch.GetElapsedTime(fallbackConfirmedAt) < TimeSpan.FromSeconds(5)) return;
        matchAttempts = 5;
        orientationResolved = true;
    }
    void Render()
    {
        if (disposed || frame == null) return;
        var w = (float)frame.Size.Width; var h = (float)frame.Size.Height;
        var (width, height) = VideoOrientation.OutputSize(w, h, rotationSteps, alignedAspect, manualSteps);
        if (image == null || Math.Abs(image.Size.Width - width) > .5 || Math.Abs(image.Size.Height - height) > .5)
        {
            image = new CanvasImageSource(frame.Device, (float)width, (float)height, 96);
        }
        using (var drawing = image.CreateDrawingSession(Microsoft.UI.Colors.Black))
        {
            System.Numerics.Matrix3x2 rotation = rotationSteps switch
            {
                1 => new(0, 1, -1, 0, h, 0),
                2 => new(-1, 0, 0, -1, w, h),
                3 => new(0, -1, 1, 0, 0, w),
                _ => System.Numerics.Matrix3x2.Identity
            };
            var rotatedWidth = rotationSteps % 2 == 0 ? w : h;
            var rotatedHeight = rotationSteps % 2 == 0 ? h : w;
            drawing.Transform = rotation * System.Numerics.Matrix3x2.CreateScale((float)(width / rotatedWidth), (float)(height / rotatedHeight));
            drawing.DrawImage(frame);
        }
        if (!orientationResolved || !fallbackConfirmed) return;
        display.Source = image;
        if (IsReady) return;
        IsReady = true;
        Ready?.Invoke();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; player.VideoFrameAvailable -= FrameAvailable; IsReady = false; Ready = null;
        display.Source = null; frame?.Dispose(); frame = null; orientationPreview?.Dispose(); orientationPreview = null; image = null;
    }
}
