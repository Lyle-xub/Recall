using System.Numerics;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
namespace Recall;

/// The response/damping pairs mirror the SwiftUI surfaces, with native
/// compositor springs that retain velocity when a pointer reverses direction.
internal static class LiquidMotion
{
    internal static void To(UIElement owner, string property, Vector3 target, double response, float damping)
    {
        var visual = ElementCompositionPreview.GetElementVisual(owner);
        if (owner is FrameworkElement element) visual.CenterPoint = new((float)element.ActualWidth / 2, (float)element.ActualHeight / 2, 0);
        if (!Design.Motion)
        {
            visual.StopAnimation(property);
            if (property == "Scale") visual.Scale = target;
            else visual.Properties.InsertVector3(property, target);
            return;
        }
        using var spring = visual.Compositor.CreateSpringVector3Animation();
        spring.FinalValue = target; spring.DampingRatio = damping; spring.Period = TimeSpan.FromSeconds(response);
        visual.StartAnimation(property, spring);
    }
    internal static void Interactive(Control control)
    {
        bool hover = false, pressed = false;
        UIElement Target() { control.ApplyTemplate(); return VisualTreeHelper.GetChildrenCount(control) > 0 ? (UIElement)VisualTreeHelper.GetChild(control,0) : control; }
        void Update() => To(Target(), "Scale", new(pressed ? .96f : hover ? 1.025f : 1, pressed ? .96f : hover ? 1.025f : 1, 1), pressed ? .18 : .3, .8f);
        control.PointerEntered += (_, _) => { hover = true; Update(); };
        control.PointerExited += (_, _) => { hover = pressed = false; Update(); };
        control.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) => { if (e.GetCurrentPoint(control).Properties.IsLeftButtonPressed) { pressed = true; Update(); } }), true);
        control.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => { pressed = false; Update(); }), true);
        control.PointerCaptureLost += (_, _) => { pressed = false; Update(); };
        control.KeyDown += (_, e) => { if (e.Key is Windows.System.VirtualKey.Space or Windows.System.VirtualKey.Enter) { pressed = true; Update(); } };
        control.KeyUp += (_, _) => { pressed = false; Update(); };
        control.LostFocus += (_, _) => { pressed = false; Update(); };
        control.Unloaded += (_, _) => { hover = pressed = false; var v = ElementCompositionPreview.GetElementVisual(Target()); v.StopAnimation("Scale"); v.Scale = Vector3.One; };
    }
    sealed class Droplet
    {
        internal required FrameworkElement Owner;
        internal required CompositeTransform Transform;
        internal double X, Y, Scale, Alpha, TargetX, TargetY, TargetScale, TargetAlpha, Response, Damping, Delay, Duration;
        internal readonly System.Diagnostics.Stopwatch Watch = System.Diagnostics.Stopwatch.StartNew();
    }
    static readonly List<Droplet> droplets = [];
    static Microsoft.UI.Dispatching.DispatcherQueueTimer? clock;
    internal static event Action? LayoutChanged;
    internal static void Cancel(FrameworkElement root)
    {
        droplets.RemoveAll(d =>
        {
            for (DependencyObject? current = d.Owner; current != null; current = VisualTreeHelper.GetParent(current))
                if (current == root) { d.Owner.RenderTransform = null; d.Owner.Opacity = 1; return true; }
            return false;
        });
        if (droplets.Count == 0) clock?.Stop();
    }
    internal static void Emerge(FrameworkElement owner, int index) => DropletTo(owner, index, true);
    internal static void Dismiss(FrameworkElement owner, int index) => DropletTo(owner, index, false);
    static void DropletTo(FrameworkElement owner, int index, bool show)
    {
        void Start()
        {
            var previous = droplets.FirstOrDefault(d => d.Owner == owner);
            droplets.RemoveAll(d => d.Owner == owner);
            if (!Design.Motion) { owner.RenderTransform = null; owner.Opacity = show ? 1 : 0; LayoutChanged?.Invoke(); return; }
            var transform = owner.RenderTransform as CompositeTransform;
            if (transform == null)
                transform = new() { ScaleX = show ? .38 : 1, ScaleY = show ? .38 : 1, TranslateX = show ? -(53 + 76 * index) : 0, TranslateY = show ? 4 : 0 };
            owner.RenderTransformOrigin = new(0,.5); owner.RenderTransform = transform;
            if (show && previous == null) owner.Opacity = 0;
            droplets.Add(new()
            {
                Owner = owner, Transform = transform, X = transform.TranslateX, Y = transform.TranslateY, Scale = transform.ScaleX, Alpha = owner.Opacity,
                TargetX = show ? 0 : -(53 + 76 * index), TargetY = show ? 0 : 4, TargetScale = show ? 1 : .38, TargetAlpha = show ? 1 : 0,
                Response = show ? .56 : .3, Damping = show ? .57 : .86, Delay = show && previous == null ? index * .035 : 0, Duration = show ? 1.05 : .55
            });
            StartClock(owner);
        }
        if (owner.IsLoaded && owner.ActualWidth > 0) Start();
        else { RoutedEventHandler? handler = null; handler = (_,_) => { owner.Loaded -= handler; Start(); }; owner.Loaded += handler; }
    }
    static void StartClock(FrameworkElement owner)
    {
            if (clock == null)
            {
                clock = owner.DispatcherQueue.CreateTimer(); clock.Interval = TimeSpan.FromMilliseconds(16);
                clock.Tick += (_,_) =>
                {
                    for (int i = droplets.Count - 1; i >= 0; i--)
                    {
                        var d = droplets[i]; var t = Math.Max(0,d.Watch.Elapsed.TotalSeconds-d.Delay);
                        var ended = !Design.Motion || t >= d.Duration || !d.Owner.IsLoaded;
                        var p = ended ? 1 : Progress(t,d.Response,d.Damping);
                        d.Transform.TranslateX = d.X+(d.TargetX-d.X)*p; d.Transform.TranslateY = d.Y+(d.TargetY-d.Y)*p;
                        d.Transform.ScaleX = d.Transform.ScaleY = d.Scale+(d.TargetScale-d.Scale)*p;
                        d.Owner.Opacity = d.Alpha+(d.TargetAlpha-d.Alpha)*Math.Clamp(t/.18,0,1);
                        if (ended) { d.Owner.Opacity = d.TargetAlpha; if (d.TargetAlpha == 1) d.Owner.RenderTransform = null; droplets.RemoveAt(i); }
                    }
                    LayoutChanged?.Invoke();
                    if (droplets.Count == 0) clock.Stop();
                };
            }
            clock.Start();
    }
    internal static void Appear(FrameworkElement owner, float fromY, float fromScale, int delay, double response, double damping)
    {
        void Start()
        {
            droplets.RemoveAll(d => d.Owner == owner);
            if (!Design.Motion) { owner.RenderTransform = null; owner.Opacity = 1; LayoutChanged?.Invoke(); return; }
            var transform = new CompositeTransform { ScaleX = fromScale, ScaleY = fromScale, TranslateY = fromY };
            owner.RenderTransformOrigin = new(.5,.5); owner.RenderTransform = transform; owner.Opacity = 0;
            droplets.Add(new() { Owner = owner, Transform = transform, X = 0, Y = fromY, Scale = fromScale, Alpha = 0,
                TargetX = 0, TargetY = 0, TargetScale = 1, TargetAlpha = 1, Response = response, Damping = damping,
                Delay = delay / 1000.0, Duration = response * 2 });
            StartClock(owner);
        }
        if (owner.IsLoaded && owner.ActualWidth > 0) Start();
        else { RoutedEventHandler? handler = null; handler = (_,_) => { owner.Loaded -= handler; Start(); }; owner.Loaded += handler; }
    }
    internal static Task Disappear(FrameworkElement owner, double y, double response, double damping, int milliseconds)
    {
        droplets.RemoveAll(d => d.Owner == owner);
        if (!Design.Motion) { owner.Opacity = 0; owner.RenderTransform = null; return Task.CompletedTask; }
        var transform = owner.RenderTransform as CompositeTransform ?? new CompositeTransform();
        owner.RenderTransform = transform;
        droplets.Add(new() { Owner = owner, Transform = transform, X = transform.TranslateX, Y = transform.TranslateY,
            Scale = transform.ScaleX, Alpha = owner.Opacity, TargetX = 0, TargetY = y, TargetScale = 1, TargetAlpha = 0,
            Response = response, Damping = damping, Duration = milliseconds / 1000.0 });
        StartClock(owner);
        return Task.Delay(milliseconds);
    }
    internal static double Progress(double seconds, double response, double damping)
    {
        var omega = 2 * Math.PI / response; var damped = omega * Math.Sqrt(1 - damping * damping);
        return 1 - Math.Exp(-damping * omega * seconds) * (Math.Cos(damped * seconds) + damping * omega / damped * Math.Sin(damped * seconds));
    }
}
