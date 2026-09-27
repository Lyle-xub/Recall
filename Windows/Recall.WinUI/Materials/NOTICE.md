# Refraction shader provenance

This directory vendors the minimal shader definition and native interop from
[LiquidGlassWinUI](https://github.com/luckyelysia/LiquidGlassWinUI) commit
`77d9ff9d99a7c388c67e07d8c15755e79618aec5` under its MIT license (LICENSE).
Namespaces are changed to Recall.Materials; nullable analysis is disabled only
for the imported code. Recall modifies the shader to stabilize the softmax
surface normal (avoiding underflow/NaNs on large panels), enforce a nonzero
antialiasing width, remove the extra inset rim, and add luminance compression,
offset and saturation parameters. The modified effect uses a distinct GUID.

RecallGlassBrush builds its own graph around this shader: native Gaussian blur,
alpha-preserving composition over the OS desktop layer, per-window DPI, pooled
factories and explicit lifecycle management. The pinned NuGet package supplies
CustomEffectRuntimeNative.dll; its private ABI still requires the runtime hash
check in GlassMaterial before creating a shader.
