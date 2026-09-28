using System.Security.Cryptography;
namespace Recall;

/// Material parameters are local to each surface; RecallGlassBrush pools GPU factories.
internal static class GlassMaterial
{
    static readonly List<WeakReference<Surface>> surfaces = [];
    static readonly Windows.UI.ViewManagement.UISettings settings = new();
    static readonly Lazy<bool> compatibleRuntime = new(CheckRuntime);
    static string? compatibilityError;
    static string? connectionError;
    internal static void ReportError(string error) { connectionError = error; RefreshPolicy(); }
    static Microsoft.UI.Dispatching.DispatcherQueue? dispatcher;
    internal static bool ValidationFallback;
    internal static event Action? PolicyChanged;
    internal static bool TransparencyAvailable => !ValidationFallback &&
        !System.Windows.Forms.SystemInformation.HighContrast && settings.AdvancedEffectsEnabled;
    internal static Color FallbackColor => System.Windows.Forms.SystemInformation.HighContrast
        ? settings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Background)
        : Design.Dark ? Color.FromArgb(255, 45, 48, 54) : Color.FromArgb(255, 235, 237, 240);
    internal static Color ContrastForeground => settings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Foreground);
    static GlassMaterial()
    {
        try { settings.AdvancedEffectsEnabledChanged += (_, _) => RefreshPolicy(); }
        catch (System.Runtime.InteropServices.COMException) { /* Some unpackaged desktops lack this notification. */ }
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) => RefreshPolicy();
    }
    static bool CheckRuntime()
    {
        // The MIT shader bridge uses a private x64 Composition ABI. Do not
        // install its hook into an unverified (including newer) runtime.
        try
        {
            using var file = File.OpenRead(Path.Combine(AppContext.BaseDirectory, "wuceffectsi.dll"));
            if (System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.X64 && Convert.ToHexString(SHA256.HashData(file)) ==
                "DBEA457AC1C6D5C4CDE5B9CFB09E65CD54B11596406CE50565DDD946468B1454") return true;
            compatibilityError = "The bundled Composition runtime does not match the tested glass ABI.";
        }
        catch (IOException) { compatibilityError = "The tested Composition runtime is unavailable."; }
        catch (UnauthorizedAccessException) { compatibilityError = "The Composition runtime could not be verified."; }
        return false;
    }
    internal static bool EffectsAvailable => TransparencyAvailable && compatibleRuntime.Value && string.IsNullOrEmpty(Error);
    static void RefreshPolicy()
    {
        // System settings notifications arrive off the XAML thread.
        dispatcher?.TryEnqueue(() => Design.SetDark(Design.Dark));
    }
    internal static Dictionary<string, double> ValidationParameters = [];
    internal static void Configure(System.Text.Json.JsonElement values)
    {
        ValidationParameters.Clear();
        foreach (var value in values.EnumerateObject())
            if (value.Value.TryGetDouble(out var number) && double.IsFinite(number)) ValidationParameters[value.Name] = number;
        SetDark(Design.Dark);
    }
    static void Override(RecallGlassBrush brush)
    {
        // Only this fixed effect's numeric properties can be adjusted by the opt-in harness.
        foreach (var (name, value) in ValidationParameters)
        {
            var property = typeof(RecallGlassBrush).GetProperty(name);
            if (property?.PropertyType == typeof(double) && property.CanWrite) property.SetValue(brush, value);
        }
    }
    static RecallGlassBrush Create()
    {
        var brush = new RecallGlassBrush
        {
            BlurAmount = 10, RefThickness = 1, RefFactor = 1.002,
            RefDispersion = .05, DispersionRange = .3, RefFresnelRange = 20,
            RefFresnelHardness = 30, RefFresnelFactor = 1,
            GlareAngle = -65, GlareRange = 18, GlareHardness = 25,
            GlareFactor = .2, GlareOppositeFactor = .2, GlareConvergence = 35,
            ShapeRadius = 1, ShapeRoundness = 2, Magnification = 1,
        };
        Apply(brush, Design.Dark); Override(brush); return brush;
    }
    public static void Attach(FrameworkElement owner, double radius, Color? accent = null, bool desktopOnly = false, bool desktopSurface = true, double glassOpacity = 1)
    {
        var surface = new Surface(owner, radius, accent, desktopOnly, desktopSurface, glassOpacity);
        dispatcher ??= owner.DispatcherQueue;
        surfaces.RemoveAll(reference => !reference.TryGetTarget(out _));
        surfaces.Add(new(surface));
        owner.SizeChanged += (_, _) => surface.Resize();
        owner.Loaded += (_, _) =>
        {
            surface.Update(); surface.Resize();
            // The upstream brush reports shader connection failures rather than
            // throwing them. Replace its diagnostic fill before presenting it.
            owner.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            { if (!string.IsNullOrEmpty(Error)) SetDark(Design.Dark); });
        };
        owner.Unloaded += (_, _) => surface.Disconnect();
        // Defer GPU graph creation for cards that are never brought on screen.
        surface.Update();
    }
    internal static List<ControlBackdrop.Surface> DesktopSurfaces(FrameworkElement root)
    {
        var result = new List<ControlBackdrop.Surface>();
        foreach (var reference in surfaces)
        {
            if (!reference.TryGetTarget(out var surface) || !surface.DesktopSurface) continue;
            var owner = surface.Owner;
            if (!owner.IsLoaded || owner.ActualWidth < 1 || owner.ActualHeight < 1) continue;
            bool visible = true; double opacity = 1;
            for (DependencyObject? parent = owner; parent != null && parent != root; parent = VisualTreeHelper.GetParent(parent))
                if (parent is FrameworkElement element)
                {
                    opacity *= element.Opacity;
                    if (element.Visibility != Visibility.Visible || opacity < .01 || element.ActualWidth < 1 || element.ActualHeight < 1) { visible = false; break; }
                }
            if (!visible) continue;
            try
            {
                var r = owner.TransformToVisual(root).TransformBounds(new(0, 0, owner.ActualWidth, owner.ActualHeight));
                if (r.Right < 0 || r.Bottom < 0 || r.X > root.ActualWidth || r.Y > root.ActualHeight) continue;
                // Keep scroll-view clipping in the shared desktop mask.
                for (var parent = VisualTreeHelper.GetParent(owner); parent != null && parent != root; parent = VisualTreeHelper.GetParent(parent))
                    if (parent is ScrollViewer scroll) r.Intersect(scroll.TransformToVisual(root).TransformBounds(new(0, 0, scroll.ActualWidth, scroll.ActualHeight)));
                if (r.Width > 0 && r.Height > 0)
                {
                    // Subpixel spring tails must not rebuild the OS graph forever.
                    double Snap(double value) => Math.Round(value * 2) / 2;
                    result.Add(new(new Rect(Snap(r.X), Snap(r.Y), Snap(r.Width), Snap(r.Height)), surface.Radius, Math.Round(opacity*255)/255));
                }
            }
            catch (ArgumentException) { /* A popup belongs to a separate XAML root. */ }
        }
        return result;
    }
    static void Apply(RecallGlassBrush brush, bool dark, bool compact = false)
    {
        // Reset all tuning values before applying a command's overrides, including
        // retained toolbar brushes that survive page navigation in validation.
        brush.BlurAmount = compact ? 12 : 14; brush.RefThickness = compact ? 6 : 8; brush.RefFactor = 1.16;
        brush.RefDispersion = .28; brush.DispersionRange = .62;
        brush.RefFresnelRange = compact ? 22 : 28; brush.RefFresnelHardness = 18; brush.RefFresnelFactor = 16;
        brush.GlareAngle = -58; brush.GlareRange = compact ? 24 : 30; brush.GlareHardness = 18;
        brush.GlareFactor = 18; brush.GlareOppositeFactor = 7; brush.GlareConvergence = 24;
        brush.ShapeRoundness = 4.6; brush.Magnification = 1.006;
        brush.TintR = brush.TintG = brush.TintB = dark ? 48 : 250;
        brush.TintA = dark ? compact ? .16 : .24 : compact ? .18 : .25;
        brush.LumaCompression = dark ? .78 : .84;
        brush.ColorSaturation = dark ? 1.22 : 1.10;
        brush.LumaOffset = (dark ? compact ? 26 : 30 : compact ? 24 : 28) / 255.0;
        brush.FallbackColor = dark ? Color.FromArgb(255, 45, 48, 54) : Color.FromArgb(255, 235, 237, 240);
    }
    internal static void SetAccent(FrameworkElement owner, Color? accent)
    {
        foreach (var reference in surfaces) if (reference.TryGetTarget(out var surface) && surface.Owner == owner && surface.Accent != accent) { surface.Accent = accent; surface.Update(); }
    }
    internal static void SetEnabled(FrameworkElement owner, bool enabled)
    {
        foreach (var reference in surfaces) if (reference.TryGetTarget(out var surface) && surface.Owner == owner) { surface.Enabled = enabled; surface.Update(); }
    }
    internal static void SetDesktopSampling(FrameworkElement owner, bool desktopOnly)
    {
        foreach (var reference in surfaces)
            if (reference.TryGetTarget(out var surface) && surface.Owner == owner && surface.DesktopOnly != desktopOnly)
            { surface.DesktopOnly = desktopOnly; surface.Update(); }
    }
    internal static void SetDesktopSurface(FrameworkElement owner, bool included)
    {
        foreach (var reference in surfaces)
            if (reference.TryGetTarget(out var surface) && surface.Owner == owner && surface.DesktopSurface != included)
            { surface.DesktopSurface = included; }
    }
    public static void SetDark(bool dark)
    {
        surfaces.RemoveAll(reference => !reference.TryGetTarget(out _));
        foreach (var reference in surfaces) if (reference.TryGetTarget(out var surface)) surface.Update();
        PolicyChanged?.Invoke();
    }
    public static string? Error => compatibilityError ?? connectionError;
    internal static object Diagnostics => new
    {
        advancedEffects = settings.AdvancedEffectsEnabled,
        highContrast = System.Windows.Forms.SystemInformation.HighContrast,
        runtimeCompatible = compatibleRuntime.Value,
        validationFallback = ValidationFallback,
        effectsAvailable = EffectsAvailable,
        error = Error,
        surfaces = surfaces.Count(reference => reference.TryGetTarget(out _))
    };
    sealed class Surface(FrameworkElement owner, double radius, Color? accent, bool desktopOnly, bool desktopSurface, double glassOpacity)
    {
        public FrameworkElement Owner { get; } = owner;
        public bool DesktopSurface { get; internal set; } = desktopSurface;
        public double Radius => Owner is Control control ? control.CornerRadius.TopLeft : Owner is Border border ? border.CornerRadius.TopLeft : radius;
        internal bool DesktopOnly = desktopOnly;
        internal bool Enabled = true;
        internal Color? Accent = accent;
        RecallGlassBrush? glass;
        readonly SolidColorBrush fallback = new();
        void Assign(Brush brush)
        {
            brush.Opacity = brush is RecallGlassBrush && !System.Windows.Forms.SystemInformation.HighContrast ? glassOpacity : 1;
            if (Owner is Border border) border.Background = brush;
            else if (Owner is Control control) control.Background = brush;
            else if (Owner is Panel panel) panel.Background = brush;
        }
        public void Update()
        {
            if (!Enabled || !Owner.IsLoaded || !EffectsAvailable)
            {
                Disconnect(); return;
            }
            if (DesktopOnly)
            {
                // Native text editing creates an intermediate composition surface
                // while focused. Sampling that surface as an in-window backdrop
                // feeds its rectangular editor fill back into the glass. Keep
                // desktop blur in ControlBackdrop and use only a clear highlight here.
                Assign(new LinearGradientBrush
                {
                    StartPoint = new(0, 0), EndPoint = new(1, 1),
                    GradientStops = { new() { Color = Color.FromArgb(14,255,255,255), Offset = 0 }, new() { Color = Color.FromArgb(2,255,255,255), Offset = .55 }, new() { Color = Color.FromArgb(7,255,255,255), Offset = 1 } }
                });
                return;
            }
            var scale = (float)(Owner.XamlRoot?.RasterizationScale ?? 1);
            if (glass != null && glass.DpiScale != scale) Disconnect();
            glass ??= Create(); glass.DpiScale = scale; Apply(glass, Design.Dark, Owner.ActualHeight <= 100); Override(glass);
            glass.AccentTint = Accent;
            if (Accent is Color tint) { glass.TintR = tint.R; glass.TintG = tint.G; glass.TintB = tint.B; glass.TintA = .6; }
            glass.RefreshSource();
            Assign(glass); Resize();
        }
        public void Disconnect()
        {
            fallback.Color = System.Windows.Forms.SystemInformation.HighContrast ? FallbackColor : Accent ?? FallbackColor;
            Assign(Enabled ? fallback : Design.ArchiveBrush); glass = null;
        }
        public void Resize()
        {
            if (glass != null && glass.DpiScale != (float)(Owner.XamlRoot?.RasterizationScale ?? 1)) { Update(); return; }
            var corner = Radius;
            var side = Math.Min(Owner.ActualWidth, Owner.ActualHeight);
            if (glass != null && side > 0) { glass.ShapeRadius = Math.Clamp(corner * 2 / side, 0, 1); glass.RefreshSource(); }
        }
    }
}
