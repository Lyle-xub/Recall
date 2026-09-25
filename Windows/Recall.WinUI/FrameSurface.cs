using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Microsoft.UI.Input;
using Windows.System;
namespace Recall;

internal sealed class FrameSurface : Grid
{
    MemoryFrame frame; readonly Image image = new() { Stretch = Stretch.Uniform }; readonly Canvas selection = new() { IsHitTestVisible = false }; BitmapImage? bitmap;
    (int Line, int Character)? anchor, focus; bool dragging; readonly bool meeting;
    public FrameSurface(MemoryStore store, MemoryFrame frame, bool meeting = false)
    {
        this.meeting = meeting;
        frame = Display(frame);
        this.frame = frame;
        Background = Design.Brush(Color.FromArgb(245, 252, 252, 253));
        CornerRadius = new(26);
        Padding = new(8);
        IsTabStop = true;
        Design.Rounded(this, 26);
        Children.Add(image);
        Children.Add(selection);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.IBeam);
        image.ImageOpened += (_, _) => Paint();
        SizeChanged += (_, _) => Paint();
        Loaded += async (_, _) => { try { bitmap = await MemoryImages.Load(store, frame.ImagePath, 0); image.Source = bitmap; } catch (Exception ex) { if (store.Frame(frame.Id) is { } latest && latest.ImagePath != frame.ImagePath) { this.frame = latest; try { bitmap = await MemoryImages.Load(store, latest.ImagePath, 0); image.Source = bitmap; } catch { } } else Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(this, ex.Message); } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, "Recorded image. Drag across text to select; press Control C to copy.");
        PointerPressed += (_, e) => { var point = e.GetCurrentPoint(selection); if (!point.Properties.IsLeftButtonPressed) return; Focus(FocusState.Pointer); anchor = focus = Hit(point.Position); dragging = true; CapturePointer(e.Pointer); Paint(); e.Handled = true; };
        PointerMoved += (_, e) => { if (dragging) { focus = Hit(e.GetCurrentPoint(selection).Position); Paint(); e.Handled = true; } };
        PointerReleased += (_, e) => { dragging = false; ReleasePointerCaptures(); e.Handled = true; };
        PointerCaptureLost += (_, _) => dragging = false;
        DoubleTapped += (_, e) => { var hit = Hit(e.GetPosition(selection)); if (hit != null) { anchor = (hit.Value.Line, 0); focus = (hit.Value.Line, frame.Regions[hit.Value.Line].Text.Length); Paint(); } e.Handled = true; };
        KeyDown += (_, e) => { if ((InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & Windows.UI.Core.CoreVirtualKeyStates.Down) == 0) return; if (e.Key == VirtualKey.C) { Copy(); e.Handled = true; } if (e.Key == VirtualKey.A && frame.Regions.Count > 0) { anchor = (0, 0); focus = (frame.Regions.Count - 1, frame.Regions[^1].Text.Length); Paint(); e.Handled = true; } };
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = "Copy selected text" };
        copy.Click += (_, _) => Copy();
        menu.Items.Add(copy);
        var all = new MenuFlyoutItem { Text = "Copy all text" };
        all.Click += (_, _) => ClipboardText(frame.Text);
        menu.Items.Add(all);
        ContextFlyout = menu;
    }
    MemoryFrame Display(MemoryFrame value) => meeting && value.MeetingImagePath != null ? value with { ImagePath = value.MeetingImagePath, Regions = value.MeetingRegions, Text = string.Join("\n", value.MeetingRegions.Select(r => r.Text)) } : value;
    public void Update(MemoryFrame value)
    {
        value = Display(value);
        if (frame.Text != value.Text)
        {
            anchor = focus = null;
        }
        frame = value;
        Paint();
    }
    Rect ImageRect()
    {
        var width = Math.Max(1, ActualWidth - 16);
        var height = Math.Max(1, ActualHeight - 16);
        var aspect = bitmap?.PixelHeight > 0 ? (double)bitmap.PixelWidth / bitmap.PixelHeight : 16.0 / 10;
        var w = Math.Min(width, height * aspect);
        var h = w / aspect;
        return new((width - w) / 2, (height - h) / 2, w, h);
    }
    (int Line, int Character)? Hit(Point point)
    {
        if (frame.Regions.Count == 0)
            return null;
        var r = ImageRect();
        var x = (point.X - r.X) / r.Width;
        var y = (point.Y - r.Y) / r.Height;
        var best = frame.Regions.Select((region, i) => (region, i, Distance: Math.Abs(y - (region.Y + region.Height / 2)) + (x < region.X ? region.X - x : x > region.X + region.Width ? x - region.X - region.Width : 0) * .15)).MinBy(v => v.Distance);
        var character = (int)Math.Round(Math.Clamp((x - best.region.X) / Math.Max(.001, best.region.Width), 0, 1) * best.region.Text.Length);
        return (best.i, character);
    }
    ((int Line, int Character) Start, (int Line, int Character) End)? Range()
    {
        if (anchor == null || focus == null)
            return null;
        return anchor.Value.CompareTo(focus.Value) <= 0 ? (anchor.Value, focus.Value) : (focus.Value, anchor.Value);
    }
    string Selected()
    {
        var range = Range();
        if (range == null)
            return "";
        var (a, b) = range.Value;
        return string.Join("\n", Enumerable.Range(a.Line, b.Line - a.Line + 1).Select(i => { var text = frame.Regions[i].Text; var start = i == a.Line ? a.Character : 0; var end = i == b.Line ? b.Character : text.Length; return text[start..end]; }));
    }
    void Copy()
    {
        var text = Selected();
        if (text.Length > 0)
            ClipboardText(text);
    }
    internal static void ClipboardText(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }
    void Paint()
    {
        var imageRect = ImageRect();
        var visual = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(image);
        var shape = visual.Compositor.CreateRoundedRectangleGeometry();
        shape.Size = new((float)imageRect.Width, (float)imageRect.Height);
        shape.Offset = new((float)imageRect.X, (float)imageRect.Y);
        shape.CornerRadius = new(20);
        visual.Clip = visual.Compositor.CreateGeometricClip(shape);
        selection.Children.Clear();
        var range = Range();
        if (range == null)
            return;
        var (a, b) = range.Value;
        var r = ImageRect();
        for (var i = a.Line; i <= b.Line; i++)
        {
            var region = frame.Regions[i];
            var start = i == a.Line ? a.Character : 0;
            var end = i == b.Line ? b.Character : region.Text.Length;
            if (end <= start)
                continue;
            double unit = region.Width / Math.Max(1, region.Text.Length);
            var rect = new Border { Width = (end - start) * unit * r.Width, Height = region.Height * r.Height, CornerRadius = new(2), Background = Design.Brush(Color.FromArgb(95, 109, 171, 239)) };
            Canvas.SetLeft(rect, r.X + (region.X + start * unit) * r.Width);
            Canvas.SetTop(rect, r.Y + region.Y * r.Height);
            selection.Children.Add(rect);
        }
    }
}
