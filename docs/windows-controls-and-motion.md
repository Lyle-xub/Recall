# Windows controls, motion and typography

This change extends the existing desktop blur to the controls in the normal
application. It is not a separate UI for the visual test runner.

## Materials

- `ControlBackdrop` samples the live desktop through the OS compositor and
  masks a separate material to visible control bounds. Controls use an 8 DIP
  blur, saturation 1.18, and 74% desktop / 26% tint, independently of the shared
  desktop material. The existing 60% desktop background is preserved.
- `RecallGlassBrush` refracts content rendered inside the application. Its
  coverage mask prevents empty XAML pixels from covering the desktop in white.
- Search, action buttons, filter chips, result cards, settings sections,
  selection tabs, editable fields, primary actions and extracted-card controls
  share the material. Tabs retain their glass when selection changes.
- Directional rims, a hover sheen, and native rounded shadows give controls
  visible depth. Popup menus, calendars and combo dropdowns use native acrylic.
  Switches retain the native accessible toggle implementation and knob motion,
  with glass rail/rim resources.
- Archive scene planes use inexpensive translucent gradients, matching the
  distinction between SceneKit planes and SwiftUI glass in the Mac source.
  The extracted plane gets the full in-window refraction shader. It releases
  that shader when returned to the wall. Hidden fake footer buttons were removed.
- The system compositor does **not** support the tested displacement-map graph.
  Desktop control blur and tint therefore use public supported effects; true
  shader refraction is limited to in-window content. This is not a claim to
  reproduce Apple's proprietary optical renderer or cross-control liquid union.
- Normal launches retain `WDA_EXCLUDEFROMCAPTURE`. No desktop copying, wallpaper
  substitution, recording changes or private-library access are used for glass.

## Motion

| Interaction | Windows behavior / Mac source reference |
| --- | --- |
| Search engagement | Width, height and position interpolate; response 0.58, damping 0.64 |
| Toolbar droplets | Response 0.56, damping 0.57, 35 ms stagger; emergence from the search side |
| Press / hover | Native composition springs, press response 0.18, hover response 0.30 / damping 0.8; pointer, keyboard, capture loss and unload handled |
| Page / section entry | Shared XAML transform clock with analytic springs; normal response 0.42 / damping 0.9 |
| Timeline | Bottom-edge reveal with 88 DIP trigger / 258 DIP hysteresis; response 0.38 entry, 0.24 exit with 180 ms fade |
| Archive extraction | Independent 16 ms timer runs only while springs are moving; analytic integration catches up after a delayed callback |
| Extracted actions | Real XAML buttons with keyboard focus, readable unscaled labels and a delayed entrance once the card faces the viewer |

`CompositionTarget.Rendering` alone did not reliably advance the archive when
XAML stopped invalidating. A card could stall before its controls appeared.
The timer and explicit settled-state checks address that failure. Reversing the
search spring preserves the current layout and ignores superseded timer ticks.
Toolbar droplet transforms and opacity are advanced together on the UI thread, so the OS material mask reads the same geometry rather than leaving stationary glass circles behind a moving compositor visual. This clock also stops at rest. Page, section and timeline transforms use this same XAML clock to keep hit testing and automation bounds aligned. Reduced motion sets final states immediately and clears latched animations.

Button hover/press springs target the inner template visual, leaving the outer
XAML element in charge of layout and hit testing. Transparent template roots
retain input regions even when the glass brush has transparent pixels. Actual
mouse clicks must supplement harness navigation when verifying these controls.

## Typography

Use Segoe UI Variable Text for normal copy and input, Small for captions up to
12 DIP, and Display for headings at 23 DIP and above. Regular button labels,
semibold hierarchy, full line bounds and native Unicode fallback avoid forced
bold labels and clipping of CJK glyphs. Native icons retain their icon font.
San Francisco is not redistributed as a Windows font.

## Verification

Run on Windows 11 with the published self-contained executable:

```powershell
Recall.exe --visual-parity C:\path\to\synthetic-validation
./scripts/test-windows-visual-parity.ps1 -Directory C:\path\to\synthetic-validation -Round delivery
./scripts/test-windows-glass.ps1 -Directory C:\path\to\synthetic-validation -Round delivery-glass
./scripts/test-windows-desktop-blur.ps1 -Directory C:\path\to\synthetic-validation
./scripts/test-windows-control-motion.ps1 -Directory C:\path\to\synthetic-validation
python ./scripts/verify-windows-desktop-blur.py C:\path\to\synthetic-validation
```

The opt-in runner uses synthetic records and exposes control commands only in
that mode. It does not register competing global hotkeys. The motion script
checks intermediate frames, rapid reversals, settled widths, visible archive
actions, collapse, reduced motion and stopped animation clocks.

The shared desktop probe samples above the reference cards because those cards
now have an independent desktop material. A quadratic detrend separates the
broad scene-edge blur from the 2 px stripe signal; control interiors are also
checked independently for stripe attenuation.

Native Mac screenshots remain the optical reference. Interior SSIM must not be
reported as whole-app similarity. Text, rims, desktop tone and liquid merging
remain separate comparison regions. No measured overall 90% parity is claimed.
Rendering callbacks are UI scheduling observations, not GPU presentation FPS.

## Dismissal lifecycle

Esc dismissal detaches the independent OS backdrop immediately. A bounded XAML
exit replaces waiting indefinitely for a compositor batch completion callback.
The hidden window releases its effect graph and ignores subsequent material
policy notifications until reopened. A revision guard prevents an old exit
from hiding a newly reopened window. Tests cover both modes, reduced motion,
reopening, interrupted closes, native HWND visibility and backdrop attachment.
Actual Escape input was also verified against a sharp synthetic desktop.
Run `scripts/test-windows-dismiss.ps1` in the same validation session.
