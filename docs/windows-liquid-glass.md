# Windows liquid glass implementation

## Development handoff — 2026-09-27

Work is paused at the user's request on `feat/windows-visual-parity`. This is an **in-progress source checkpoint**, not a validated release or a claim of 90% macOS visual fidelity. No README changes are included in this checkpoint.

- The C# source check passed with zero errors and warnings. A native Windows x64 publish also completed. An earlier native probe rendered the upstream refractive effect, but the final guarded integration has not completed its light/dark visual checks.
- The latest native probe showed opaque controls. Check `UISettings.AdvancedEffectsEnabled`, high contrast, the verified runtime hash and `LiquidGlassBrush.LastError` before tuning the shader. The HTTP validation client did not reach the Mac endpoint; proxy routing is a hypothesis, not an established cause.
- Windows RDP validation was interrupted by another session taking over the desktop (error 0x5). No final screenshots or performance measurements establish the behavior of this new material. The measurements in `windows-visual-parity.md` describe the earlier implementation at `cd94476`.
- Remaining work: verify material fallback and host-backdrop failure handling, tune blur/tint/refraction against the Mac reference, test both appearance modes in actual application pages, then measure idle and pointer-motion CPU/memory and GPU presentation on the Windows console.
- `VisualParitySession` is opt-in via `--visual-parity <directory>`. Its optional `transport.json` currently targets the previous development machine's fixed private endpoint. On a new machine, omit that file and use the existing local `control.json` workflow, or deliberately reconfigure the transport. The normal application never opens this transport.
- `.test-data/`, `release/`, local SDK/NuGet caches, recordings and connection credentials are not part of Git. Recreate the SDK/runtime dependencies on the new machine. The Mac reference captures and shared synthetic fixtures are now available in [the committed reference bundle](macos-visual-reference.md); other local test artifacts remain excluded. The earlier portable ZIP does not contain this material checkpoint.

Build on Windows with .NET 10 x64:

```powershell
dotnet publish Windows/Recall.WinUI/Recall.WinUI.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -o release/glass-probe
```

Keep the pinned Windows App SDK and LiquidGlassWinUI versions below. The previous offline restore reported NU1603 after resolving MachineLearning 2.1.74 instead of 2.1.70; verify a fresh restore on the new machine before release packaging. For the isolated fixture workflow, see `windows-visual-parity.md` and `scripts/test-windows-visual-parity.ps1`.

## Reuse research

Research and native experiments performed on 2026-09-27.

| Project | License | Rendering | Decision |
| --- | --- | --- | --- |
| [LiquidGlassWinUI](https://github.com/luckyelysia/LiquidGlassWinUI) | MIT | Composition HLSL refraction, separable blur, dispersion and Fresnel rims | Reuse pinned NuGet 1.0.3 with a verified, self-contained Windows App SDK 2.2.0 runtime. |
| [LiquidGlassPoC](https://github.com/olivierlevon/LiquidGlassPoC) | MIT | Acrylic, gradient rims and pointer lighting | Useful reference, but lacks actual backdrop displacement. |
| [electron-liquid-glass](https://github.com/hicccc77/electron-liquid-glass) | MIT | Native D3D/DXGI capture and DirectComposition shader | Requires a new capture and C++ integration layer; avoided an Electron rewrite. |
| [liquidDX11](https://github.com/poncippg-spec/liquidDX11) | MIT plus third-party notices | C++/ImGui/D3D renderer | Does not integrate directly with retained WinUI controls. |
| [liquid-glass-WinUI](https://github.com/pratikone/liquid-glass-WinUI) | No license found | WinUI experiment | Not copied. |

The selected package uses a **private Composition ABI**. Its native bridge is limited to x64 and the bundled runtime; this is not a general Windows API guarantee. `GlassMaterial` verifies the SHA-256 of `wuceffectsi.dll` before creating any custom brush. A mismatched runtime, disabled advanced effects, high contrast or a shader connection failure uses a readable opaque surface. SDK upgrades require a new native compatibility test and hash review. The original MIT notice is shipped in `licenses/`.

NuGet 1.0.3 was built from upstream commit `77d9ff9d99a7c388c67e07d8c15755e79618aec5`. Its `BloomAmount=0` selects the blurred source; the later GitHub implementation reverses that interpolation. Parameters must be matched to the package rather than copied from the current README.

## Material architecture

- One continuous host-desktop Gaussian blur and tone layer sits below XAML. The classic home page retains its control mask and smooth lower fade. Search and Rhine Lab mode share a full backdrop without an extra filter-bar slab.
- Foreground controls use individually sized refractive brushes. Shader factories are pooled by the upstream package; disconnected brushes release their per-surface GPU resources.
- Distant overlapping Rhine Lab image sheets keep inexpensive fills. Large collections do not run a full multi-pass refraction pipeline on every screenshot.
- Existing bounded image caches, lazy image decoding and retained spring transforms remain in place.

## Reproducible validation

Downloadable Mac captures, color-normalized references, all 16 application layout baselines and the 60 shared fixture images are committed under `docs/macos-visual-reference/`. See [Mac visual references](macos-visual-reference.md) for previews, provenance and Windows setup commands.

`macOS/Tools/MaterialReference.swift` is a separate native AppKit/SwiftUI reference. It uses the same public liquid-glass API as the Mac application over a deterministic striped pattern. `MaterialReferenceView.cs` uses the same geometry and pattern with the real Windows production brushes. Neither harness opens a real recording library.

Mac per-window screenshots exclude behind-window sampling. The blur reference therefore uses an **in-window** NSVisualEffectView; it is a material reference, not proof of exact desktop-background equivalence. Mac captures carry a display ICC profile and must be converted to sRGB before comparison with Windows PNG captures. Native Windows capture includes the complete 1280×800 desktop, independent of the RDP client's display scaling.

A whole-screen image score dominated by the shared background must not be presented as “90% macOS fidelity.” Compare glass interiors, boundaries, blur profiles, text and actual application states separately, and report limitations. UI rendering callbacks measure scheduling, not GPU presentation time.
