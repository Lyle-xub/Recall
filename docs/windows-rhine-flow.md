# Rhine glass, return motion, and dismissal

The Windows rack uses five shared four-stop gradient textures derived from macOS
`ArchiveGlassScene.glassTexture`. Each column moves from warm gray on the left
to cooler blue on the right; each pane has a pale rim, blue-gray shoulder,
translucent middle and warm lower portion. Dark appearance uses a separate
palette. Each 1×320 premultiplied BGRA texture is rasterized once per column
and reused by its cards, following the Mac texture approach. Screenshot pixels keep their original colors; depth fog blends them
against an opaque neutral surface instead of exposing screenshots behind them.

Card extraction follows one cubic path. The previous two separately eased
segments had zero velocity at their join. A bounded Hermite transition now
reaches its exact endpoint in approximately 620 ms for a full traversal,
preserves velocity when reversed, and restores the toolbar in the same render
step. Actual wall-clock completion depends on UI scheduling. The rack pose is
evaluated live during return, preventing a snap to an old captured position.

Focus glass remains attached to a separate retained surface and crossfades with
the rack material. Footer opacity is continuous, and animation changes use
composition transforms rather than resizing the XAML tree. Cached visuals,
matrices and depth order avoid repeated interop calls. Image requests are
limited to two, prioritize visible central cards, and pause during extraction
and dragging. A background clock coalesces animation work to one pending UI
update so image work cannot accumulate stale animation messages. UI mutations
remain on the UI thread. Both scene and image timers stop when idle.

The decorative card wall has a dedicated automation peer with no child peers.
Its hundreds of transformed screenshot labels are a rendered scene, not separate
interactive controls. Exposing them as a full automation subtree caused roughly
1.2 seconds of foreground UI-thread work on each extraction/return in validation.
The archive retains keyboard selection and a current-memory accessible name;
date navigation and expanded actions remain real accessible controls. Hidden
actions must be removed from keyboard navigation and disabled, not just faded.

Escape closes the entire overlay from home, search, settings, timeline and
expanded cards. Back and Collapse remain local navigation. Dismissal synchronously
closes popups, removes the system backdrop target, hides the native window and
disables the native host backdrop before slower cleanup. Reopening explicitly
reconnects the native host before creating its backdrop brush. Capture exclusion
for normal launches is unchanged.

Validation commands:

```powershell
dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj -c Release
scripts/test-windows-rhine-flow.ps1 -Directory <synthetic-validation-directory>
scripts/test-windows-dismiss.ps1 -Directory <synthetic-validation-directory>
scripts/test-windows-navigation.ps1 -Directory <synthetic-validation-directory>
# Relaunch the synthetic app with --validate-capture-excluded, then:
scripts/test-windows-navigation.ps1 -Directory <synthetic-validation-directory> -CaptureExcluded
```

The flow script requires a foreground window and tests warmed thumbnails, three open/close cycles, mid-flight
reversal, reduced motion and idle timers. Cold image loading is a separate
workload. Interaction-only harness commands preserve glass policy, so an
artificial shader refresh does not contaminate each action. Rendering callbacks
measure UI scheduling, not GPU presentation or FPS. Native keyboard dismissal
must also be checked through the actual window; invoking Hide alone does not
test keyboard routing. A static Mac screenshot cannot establish animation
parity or a quantitative 90% cross-platform match.
