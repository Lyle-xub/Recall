# Refraction shader provenance

This directory vendors the minimal shader definition and native interop from
[LiquidGlassWinUI](https://github.com/luckyelysia/LiquidGlassWinUI), originally
integrated from commit `77d9ff9d99a7c388c67e07d8c15755e79618aec5` and refreshed from commit
`647fd60c3ded87dc2a7472f813ec86a265529509`, under its MIT license (LICENSE).
Namespaces are changed to Recall.Materials; nullable analysis is disabled only
for the imported code. Recall keeps the analytical rounded-rectangle normal and
bounded seven-position spectral dispersion, while retaining a nonzero
antialiasing width, removing the extra inset rim, and adding luminance
compression, offset and saturation parameters. The modified effect uses a
distinct GUID.

RecallGlassBrush builds its own graph around this shader: native Gaussian blur,
alpha-preserving composition over the OS desktop layer, per-window DPI, pooled
factories and explicit lifecycle management. The pinned NuGet package supplies
CustomEffectRuntimeNative.dll; its private ABI still requires the runtime hash
check in GlassMaterial before creating a shader.
