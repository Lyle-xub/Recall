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

/// A bounded, velocity-continuous transition. Unlike the infinite spring tail,
/// completion coincides with the visible arrival and can release input immediately.
internal struct RhineTransition(double value)
{
    public double Value = value, Velocity;
    double start = value, startVelocity, target = value, elapsed, duration;
    public bool Settled(double destination) => target == destination && elapsed >= duration;
    public void Step(double destination, double dt)
    {
        if (destination != target)
        {
            start = Value; target = destination; elapsed = 0;
            duration = .44 + .18 * Math.Abs(target - start);
            startVelocity = Math.Clamp(Velocity, -3 * start / duration, 3 * (1 - start) / duration);
        }
        if (duration == 0 || (elapsed += dt) >= duration) { Value = target; Velocity = 0; return; }
        var t = elapsed / duration; var t2 = t*t; var t3 = t2*t;
        Value = (2*t3-3*t2+1)*start + (t3-2*t2+t)*duration*startVelocity + (-2*t3+3*t2)*target;
        Velocity = ((6*t2-6*t)*start + (3*t2-4*t+1)*duration*startVelocity + (-6*t2+6*t)*target)/duration;
    }
}

/// Mac glassTexture's four vertical stops, blended continuously across lanes.
internal static class RhineTone
{
    public static Vector4 Stop(int lane, int stop, bool dark)
    {
        var across = Math.Clamp((lane + 2) / 4f, 0, 1);
        if (dark) return stop switch
        {
            0 => Vector4.Lerp(new(.10f,.095f,.09f,.28f),new(.08f,.11f,.15f,.28f),across),
            1 => new(.20f,.21f,.23f,.13f),
            2 => Vector4.Lerp(new(.07f,.08f,.10f,.38f),new(.07f,.15f,.23f,.38f),across),
            _ => new(.36f,.38f,.41f,.32f)
        };
        return stop switch
        {
            0 => Vector4.Lerp(new(.78f,.77f,.71f,.25f),new(.76f,.78f,.77f,.25f),across),
            1 => new(.62f,.67f,.70f,.11f),
            2 => Vector4.Lerp(new(.40f,.43f,.49f,.28f),new(.46f,.59f,.70f,.31f),across),
            _ => new(.82f,.82f,.82f,.35f)
        };
    }
}

/// Shared projection for composition transforms and pointer picking. Units and
/// critically damped motion match macOS ArchiveRidgeMotion/ArchiveGlassScene.
internal static class RhineGeometry
{
    // Rows are slightly closer than the original one-unit rack pitch. This
    // exposes more real photographs in the viewport without shrinking cards.
    public const float RowPitch = .82f;
    public static float Depth(int row, int lane) => (row - (lane == 0 ? 0 : lane < 0 ? 3.5f : 1.5f)) * RowPitch;
    public static float LastScroll(int rows) => Math.Max(0, rows - 2) * RowPitch;
    public const float ArtBaseWidth = 495, FooterBaseHeight = 54;
    const float CardInset = 12, ContentGap = 10;
    internal readonly record struct CardLayout(float Width, float Height, float ArtWidth, float ArtHeight)
    {
        public float ArtLeft => -ArtWidth / 2;
        public float ArtTop => -Height / 2 + CardInset;
        public float FooterTop => ArtTop + ArtHeight + ContentGap;
        public float FooterScale => ArtWidth / ArtBaseWidth;
        public float FooterHeight => FooterBaseHeight * FooterScale;
    }

    public static CardLayout Layout(float width, float height, float aspect)
    {
        aspect = Math.Clamp(aspect, .2f, 5);
        var artWidth = Math.Max(1, Math.Min(width - 2 * CardInset,
            (height - 2 * CardInset - ContentGap) / (1 / aspect + FooterBaseHeight / ArtBaseWidth)));
        return new(width, height, artWidth, artWidth / aspect);
    }

    public static (float Width, float Height) ExpandedSize(float aspect, float viewportWidth, float viewportHeight) =>
        ExpandedSize(aspect, viewportWidth, viewportHeight, 0, 0);

    public static (float Width, float Height) ExpandedSize(float aspect, float viewportWidth,
        float viewportHeight, float topInset, float bottomInset)
    {
        aspect = Math.Clamp(aspect, .2f, 5);
        // Card-local coordinates are scaled by .01 world units per unit in
        // Plane(), then projected at viewportWidth / 19.98 pixels per world
        // unit. Reserve the actual controls before choosing the card size.
        var localPerPixel = 19.98f * 100 / Math.Max(1, viewportWidth);
        var availableHeight = Math.Max(1, viewportHeight - topInset - bottomInset - 24);
        var maxHeight = availableHeight * localPerPixel;
        var maxWidth = Math.Max(1, viewportWidth * .88f) * localPerPixel;
        var artWidth = Math.Max(1, Math.Min(maxWidth - 2 * CardInset,
            (maxHeight - 2 * CardInset - ContentGap) / (1 / aspect + FooterBaseHeight / ArtBaseWidth)));
        const float macPresentationScale = .82f;
        return ((artWidth + 2 * CardInset) * macPresentationScale,
            (artWidth / aspect + FooterBaseHeight * artWidth / ArtBaseWidth + 2 * CardInset + ContentGap) * macPresentationScale);
    }

