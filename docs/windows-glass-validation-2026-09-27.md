> **已修正桌面透明度**：本页记录的是先前配比，背景 SSIM 不适用于最新实现。详见 [桌面模糊修复](windows-desktop-blur-fix.md)。

# Windows glass native validation — 2026-09-27

Source base: `12c9aac`, branch `feat/windows-visual-parity`. This report covers
an unsigned native x64 development build on Windows 11 build 22621, 1280×800,
100% scale, 8 logical processors. The Mac material references are normalized
sRGB at the same logical dimensions; the original captures are 2× JPEG with ICC.

## Result and scope

Live desktop blur, transparent classic homepage, foreground liquid refraction,
light/dark tone and masked fallback are implemented and exercised. The shader
refracts XAML content, while the separate host-desktop layer supplies live blur,
tint and transparency. It does not refract the desktop itself. Production uses
neither wallpaper substitution nor screenshot polling.

**Overall 90% macOS parity is not certified.** High interior SSIM does not establish
that claim. Thin rims, SF versus Segoe fonts/icons, Rhine card projection and
settings layout differ. Mac layout captures use cacheDisplay and cannot certify
native glass; the Mac background material uses within-window sampling rather
than the Windows host-desktop path. These limits are visible in the evidence.

## Quantitative material comparison

| Case | Interior SSIM | Interior RGB MAE /255 | Rim SSIM | Text/icons SSIM | Outside SSIM |
|---|---:|---:|---:|---:|---:|
| material-light | 0.9825 | 2.559 | 0.6422 | 0.5295 | 0.9338 |
| material-dark | 0.9607 | 4.788 | 0.7156 | 0.5456 | 0.9387 |
| background-light | 0.9965 | 2.767 | 0.6015 | 0.5413 | 0.9590 |
| background-dark | 0.9883 | 3.342 | 0.7339 | 0.5165 | 0.9584 |

`scripts/compare-windows-glass.py` reports RGB channels with 11×11 uniform-window
SSIM (K1=.01, K2=.03, L=255, population covariance, reflect padding) and absolute
RGB error. Fixed masks: interior inset 8 px excluding text; rim inner 3 px;
separate text/icon rectangles and outside pixels. No registration, fitting,
background-dominated combined score, or weighting hidden by an overall percentage.
Mac JPEG and 2× resampling contribute to the remaining edge differences.

## Iteration and verification

- Native material rounds 3, 4, 5, 7 and final each captured all four light/dark
  sharp-stripe and host-blur cases. Earlier rounds 1/2 contained unusable cold
  compositor frames and are not accepted as evidence. The harness now rejects
  uniform frames, retrying before failing.
- Round 3 introduced the alpha-preserving foreground graph and stable normals;
  round 4/5 tuned tone and saturation. Round 6 fixed opaque native window backing
  and the dark timeline; round 7 removed the extra inset rim and adjusted text bounds.
- Application rounds 4, 7 and final: 17 states each (51 captures), covering classic
  and Rhine home/results/filtered search in both themes, expanded cards, recording
  and storage settings, and the populated timeline. Final metrics contain no
  material connection errors or failed Rhine image loads. A separate dark timeline
  capture was also inspected.
- Final `test-windows-glass.ps1`: 12 native cases with assertions, covering the four
  comparisons, solid accessibility fallback in both themes, injected host failure,
  recovery, and masked classic desktop in both themes. All passed.
- `Rewind.Tests`: 89 checks passed, including the progressive timeline profile.
  Native self-contained Release x64 publish passed; `git diff --check` passed.
- Only the isolated fixture harness ran: 60 generated images, synthetic usage,
  no real history opened and no recording started. Full recording/OCR/model smoke
  tests were outside this visual-change validation.

## Resource sampling

| Case | Seconds | CPU (one core) | Working set MiB | Private MiB |
|---|---:|---:|---:|---:|
| perf-idle-before | 10.01 | 0.00% | 264.7 | 231.6 |
| perf-motion | 21.02 | 8.03% | 246.8 | 217.8 |
| perf-idle-after | 10.01 | 0.16% | 250.7 | 217.8 |

The motion sample retargeted the real springs 80 times at 250 ms intervals.
Idle samples disabled the Rendering observer and screenshot capture. Idle ticking
was false before/after; no image loads failed. This short run showed no retained
memory growth, but is not a long-duration leak test. Motion Rendering callbacks:
median 16.66 ms, p95 71.92 ms, maximum 80.71 ms. These are UI scheduling intervals,
not GPU presentation times or proof of sustained 60 FPS. Pointer/keyboard input,
GPU frame timing, other displays/DPI and actual OS high-contrast toggling remain
untested. Fallback injection exercises the shared rendering branch only.

## Reproduction and runtime dependency

Follow `macos-visual-reference.md` to copy fixtures and launch `Recall.exe
--visual-parity <directory>` on an interactive 1280×800 desktop. Omit the legacy
transport.json. Run `test-windows-glass.ps1`, `test-windows-visual-parity.ps1` and
`compare-windows-glass.py` (Pillow + NumPy). Each command produces PNG and JSON.

Keep Windows App SDK 2.2.0 / LiquidGlassWinUI 1.0.3 pinned. The private ABI is
checked against wuceffectsi.dll SHA-256
`DBEA457AC1C6D5C4CDE5B9CFB09E65CD54B11596406CE50565DDD946468B1454`.
Unsupported architectures/runtime hashes and shader failure use solid fallback.
MIT sources, license and modification notice are included. The self-contained
package includes OCR/native runtime assets but their inference was not revalidated
in this visual task. It is a development portable build, not a signed release.
