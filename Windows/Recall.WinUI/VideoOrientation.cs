namespace Recall;

internal static class VideoOrientation
{
    internal readonly record struct MatchResult(int SelectedSteps, int BestSteps, double Score, double Margin, bool Confident);

    internal static (double Width, double Height) OutputSize(double sourceWidth, double sourceHeight,
        int totalSteps, double alignedAspect, int manualSteps)
    {
        var turned = Math.Abs(totalSteps % 2) == 1;
        if (alignedAspect <= 0)
            return turned ? (sourceHeight, sourceWidth) : (sourceWidth, sourceHeight);
        var targetAspect = Math.Abs(manualSteps % 2) == 1 ? 1 / alignedAspect : alignedAspect;
        var area = sourceWidth * sourceHeight;
        return (Math.Sqrt(area * targetAspect), Math.Sqrt(area / targetAspect));
    }

    // Recall's video and still capture the same display. Undo a quarter-turn
    // metadata tag only when the recorded still agrees with the unrotated aspect.
    // Ambiguous media keeps the decoder's orientation and offers manual rotation.
    internal static int Correction(int metadataDegrees, double stillAspect, double presentedAspect)
    {
        if (metadataDegrees is not (90 or 270) || stillAspect <= 0 || presentedAspect <= 0) return 0;
        if (System.Math.Abs(presentedAspect / stillAspect - 1) < .2) return 0;
        if (System.Math.Abs(1 / presentedAspect / stillAspect - 1) > .15) return 0;
        return metadataDegrees == 90 ? 3 : 1;
    }

    // The capture still and the video frame depict the same display. Compare
    // them locally once, after seeking to that still's timestamp. This catches
    // files whose pixels are turned but whose MP4 rotation matrix is identity.
    // A weak or ambiguous match leaves the metadata/manual fallback unchanged.
    internal static MatchResult Match(byte[] still, int stillWidth, int stillHeight,
        byte[] decoded, int decodedWidth, int decodedHeight, int fallbackSteps)
    {
        fallbackSteps = ((fallbackSteps % 4) + 4) % 4;
        var fallback = new MatchResult(fallbackSteps, fallbackSteps, 0, 0, false);
        if (stillWidth <= 0 || stillHeight <= 0 || decodedWidth <= 0 || decodedHeight <= 0 ||
            still.Length < (long)stillWidth * stillHeight || decoded.Length < (long)decodedWidth * decodedHeight)
            return fallback;

        var reference = Sample(still, stillWidth, stillHeight, 0);
        if (Variance(reference) < 64) return fallback;
        var referenceEdges = Edges(reference);
        var scores = new double[4];
        for (var steps = 0; steps < 4; steps++)
        {
            var candidate = Sample(decoded, decodedWidth, decodedHeight, steps);
            scores[steps] = .7 * Correlation(reference, candidate) +
                            .3 * Correlation(referenceEdges, Edges(candidate));
        }
        var best = Array.IndexOf(scores, scores.Max());
        var runnerUp = scores.Where((_, index) => index != best).Max();
        var margin = scores[best] - runnerUp;
        var confident = scores[best] >= .62 && margin >= .10;
        return new(confident ? best : fallbackSteps, best, scores[best], margin, confident);
    }

    private static double[] Sample(byte[] pixels, int width, int height, int steps)
    {
        const int side = 32;
        var result = new double[side * side];
        for (var y = 0; y < side; y++)
            for (var x = 0; x < side; x++)
            {
                var u = (x + .5) / side;
                var v = (y + .5) / side;
                var sourceU = steps switch { 1 => v, 2 => 1 - u, 3 => 1 - v, _ => u };
                var sourceV = steps switch { 1 => 1 - u, 2 => 1 - v, 3 => u, _ => v };
                var column = Math.Clamp((int)(sourceU * width), 0, width - 1);
                var row = Math.Clamp((int)(sourceV * height), 0, height - 1);
                result[y * side + x] = pixels[row * width + column];
            }
        return result;
    }

    private static double[] Edges(double[] pixels)
    {
        const int side = 32;
        var result = new double[(side - 1) * (side - 1)];
        for (var y = 0; y < side - 1; y++)
            for (var x = 0; x < side - 1; x++)
            {
                var at = y * side + x;
                result[y * (side - 1) + x] = Math.Abs(pixels[at] - pixels[at + 1]) +
                                                Math.Abs(pixels[at] - pixels[at + side]);
            }
        return result;
    }

    private static double Variance(double[] values)
    {
        var mean = values.Average();
        return values.Sum(value => (value - mean) * (value - mean)) / values.Length;
    }

    private static double Correlation(double[] left, double[] right)
    {
        var leftMean = left.Average();
        var rightMean = right.Average();
        double cross = 0, leftEnergy = 0, rightEnergy = 0;
        for (var index = 0; index < left.Length; index++)
        {
            var a = left[index] - leftMean;
            var b = right[index] - rightMean;
            cross += a * b;
            leftEnergy += a * a;
            rightEnergy += b * b;
        }
        return leftEnergy > 1 && rightEnergy > 1 ? cross / Math.Sqrt(leftEnergy * rightEnergy) : 0;
    }
}