    public static float ExpandedCenterShift(float topInset, float bottomInset) =>
        (topInset - bottomInset) / 2;

    // Buttons are painted in the card plane. Outside the wall, the transparent
    // input proxy uses this same affine map only after the card has settled.
    public static Matrix3x2 FooterMatrix(CardLayout layout, Matrix3x2 cardMatrix) =>
        Matrix3x2.CreateScale(layout.FooterScale) *
        Matrix3x2.CreateTranslation(layout.ArtLeft, layout.FooterTop) * cardMatrix;

    public static float ActionBlend(float extraction) => Smooth((extraction - .18f) / .26f);

    // The home sheet is always opaque in its normal depth order. Only its
    // decorative front copy fades, so an unoccluded image pixel never fades out
    // and back in while the card crosses a neighboring sheet.
    public static float FrontBlend(float extraction) => Smooth(extraction / .65f);

    public static float FooterScreenScale(CardLayout layout, Matrix3x2 cardMatrix) =>
        layout.FooterScale * MathF.Sqrt(cardMatrix.M11 * cardMatrix.M11 + cardMatrix.M12 * cardMatrix.M12);

    public static Matrix3x2 SnapFacingPlane(Matrix3x2 matrix, CardLayout layout, float rasterizationScale)
    {
        var x = MathF.Sqrt(matrix.M11*matrix.M11 + matrix.M12*matrix.M12);
        var y = MathF.Sqrt(matrix.M21*matrix.M21 + matrix.M22*matrix.M22);
        matrix.M11 = matrix.M11 < 0 ? -x : x;
        matrix.M12 = matrix.M21 = 0;
        matrix.M22 = matrix.M22 < 0 ? -y : y;
        // Pixel-align the visible footer origin, including at noninteger DPI.
        var footer = FooterMatrix(layout, matrix);
        var dpi = Math.Max(.1f, rasterizationScale);
        matrix.M31 += MathF.Round(footer.M31*dpi)/dpi - footer.M31;
        matrix.M32 += MathF.Round(footer.M32*dpi)/dpi - footer.M32;
        return matrix;
    }

    public static (Vector2 Origin, Vector2 Edge) FooterProjection(CardLayout layout, Matrix3x2 matrix)
    {
        var footer = FooterMatrix(layout, matrix);
        var origin = Vector2.Transform(Vector2.Zero, footer);
        var end = Vector2.Transform(new(ArtBaseWidth, 0), footer);
        return (origin, end - origin);
    }
    public static int DepthOrder(float firstDistance, float secondDistance) =>
        secondDistance.CompareTo(firstDistance);

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
        // One continuous curve: two separately eased segments stopped at their
        // join on every return, even when the frame scheduler was perfectly smooth.
        var t = Math.Clamp(p,0,1); var u = 1-t;
        return u*u*u*origin + 3*u*u*t*(origin+new Vector3(0,.85f,3.4f))
            + 3*u*t*t*(destination+new Vector3(0,.8f,-1.2f)) + t*t*t*destination;
    }
    public static Matrix4x4 View(float scroll) => Matrix4x4.CreateLookAt(Camera + new Vector3(0, 0, scroll), Target + new Vector3(0, 0, scroll), Vector3.UnitY);
    public static Vector2 Project(Vector3 point, Matrix4x4 view, float width, float height)
    {
        var p = Vector3.Transform(point, view); var scale = width / 19.98f;
        return new(width / 2 + p.X * scale, height / 2 - p.Y * scale);
    }
    // A conservative row window avoids visiting thousands of off-screen
    // records on every motion tick. The exact card bounds are checked by the
    // caller before creating XAML or Composition objects.
    public static (int First, int Last) CandidateRows(Matrix4x4 view, float width, float height, int rows, float dragY = 0)
    {
        if (width <= 0 || height <= 0) return (0, -1);
        var y0 = Project(new(0, 0, -5), view, width, height).Y;
        var pitch = Project(new(0, 0, -4), view, width, height).Y - y0;
        if (Math.Abs(pitch) < .01f) return (0, -1);
        var center = (height / 2 - y0 - dragY) / (pitch * RowPitch);
        // Includes a full tilted card, the ridge height, lane offsets and a
        // 160 px prefetch margin even at a narrow/high-DPI logical viewport.
        var radius = (height / 2 + width * .9f + 240) / Math.Abs(pitch * RowPitch) + 5;
        return (Math.Max(-16, (int)Math.Floor(center - radius)),
            Math.Min(rows + 3, (int)Math.Ceiling(center + radius)));
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
