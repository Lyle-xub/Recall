using System.Numerics;

namespace Recall;

internal struct RhineSpring(double value)
{
    public double Value = value;
    public double Velocity;
    public bool Settled(double target) => Math.Abs(Value - target) < .0004 && Math.Abs(Velocity) < .003;
    public void Step(double target, double frequency, double dt)
    {
        var displacement = Value - target;
        var c = Velocity + frequency * displacement;
        var decay = Math.Exp(-frequency * dt);
        Value = target + (displacement + c * dt) * decay;
        Velocity = (Velocity - frequency * c * dt) * decay;
    }
}

/// Shared projection for composition transforms and pointer picking. Units and
/// critically damped motion match macOS ArchiveRidgeMotion/ArchiveGlassScene.
internal static class RhineGeometry
{
    public static readonly Vector3 Camera = new(-12.9f, 17.7f, 22.2f), Target = new(-1.9f, 5.4f, .2f);
    public static double Height(double lane, double depth, double crest, double across)
    {
        var x = lane - across; var d = depth - crest - Math.Abs(x) * .42;
        return -1.35 + (lane < 0 ? .4 : lane > 0 ? -.35 : 0)
            + 2.1 * Math.Exp(-x * x / 2) * Math.Exp(-d * d / (2 * 5.3 * 5.3))
            + 1.9 * Math.Exp(-x * x / .48) * Math.Exp(-d * d / (2 * .85 * .85));
    }
    public static float Smooth(float p) { p = Math.Clamp(p, 0, 1); return p * p * (3 - 2 * p); }
    public static Vector3 Extract(Vector3 origin, Vector3 destination, float p)
    {
        var clearance = origin + new Vector3(0, .85f, 3.4f);
        if (p <= .34f) return Vector3.Lerp(origin, clearance, Smooth(p / .34f));
        var t = Smooth((p - .34f) / .66f); var u = 1 - t;
        return u * u * u * clearance + 3 * u * u * t * (clearance + new Vector3(0, .15f, 2)) + 3 * u * t * t * (destination + new Vector3(0, .8f, -1.2f)) + t * t * t * destination;
    }
    public static Matrix4x4 View(float scroll) => Matrix4x4.CreateLookAt(Camera + new Vector3(0, 0, scroll), Target + new Vector3(0, 0, scroll), Vector3.UnitY);
    public static Vector2 Project(Vector3 point, Matrix4x4 view, float width, float height)
    {
        var p = Vector3.Transform(point, view); var scale = width / 19.98f;
        return new(width / 2 + p.X * scale, height / 2 - p.Y * scale);
    }
    public static Matrix3x2 Plane(Vector3 origin, Quaternion rotation, Matrix4x4 view, float width, float height)
    {
        var p = Project(origin, view, width, height);
        var x = Project(origin + Vector3.Transform(new Vector3(.01f, 0, 0), rotation), view, width, height) - p;
        var y = Project(origin + Vector3.Transform(new Vector3(0, -.01f, 0), rotation), view, width, height) - p;
        return new(x.X, x.Y, y.X, y.Y, p.X, p.Y);
    }
    public static Matrix4x4 Matrix(Matrix3x2 m) => new(m.M11, m.M12, 0, 0, m.M21, m.M22, 0, 0, 0, 0, 1, 0, m.M31, m.M32, 0, 1);
    public static bool Hit(Matrix3x2 matrix, Vector2 pointer, float width, float height, out Vector2 local)
    {
        local = default;
        if (!Matrix3x2.Invert(matrix, out var inverse)) return false;
        local = Vector2.Transform(pointer, inverse);
        return local.X >= -width / 2 && local.X <= width / 2 && local.Y >= -height / 2 && local.Y <= height / 2;
    }
}
