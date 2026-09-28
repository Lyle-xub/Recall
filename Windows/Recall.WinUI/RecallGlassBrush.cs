using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.UI.Composition;
using Recall.Materials.Effects;
namespace Recall;

/// Refract XAML content without covering the OS host backdrop with opaque void.
/// The desktop stays live; there is no screen copying or wallpaper substitution.
internal sealed class RecallGlassBrush : XamlCompositionBrushBase
{
    static readonly Dictionary<float, CompositionEffectFactory> glassFactories = [];
    static CompositionEffectFactory? blurFactory, compositeFactory;
    readonly List<IDisposable> resources = [];
    CompositionEffectBrush? source, glass, composite;
    internal float DpiScale { get; set; } = 1;

    // Parameters remain local to each surface; GPU shader factories are pooled.
    internal Color? AccentTint;
    public double BlurAmount { get; set; } = 10;
    public double RefThickness { get; set; } = 3;
    public double RefFactor { get; set; } = 1.12;
    public double RefDispersion { get; set; } = .15;
    public double DispersionRange { get; set; } = .3;
    public double RefFresnelRange { get; set; } = 20;
    public double RefFresnelHardness { get; set; } = 30;
    public double RefFresnelFactor { get; set; } = 2;
    public double Magnification { get; set; } = 1;
    public double GlareRange { get; set; } = 18;
    public double GlareHardness { get; set; } = 25;
    public double GlareFactor { get; set; } = 2;
    public double GlareConvergence { get; set; } = 35;
    public double GlareOppositeFactor { get; set; } = 2;
    public double GlareAngle { get; set; } = -65;
    public double TintR { get; set; } = 255;
    public double TintG { get; set; } = 255;
    public double TintB { get; set; } = 255;
    public double TintA { get; set; } = .32;
    public double LumaCompression { get; set; } = 1;
    public double ColorSaturation { get; set; } = 1;
    public double LumaOffset { get; set; }
    public double ShapeRadius { get; set; } = 1;
    public double ShapeRoundness { get; set; } = 2;

    protected override void OnConnected()
    {
        if (CompositionBrush != null) return;
        T Own<T>(T item) where T : IDisposable { resources.Add(item); return item; }
        try
        {
            var compositor = CompositionTarget.GetCompositorForCurrentThread();
            var backdrop = Own(compositor.CreateBackdropBrush());
            // Use the native Gaussian kernel; sparse shader taps band at this radius.
            blurFactory ??= compositor.CreateEffectFactory(new GaussianBlurEffect
            {
                Name = "Blur", BlurAmount = 10, BorderMode = EffectBorderMode.Hard,
                Optimization = EffectOptimization.Balanced,
                Source = new CompositionEffectSourceParameter("Backdrop")
            }, ["Blur.BlurAmount"]);
            source = Own(blurFactory.CreateBrush()); source.SetSourceParameter("Backdrop", backdrop);
            if (!glassFactories.TryGetValue(DpiScale, out var factory))
            {
                factory = compositor.CreateEffectFactory(new LiquidGlassEffect { Dpr = DpiScale }.Create(),
                    LiquidGlassEffect.Params.Select(p => LiquidGlassEffect.EffectNameValue + "." + p.Key).ToArray());
                glassFactories.Add(DpiScale, factory);
            }
            glass = Own(factory.CreateBrush()); glass.SetSourceParameter("Backdrop", source);
            compositeFactory ??= compositor.CreateEffectFactory(new CompositeEffect
            {
                Mode = CanvasComposite.SourceOver,
                Sources =
                {
                    new ColorSourceEffect { Name = "Veil", Color = Color.FromArgb(14, 255, 255, 255) },
                    new AlphaMaskEffect
                    {
                        Source = new CompositionEffectSourceParameter("Glass"),
                        AlphaMask = new CompositionEffectSourceParameter("Coverage")
                    }
                }
            }, ["Veil.Color"]);
            composite = Own(compositeFactory.CreateBrush());
            composite.SetSourceParameter("Glass", glass);
            composite.SetSourceParameter("Coverage", backdrop);
            RefreshSource(); CompositionBrush = composite;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException
            or DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            Release(); GlassMaterial.ReportError(error.Message);
            CompositionBrush = Own(CompositionTarget.GetCompositorForCurrentThread().CreateColorBrush(GlassMaterial.FallbackColor));
        }
    }
    internal void RefreshSource()
    {
        source?.Properties.InsertScalar("Blur.BlurAmount", (float)BlurAmount);
        if (glass != null)
            foreach (var parameter in LiquidGlassEffect.Params)
            {
                var value = (double)GetType().GetProperty(parameter.Key)!.GetValue(this)!;
                glass.Properties.InsertScalar(LiquidGlassEffect.EffectNameValue + "." + parameter.Key, (float)value);
            }
        composite?.Properties.InsertColor("Veil.Color", AccentTint is Color tint ? Color.FromArgb(190, tint.R, tint.G, tint.B) : Design.Dark
            ? Color.FromArgb(10, 255, 255, 255) : Color.FromArgb(7, 255, 255, 255));
    }
    protected override void OnDisconnected() => Release();
    void Release()
    {
        CompositionBrush = null;
        for (var i = resources.Count - 1; i >= 0; i--) resources[i].Dispose();
        resources.Clear(); source = glass = composite = null;
    }
}
