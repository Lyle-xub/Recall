using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Imaging;
namespace Recall;

internal static class Design
{
    public static readonly Color Ink = Color.FromArgb(255, 61, 67, 73), Muted = Color.FromArgb(255, 126, 134, 145), Blue = Color.FromArgb(255, 92, 151, 235);
    public static readonly Color[] Pastels = [Color.FromArgb(255, 116, 174, 228), Color.FromArgb(255, 144, 205, 195), Color.FromArgb(255, 172, 165, 225), Color.FromArgb(255, 234, 185, 153), Color.FromArgb(255, 201, 188, 222), Color.FromArgb(255, 190, 200, 211)];
    public static SolidColorBrush Brush(Color color) => new(color);
    public static TextBlock Text(string text, double size = 15, bool strong = false, Color? color = null) => new() { Text = text, FontSize = size, FontWeight = strong ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal, Foreground = Brush(color ?? Ink), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    public static StackPanel Stack(double spacing = 12, params UIElement[] children)
    {
        var p = new StackPanel { Spacing = spacing };
        foreach (var c in children)
            p.Children.Add(c);
        return p;
    }
    public static StackPanel Row(double spacing = 12, params UIElement[] children)
    {
        var p = Stack(spacing, children);
        p.Orientation = Orientation.Horizontal;
        return p;
    }
    public static Border Card(UIElement child, double radius = 24, double padding = 22) => new() { Child = child, CornerRadius = new(radius), Padding = new(padding), Background = Brush(Color.FromArgb(238, 255, 255, 255)), BorderBrush = Brush(Color.FromArgb(160, 255, 255, 255)), BorderThickness = new(1) };
    public static Button Button(string title, Action click, bool primary = false)
    {
        var b = new Button { Content = Text(title, 14, true, primary ? Microsoft.UI.Colors.White : Ink), MinHeight = 44, Padding = new(20, 10, 20, 10), CornerRadius = new(22), BorderThickness = new(1), BorderBrush = Brush(Color.FromArgb(26, 80, 90, 110)), Background = Brush(primary ? Blue : Color.FromArgb(230, 247, 248, 250)) };
        b.Click += (_, _) => click();
        return b;
    }
    public static Button Icon(string glyph, string tooltip, Action click, double size = 48)
    {
        var b = Button("", click);
        b.Content = Symbol(glyph);
        b.Width = size;
        b.Height = size;
        b.Padding = new(0);
        b.CornerRadius = new(size / 2);
        ToolTipService.SetToolTip(b, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tooltip);
        return b;
    }
    public static FrameworkElement Symbol(string glyph, double size = 21, Color? color = null)
    {
        // Keep the primary toolbar independent of font glyph substitutions on Windows.
        var ink = Brush(color ?? Ink);
        var canvas = new Canvas { Width = 24, Height = 24 };
        void Line(double x1, double y1, double x2, double y2) => canvas.Children.Add(new Line { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, Stroke = ink, StrokeThickness = 1.7, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
        void Box(double x, double y, double w, double h, double radius = 2)
        {
            var box = new Rectangle { Width = w, Height = h, RadiusX = radius, RadiusY = radius, Stroke = ink, StrokeThickness = 1.7 };
            Canvas.SetLeft(box, x);
            Canvas.SetTop(box, y);
            canvas.Children.Add(box);
        }
        switch (glyph)
        {
            case "\uE71D":
                foreach (var x in new[] { 3.0, 14.0 })
                    foreach (var y in new[] { 3.0, 14.0 })
                        Box(x, y, 7, 7);
                break;
            case "\uE945":
                var star = new PathFigure { StartPoint = new(12, 1.5), IsClosed = true };
                star.Segments.Add(new BezierSegment { Point1 = new(13.5, 9), Point2 = new(15, 10.5), Point3 = new(22.5, 12) });
                star.Segments.Add(new BezierSegment { Point1 = new(15, 13.5), Point2 = new(13.5, 15), Point3 = new(12, 22.5) });
                star.Segments.Add(new BezierSegment { Point1 = new(10.5, 15), Point2 = new(9, 13.5), Point3 = new(1.5, 12) });
                star.Segments.Add(new BezierSegment { Point1 = new(9, 10.5), Point2 = new(10.5, 9), Point3 = new(12, 1.5) });
                var geometry = new PathGeometry();
                geometry.Figures.Add(star);
                canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = ink, StrokeThickness = 1.7, StrokeLineJoin = PenLineJoin.Round });
                break;
            case "\uE9D9":
                Box(3, 13, 4, 8, 1.5);
                Box(10, 8, 4, 13, 1.5);
                Box(17, 3, 4, 18, 1.5);
                break;
            case "\uE713":
                foreach (var pair in new[] { (Y: 5.0, X: 8.0), (Y: 12.0, X: 16.0), (Y: 19.0, X: 10.0) })
                {
                    Line(3, pair.Y, pair.X - 2.5, pair.Y);
                    Line(pair.X + 2.5, pair.Y, 21, pair.Y);
                    Box(pair.X - 2.5, pair.Y - 2.5, 5, 5, 2.5);
                }
                break;
            default:
                return new FontIcon { Glyph = glyph, FontFamily = new("Segoe Fluent Icons"), FontSize = size, Foreground = ink };
        }
        return new Viewbox { Width = size, Height = size, Child = canvas };
    }
    public static ScrollViewer Scroll(UIElement content) => new() { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch, IsVerticalRailEnabled = true };
    public static TextBox Input(string placeholder, string value = "", double height = 44) => new() { PlaceholderText = placeholder, Text = value, MinHeight = height, CornerRadius = new(height / 2), Padding = new(18, 10, 18, 10), BorderThickness = new(1), BorderBrush = Brush(Color.FromArgb(32, 80, 90, 110)), Background = Brush(Color.FromArgb(180, 255, 255, 255)), Foreground = Brush(Ink), FontSize = 15, SelectionHighlightColor = Brush(Color.FromArgb(90, 130, 180, 239)) };
    public static Image Asset(string name, double width = 64) => new() { Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", name))), Width = width, Height = width, Stretch = Stretch.Uniform };
    public static bool Motion => new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
    public static void Spring(UIElement element, float fromY = 18, float fromScale = .94f, int delay = 0)
    {
        element.Opacity = 1;
        if (!Motion)
            return;
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        var v = ElementCompositionPreview.GetElementVisual(element);
        v.CenterPoint = new((float)((element as FrameworkElement)?.ActualWidth ?? 0) / 2, (float)((element as FrameworkElement)?.ActualHeight ?? 0) / 2, 0);
        var c = v.Compositor;
        var move = c.CreateVector3KeyFrameAnimation();
        move.InsertKeyFrame(0, new(0, fromY, 0));
        move.InsertKeyFrame(.68f, new(0, -fromY * .13f, 0));
        move.InsertKeyFrame(1, Vector3.Zero);
        move.Duration = TimeSpan.FromMilliseconds(520);
        move.DelayTime = TimeSpan.FromMilliseconds(delay);
        v.StartAnimation("Translation", move);
        var scale = c.CreateVector3KeyFrameAnimation();
        scale.InsertKeyFrame(0, new(fromScale, fromScale, 1));
        scale.InsertKeyFrame(.64f, new(1.035f, 1.035f, 1));
        scale.InsertKeyFrame(1, Vector3.One);
        scale.Duration = TimeSpan.FromMilliseconds(560);
        scale.DelayTime = TimeSpan.FromMilliseconds(delay);
        v.StartAnimation("Scale", scale);
        var fade = c.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0, 0);
        fade.InsertKeyFrame(1, 1);
        fade.Duration = TimeSpan.FromMilliseconds(230);
        fade.DelayTime = TimeSpan.FromMilliseconds(delay);
        v.StartAnimation("Opacity", fade);
    }
    public static Task Fade(UIElement e, float to, int ms, float? from = null)
    {
        if (!Motion)
        {
            e.Opacity = to;
            return Task.CompletedTask;
        }
        var t = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var v = ElementCompositionPreview.GetElementVisual(e);
        if (from.HasValue)
            v.Opacity = from.Value;
        var c = v.Compositor;
        var batch = c.CreateScopedBatch(CompositionBatchTypes.Animation);
        var a = c.CreateScalarKeyFrameAnimation();
        a.InsertKeyFrame(1, to);
        a.Duration = TimeSpan.FromMilliseconds(ms);
        v.StartAnimation("Opacity", a);
        batch.Completed += (_, _) => { t.TrySetResult(); batch.Dispose(); };
        batch.End();
        return t.Task;
    }
    public static void Rounded(FrameworkElement element, float radius)
    {
        element.SizeChanged += (_, _) => { var v = ElementCompositionPreview.GetElementVisual(element); var g = v.Compositor.CreateRoundedRectangleGeometry(); g.Size = new((float)element.ActualWidth, (float)element.ActualHeight); g.CornerRadius = new(radius); v.Clip = v.Compositor.CreateGeometricClip(g); };
    }
    public static string Size(long bytes) => bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.00} GB" : $"{bytes / 1e6:0.#} MB";
    public static string Time(double seconds) => seconds >= 3600 ? $"{(int)(seconds / 3600)} hr {(int)(seconds % 3600 / 60)} min" : $"{Math.Max(0, (int)(seconds / 60))} min";
}
internal sealed class ClearBackdrop : SystemBackdrop
{
    readonly Windows.UI.Composition.Compositor compositor = new();
    ICompositionSupportsSystemBackdrop? target;
    Windows.UI.Composition.CompositionBrush? brush;
    string? lastKey; bool full; double width = 1920, height = 1080; Rect search; List<Rect> buttons = [];
    public void Update(bool full, double width, double height, Rect search, List<Rect> buttons)
    {
        var key = $"{full}/{width:0.0}/{height:0.0}/{search}/" + string.Join("/", buttons);
        if (key == lastKey)
            return;
        lastKey = key;
        this.full = full;
        this.width = width;
        this.height = height;
        this.search = search;
        this.buttons = buttons;
        Draw();
    }
    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot root)
    {
        base.OnTargetConnected(target, root);
        this.target = target;
        Draw();
    }
    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        target.SystemBackdrop = null;
        this.target = null;
        brush?.Dispose();
        base.OnTargetDisconnected(target);
    }
    void Draw()
    {
        if (target == null || width <= 0 || height <= 0)
            return;
        var maskRoot = compositor.CreateContainerVisual();
        maskRoot.Size = new((float)width, (float)height);
        var bottom = compositor.CreateSpriteVisual();
        bottom.Size = maskRoot.Size;
        var gradient = compositor.CreateLinearGradientBrush();
        gradient.StartPoint = new(0, 0);
        gradient.EndPoint = new(0, 1);
        gradient.ColorStops.Add(compositor.CreateColorGradientStop(0, full ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Transparent));
        for (int i = 0; i <= 12; i++)
        {
            float t = i / 12f;
            float a = full ? 1 : t * t * t * (t * (t * 6 - 15) + 10);
            gradient.ColorStops.Add(compositor.CreateColorGradientStop((float)Math.Max(0, 1 - 234 / height + 234 / height * t), Color.FromArgb((byte)(a * 255), 255, 255, 255)));
        }
        bottom.Brush = gradient;
        maskRoot.Children.InsertAtBottom(bottom);
        if (!full)
            foreach (var rect in buttons.Prepend(search).Where(r => r.Width > 0))
            {
                var geometry = compositor.CreateRoundedRectangleGeometry();
                geometry.Size = new((float)rect.Width, (float)rect.Height);
                geometry.CornerRadius = new((float)rect.Height / 2);
                var shape = compositor.CreateSpriteShape(geometry);
                shape.FillBrush = compositor.CreateColorBrush(Microsoft.UI.Colors.White);
                var visual = compositor.CreateShapeVisual();
                visual.Shapes.Add(shape);
                visual.Size = geometry.Size;
                visual.Offset = new((float)rect.X, (float)rect.Y, 0);
                maskRoot.Children.InsertAtTop(visual);
            }
        var surface = compositor.CreateVisualSurface();
        surface.SourceVisual = maskRoot;
        surface.SourceSize = maskRoot.Size;
        var mask = compositor.CreateMaskBrush();
        mask.Source = compositor.CreateHostBackdropBrush();
        mask.Mask = compositor.CreateSurfaceBrush(surface);
        var old = brush;
        brush = mask;
        target.SystemBackdrop = mask;
        old?.Dispose();
    }
}
internal sealed class DesktopBlur : Grid
{
    public DesktopBlur(bool gradient = false)
    {
        IsHitTestVisible = false;
        if (!gradient)
            Background = new AcrylicBrush { TintColor = Microsoft.UI.Colors.White, TintOpacity = .18, FallbackColor = Color.FromArgb(190, 250, 250, 252) };
    }
}
