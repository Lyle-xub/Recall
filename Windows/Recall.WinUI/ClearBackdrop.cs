using System.Numerics;
using Microsoft.Graphics.Canvas.Effects;
using WUC = Windows.UI.Composition;
namespace Recall;

/// One continuous desktop material, below the XAML content. Only the classic
/// home screen masks it to the controls and the smooth bottom fade.
internal sealed class ClearBackdrop : SystemBackdrop
{
    readonly WUC.Compositor compositor = new();
    readonly List<IDisposable> graph = [];
    Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop? target;
    WUC.CompositionEffectFactory? materialFactory;
    WUC.CompositionEffectBrush? material;
    string? lastKey;
    bool full; double width = 1920, height = 1080; Rect search; List<Rect> buttons = [];
    public void Update(bool full, double width, double height, Rect search, List<Rect> buttons)
    {
        var key = $"{full}/{Design.Dark}/{width:0.0}/{height:0.0}/{search}/" + string.Join("/", buttons);
        if (key == lastKey) return;
        lastKey = key; this.full = full; this.width = width; this.height = height;
        this.search = search; this.buttons = buttons; Draw();
    }
    protected override void OnTargetConnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target, XamlRoot root)
    {
        base.OnTargetConnected(target, root); this.target = target; Draw();
    }
    protected override void OnTargetDisconnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target)
    {
        target.SystemBackdrop = null; this.target = null;
        ReleaseGraph(); materialFactory?.Dispose(); materialFactory = null;
        base.OnTargetDisconnected(target);
    }
    void ReleaseGraph()
    {
        material?.Dispose(); material = null;
        for (int i = graph.Count - 1; i >= 0; i--) graph[i].Dispose();
        graph.Clear();
    }
    void Draw()
    {
        if (target == null || width <= 0 || height <= 0) return;
        var next = new List<IDisposable>();
        T Own<T>(T resource) where T : IDisposable { next.Add(resource); return resource; }
        var maskRoot = Own(compositor.CreateContainerVisual());
        maskRoot.Size = new((float)width, (float)height);
        var bottom = Own(compositor.CreateSpriteVisual()); bottom.Size = maskRoot.Size;
        var gradient = Own(compositor.CreateLinearGradientBrush());
        gradient.StartPoint = Vector2.Zero; gradient.EndPoint = new(0, 1);
        gradient.ColorStops.Add(Own(compositor.CreateColorGradientStop(0, full ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Transparent)));
        for (int i = 0; i <= 12; i++)
        {
            float t = i / 12f, a = full ? 1 : t * t * t * (t * (t * 6 - 15) + 10);
            gradient.ColorStops.Add(Own(compositor.CreateColorGradientStop((float)Math.Max(0, 1 - 234 / height + 234 / height * t), Color.FromArgb((byte)(a * 255), 255, 255, 255))));
        }
        bottom.Brush = gradient; maskRoot.Children.InsertAtBottom(bottom);
        if (!full)
            foreach (var rect in buttons.Prepend(search).Where(r => r.Width > 0))
            {
                var geometry = Own(compositor.CreateRoundedRectangleGeometry());
                geometry.Size = new((float)rect.Width, (float)rect.Height); geometry.CornerRadius = new((float)rect.Height / 2);
                var shape = Own(compositor.CreateSpriteShape(geometry)); shape.FillBrush = Own(compositor.CreateColorBrush(Microsoft.UI.Colors.White));
                var visual = Own(compositor.CreateShapeVisual()); visual.Shapes.Add(shape); visual.Size = geometry.Size;
                visual.Offset = new((float)rect.X, (float)rect.Y, 0); maskRoot.Children.InsertAtTop(visual);
            }
        var surface = Own(compositor.CreateVisualSurface()); surface.SourceVisual = maskRoot; surface.SourceSize = maskRoot.Size;
        materialFactory ??= compositor.CreateEffectFactory(new AlphaMaskEffect
        {
            Source = new ArithmeticCompositeEffect
            {
                Name = "Tone", Source1Amount = 1, Source2Amount = 0, MultiplyAmount = 0,
                Source1 = new SaturationEffect
                {
                    Saturation = 1.1f,
                    Source = new GaussianBlurEffect
                    {
                        BlurAmount = 24, BorderMode = EffectBorderMode.Hard,
                        Optimization = EffectOptimization.Balanced,
                        Source = new WUC.CompositionEffectSourceParameter("Desktop")
                    }
                },
                Source2 = new ColorSourceEffect { Name = "Tint", Color = Microsoft.UI.Colors.White }
            },
            AlphaMask = new WUC.CompositionEffectSourceParameter("Mask")
        }, ["Tone.Source1Amount", "Tone.Source2Amount", "Tint.Color"]);
        var effect = materialFactory.CreateBrush();
        effect.SetSourceParameter("Desktop", Own(compositor.CreateHostBackdropBrush()));
        effect.SetSourceParameter("Mask", Own(compositor.CreateSurfaceBrush(surface)));
        effect.Properties.InsertScalar("Tone.Source1Amount", Design.Dark ? .30f : .76f);
        effect.Properties.InsertScalar("Tone.Source2Amount", Design.Dark ? .70f : .24f);
        effect.Properties.InsertColor("Tint.Color", Design.Dark ? Color.FromArgb(255, 20, 23, 30) : Microsoft.UI.Colors.White);
        target.SystemBackdrop = effect;
        ReleaseGraph(); graph.AddRange(next); material = effect;
    }
}
