# 虹彩玻璃材质

材质通过内置 image_gen 工具，以用户提供的玻璃装置照片为参考生成；没有使用 CLI/API fallback。保存为 `macOS/Artwork/IridescentGlass.png`。原生 AppKit 图标渲染器将纹理放大 35%、叠加 15% 白色淡化后裁入圆角背景，并独立绘制倾斜椭圆光环；分层图标保留背景与光环两个图层。生成材质不是源照片的逐像素拷贝。以下保留实际生成提示词，生成时预定的四角星随后按用户新参考替换为光环。

## 最终提示词

```text
Use case: style-transfer / material extraction.
Asset type: production texture for the colored inset of a macOS app icon. Output a square 1024x1024 full-bleed image of ONLY the iridescent glass surface from the provided reference.
Input image 1 is the material reference. Reproduce as faithfully as possible the EXACT material and colors of the large exterior glass portal in the middle of the photo, especially its upper rectangular lintel: vivid coral red/orange translucent dichroic glass, magenta-violet interference, turquoise/teal/green and deep blue-gray narrow vertical reflections. Match its optical complexity, NOT a pastel approximation. There are dense vertical glass flutes and subtle horizontal panel divisions; the refracted colors change irregularly from row to row. Use about 22 narrow vertical flutes and 5 horizontal rows of rectangular optical glass panels. Rounded wavering transitions and refracted highlights at the intersections, no black grid outlines. Real photographic glass texture, subtle softness and reflected light exactly as seen in reference, mostly warm coral, amber and red with occasional cool dark teal-violet streaks. No uniform rainbow gradient, no milky desaturation, no evenly repeated simplified stripes.
Composition: straight-on orthographic rectangular uninterrupted glass wall, filling EVERY pixel of the square. No perspective, no room, no white margin, no frame, no rounded corners, no door opening, no person, no text, no logo, no star. The existing four-point star will be placed by the app afterwards. Preserve the reference material as literally as possible, extract and extend it into a continuous square swatch.
```
