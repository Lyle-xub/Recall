# Windows Rhine cards — 2026-09-27

This change follows the supplied native Mac expanded-card reference: a larger screenshot, a compact title/date strip, and four equal-width icon-and-text actions. The screenshot keeps its own aspect ratio. The entire visible footer belongs to the card plane; real pointer, keyboard and accessibility actions are enabled through a matching transparent input surface only after expansion finishes.

## Continuous extraction and return

A whole-card Z-order swap can visibly replace a large overlapping region in a single frame. The original card now keeps its home-depth sort position. One decorative front copy shares the original decoded bitmap, geometry and transform, with a continuous opacity ramp during extraction and return. The original does not fade out reciprocally: that would dim pixels that are not occluded. The copy is released on return, hide, rebuild and selection changes. There is no additional screenshot decoding for this copy.

The image, title, date and actions use the same plane throughout the motion. On return, the destination follows the current ridge pose. Image uploads are deferred during the transition. This is a continuous composited occlusion treatment, not a claim of per-pixel 3D depth rendering.

## Clear text at the expanded endpoint

Reducing the base font and enlarging the footer through Composition blurred the text. The expanded footer now lays out at its final screen size, counter-scales its local Composition transform, and aligns the final footer origin to the display pixel grid. At the 1280 × 800, 100% validation display, both the XAML title and its projected size are 18 DIP; the footer layout factor is approximately 1.78384 and its final composite scale is 1. The date is 14 DIP, action labels are 16 DIP, and symbols are 16.5 DIP. The title uses semibold Segoe UI Variable with normal system fallback. Layout and font sizes change at transition boundaries, not on every animation tick.

## Complete day columns and bounded rendering

`MemoryStore.ArchiveIndex` queries every non-deleted, non-demo screenshot in the five displayed local days. It projects only wall metadata; OCR and complete frame payloads are loaded for selected actions. It has no per-day row limit. A partial time/ID index supports this query, including stable ordering for tied timestamps and independently resolved local midnights at daylight-saving boundaries.

The query, date bucketing, application summary and unchanged-content comparison run in the background. The UI swaps the prepared index and creates only cards near the viewport. Distant seeks jump directly to the destination window instead of creating intermediate cards. Cancelled and superseded queries cannot replace the latest selection, and hidden/rebuilt views release stale image candidates.

## Targeted validation

- Release, self-contained Windows x64 build succeeded.
- 80 targeted geometry, motion, pixel-alignment and archive checks passed. No full regression suite was run.
- Actual Windows screenshots include expanded light/dark cards, 20-frame extraction and return sequences, and native Star, Rewind and Collapse interactions. Reduced-motion return releases the duplicate visual and action input surface.
- The regular 249-record fixture was compared against the previous delivered binary. Three capture-free return durations were 631.4, 629.0 and 627.4 ms, versus 634.1, 632.5 and 624.0 ms. Worst scheduling intervals were 65.6, 62.0 and 80.5 ms, versus 73.2, 101.3 and 63.4 ms. These are UI scheduling measurements, not GPU frame times.
- The motion sample used 17.77% of one logical CPU core versus 15.60% previously. This run does not demonstrate a CPU reduction; the additional front visual improves continuity at some compositing cost. The 3-second idle samples were 1.56% versus 0%, too short to infer a sustained idle regression or improvement.
- The dense synthetic library contains 68,250 records, with 20,049 in its busiest day. Newest, middle and oldest records were reached, and the oldest card in each of five days matched an independent SQLite query. Only 115–222 regular card visuals were retained in the sampled scenes, plus at most one front copy. UI build portions measured 9.2–19.6 ms; background query/preparation measured 403–1,161 ms across the sampled date ranges.
- Dense records intentionally reuse source fixture images. This validates complete indexing, navigation and bounded visual realization; it is not a benchmark for decoding 68,250 distinct image files.

The review HTML includes actual images, per-frame state, raw measurements, source hashes and the installer checksum. No GPU FPS target or numeric Mac visual-similarity percentage is asserted. The running production installation was not replaced during these tests.

## Delivery

- `Recall-Windows-x64-0.4.25-RhineCards-Setup.exe`
- `windows-rhine-cards.patch` — cumulative Windows/scripts/docs changes against the branch HEAD; unrelated shared model catalogue edits are excluded.
- `rhine-card-review.html`, `rhine-card-manifest.json`, and `rhine-card-evidence/`
