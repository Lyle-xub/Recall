using System.Numerics;
using System.Diagnostics;
using Microsoft.Graphics.Canvas.Effects;
using WUC = Windows.UI.Composition;
namespace Recall;

/// One continuous desktop material, below the XAML content. Only the classic
/// home screen masks it to the controls and the smooth bottom fade.
internal sealed class ClearBackdrop : SystemBackdrop
{
    readonly WUC.Compositor compositor = new();
    readonly List<IDisposable> graph = [];
    ControlBackdrop? controlMaterial;
    WUC.CompositionEffectFactory? compositeFactory;
    List<ControlBackdrop.Surface> controls = [];
    Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop? target;
    bool policySubscribed;
    WUC.CompositionEffectFactory? materialFactory;
    WUC.CompositionEffectFactory? fallbackFactory;
    WUC.CompositionEffectBrush? material;
    string? hostError;
    bool usingFallback, visible = true; long draws;
    double lastDrawMs, maxDrawMs;
    float desktopWeight, blurRadius;
    internal static bool ValidationHostFailure;
    internal object Diagnostics => new { visible, attached = material != null, targetConnected = target != null, draws, lastDrawMs, maxDrawMs, controlSurfaces = controls.Count, usingFallback, hostError, full, width, height, desktopWeight, blurRadius };
    string? lastKey;
    bool full; double width = 1920, height = 1080; Rect search; List<Rect> buttons = [];
    internal void SetVisible(bool value)
    {
        if (visible == value && value) return;
        visible = value;
        if (value) Draw();
        else { if (target != null) target.SystemBackdrop = null; ReleaseGraph(); lastKey = null; }
    }
    public void Update(bool full, double width, double height, Rect search, List<Rect> buttons, List<ControlBackdrop.Surface>? controls = null)
    {
        var key = $"{full}/{Design.Dark}/{width:0.0}/{height:0.0}/{search}/" + string.Join("/", buttons) + "/" + string.Join("/", controls ?? []);
        if (key == lastKey) return;
        lastKey = key; this.full = full; this.width = width; this.height = height;
        this.search = search; this.buttons = buttons; this.controls = controls ?? []; Draw();
    }
    protected override void OnTargetConnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target, XamlRoot root)
    {
        base.OnTargetConnected(target, root); this.target = target;
        if (!policySubscribed) { GlassMaterial.PolicyChanged += Draw; policySubscribed = true; }
        Draw();
    }
    protected override void OnTargetDisconnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target)
    {
        target.SystemBackdrop = null; this.target = null;
        if (policySubscribed) { GlassMaterial.PolicyChanged -= Draw; policySubscribed = false; }
        ReleaseGraph(); materialFactory?.Dispose(); materialFactory = null;
        fallbackFactory?.Dispose(); fallbackFactory = null;
        compositeFactory?.Dispose(); compositeFactory = null; controlMaterial?.Dispose(); controlMaterial = null;
        base.OnTargetDisconnected(target);
    }
    protected override void OnDefaultSystemBackdropConfigurationChanged(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop changed, XamlRoot root)
    {
        // A queued OS settings callback can arrive after Hide disconnects the
        // window backdrop. Only redraw a target that still belongs to us.
        if (target != null && EqualityComparer<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop>.Default.Equals(target, changed)) Draw();
    }
    void ReleaseGraph()
    {
        material?.Dispose(); material = null;
        for (int i = graph.Count - 1; i >= 0; i--) graph[i].Dispose();
        graph.Clear();
    }
    void Draw()
    {
        if (!visible || target == null || width <= 0 || height <= 0) return;
        draws++;
        var started = Stopwatch.GetTimestamp();
        try
        {
            try { DrawMaterial(!GlassMaterial.TransparencyAvailable); }
            catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or NotSupportedException)
            {
                hostError = error.Message;
                // Keep the same local mask when desktop sampling cannot connect.
                // An unavailable host backdrop must never become a black desktop.
                DrawMaterial(true);
            }
        }
        finally { lastDrawMs = (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency; maxDrawMs = Math.Max(maxDrawMs,lastDrawMs); }
    }
    void DrawMaterial(bool fallback)
    {
        if (!visible || target == null || width <= 0 || height <= 0) return;
        var next = new List<IDisposable>();
        T Own<T>(T resource) where T : IDisposable { next.Add(resource); return resource; }
        try
        {
            var maskRoot = Own(compositor.CreateContainerVisual());
            maskRoot.Size = new((float)width, (float)height);
            var bottom = Own(compositor.CreateSpriteVisual()); bottom.Size = maskRoot.Size;
            var gradient = Own(compositor.CreateLinearGradientBrush());
            gradient.StartPoint = Vector2.Zero; gradient.EndPoint = new(0, 1);
            gradient.ColorStops.Add(Own(compositor.CreateColorGradientStop(0, full ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Transparent)));
            for (int i = 0; i <= 12; i++)
            {
                float t = i / 12f, a = full ? 1 : (float)GlassProfile.TimelineOpacity(t);
                gradient.ColorStops.Add(Own(compositor.CreateColorGradientStop((float)Math.Max(0, 1 - 234 / height + 234 / height * t), Color.FromArgb((byte)(a * 255), 255, 255, 255))));
            }
            bottom.Brush = gradient; maskRoot.Children.InsertAtBottom(bottom);
            if (!full)
                foreach (var item in (controls.Count > 0 ? controls : buttons.Prepend(search).Where(r => r.Width > 0).Select(r => new ControlBackdrop.Surface(r, r.Height / 2)).ToList()))
                {
                    var rect = item.Bounds;
                    var geometry = Own(compositor.CreateRoundedRectangleGeometry());
                    geometry.Size = new((float)rect.Width, (float)rect.Height); geometry.CornerRadius = new((float)Math.Min(item.Radius, Math.Min(rect.Width, rect.Height) / 2));
                    var shape = Own(compositor.CreateSpriteShape(geometry)); shape.FillBrush = Own(compositor.CreateColorBrush(Color.FromArgb((byte)(Math.Clamp(item.Opacity,0,1)*255),255,255,255)));
                    var visual = Own(compositor.CreateShapeVisual()); visual.Shapes.Add(shape); visual.Size = geometry.Size;
                    visual.Offset = new((float)rect.X, (float)rect.Y, 0); maskRoot.Children.InsertAtTop(visual);
                }
            var surface = Own(compositor.CreateVisualSurface()); surface.SourceVisual = maskRoot; surface.SourceSize = maskRoot.Size;
            WUC.CompositionEffectBrush effect;
            if (fallback)
            {
                fallbackFactory ??= compositor.CreateEffectFactory(new AlphaMaskEffect
                {
                    Source = new WUC.CompositionEffectSourceParameter("Fill"),
                    AlphaMask = new WUC.CompositionEffectSourceParameter("Mask")
                });
                effect = Own(fallbackFactory.CreateBrush());
                effect.SetSourceParameter("Fill", Own(compositor.CreateColorBrush(GlassMaterial.FallbackColor)));
            }
            else
            {
                if (ValidationHostFailure) throw new NotSupportedException("Validation: host backdrop unavailable.");
                materialFactory ??= compositor.CreateEffectFactory(new AlphaMaskEffect
                {
                    Source = new ArithmeticCompositeEffect
                    {
                        Name = "Tone", Source1Amount = 1, Source2Amount = 0, MultiplyAmount = 0,
                        Source1 = new SaturationEffect
                        {
                            Name = "Saturation", Saturation = 1.1f,
                            Source = new GaussianBlurEffect
                            {
                                Name = "Blur", BlurAmount = 24, BorderMode = EffectBorderMode.Hard,
                                Optimization = EffectOptimization.Balanced,
                                Source = new WUC.CompositionEffectSourceParameter("Desktop")
                            }
                        },
                        Source2 = new ColorSourceEffect { Name = "Tint", Color = Microsoft.UI.Colors.White }
                    },
                    AlphaMask = new WUC.CompositionEffectSourceParameter("Mask")
                }, ["Tone.Source1Amount", "Tone.Source2Amount", "Tint.Color", "Blur.BlurAmount", "Saturation.Saturation"]);
                effect = Own(materialFactory.CreateBrush());
                effect.SetSourceParameter("Desktop", Own(compositor.CreateHostBackdropBrush()));
                float Parameter(string name, float value) => GlassMaterial.ValidationParameters.TryGetValue(name, out var number) ? (float)number : value;
                // The Mac reference's within-window material is not a desktop
                // opacity recipe. A 10% source weight washed real desktops out.
                var strength = Parameter("DesktopSource", Design.Dark ? .60f : full ? .60f : .64f);
                desktopWeight = strength;
                effect.Properties.InsertScalar("Tone.Source1Amount", strength);
                effect.Properties.InsertScalar("Tone.Source2Amount", 1 - strength);
                blurRadius = Parameter("DesktopBlur", full ? 22 : 12);
                effect.Properties.InsertScalar("Blur.BlurAmount", blurRadius);
                effect.Properties.InsertScalar("Saturation.Saturation", Parameter("DesktopSaturation", 1.1f));
                var tint = (byte)Math.Clamp(Parameter("DesktopTint", Design.Dark ? 12 : full ? 245 : 255), 0, 255);
                effect.Properties.InsertColor("Tint.Color", Color.FromArgb(255, tint, tint, tint));
                hostError = null;
            }
            effect.SetSourceParameter("Mask", Own(compositor.CreateSurfaceBrush(surface)));
            if (!fallback && controls.Count > 0)
            {
                controlMaterial ??= new(compositor);
                var lenses = controlMaterial.Build(maskRoot.Size, controls, next);
                compositeFactory ??= compositor.CreateEffectFactory(new CompositeEffect
                {
                    Mode = Microsoft.Graphics.Canvas.CanvasComposite.SourceOver,
                    Sources = { new WUC.CompositionEffectSourceParameter("Base"), new WUC.CompositionEffectSourceParameter("Controls") }
                });
                var combined = Own(compositeFactory.CreateBrush());
                combined.SetSourceParameter("Base", effect); combined.SetSourceParameter("Controls", lenses);
                effect = combined;
            }
            target.SystemBackdrop = effect;
            usingFallback = fallback;
            ReleaseGraph(); next.Remove(effect); graph.AddRange(next); material = effect;
        }
        catch
        {
            for (var i = next.Count - 1; i >= 0; i--) next[i].Dispose();
            throw;
        }
    }
}
