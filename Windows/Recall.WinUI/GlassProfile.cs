namespace Recall;

/// Geometry shared with macOS TimelineBlurProfile. No platform dependencies.
internal static class GlassProfile
{
    public static double TimelineOpacity(double fraction)
    {
        var t = System.Math.Clamp((fraction - .18) / .82, 0, 1);
        return t * t * t * (t * (t * 6 - 15) + 10);
    }
}
