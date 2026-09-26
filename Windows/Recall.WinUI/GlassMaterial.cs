using LiquidGlassWinUI;
using System.Security.Cryptography;
namespace Recall;

/// Material parameters are local to each surface; the library pools GPU factories.
internal static class GlassMaterial
{
    static readonly List<WeakReference<Surface>> surfaces = [];
    static readonly Windows.UI.ViewManagement.UISettings settings = new();
    static readonly Lazy<bool> compatibleRuntime = new(CheckRuntime);
    static string? compatibilityError;
    static Microsoft.UI.Dispatching.DispatcherQueue? dispatcher;
    internal static bool ValidationFallback;
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
            if (Environment.Is64BitProcess && Convert.ToHexString(SHA256.HashData(file)) ==
                "DBEA457AC1C6D5C4CDE5B9CFB09E65CD54B11596406CE50565DDD946468B1454") return true;
            compatibilityError = "The bundled Composition runtime does not match the tested glass ABI.";
        }
        catch (IOException) { compatibilityError = "The tested Composition runtime is unavailable."; }
        catch (UnauthorizedAccessException) { compatibilityError = "The Composition runtime could not be verified."; }
        return false;
    }
    static bool EffectsAvailable => !ValidationFallback && !System.Windows.Forms.SystemInformation.HighContrast &&
        settings.AdvancedEffectsEnabled && compatibleRuntime.Value && string.IsNullOrEmpty(LiquidGlassBrush.LastError);
    static void RefreshPolicy()
    {
        // System settings notifications arrive off the XAML thread.
        dispatcher?.TryEnqueue(() => SetDark(Design.Dark));
    }
    internal static Dictionary<string, double> ValidationParameters = [];
    internal static void Configure(System.Text.Json.JsonElement values)
    {
        ValidationParameters.Clear();
        foreach (var value in values.EnumerateObject())
            if (value.Value.TryGetDouble(out var number) && double.IsFinite(number)) ValidationParameters[value.Name] = number;
        SetDark(Design.Dark);
    }
    static void Override(LiquidGlassBrush brush)
    {
        // Only this fixed effect's numeric properties can be adjusted by the opt-in harness.
        foreach (var (name, value) in ValidationParameters)
        {
            var property = typeof(LiquidGlassBrush).GetProperty(name);
            if (property?.PropertyType == typeof(double) && property.CanWrite) property.SetValue(brush, value);
        }
    }
    static LiquidGlassBrush Create()
    {
        var brush = new LiquidGlassBrush
        {
            BlurAmount = 1.25, BloomAmount = 0, RefThickness = 12, RefFactor = 1.5,
            RefDispersion = .8, DispersionRange = .3, RefFresnelRange = 20,
            RefFresnelHardness = 30, RefFresnelFactor = 10,
            GlareAngle = -65, GlareRange = 18, GlareHardness = 25,
            GlareFactor = 22, GlareOppositeFactor = 14, GlareConvergence = 35,
            ShapeRadius = 1, ShapeRoundness = 2, Magnification = 1,
            Saturation = 1.1, Contrast = 1, Exposure = 1, TintA = .18,
        };
        Apply(brush, Design.Dark); Override(brush); return brush;
    }
    public static void Attach(FrameworkElement owner, double radius)
    {
        var surface = new Surface(owner, radius);
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
            { if (!string.IsNullOrEmpty(LiquidGlassBrush.LastError)) SetDark(Design.Dark); });
        };
        // Defer GPU graph creation for cards that are never brought on screen.
        surface.Update();
    }
    static void Apply(LiquidGlassBrush brush, bool dark)
    {
        brush.Brightness = dark ? -.13 : .08;
        brush.TintR = brush.TintG = brush.TintB = dark ? 68 : 255;
        brush.TintA = dark ? .48 : .16;
        brush.FallbackColor = dark ? Color.FromArgb(255, 45, 48, 54) : Color.FromArgb(255, 235, 237, 240);
    }
    public static void SetDark(bool dark)
    {
        surfaces.RemoveAll(reference => !reference.TryGetTarget(out _));
        foreach (var reference in surfaces) if (reference.TryGetTarget(out var surface)) surface.Update();
    }
    public static string? Error => compatibilityError ?? LiquidGlassBrush.LastError;
    sealed class Surface(FrameworkElement owner, double radius)
    {
        public FrameworkElement Owner { get; } = owner;
        LiquidGlassBrush? glass;
        readonly SolidColorBrush fallback = new();
        void Assign(Brush brush)
        {
            if (Owner is Border border) border.Background = brush;
            else if (Owner is Control control) control.Background = brush;
            else if (Owner is Panel panel) panel.Background = brush;
        }
        public void Update()
        {
            if (!EffectsAvailable)
            {
                fallback.Color = System.Windows.Forms.SystemInformation.HighContrast
                    ? settings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Background)
                    : Design.Dark ? Color.FromArgb(255, 45, 48, 54) : Color.FromArgb(255, 235, 237, 240);
                Assign(fallback); glass = null; return;
            }
            glass ??= Create(); Apply(glass, Design.Dark); Override(glass);
            Assign(glass); Resize();
        }
        public void Resize()
        {
            var corner = Owner is Control control ? control.CornerRadius.TopLeft : radius;
            var side = Math.Min(Owner.ActualWidth, Owner.ActualHeight);
            if (glass != null && side > 0) glass.ShapeRadius = Math.Clamp(corner * 2 / side, 0, 1);
        }
    }
}
