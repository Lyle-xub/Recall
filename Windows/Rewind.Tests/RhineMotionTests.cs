using System.Numerics;
using Recall;

static class RhineMotionTests
{
    public static void Run(Action<bool, string> assert)
    {
        // Event frequency must not change the trajectory, including a retarget
        // while moving. This catches Euler integration spikes after slow frames.
        var fast = new RhineSpring(0); var slow = new RhineSpring(0);
        for (var i = 0; i < 120; i++) fast.Step(5, 8, 1.0 / 120);
        for (var i = 0; i < 20; i++) slow.Step(5, 8, .05);
        assert(Math.Abs(fast.Value - slow.Value) < 1e-10, "Rhine motion is independent of display frequency");
        for (var i = 0; i < 60; i++) fast.Step(-2, 8, 1.0 / 60);
        for (var i = 0; i < 20; i++) slow.Step(-2, 8, .05);
        assert(Math.Abs(fast.Value - slow.Value) < 1e-10, "Rhine retarget preserves velocity");
        foreach (var scroll in new[] { 0f, 6f, 18f })
        {
            var view = RhineGeometry.View(scroll);
            Matrix4x4.Invert(view, out var camera);
            foreach (var rotation in new[] { Quaternion.Identity, Quaternion.CreateFromRotationMatrix(camera) })
            {
                var plane = RhineGeometry.Plane(new(6.25f, 2.1f, scroll - 5), rotation, view, 1280, 800);
                foreach (var local in new[] { Vector2.Zero, new(266, 324), new(-266, -324) })
                {
                    var pointer = Vector2.Transform(local, plane);
                    assert(RhineGeometry.Hit(plane, pointer, 535, 650, out var hit) && Vector2.Distance(hit, local) < .01, "Rhine visual and hit coordinates agree after scrolling and extraction");
                }
                assert(!RhineGeometry.Hit(plane, Vector2.Transform(new Vector2(270, 0), plane), 535, 650, out _), "Rhine picking rejects points beyond the sheet edge");
            }
        }
        var origin = new Vector3(1, 2, 3); var destination = new Vector3(10, 12, 14);
        assert(Vector3.Distance(RhineGeometry.Extract(origin, destination, 0), origin) < .001, "Collapse returns to its original card position");
        assert(Vector3.Distance(RhineGeometry.Extract(origin, destination, 1), destination) < .001, "Extraction ends at its safe-area center");
    }
}
