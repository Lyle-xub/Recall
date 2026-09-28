using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using WUC = Windows.UI.Composition;
namespace Recall;

/// Desktop control material lives in the OS compositor, which can sample behind the HWND.
/// The XAML shader separately handles content inside the window. Neither path
/// reads screen pixels or disables capture exclusion.
internal sealed class ControlBackdrop(WUC.Compositor compositor) : IDisposable
{
    WUC.CompositionEffectFactory? factory;
    internal readonly record struct Surface(Rect Bounds, double Radius, double Opacity = 1);
    public WUC.CompositionBrush Build(Vector2 size, IReadOnlyList<Surface> controls, List<IDisposable> resources)
    {
        T Own<T>(T value) where T : IDisposable { resources.Add(value); return value; }
        WUC.CompositionBrush Mask()
        {
            var root = Own(compositor.CreateContainerVisual()); root.Size = size;
            var background = Own(compositor.CreateSpriteVisual()); background.Size = size;
            background.Brush = Own(compositor.CreateColorBrush(Microsoft.UI.Colors.Transparent));
            root.Children.InsertAtBottom(background);
            foreach (var item in controls)
            {
                var r = item.Bounds;
                var geometry = Own(compositor.CreateRoundedRectangleGeometry());
                geometry.Size = new((float)r.Width, (float)r.Height);
                geometry.CornerRadius = new((float)Math.Min(item.Radius, Math.Min(r.Width, r.Height) / 2));
                var shape = Own(compositor.CreateSpriteShape(geometry));
                shape.FillBrush = Own(compositor.CreateColorBrush(Color.FromArgb((byte)(Math.Clamp(item.Opacity,0,1)*255),255,255,255)));
                var visual = Own(compositor.CreateShapeVisual()); visual.Size = geometry.Size + new Vector2(8);
                visual.Shapes.Add(shape); visual.Offset = new((float)r.X, (float)r.Y, 0);
                root.Children.InsertAtTop(visual);
            }
            var surface = Own(compositor.CreateVisualSurface()); surface.SourceVisual = root; surface.SourceSize = size;
            return Own(compositor.CreateSurfaceBrush(surface));
        }
        factory ??= compositor.CreateEffectFactory(new AlphaMaskEffect
        {
            Source = new ArithmeticCompositeEffect
            {
                Name = "Tone", Source1Amount = .45f, Source2Amount = .55f, MultiplyAmount = 0,
                Source1 = new SaturationEffect { Saturation = 1.18f, Source = new GaussianBlurEffect
                {
                    BlurAmount = 26, BorderMode = EffectBorderMode.Hard,
                    Source = new WUC.CompositionEffectSourceParameter("Desktop")
                } },
                Source2 = new ColorSourceEffect { Name = "Tint", Color = Microsoft.UI.Colors.White }
            },
            AlphaMask = new WUC.CompositionEffectSourceParameter("Mask")
        }, ["Tone.Source1Amount", "Tone.Source2Amount", "Tint.Color"]);
        var effect = Own(factory.CreateBrush());
        effect.SetSourceParameter("Desktop", Own(compositor.CreateHostBackdropBrush()));
        effect.SetSourceParameter("Mask", Mask());
        effect.Properties.InsertScalar("Tone.Source1Amount", Design.Dark ? .55f : .56f);
        effect.Properties.InsertScalar("Tone.Source2Amount", Design.Dark ? .45f : .44f);
        effect.Properties.InsertColor("Tint.Color", Design.Dark ? Color.FromArgb(255, 24, 27, 33) : GlassMaterial.LightTint);
        return effect;
    }
    public void Dispose() { factory?.Dispose(); factory = null; }
}
