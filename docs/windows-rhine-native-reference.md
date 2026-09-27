# Rhine native screenshot alignment — 2026-09-27

Reference: user-supplied macOS screenshot `Snapzy_2026-09-27_09-42-45_585.png` (3022 × 1954). The screenshot is a local review reference and is not copied into the source tree.

## Appearance

- Retain the Mac camera pose, orthographic projection, five day columns, 48-record limit per column and shared draw/pick transforms.
- Start with up to eight recent rows behind the central crest. Add noninteractive empty glass sheets behind the record range so the archive fills the upper viewport without inventing memories.
- Use stronger top/left glass edges, open bottom/right edges and a lower-opacity, muted blue-grey body. Blend distant screenshots toward a warm neutral (dark neutral in dark mode), rather than revealing other screenshots through faded artwork.
- Scale the Rhine toolbar from the native reference: at 1280 px, the search surface is about 527 px wide, 55 px tall and 34 px from the top. The five actions share the same circle size and spacing. Add a working Close Recall button.
- Use a compact date capsule, Segoe UI Variable text hierarchy and letter-spaced collection/status labels. Counts explicitly describe the loaded collection, not the entire database. Narrow windows and the timeline hide peripheral labels.
- Place the primary search glass in a sibling border outside the native TextBox compositor surface; keep the editable background transparent. Apply a warm neutral veil to the Rhine toolbar to preserve readability over dense cards.

## Rendering and interaction

Cull against transformed card extents with an 80 px overscan. Queue visible thumbnails nearest the viewport center first, preventing far columns from starving the foreground. Preserve two-axis dragging, animated crest movement, card extraction/return, timeline selection and reduced-motion handling. Idle animation timers stop after springs settle.

The validation launcher waits for XamlRoot attachment before starting captures, avoiding a cold-start race in the former fixed 500 ms delay. Normal application startup and capture exclusion are unchanged.

## Validation scope

The local report `outputs/rhine-native-review.html` contains the reference, successive screenshots, final evidence and exact test results. Tests use synthetic libraries of 60 and 240 records on Windows 11 build 22621, 1280 × 800 at 100% scale. Native mouse/keyboard checks supplement the command-driven captures. Portable delivery includes earlier icon, video, timeline, settings and dismissal fixes.

This is visual alignment to one native screenshot, not proof of overall 90% platform parity. Screenshot contents, GPU rendering, native SceneKit depth of field and desktop backgrounds differ. The supplied still image does not establish the exact timing of Mac animations. Higher DPI, multiple displays and other GPUs have not been revalidated here.
