using System.Diagnostics;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Windows.ApplicationModel.DataTransfer;

namespace Recall;

/// Retained card surfaces. Pointer events only retarget springs; the shared
/// projection is also used to pick the frontmost card, without XAML relayout.
internal sealed class RhineArchiveView : Grid
{
    sealed class Sheet
    {
        public required Canvas Root;
        public required Border Glass;
        public required Grid Art;
        public required Image Image;
        public required Grid Footer;
        public required StackPanel Buttons;
        public required Visual Visual;
        public MemoryFrame? Frame;
        public int Lane;
        public double Depth;
        public RhineSpring Height;
        public Matrix3x2 Matrix;
        public Vector3 Position, Origin;
        public float Width = 535, Size = 650, Distance, FooterWidth = 495;
        public bool Loading, Failed;
    }
    readonly AppRuntime runtime;
    readonly Action<MemoryFrame> rewind;
    readonly Canvas wall = new() { IsHitTestVisible = false };
    readonly List<Sheet> sheets = [];
    readonly List<Sheet> drawOrder = [];
    readonly Border caption;
    readonly TextBlock captionText = Design.Text("", 14, true);
    readonly StackPanel dayControls;
    readonly TextBlock dayText = Design.Text("", 16, true);
    RhineSpring crest = new(0), across = new(0), pan = new(0), extraction = new(0);
    double crestTarget, acrossTarget, panTarget, extractTarget;
    long previous;
    bool ticking, active, reduced, timeline;
    Sheet? hovered, extracted;
    DateTime day;
    List<MemoryFrame> records = [];
    int revision, rows = 20;
    CancellationTokenSource imageLoads = new();
    int pointerMoves, hoverChanges, expansions, collapses;
    internal object Diagnostics => new { active, ticking, reducedMotion = reduced, pointerMoves, hoverChanges, expansions, collapses, hovered = hovered?.Frame?.Id, extracted = extracted?.Frame?.Id, crestTarget, acrossTarget, imageCount = sheets.Count(s => s.Frame != null), loadedImages = sheets.Count(s => s.Image.Source != null), failedImages = sheets.Count(s => s.Failed) };
    internal void ValidationRetarget(int step)
    {
        if (!active || extracted != null) return;
        acrossTarget = step % 3 - 1; crestTarget = step % 7;
        Wake();
    }
    public bool IsExpanded => extracted != null;
    public event Action? TimelineRequested;
    public event Action<bool>? ExpansionChanged;
    public RhineArchiveView(AppRuntime runtime, Action<MemoryFrame> rewind)
    {
        this.runtime = runtime; this.rewind = rewind;
        Background = Design.Brush(Microsoft.UI.Colors.Transparent);
        IsTabStop = true;
        Children.Add(wall);
        caption = Design.Card(captionText, 28, 18);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        caption.VerticalAlignment = VerticalAlignment.Bottom;
        caption.Margin = new(0, 0, 0, 24);
        caption.Visibility = Visibility.Collapsed;
        Children.Add(caption);
        dayControls = Design.Row(20, Design.Icon("\uE76B", "Previous day", () => ShiftDay(-1), 44), dayText, Design.Text("One column per day", 13, color: Design.Muted), Design.Icon("\uE76C", "Next day", () => ShiftDay(1), 44));
        var dayPill = Design.Card(dayControls, 28, 3);
        dayPill.HorizontalAlignment = HorizontalAlignment.Center;
        dayPill.VerticalAlignment = VerticalAlignment.Bottom;
        dayPill.Margin = new(0, 0, 0, 22);
        Children.Add(dayPill);
        dayPill.PointerPressed += (_, e) => e.Handled = true;
        dayText.Tapped += (_, e) => { TimelineRequested?.Invoke(); e.Handled = true; };
        PointerMoved += (_, e) => Move(e.GetCurrentPoint(this).Position);
        PointerExited += (_, _) => { hovered = null; UpdateCaption(); };
        PointerPressed += (_, e) =>
        {
            var p = e.GetCurrentPoint(this);
            if (!p.Properties.IsLeftButtonPressed) return;
            Focus(FocusState.Pointer);
            var hit = Pick(p.Position, out var local);
            if (extracted != null)
            {
                if (hit == extracted && extraction.Value > .98)
                {
                    var artH = (extracted.Width - 40) / 1.6f;
                    var footerTop = -extracted.Size / 2 + 20 + artH + 14;
                    if (local.Y > footerTop + 42 && local.Y < footerTop + 98)
                        Act(Math.Clamp((int)((local.X + extracted.Width / 2 - 20) / ((extracted.Width - 40) / 4)), 0, 3));
                }
                else Collapse();
            }
            else if (hit?.Frame != null) Expand(hit);
            e.Handled = true;
        };
        PointerWheelChanged += (_, e) =>
        {
            if (extracted != null) return;
            var d = -e.GetCurrentPoint(this).Properties.MouseWheelDelta / 120.0;
            panTarget = Math.Clamp(panTarget + d * .9, 0, rows - 2);
            crestTarget = panTarget + d * .8; acrossTarget = 0;
            hovered = null; UpdateCaption(); Wake(); e.Handled = true;
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape && IsExpanded) { Collapse(); e.Handled = true; }
            else if (e.Key == Windows.System.VirtualKey.Enter && hovered?.Frame != null) { Expand(hovered); e.Handled = true; }
            else if (e.Key is Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down && extracted == null)
            {
                var column = sheets.Where(s => s.Lane == 0 && s.Frame != null).ToArray();
                if (column.Length == 0) return;
                var index = Array.IndexOf(column, hovered);
                hovered = column[Math.Clamp(index + (e.Key == Windows.System.VirtualKey.Down ? 1 : -1), 0, column.Length - 1)];
                crestTarget = hovered.Depth; acrossTarget = hovered.Lane; panTarget = Math.Clamp(hovered.Depth, 0, rows - 2);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, hovered.Frame!.Title + ", " + hovered.Frame.TimeLabel + ". Enter to open.");
                UpdateCaption(); Wake(); e.Handled = true;
            }
            else if (extracted != null && e.Key is Windows.System.VirtualKey.S or Windows.System.VirtualKey.C or Windows.System.VirtualKey.R)
            { Act(e.Key == Windows.System.VirtualKey.S ? 0 : e.Key == Windows.System.VirtualKey.C ? 1 : 2); e.Handled = true; }
            else if (e.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right) { ShiftDay(e.Key == Windows.System.VirtualKey.Left ? -1 : 1); e.Handled = true; }
        };
        SizeChanged += (_, _) => { Clip = new RectangleGeometry { Rect = new(0, 0, ActualWidth, ActualHeight) }; Wake(); };
        Unloaded += (_, _) => SetActive(false);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, "Rhine Lab archive. Scroll through memories, use arrow keys to change day, Enter to open and Escape to collapse.");
    }
    public async Task Refresh(DateTime? anchor = null)
    {
        var version = ++revision;
        var frames = await Task.Run(() => runtime.Store.Frames(limit: 2400));
        if (version != revision) return;
        records = frames;
        day = anchor?.Date ?? (frames.FirstOrDefault()?.Timestamp.LocalDateTime ?? DateTime.Today).Date;
        Build();
    }
    public void SetTimeline(bool visible)
    {
        timeline = visible;
        ((FrameworkElement)dayControls.Parent).Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        UpdateCaption();
    }
    public void SetActive(bool value)
    {
        active = value;
        Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        if (value) Wake(); else { Stop(); ++revision; imageLoads.Cancel(); }
    }
    public void Seek(MemoryFrame frame)
    {
        if (frame.Timestamp.LocalDateTime.Date != day) { day = frame.Timestamp.LocalDateTime.Date; Build(); }
        var sheet = sheets.FirstOrDefault(s => s.Frame?.Id == frame.Id);
        if (sheet == null) return;
        Collapse(); panTarget = Math.Clamp(sheet.Depth, 0, rows - 2);
        crestTarget = sheet.Depth; acrossTarget = sheet.Lane; Wake();
    }
    void ShiftDay(int delta) { if (extracted != null) Collapse(); day = day.AddDays(delta); Build(); }
    void Build()
    {
        imageLoads.Cancel(); imageLoads.Dispose(); imageLoads = new();
        Stop(); wall.Children.Clear(); sheets.Clear(); drawOrder.Clear(); extracted = hovered = null;
        ExpansionChanged?.Invoke(false);
        crest = new(0); across = new(0); pan = new(0); crestTarget = acrossTarget = panTarget = 0;
        extraction = new(0); extractTarget = 0;
        dayText.Text = day.ToString("MMMM d, yyyy");
        var columns = Enumerable.Range(-2, 5).ToDictionary(l => l, l => records.Where(f => f.Timestamp.LocalDateTime.Date == day.AddDays(l)).OrderByDescending(f => f.Timestamp).Take(48).ToArray());
        rows = Math.Max(20, columns.Values.Max(f => f.Length));
        foreach (var lane in Enumerable.Range(-2, 5))
            for (var row = -2; row < rows + 2; row++)
            {
                var frames = columns[lane];
                var frame = row >= 0 && row < frames.Length ? frames[row] : null;
                var depth = row - (lane == 0 ? 0 : lane < 0 ? 3.5 : 1.5);
                var root = new Canvas { Width = 0, Height = 0 };
                var glass = new Border { Width = 535, Height = 650, Background = Design.Brush(Design.Dark ? Color.FromArgb(110, 80, 83, 90) : Color.FromArgb(65, 255, 255, 255)), BorderBrush = Design.RimBrush, BorderThickness = new(1.5), CornerRadius = new(2) };
                var image = new Image { Width = 495, Height = 309.375, Stretch = Stretch.Uniform, Opacity = Design.Dark ? .78 : 1 };
                var art = new Grid { Width = 495, Height = 309.375, Background = Design.Brush(Design.Dark ? Color.FromArgb(110, 80, 83, 90) : Color.FromArgb(65, 255, 255, 255)) };
                art.Children.Add(image);
                var footer = new Grid { Width = 495, Height = 100, Background = Design.Brush(Design.Dark ? Color.FromArgb(240, 37, 40, 45) : Color.FromArgb(235, 255, 255, 255)) };
                var buttons = Design.Row(8);
                if (frame != null)
                {
                    var title = Design.Text(frame.Title, 18, true); title.MaxLines = 1; title.TextTrimming = TextTrimming.CharacterEllipsis;
                    title.Margin = new(8, 4, 210, 0); title.VerticalAlignment = VerticalAlignment.Top;
                    footer.Children.Add(title);
                    var date = Design.Text(frame.Timestamp.LocalDateTime.ToString("MMM d, yyyy  HH:mm"), 16, color: Design.Muted);
                    date.HorizontalAlignment = HorizontalAlignment.Right; date.VerticalAlignment = VerticalAlignment.Top; date.Margin = new(0, 6, 8, 0); footer.Children.Add(date);
                    foreach (var text in new[] { frame.Starred ? "★  Starred" : "☆  Star", "▢  Copy text", "↗  Rewind", "↙  Collapse" })
                    {
                        var label = Design.Text(text, 16, true); label.HorizontalAlignment = HorizontalAlignment.Center;
                        var b = Design.Card(label, 14, 8); b.Width = 116; b.Height = 44; buttons.Children.Add(b);
                    }
                    buttons.VerticalAlignment = VerticalAlignment.Bottom; buttons.Margin = new(4, 0, 4, 4); footer.Children.Add(buttons);
                }
                root.Children.Add(glass);
                if (frame != null) { root.Children.Add(art); root.Children.Add(footer); }
                var h = RhineGeometry.Height(lane, depth, 0, 0);
                var sheet = new Sheet { Root = root, Glass = glass, Art = art, Image = image, Footer = footer, Buttons = buttons, Visual = ElementCompositionPreview.GetElementVisual(root), Frame = frame, Lane = lane, Depth = depth, Height = new(h), Position = new(lane * (lane < 0 ? 5.65f : 6.25f), (float)h, (float)depth - 5) };
                Shape(sheet, 535, 650);
                sheets.Add(sheet); drawOrder.Add(sheet); wall.Children.Add(root);
            }
        reduced = !Design.Motion; UpdateCaption(); Wake();
    }
    static void Shape(Sheet s, float width, float height)
    {
        // Immutable child layout: resize the glass/art/footer with compositor
        // transforms, so the footer can never animate outside its card root.
        s.Width = width; s.Size = height;
        var artW = Math.Min(width - 40, (height - 154) * 1.6f); var artH = artW / 1.6f;
        static void Transform(UIElement e, float x, float y, float sx, float sy)
        { var v = ElementCompositionPreview.GetElementVisual(e); v.TransformMatrix = Matrix4x4.CreateScale(sx, sy, 1) * Matrix4x4.CreateTranslation(x, y, 0); }
        Transform(s.Glass, -width / 2, -height / 2, width / 535, height / 650);
        Transform(s.Art, -artW / 2, -height / 2 + 20, artW / 495, artH / 309.375f);
        Transform(s.Footer, -artW / 2, -height / 2 + 20 + artH + 14, artW / s.FooterWidth, 1);
    }
    async void Load(Sheet sheet)
    {
        if (sheet.Loading || sheet.Failed || sheet.Frame == null || sheet.Image.Source != null) return;
        sheet.Loading = true;
        var token = imageLoads.Token;
        try
        {
            var bitmap = await MemoryImages.Load(runtime.Store, sheet.Frame.ImagePath, 600, token);
            if (!token.IsCancellationRequested)
            {
                sheet.Image.Source = bitmap;
                // Dark tone must blend against black, never reveal the cards
                // behind the screenshot. Keep an empty placeholder light.
                sheet.Art.Background = Design.Brush(Microsoft.UI.Colors.Black);
            }
        }
        catch (OperationCanceledException) { }
        catch { sheet.Failed = true; /* Do not retry failed I/O every animation tick. */ }
        finally { sheet.Loading = false; }
    }
    void Move(Point point)
    {
        pointerMoves++;
        if (extracted != null) return;
        var hit = Pick(point, out _);
        if (hovered == hit) return;
        hovered = hit; hoverChanges++; UpdateCaption();
        if (hit != null) { acrossTarget = hit.Lane; crestTarget = hit.Depth; Wake(); }
    }
    Sheet? Pick(Point point, out Vector2 local)
    {
        if (extracted != null && RhineGeometry.Hit(extracted.Matrix, new((float)point.X, (float)point.Y), extracted.Width, extracted.Size, out local)) return extracted;
        local = default; Sheet? best = null; var distance = float.MaxValue;
        foreach (var s in sheets)
        {
            if (s.Frame == null || s.Distance > distance || s.Root.Visibility != Visibility.Visible) continue;
            if (!RhineGeometry.Hit(s.Matrix, new((float)point.X, (float)point.Y), s.Width, s.Size, out var p)) continue;
            distance = s.Distance; best = s; local = p;
        }
        return best;
    }
    void Expand(Sheet sheet)
    {
        if (extracted != null && extracted != sheet) return;
        expansions++;
        var span = 19.98f * (float)(ActualHeight / Math.Max(1, ActualWidth));
        var openH = Math.Min(span * .76f, ((float)ActualHeight - 296) * span / (float)ActualHeight);
        sheet.FooterWidth = Math.Max(200, Math.Min(19.98f * .88f - .4f, (openH - 1.54f) * 1.6f) * 100);
        sheet.Footer.Width = sheet.FooterWidth;
        foreach (FrameworkElement button in sheet.Buttons.Children) button.Width = Math.Max(32, (sheet.FooterWidth - 32) / 4);
        extracted = sheet; sheet.Origin = sheet.Position; extractTarget = 1; hovered = null; ExpansionChanged?.Invoke(true); UpdateCaption(); Wake();
    }
    public void Open(string id) { var s = sheets.FirstOrDefault(s => s.Frame?.Id == id); if (s != null) Expand(s); }
    public void Collapse() { if (extracted == null || extractTarget == 0) return; collapses++; extractTarget = 0; Wake(); }
    async void Act(int index)
    {
        if (extracted?.Frame is not { } frame) return;
        if (index == 0) { var sheet = extracted; await Task.Run(() => runtime.Store.Star(frame.Id)); sheet.Frame = frame with { Starred = !frame.Starred }; ((Border)sheet.Buttons.Children[0]).Child = Design.Text(sheet.Frame.Starred ? "★  Starred" : "☆  Star", 16, true); }
        else if (index == 1) { var data = new DataPackage(); data.SetText(frame.Text); Clipboard.SetContent(data); }
        else if (index == 2) rewind(frame);
        else Collapse();
    }
    void UpdateCaption()
    {
        caption.Visibility = !timeline && hovered?.Frame != null && extracted == null ? Visibility.Visible : Visibility.Collapsed;
        captionText.Text = hovered?.Frame?.Timestamp.LocalDateTime.ToString("MMM d · HH:mm") ?? "";
    }
    void Wake()
    {
        if (!active || ticking) return;
        previous = Stopwatch.GetTimestamp(); ticking = true; CompositionTarget.Rendering += Render;
    }
    void Stop() { if (!ticking) return; CompositionTarget.Rendering -= Render; ticking = false; }
    void Render(object? sender, object args)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var now = Stopwatch.GetTimestamp(); var dt = Math.Clamp((now - previous) / (double)Stopwatch.Frequency, 1.0 / 240, .05); previous = now;
        if (reduced) { crest = new(crestTarget); across = new(acrossTarget); pan = new(panTarget); extraction = new(extractTarget); }
        else { crest.Step(crestTarget, 8, dt); across.Step(acrossTarget, 7, dt); pan.Step(panTarget, 10, dt); extraction.Step(extractTarget, 6.5, dt); }
        bool moving = !crest.Settled(crestTarget) || !across.Settled(acrossTarget) || !pan.Settled(panTarget) || !extraction.Settled(extractTarget);
        var view = RhineGeometry.View((float)pan.Value); Matrix4x4.Invert(view, out var camera);
        var cameraRotation = Quaternion.CreateFromRotationMatrix(camera);
        var span = 19.98f * (float)(ActualHeight / ActualWidth);
        foreach (var s in sheets)
        {
            var wanted = RhineGeometry.Height(s.Lane, s.Depth, crest.Value, across.Value);
            if (reduced) s.Height = new(wanted); else s.Height.Step(wanted, 9 - Math.Abs(s.Lane) * .9, dt);
            moving |= !s.Height.Settled(wanted);
            var rotation = Quaternion.Identity;
            s.Position = new(s.Lane * (s.Lane < 0 ? 5.65f : 6.25f), (float)s.Height.Value, (float)s.Depth - 5);
            if (s == extracted)
            {
                var p = (float)Math.Clamp(extraction.Value, 0, 1);
                var centerY = 32 * span / (float)ActualHeight;
                var destination = Vector3.Transform(new Vector3(0, centerY, -14), camera);
                s.Position = RhineGeometry.Extract(s.Origin, destination, p);
                rotation = Quaternion.Slerp(Quaternion.Identity, cameraRotation, RhineGeometry.Smooth((p - .3f) / .65f));
                var openH = Math.Min(span * .76f, ((float)ActualHeight - 296) * span / (float)ActualHeight);
                var openW = Math.Min(19.98f * .88f, (openH - 1.54f) * 1.6f + .4f);
                var t = RhineGeometry.Smooth((p - .3f) / .7f);
                Shape(s, 535 + (openW * 100 - 535) * t, 650 + (openH * 100 - 650) * t);
                s.Buttons.Opacity = p > .98f ? 1 : 0;
            }
            else s.Buttons.Opacity = 0;
            s.Matrix = RhineGeometry.Plane(s.Position, rotation, view, (float)ActualWidth, (float)ActualHeight);
            s.Visual.TransformMatrix = RhineGeometry.Matrix(s.Matrix);
            s.Distance = -Vector3.Transform(s.Position, view).Z;
            var center = Vector2.Transform(Vector2.Zero, s.Matrix);
            var visible = center.X > -600 && center.X < ActualWidth + 600 && center.Y > -600 && center.Y < ActualHeight + 600;
            var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            if (s.Root.Visibility != visibility) s.Root.Visibility = visibility;
            s.Visual.Opacity = s == extracted ? 1 : Math.Clamp((49 - s.Distance) / 13, .12f, 1);
            if (visible) Load(s);
        }
        // A numeric depth changes on every spring tick; the relative draw
        // order usually does not. Only crossings need a XAML ZIndex update.
        drawOrder.Sort((a, b) => b.Distance.CompareTo(a.Distance));
        for (var i = 0; i < drawOrder.Count; i++)
        {
            var z = drawOrder[i] == extracted ? drawOrder.Count : i;
            if (Canvas.GetZIndex(drawOrder[i].Root) != z) Canvas.SetZIndex(drawOrder[i].Root, z);
        }
        if (extracted != null && extractTarget == 0 && extraction.Settled(0)) { extracted.FooterWidth = 495; extracted.Footer.Width = 495; foreach (FrameworkElement button in extracted.Buttons.Children) button.Width = 116; Shape(extracted, 535, 650); extracted = null; ExpansionChanged?.Invoke(false); UpdateCaption(); }
        if (!moving) Stop();
    }
}
