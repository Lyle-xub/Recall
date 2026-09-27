using Recall;

internal static class VideoOrientationTests
{
    internal static void Run(Action<bool, string> check)
    {
        const int width = 160, height = 100;
        var upright = new byte[width * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
                upright[y * width + x] = (byte)((x * 3 + y * 7 +
                    (x < 35 && y < 20 ? 91 : 0) +
                    (x > 112 && y > 67 ? 63 : 0) +
                    ((x / 14 + y / 12) % 2 == 0 ? 34 : 0)) % 256);

        for (var turn = 0; turn < 4; turn++)
        {
            var (rotated, rotatedWidth, rotatedHeight) = Rotate(upright, width, height, turn);
            var match = VideoOrientation.Match(upright, width, height, rotated, rotatedWidth, rotatedHeight, 0);
            check(match.Confident && match.SelectedSteps == (4 - turn) % 4,
                $"A decoded frame rotated {turn * 90} degrees aligns to its captured still");
        }
        var restored = VideoOrientation.OutputSize(720, 450, 3, 16d / 10, 0);
        check(Math.Abs(restored.Width / restored.Height - 1.6) < .001,
            "A squeezed sideways capture returns to the still's landscape aspect after correction");
        var manuallyTurned = VideoOrientation.OutputSize(720, 450, 0, 16d / 10, 1);
        check(Math.Abs(manuallyTurned.Width / manuallyTurned.Height - .625) < .001,
            "Manual rotation after alignment intentionally swaps the fitted aspect");
        var blank = new byte[width * height];
        Array.Fill(blank, (byte)120);
        check(!VideoOrientation.Match(blank, width, height, upright, width, height, 2).Confident &&
              VideoOrientation.Match(blank, width, height, upright, width, height, 2).SelectedSteps == 2,
            "An uninformative still keeps the metadata fallback");
        var unrelated = new byte[width * height];
        new Random(42).NextBytes(unrelated);
        var weak = VideoOrientation.Match(upright, width, height, unrelated, width, height, 3);
        check(!weak.Confident && weak.SelectedSteps == 3,
            "An unrelated frame cannot override the metadata/manual fallback");
    }

    private static (byte[] Pixels, int Width, int Height) Rotate(byte[] source, int width, int height, int steps)
    {
        var outputWidth = steps % 2 == 0 ? width : height;
        var outputHeight = steps % 2 == 0 ? height : width;
        var output = new byte[outputWidth * outputHeight];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var dx = steps switch { 1 => height - 1 - y, 2 => width - 1 - x, 3 => y, _ => x };
                var dy = steps switch { 1 => x, 2 => height - 1 - y, 3 => width - 1 - x, _ => y };
                output[dy * outputWidth + dx] = source[y * width + x];
            }
        return (output, outputWidth, outputHeight);
    }
}
