> **已修正桌面透明度**：本页记录的是先前配比，背景 SSIM 不适用于最新实现。详见 [桌面模糊修复](windows-desktop-blur-fix.md)。

# Windows liquid glass implementation

## Native validation — 2026-09-27

Windows x64 implementation and native validation are complete for the material
changes below, based on `12c9aac` and its committed Mac reference bundle.
This is an unsigned development build. **Overall 90% macOS visual parity is not
established.** The four material-interior SSIM measurements are 0.9607–0.9965;
boundaries, text, projection and some application layouts still differ. See
[the measured results and limits](windows-glass-validation-2026-09-27.md).

The opaque-white desktop, sparse-blur banding, large-panel normal underflow,
double inset rim and pale dark timeline were fixed. Twelve final native glass,
fallback, failure/recovery and desktop-mask cases passed their state assertions.
Three 17-state application matrices were captured during refinement. The final
matrix had no material connection errors or failed Rhine image loads. Core
regression checks: 89 passed. Native Release x64 publish succeeded.

Build on Windows with .NET 10 x64, after preparing the native OCR/model assets
with the repository preparation scripts:

```powershell
dotnet publish Windows/Recall.WinUI/Recall.WinUI.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -o release/glass-probe
```

Keep Windows App SDK 2.2.0 and LiquidGlassWinUI 1.0.3 pinned. The effect bridge
uses a private x64 ABI, guarded by the bundled `wuceffectsi.dll` SHA-256. A SDK
upgrade requires a new native compatibility test and deliberate hash review.
The current offline restore/publish completed without package warnings.

`VisualParitySession` is opt-in via `--visual-parity <directory>`. Use local
`control.json`; omit the optional legacy `transport.json`, which targets a fixed
private development endpoint. Normal app startup never opens this transport.
Tests use the 60 synthetic fixtures, disable recording and use an isolated
library. Uniform startup frames are rejected and retried, not counted as visual
evidence. Validation also supplies synthetic usage intervals for the timeline.

## Reuse research

Research and native experiments performed on 2026-09-27.

| Project | License | Rendering | Decision |
| --- | --- | --- | --- |
| [LiquidGlassWinUI](https://github.com/luckyelysia/LiquidGlassWinUI) | MIT | Composition HLSL refraction, separable blur, dispersion and Fresnel rims | Vendor the minimal MIT shader/interop; reuse the pinned 1.0.3 native bridge and verified self-contained Windows App SDK 2.2.0 runtime. |
| [LiquidGlassPoC](https://github.com/olivierlevon/LiquidGlassPoC) | MIT | Acrylic, gradient rims and pointer lighting | Useful reference, but lacks actual backdrop displacement. |
| [electron-liquid-glass](https://github.com/hicccc77/electron-liquid-glass) | MIT | Native D3D/DXGI capture and DirectComposition shader | Requires a new capture and C++ integration layer; avoided an Electron rewrite. |
| [liquidDX11](https://github.com/poncippg-spec/liquidDX11) | MIT plus third-party notices | C++/ImGui/D3D renderer | Does not integrate directly with retained WinUI controls. |
| [liquid-glass-WinUI](https://github.com/pratikone/liquid-glass-WinUI) | No license found | WinUI experiment | Not copied. |

The selected package uses a **private Composition ABI**. Its native bridge is limited to x64 and the bundled runtime; this is not a general Windows API guarantee. `GlassMaterial` verifies the SHA-256 of `wuceffectsi.dll` before creating any custom brush. A mismatched runtime, disabled advanced effects, high contrast or a shader connection failure uses a readable opaque surface. SDK upgrades require a new native compatibility test and hash review. The original MIT notice is shipped in `licenses/`.

The vendored shader/interop comes from upstream commit `77d9ff9d99a7c388c67e07d8c15755e79618aec5`. Recall uses a distinct effect GUID, stabilizes the surface normal, removes the extra inset and adds explicit tone parameters. [The notice](../Windows/Recall.WinUI/Materials/NOTICE.md) and MIT license are shipped with the build.

## Material architecture

- One continuous host-desktop Gaussian blur and tone layer sits below XAML. The classic home page retains its control mask and smooth lower fade. Search and Rhine Lab mode share a full backdrop without an extra filter-bar slab.
- Foreground controls use `RecallGlassBrush`: native 10 px Gaussian blur, the modified refraction shader, and an alpha-preserving composition graph. It refracts **in-window XAML content**. The Windows.UI host-desktop layer is a separate compositor source: the foreground shader does not displace desktop pixels. A light veil and edge treatment combine with the live desktop blur. No wallpaper proxy or screenshot loop is used in production.
- Recall pools factories by DPI and releases per-surface brushes on disconnect. It recreates materials when loaded, resized across DPI scales or when accessibility policy changes. Advanced-effects disabled and high-contrast paths use solid surfaces; foreground text follows the system contrast colors. Only the injected fallback was exercised here; OS high-contrast switching and multiple DPI monitors were not tested.
- `NativeShell` enables zero-alpha native backing without a full-window DWM frame. The masked classic homepage therefore exposes the sharp live desktop outside its controls. The Win32 pattern was cross-checked against [WinUIEx TransparentTintBackdrop](https://github.com/dotMorten/WinUIEx/blob/main/src/WinUIEx/TransparentTintBackdrop.cs).
- Host connection failure retains the same geometry using a solid masked fallback. It recovers on the next successful material update; shader/runtime errors remain in safe fallback until restart.
- Distant overlapping Rhine Lab image sheets keep inexpensive fills. Large collections do not run a full multi-pass refraction pipeline on every screenshot.
- Existing bounded image caches, lazy image decoding and retained spring transforms remain in place.

## Reproducible validation

Downloadable Mac captures, color-normalized references, all 16 application layout baselines and the 60 shared fixture images are committed under `docs/macos-visual-reference/`. See [Mac visual references](macos-visual-reference.md) for previews, provenance and Windows setup commands.

`macOS/Tools/MaterialReference.swift` is a separate native AppKit/SwiftUI reference. It uses the same public liquid-glass API as the Mac application over a deterministic striped pattern. `MaterialReferenceView.cs` uses the same geometry and pattern with the real Windows production brushes. Neither harness opens a real recording library.

Mac per-window screenshots exclude behind-window sampling. The blur reference therefore uses an **in-window** NSVisualEffectView; it is a material reference, not proof of exact desktop-background equivalence. Mac captures carry a display ICC profile and must be converted to sRGB before comparison with Windows PNG captures. Native Windows capture includes the complete 1280×800 desktop, independent of the RDP client's display scaling.

A whole-screen image score dominated by the shared background must not be presented as “90% macOS fidelity.” Compare glass interiors, boundaries, blur profiles, text and actual application states separately, and report limitations. UI rendering callbacks measure scheduling, not GPU presentation time.

Run the reproducible material assertions and region comparisons after starting
the isolated desktop session described in [Mac references](macos-visual-reference.md):

```powershell
.\scripts\test-windows-glass.ps1 -Directory $validation -Round final
.\scripts\test-windows-visual-parity.ps1 -Directory $validation -Round app-final
# Python requires Pillow and NumPy.
python .\scripts\compare-windows-glass.py $validation --round final
```

The comparison uses fixed geometry masks, RGB MAE and an 11×11 uniform-window
SSIM with no image registration or fitted transforms. Glass interiors exclude
an 8 px edge and text; boundaries use the inner 3 px; text/icons and background
are reported separately. Mac references contain JPEG/resampling artifacts.
