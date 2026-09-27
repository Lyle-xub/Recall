using Microsoft.Graphics.Canvas.Effects;
using WUC = Windows.UI.Composition;

namespace Recall;

/// <summary>
/// Supplies the native flyout host with a live backdrop. XAML's liquid brush
/// then refracts this base within the flyout presenter.
/// </summary>
internal sealed class PopupGlassBackdrop : SystemBackdrop
{
    static int active, totalConnections, fallbacks;
    static string? lastError;
    internal static object Diagnostics => new { active, connections = totalConnections, fallbacks, lastError };
    readonly Dictionary<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop, Connection> targets = [];
    bool policySubscribed;

    protected override void OnTargetConnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop connected, XamlRoot root)
    {
        base.OnTargetConnected(connected, root);
        if (targets.Remove(connected, out var previous)) { previous.Dispose(); active--; }
        var connection = new Connection(connected);
        targets.Add(connected, connection);
        totalConnections++;
        active++;
        if (!policySubscribed) { GlassMaterial.PolicyChanged += Refresh; policySubscribed = true; }
        connection.Draw();
    }

    protected override void OnTargetDisconnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop disconnected)
    {
        if (targets.Remove(disconnected, out var connection))
        {
            connection.Dispose();
            active = Math.Max(0, active - 1);
        }
        else disconnected.SystemBackdrop = null;
        if (targets.Count == 0 && policySubscribed) { GlassMaterial.PolicyChanged -= Refresh; policySubscribed = false; }
        base.OnTargetDisconnected(disconnected);
    }

    protected override void OnDefaultSystemBackdropConfigurationChanged(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop changed, XamlRoot root)
    {
        // WinUI can deliver a queued configuration change after a native popup
        // has disconnected. The base implementation rejects that stale target;
        // our material owns its configuration and redraws only live targets.
        if (targets.TryGetValue(changed, out var connection)) connection.Draw();
    }

    void Refresh()
    {
        foreach (var connection in targets.Values.ToArray()) connection.Draw();
    }

    sealed class Connection(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target) : IDisposable
    {
        readonly WUC.Compositor compositor = new();
        readonly List<IDisposable> resources = [];

        public void Draw()
        {
            target.SystemBackdrop = null;
            Release();
            if (!GlassMaterial.TransparencyAvailable)
            {
                target.SystemBackdrop = Own(compositor.CreateColorBrush(GlassMaterial.FallbackColor));
                return;
            }
            try
            {
                // A WUC host brush samples behind each separate native popup.
                // The MUC liquid brush on its presenter adds the optical edge.
                var host = Own(compositor.CreateHostBackdropBrush());
                var tint = Design.Dark ? .22f : .46f;
                var factory = Own(compositor.CreateEffectFactory(new ArithmeticCompositeEffect
                {
                    Source1Amount = 1 - tint, Source2Amount = tint, MultiplyAmount = 0,
                    Source1 = new GaussianBlurEffect
                    {
                        BlurAmount = 12, BorderMode = EffectBorderMode.Hard,
                        Optimization = EffectOptimization.Balanced,
                        Source = new WUC.CompositionEffectSourceParameter("Host")
                    },
                    Source2 = new ColorSourceEffect
                    {
                        Color = Design.Dark ? Color.FromArgb(255, 45, 48, 54) : Microsoft.UI.Colors.White
                    }
                }));
                var material = Own(factory.CreateBrush());
                material.SetSourceParameter("Host", host);
                target.SystemBackdrop = material;
                lastError = null;
            }
            catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException)
            {
                lastError = error.Message;
                fallbacks++;
                target.SystemBackdrop = null;
                Release();
                target.SystemBackdrop = Own(compositor.CreateColorBrush(GlassMaterial.FallbackColor));
            }
        }

        public void Dispose()
        {
            target.SystemBackdrop = null;
            Release();
            compositor.Dispose();
        }

        void Release()
        {
            for (var i = resources.Count - 1; i >= 0; i--) resources[i].Dispose();
            resources.Clear();
        }

        T Own<T>(T resource) where T : IDisposable
        {
            resources.Add(resource);
            return resource;
        }
    }
}
