using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
namespace Recall;

internal static class Design
{
    public static bool Dark { get; private set; }
    public static Color Ink => System.Windows.Forms.SystemInformation.HighContrast ? GlassMaterial.ContrastForeground : Dark ? Color.FromArgb(255, 237, 238, 241) : Color.FromArgb(255, 43, 44, 47);
    public static Color Muted => System.Windows.Forms.SystemInformation.HighContrast ? GlassMaterial.ContrastForeground : Dark ? Color.FromArgb(255, 184, 187, 193) : Color.FromArgb(255, 112, 115, 120);
    public static readonly Color Blue = Color.FromArgb(255, 92, 151, 235);
    static readonly SolidColorBrush inkBrush = new(Ink), mutedBrush = new(Muted);
    public static readonly SolidColorBrush GlassBrush = new(Color.FromArgb(104, 255, 255, 255));
    public static readonly FontFamily BodyFont = new("Segoe UI Variable Text");
    public static readonly FontFamily DisplayFont = new("Segoe UI Variable Display");
    public static readonly FontFamily SmallFont = new("Segoe UI Variable Small");
    public static readonly LinearGradientBrush ArchiveBrush = new() { StartPoint = new(0,0), EndPoint = new(1,1), GradientStops = { new() { Offset = 0, Color = Color.FromArgb(45,250,249,244) }, new() { Offset = .35, Color = Color.FromArgb(16,223,228,228) }, new() { Offset = 1, Color = Color.FromArgb(46,132,151,169) } } };
    public static readonly LinearGradientBrush RimBrush = new() { StartPoint = new(0, 0), EndPoint = new(.8, 1), GradientStops = { new() { Offset = 0, Color = Color.FromArgb(210,255,255,255) }, new() { Offset = .48, Color = Color.FromArgb(30,70,80,100) }, new() { Offset = 1, Color = Color.FromArgb(100,255,255,255) } } };
    public static void SetDark(bool dark)
    {
        Dark = dark; inkBrush.Color = Ink; mutedBrush.Color = Muted;
        GlassBrush.Color = dark ? Color.FromArgb(100, 70, 74, 82) : Color.FromArgb(80, 255, 255, 255);
        ArchiveBrush.GradientStops[0].Color = dark ? Color.FromArgb(100,125,145,170) : Color.FromArgb(45,250,249,244);
        ArchiveBrush.GradientStops[1].Color = dark ? Color.FromArgb(60,40,50,65) : Color.FromArgb(16,223,228,228);
        ArchiveBrush.GradientStops[2].Color = dark ? Color.FromArgb(95,65,80,105) : Color.FromArgb(46,132,151,169);
        PopupBrush.TintColor = dark ? Color.FromArgb(255,32,36,44) : Microsoft.UI.Colors.White;
        PopupBrush.FallbackColor = GlassMaterial.FallbackColor;
        PopupBrush.AlwaysUseFallback = !GlassMaterial.TransparencyAvailable;
        GlassMaterial.SetDark(dark);
        RimBrush.GradientStops[0].Color = dark ? Color.FromArgb(68,230,240,255) : Color.FromArgb(190,255,255,255);
        RimBrush.GradientStops[1].Color = Color.FromArgb(dark ? (byte)34 : (byte)28,30,40,60);
        RimBrush.GradientStops[2].Color = Color.FromArgb(dark ? (byte)38 : (byte)115,230,240,255);
        if (System.Windows.Forms.SystemInformation.HighContrast) foreach (var stop in RimBrush.GradientStops) stop.Color = Ink;
    }
    public static readonly AcrylicBrush PopupBrush = new() { TintColor = Microsoft.UI.Colors.White, TintOpacity = .38, TintLuminosityOpacity = .65, FallbackColor = Color.FromArgb(255,235,237,240) };
    static Style PopupStyle(Type type)
    {
        var style = new Style(type);
        // The native flyout host supplies the blurred scene behind this
        // transparent presenter; the XAML liquid brush adds the optical edge.
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brush(Microsoft.UI.Colors.Transparent)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, RimBrush));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(18)));
        style.Setters.Add(new Setter(Control.FontFamilyProperty, BodyFont));
        style.Setters.Add(new Setter(Control.FontSizeProperty, 14d));
        style.Setters.Add(new Setter(Control.ForegroundProperty, inkBrush));
        return style;
    }
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<FrameworkElement, object> glassPopups = new();
    static int popupOpenings, popupScans, popupPresenters;
    static string[] lastPopupRoots = [];
    internal static object PopupDiagnostics => new { popupOpenings, popupScans, popupPresenters, lastPopupRoots };
    static void GlassPresenters(FlyoutBase flyout)
    {
        var xamlRoot = flyout.XamlRoot ?? (flyout.Target as FrameworkElement)?.XamlRoot;
        if (xamlRoot == null) { lastPopupRoots = ["No XamlRoot"]; return; }
        popupScans++;
        void Visit(DependencyObject element)
        {
            var styled = flyout switch
            {
                // WinUI creates submenu presenters separately and does not expose
                // their originating flyout. Menus dismiss one another, so while
                // this Design.Menu is open these are its native submenu surfaces.
                MenuFlyout => element is MenuFlyoutPresenter,
                Microsoft.UI.Xaml.Controls.Flyout => element is FlyoutPresenter,
                _ => false
            };
            if (styled && element is FrameworkElement presenter && !glassPopups.TryGetValue(presenter, out _))
            {
                popupPresenters++;
                glassPopups.Add(presenter, new object());
                // The native popup host supplies a live HostBackdrop below
                // this XAML surface. The normal liquid brush adds its optical
                // edge to that material inside the popup's compositor.
                GlassMaterial.Attach(presenter, 18, desktopSurface: false, glassOpacity: .32);
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(element); i++) Visit(VisualTreeHelper.GetChild(element, i));
        }
        var popups = VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot);
        lastPopupRoots = popups.Select(popup => popup.Child?.GetType().Name ?? "No Child").ToArray();
        foreach (var popup in popups)
            if (popup.Child != null) Visit(popup.Child);
    }
    static void GlassFlyout(FlyoutBase flyout, bool submenus = false)
    {
        Microsoft.UI.Dispatching.DispatcherQueueTimer? scan = null;
        flyout.Opened += (_, _) =>
        {
            popupOpenings++;
            GlassPresenters(flyout);
            flyout.DispatcherQueue.TryEnqueue(() => GlassPresenters(flyout));
            if (!submenus) return;
            // Native submenu presenters appear after the parent flyout opens.
            if (scan == null)
            {
                scan = flyout.DispatcherQueue.CreateTimer();
                scan.Interval = TimeSpan.FromMilliseconds(33);
                scan.Tick += (_, _) => GlassPresenters(flyout);
            }
            scan.Start();
        };
        flyout.Closed += (_, _) => scan?.Stop();
    }
    public static MenuFlyout Menu()
    {
        var menu = new MenuFlyout { MenuFlyoutPresenterStyle = PopupStyle(typeof(MenuFlyoutPresenter)), SystemBackdrop = new PopupGlassBackdrop() };
        GlassFlyout(menu, submenus: true);
        return menu;
    }
    public static Flyout Flyout(UIElement? content = null)
    {
        var flyout = new Flyout
        {
            Content = content,
            FlyoutPresenterStyle = PopupStyle(typeof(FlyoutPresenter)),
            SystemBackdrop = new PopupGlassBackdrop(),
            ShouldConstrainToRootBounds = false
        };
        GlassFlyout(flyout);
        return flyout;
    }
    public static readonly Color[] Pastels = [Color.FromArgb(255, 116, 174, 228), Color.FromArgb(255, 144, 205, 195), Color.FromArgb(255, 172, 165, 225), Color.FromArgb(255, 234, 185, 153), Color.FromArgb(255, 201, 188, 222), Color.FromArgb(255, 190, 200, 211)];
    public static SolidColorBrush Brush(Color color) => color == Ink ? inkBrush : color == Muted ? mutedBrush : new(color);
    static ControlTemplate? buttonTemplate, inputTemplate, resultTemplate;
    public static ControlTemplate ResultTemplate => resultTemplate ??= (ControlTemplate)XamlReader.Load("""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="GridViewItem"><ContentPresenter Content="{TemplateBinding Content}"/></ControlTemplate>
        """);
    public static ControlTemplate GlassButtonTemplate => buttonTemplate ??= (ControlTemplate)XamlReader.Load("""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
          <Grid x:Name="Root" Background="Transparent">
            <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name="CommonStates">
              <VisualState x:Name="Normal"/>
              <VisualState x:Name="PointerOver"><Storyboard><DoubleAnimation Storyboard.TargetName="Sheen" Storyboard.TargetProperty="Opacity" To="0.75" Duration="0:0:0.12"/></Storyboard></VisualState>
              <VisualState x:Name="Pressed"><Storyboard><DoubleAnimation Storyboard.TargetName="Sheen" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.08"/></Storyboard></VisualState>
              <VisualState x:Name="Disabled"><Storyboard><DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="Opacity" To="0.4" Duration="0"/></Storyboard></VisualState>
            </VisualStateGroup></VisualStateManager.VisualStateGroups>
            <Border x:Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{TemplateBinding CornerRadius}"/>
            <Border x:Name="Sheen" Opacity="0" IsHitTestVisible="False" CornerRadius="{TemplateBinding CornerRadius}" BorderThickness="1.5" BorderBrush="#DDFFFFFF">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#28FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.55"/><GradientStop Color="#15FFFFFF" Offset="1"/></LinearGradientBrush></Border.Background>
            </Border>
            <ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" Padding="{TemplateBinding Padding}" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
          </Grid>
        </ControlTemplate>
        """);
    static ControlTemplate SearchInputTemplate => inputTemplate ??= (ControlTemplate)XamlReader.Load("""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="TextBox">
          <Grid Background="Transparent">
            <Border x:Name="GlassSurface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{TemplateBinding CornerRadius}"/>
            <ScrollViewer x:Name="ContentElement" Background="Transparent" Foreground="{TemplateBinding Foreground}" Padding="{TemplateBinding Padding}" Margin="{TemplateBinding BorderThickness}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden" IsTabStop="False" ZoomMode="Disabled" AutomationProperties.AccessibilityView="Raw"/>
            <TextBlock x:Name="PlaceholderTextContentPresenter" Text="{TemplateBinding PlaceholderText}" Foreground="{TemplateBinding PlaceholderForeground}" Padding="{TemplateBinding Padding}" Margin="{TemplateBinding BorderThickness}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" IsHitTestVisible="False"/>
          </Grid>
        </ControlTemplate>
        """);
    public static TextBlock Text(string text, double size = 15, bool strong = false, Color? color = null) => new() { Text = text, FontFamily = size >= 23 ? DisplayFont : size <= 12 ? SmallFont : BodyFont, FontSize = size, FontWeight = strong ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal, Foreground = Brush(color ?? Ink), TextWrapping = TextWrapping.Wrap, TextLineBounds = TextLineBounds.Full, VerticalAlignment = VerticalAlignment.Center };
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
    public static Border Card(UIElement child, double radius = 24, double padding = 22)
    {
        var card = new Border { Child = child, CornerRadius = new(radius), Padding = new(padding), BorderThickness = new(1), BorderBrush = RimBrush };
        card.Shadow = new ThemeShadow(); card.Translation = new(0, 0, 12);
        GlassMaterial.Attach(card, radius); return card;
    }
    public static Button Button(string title, Action click, bool primary = false)
    {
        var b = new Button { FontFamily = BodyFont, UseSystemFocusVisuals = true, Template = GlassButtonTemplate, Content = Text(title, 14, false, Ink), MinHeight = 44, Padding = new(20, 10, 20, 10), CornerRadius = new(22), BorderThickness = new(1), BorderBrush = RimBrush, Background = primary ? Brush(Blue) : GlassBrush };
        GlassMaterial.Attach(b, 22, primary ? Blue : null);
        b.Shadow = new ThemeShadow(); b.Translation = new(0, 0, 8);
        LiquidMotion.Interactive(b);
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
                        Box(x, y, 7, 7, 1);
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
    public static TextBox Input(string placeholder, string value = "", double height = 44, bool externalGlass = false)
    {
        var field = new TextBox { FontFamily = BodyFont, UseSystemFocusVisuals = false, Template = SearchInputTemplate, PlaceholderText = placeholder, PlaceholderForeground = mutedBrush, Text = value, MinHeight = height, VerticalContentAlignment = VerticalAlignment.Center, CornerRadius = new(height / 2), Padding = new(18, 10, 18, 10), BorderThickness = new(1), BorderBrush = RimBrush, Background = GlassBrush, Foreground = inkBrush, FontSize = 15, SelectionHighlightColor = Brush(Color.FromArgb(90, 130, 180, 239)) };
        // The native text presenter must never paint a rectangular focus fill
        // over the independently rounded glass surface (including IME updates).
        foreach (var key in new[] { "TextControlBackground", "TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBackgroundDisabled" }) field.Resources[key] = Brush(Microsoft.UI.Colors.Transparent);
        field.Shadow = new ThemeShadow(); field.Translation = new(0, 0, 16);
        // The editable text host also consumes TextBox.Background internally.
        // Keep it transparent and paint glass only in the template's outer border.
        field.Background = Brush(Microsoft.UI.Colors.Transparent);
        bool attached = false;
        field.Loaded += (_, _) =>
        {
            if (attached || externalGlass) return;
            field.ApplyTemplate();
            if (VisualTreeHelper.GetChildrenCount(field) > 0 && VisualTreeHelper.GetChild(field, 0) is FrameworkElement root && root.FindName("GlassSurface") is Border surface)
            { attached = true; GlassMaterial.Attach(surface, height / 2, desktopOnly: true); }
        };
        return field;
    }
    public static Image Asset(string name, double width = 64) => new() { Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", name))), Width = width, Height = width, Stretch = Stretch.Uniform };
    internal static bool? ValidationMotion;
    static readonly Windows.UI.ViewManagement.UISettings motionSettings = new();
    public static bool Motion => ValidationMotion ?? motionSettings.AnimationsEnabled;
    public static void Spring(UIElement element, float fromY = 18, float fromScale = .94f, int delay = 0, double response = .42, double damping = .9)
    {
        // Animate XAML transforms so visual, input and automation geometry agree.
        // Direct compositor translation of a positioned panel can double its
        // offset in hit testing even after its entrance spring has settled.
        if (element is FrameworkElement owner) LiquidMotion.Appear(owner, fromY, fromScale, delay, response, damping);
        else element.Opacity = 1;
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
        CompositionRoundedRectangleGeometry? geometry = null; CompositionGeometricClip? clip = null;
        void Update()
        {
            var v = ElementCompositionPreview.GetElementVisual(element);
            geometry ??= v.Compositor.CreateRoundedRectangleGeometry();
            clip ??= v.Compositor.CreateGeometricClip(geometry);
            geometry.Size = new((float)element.ActualWidth, (float)element.ActualHeight);
            geometry.CornerRadius = new(radius); v.Clip = clip;
        }
        element.SizeChanged += (_, _) => Update(); element.Loaded += (_, _) => Update();
        element.Unloaded += (_, _) => { ElementCompositionPreview.GetElementVisual(element).Clip = null; clip?.Dispose(); geometry?.Dispose(); clip = null; geometry = null; };
    }
    public static string Size(long bytes) => bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.00} GB" : $"{bytes / 1e6:0.#} MB";
    public static string Time(double seconds) => seconds >= 3600 ? $"{(int)(seconds / 3600)} hr {(int)(seconds % 3600 / 60)} min" : $"{Math.Max(0, (int)(seconds / 60))} min";
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
