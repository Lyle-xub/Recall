namespace Recall;

/// Same logical geometry and synthetic pattern as macOS/Tools/MaterialReference.swift.
/// Only mounted by --visual-parity, never the normal UI.
internal sealed class MaterialReferenceView : Canvas
{
    public MaterialReferenceView(bool desktop)
    {
        if (!desktop)
        {
            Children.Add(new Rectangle { Width = 1280, Height = 800, Fill = Design.Brush(Color.FromArgb(255, 227, 232, 237)) });
            Color[] colors = [Color.FromArgb(255, 69, 133, 212), Color.FromArgb(255, 207, 102, 125), Color.FromArgb(255, 235, 186, 89), Color.FromArgb(255, 82, 171, 148)];
            for (var i = 0; i < 16; i++) Put(new Rectangle { Width = 40, Height = 800, Fill = Design.Brush(colors[i % 4]) }, i * 80, 0);
            for (var y = 100; y < 800; y += 160) Put(new Rectangle { Width = 1280, Height = 3, Fill = Design.Brush(Color.FromArgb(153, 0, 0, 0)) }, 0, y);
        }
        Surface(Design.Text("Search memories", 20), 130, 24, 620, 64, 32);
        string[] glyphs = ["\uE71D", "\uE734", "\uE945", "\uE9D9", "\uE713"];
        for (int i = 0; i < 5; i++) Surface(Design.Symbol(glyphs[i]), 766 + i * 80, 24, 64, 64, 32);
        Surface(Design.Text("Starred", 15, true), 40, 132, 140, 52, 26);
        foreach (var x in new[] { 40, 460, 880 }) Surface(new Grid(), x, 224, 360, 380, 29);
        Surface(Design.Text("September 26, 2026      One day per column", 16), 400, 708, 480, 54, 27);
    }
    void Surface(FrameworkElement content, double x, double y, double width, double height, double radius)
    {
        content.HorizontalAlignment = HorizontalAlignment.Center; content.VerticalAlignment = VerticalAlignment.Center;
        var border = Design.Card(content, radius, 0); border.Width = width; border.Height = height; Put(border, x, y);
    }
    void Put(FrameworkElement element, double x, double y) { SetLeft(element, x); SetTop(element, y); Children.Add(element); }
}
