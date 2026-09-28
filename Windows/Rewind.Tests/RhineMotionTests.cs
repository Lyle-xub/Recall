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
        var candidateWindowCoversVisibleCards = true;
        foreach (var (width, height) in new[] { (420f, 780f), (800f, 600f), (1280f, 800f), (1920f, 1080f) })
            foreach (var scroll in new[] { 0f, 8f, 60f, 180f })
                foreach (var dragY in new[] { -900f, 0f, 900f })
                {
                    var view = RhineGeometry.View(scroll);
                    var (first, last) = RhineGeometry.CandidateRows(view, width, height, 240, dragY);
                    for (var lane = -2; lane <= 2; lane++)
                        for (var row = -16; row < 244; row++)
                        {
                            var depth = RhineGeometry.Depth(row, lane);
                            var heightAtRow = RhineGeometry.Height(lane, depth, scroll, 0);
                            var position = new Vector3(lane * (lane < 0 ? 5.65f : 6.25f), (float)heightAtRow, (float)depth - 5);
                            var plane = RhineGeometry.Plane(position, Quaternion.Identity, view, width, height);
                            var center = Vector2.Transform(Vector2.Zero, plane) + new Vector2(0, dragY);
                            var extentX = (Math.Abs(plane.M11) * 535 + Math.Abs(plane.M21) * 650) / 2;
                            var extentY = (Math.Abs(plane.M12) * 535 + Math.Abs(plane.M22) * 650) / 2;
                            var visible = center.X + extentX > -160 && center.X - extentX < width + 160 &&
                                center.Y + extentY > -160 && center.Y - extentY < height + 160;
                            if (visible) candidateWindowCoversVisibleCards &= row >= first && row <= last;
                        }
                }
        assert(candidateWindowCoversVisibleCards, "Lazy row window contains every projected card, including narrow windows and deep seeks");
        int VisibleRows(float pitch)
        {
            var view = RhineGeometry.View(8);
            var count = 0;
            for (var row = 0; row < 50; row++)
            {
                var depth = row * pitch;
                var heightAtRow = RhineGeometry.Height(0, depth, 8, 0);
                var plane = RhineGeometry.Plane(new(0, (float)heightAtRow, depth - 5), Quaternion.Identity, view, 1280, 800);
                var center = Vector2.Transform(Vector2.Zero, plane);
                var extentY = (Math.Abs(plane.M12) * 535 + Math.Abs(plane.M22) * 650) / 2;
                if (center.Y + extentY > 0 && center.Y - extentY < 800) count++;
            }
            return count;
        }
        assert(Math.Abs(RhineGeometry.RowPitch - 1) < 1e-6 && VisibleRows(RhineGeometry.RowPitch) == VisibleRows(1),
            "Rhine uses the same one-unit rack pitch as the macOS archive scene");
        var origin = new Vector3(1, 2, 3); var destination = new Vector3(10, 12, 14);
        assert(Vector3.Distance(RhineGeometry.Extract(origin, destination, 0), origin) < .001, "Collapse returns to its original card position");
        assert(Vector3.Distance(RhineGeometry.Extract(origin, destination, 1), destination) < .001, "Extraction ends at its safe-area center");
        var beforeJoin = (RhineGeometry.Extract(origin,destination,.34f)-RhineGeometry.Extract(origin,destination,.339f))/.001f;
        var afterJoin = (RhineGeometry.Extract(origin,destination,.341f)-RhineGeometry.Extract(origin,destination,.34f))/.001f;
        assert(beforeJoin.Length() > 1 && afterJoin.Length() > 1, "Extraction does not stop at the former two-stage join");
        assert(Vector3.Distance(beforeJoin,afterJoin) < .15, "Return path has continuous velocity through its middle");
        var quick = new RhineTransition(1); var slowReturn = new RhineTransition(1);
        for (var i=0;i<72;i++) quick.Step(0,1.0/120);
        for (var i=0;i<12;i++) slowReturn.Step(0,.05);
        assert(Math.Abs(quick.Value-slowReturn.Value)<1e-10, "Bounded return is independent of refresh rate");
        quick.Step(0,.05); slowReturn.Step(0,.05);
        assert(quick.Settled(0) && slowReturn.Settled(0) && quick.Value == 0 && quick.Velocity == 0, "Return and input cleanup finish within 650 ms without a spring tail");
        var interrupted = new RhineTransition(0); interrupted.Step(1,.18);
        var savedValue = interrupted.Value; var savedVelocity = interrupted.Velocity;
        interrupted.Step(0,0);
        assert(Math.Abs(savedValue-interrupted.Value)<1e-10 && Math.Abs(savedVelocity-interrupted.Velocity)<1e-10, "Interrupted extraction preserves position and velocity");
        var bounded = true;
        for (var i=0;i<100;i++) { interrupted.Step(i<30?0:1,.01); bounded &= interrupted.Value>=0 && interrupted.Value<=1; }
        assert(bounded && interrupted.Settled(1), "Repeated reversal remains inside the card transition range");
        var onePlane = true; var noFooterOverflow = true; var continuousActions = true;
        var macLikePhoto = true;
        foreach (var (width, height) in new[] { (800f, 600f), (1280f, 800f), (1920f, 1080f) })
            foreach (var aspect in new[] { .75f, 1.6f, 16f / 9 })
            {
                var (openWidth, openHeight) = RhineGeometry.ExpandedSize(aspect,width,height);
                var final = RhineGeometry.Layout(openWidth,openHeight,aspect);
                macLikePhoto &= final.ArtWidth / openWidth > .95f;
                if (aspect == 1.6f) macLikePhoto &= final.ArtHeight / openHeight > .80f;
                var plane = RhineGeometry.Plane(new(0, 0, -14), Quaternion.Identity, RhineGeometry.View(0), width, height);
                var previousAction = 0f;
                for (var i = 0; i <= 100; i++)
                {
                    var p = i / 100f;
                    var sizeBlend = RhineGeometry.Smooth((p - .3f) / .7f);
                    var layout = RhineGeometry.Layout(535 + (openWidth - 535) * sizeBlend,
                        650 + (openHeight - 650) * sizeBlend,aspect);
                    var footer = RhineGeometry.FooterMatrix(layout,plane);
                    var top = Vector2.Transform(Vector2.Zero,footer);
                    var right = Vector2.Transform(new(RhineGeometry.ArtBaseWidth,0),footer);
                    var bottom = Vector2.Transform(new(0,RhineGeometry.FooterBaseHeight),footer);
                    var artBottom = Vector2.Transform(new(layout.ArtLeft,layout.ArtTop+layout.ArtHeight),plane);
                    onePlane &= Vector2.Distance(top,Vector2.Transform(new(layout.ArtLeft,layout.FooterTop),plane)) < .002f
                        && Vector2.Distance(right,Vector2.Transform(new(-layout.ArtLeft,layout.FooterTop),plane)) < .002f
                        && Vector2.Distance(bottom,Vector2.Transform(new(layout.ArtLeft,layout.FooterTop+layout.FooterHeight),plane)) < .002f
                        && Vector2.Distance(top,artBottom+Vector2.TransformNormal(new(0,10),plane)) < .002f;
                    noFooterOverflow &= layout.FooterTop+layout.FooterHeight <= layout.Height/2+.01f;
                    var action = RhineGeometry.ActionBlend(p);
                    continuousActions &= action >= previousAction && action >= 0 && action <= 1 &&
                        action-previousAction < .07f;
                    previousAction = action;
                }
            }
        assert(onePlane, "Artwork, information strip and action targets use one projected card plane throughout extraction");
        assert(noFooterOverflow && macLikePhoto, "Expanded screenshot nearly fills its card while the complete footer remains inside it");
        var fitsChrome = true;
        var timelineShrinksCard = true;
        foreach (var (width, height) in new[] { (800f,600f), (960f,640f), (1280f,800f), (1920f,1080f) })
        {
            var topInset = 104f;
            var dateBottom = 72f;
            var timelineBottom = 246f;
            var view = RhineGeometry.View(0);
            Matrix4x4.Invert(view,out var camera);
            var safeDestination = Vector3.Transform(new Vector3(0,0,-14),camera);
            var plane = RhineGeometry.Plane(safeDestination,Quaternion.CreateFromRotationMatrix(camera),view,width,height);
            foreach (var bottomInset in new[] { dateBottom,timelineBottom })
                foreach (var aspect in new[] { .75f,1.6f,16f/9 })
                {
                    var (cardWidth,cardHeight) = RhineGeometry.ExpandedSize(aspect,width,height,topInset,bottomInset);
                    var shifted = plane;
                    shifted.M32 += RhineGeometry.ExpandedCenterShift(topInset,bottomInset);
                    var corners = new[] { new Vector2(-cardWidth/2,-cardHeight/2),
                        new Vector2(cardWidth/2,-cardHeight/2), new Vector2(cardWidth/2,cardHeight/2),
                        new Vector2(-cardWidth/2,cardHeight/2) }.Select(point => Vector2.Transform(point,shifted)).ToArray();
                    fitsChrome &= corners.Min(point => point.Y) >= topInset - 1 &&
                        corners.Max(point => point.Y) <= height-bottomInset+1 &&
                        corners.Min(point => point.X) >= -1 && corners.Max(point => point.X) <= width+1;
                }
            var (_, withDate) = RhineGeometry.ExpandedSize(1.6f,width,height,topInset,dateBottom);
            var (_, withTimeline) = RhineGeometry.ExpandedSize(1.6f,width,height,topInset,timelineBottom);
            timelineShrinksCard &= withTimeline < withDate;
        }
        assert(fitsChrome, "Expanded artwork, footer and actions stay between the toolbar and active bottom controls");
        assert(timelineShrinksCard, "Showing the timeline reduces the complete card size instead of covering its footer");
        assert(continuousActions && RhineGeometry.ActionBlend(0) == 0 && RhineGeometry.ActionBlend(1) == 1,
            "Card-owned actions fade continuously without a separate footer handoff");
        var returning = new RhineTransition(1); returning.Step(0, .12);
        var beforeReverse = RhineGeometry.ActionBlend((float)returning.Value);
        returning.Step(1, 0);
        assert(Math.Abs(RhineGeometry.ActionBlend((float)returning.Value) - beforeReverse) < 1e-6,
            "Retargeting the card does not jump the footer/action handoff");
        var viewForDepth = RhineGeometry.View(8);
        Matrix4x4.Invert(viewForDepth,out var cameraForDepth);
        var home = new Vector3(0,0,3);
        var destinationForDepth = Vector3.Transform(new Vector3(0,0,-14),cameraForDepth);
        float DistanceAt(float p) => -Vector3.Transform(RhineGeometry.Extract(home,destinationForDepth,p),viewForDepth).Z;
        var neighborDistance = (DistanceAt(0)+DistanceAt(1))/2;
        var crossedBeforeArrival = Enumerable.Range(1,99).Any(i =>
            RhineGeometry.DepthOrder(DistanceAt(i/100f),neighborDistance) > 0);
        assert(RhineGeometry.DepthOrder(DistanceAt(0),neighborDistance) < 0 &&
            RhineGeometry.DepthOrder(DistanceAt(1),neighborDistance) > 0 && crossedBeforeArrival,
            "An extracted card physically crosses neighboring depth before reaching the front");
        var homeSortDistance = DistanceAt(0);
        assert(Enumerable.Range(0,101).All(i =>
            RhineGeometry.DepthOrder(homeSortDistance,neighborDistance) < 0),
            "The original opaque card remains in its home depth order during both directions");
        var frontOpacityMonotonic = true;
        var previousFront = 0f;
        for (var i=0;i<=100;i++)
        {
            var front = RhineGeometry.FrontBlend(i/100f);
            frontOpacityMonotonic &= front >= previousFront && front-previousFront < .04f;
            previousFront = front;
        }
        assert(frontOpacityMonotonic && RhineGeometry.FrontBlend(0)==0 &&
            RhineGeometry.FrontBlend(.31f)>0 && RhineGeometry.FrontBlend(.31f)<1 &&
            RhineGeometry.FrontBlend(.65f)==1 && RhineGeometry.FrontBlend(1)==1,
            "Only the front copy fades continuously across the neighboring depth crossing");
        var copyReturn = new RhineTransition(1); copyReturn.Step(0,.22);
        var copyOpacityAtReverse = RhineGeometry.FrontBlend((float)copyReturn.Value);
        copyReturn.Step(1,0);
        assert(Math.Abs(copyOpacityAtReverse-RhineGeometry.FrontBlend((float)copyReturn.Value))<1e-6,
            "Retargeting the front copy reverses without an opacity jump");
        var expandedLayout = RhineGeometry.Layout(900,670,1.6f);
        var finalCardMatrix = RhineGeometry.Plane(destinationForDepth,
            Quaternion.CreateFromRotationMatrix(cameraForDepth),viewForDepth,1280,800);
        var frontScale = RhineGeometry.FooterScreenScale(expandedLayout,finalCardMatrix);
        var footerRaster = Math.Max(1,frontScale);
        var titleRasterSize = 18*footerRaster/frontScale;
        var actionRasterSize = 16*footerRaster/frontScale;
        assert(frontScale > .1f && titleRasterSize >= 18 && actionRasterSize >= 16 &&
            (frontScale < 1 || MathF.Abs(frontScale/footerRaster-1)<.0001f) &&
            MathF.Abs(titleRasterSize*frontScale/footerRaster-18)<.001f &&
            MathF.Abs(actionRasterSize*frontScale/footerRaster-16)<.001f &&
            MathF.Abs((RhineGeometry.ArtBaseWidth*footerRaster)*(expandedLayout.FooterScale/footerRaster)
                - expandedLayout.ArtWidth)<.001f,
            "Expanded text is rasterized at screen resolution without changing footer bounds");
        var snapped = RhineGeometry.SnapFacingPlane(finalCardMatrix,expandedLayout,1.25f);
        var snappedFooter = RhineGeometry.FooterMatrix(expandedLayout,snapped);
        assert(snapped.M12 == 0 && snapped.M21 == 0 &&
            MathF.Abs(snappedFooter.M31*1.25f-MathF.Round(snappedFooter.M31*1.25f))<.001f &&
            MathF.Abs(snappedFooter.M32*1.25f-MathF.Round(snappedFooter.M32*1.25f))<.001f &&
            Vector2.Distance(new(snapped.M31,snapped.M32),new(finalCardMatrix.M31,finalCardMatrix.M32))<1,
            "Settled card faces the screen and its footer origin aligns with device pixels");
        foreach (var dark in new[] { false,true })
        {
            var left=RhineTone.Stop(-2,2,dark); var right=RhineTone.Stop(2,2,dark);
            assert(right.Z-right.X > left.Z-left.X, "Right columns carry a cooler blue reflection than left columns");
            var range = Enumerable.Range(1,3).Max(stop => Vector4.Distance(RhineTone.Stop(0,0,dark),RhineTone.Stop(0,stop,dark)));
            assert(range>.15f, "Each glass sheet retains a visible vertical tone transition");
        }
    }
}
