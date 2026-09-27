# Windows app icons and Rhine performance

The application icon view now uses an opaque, theme-aware rounded plate, including while an icon is loading or unavailable. The same view is used in application filters, search results, timeline nodes and previews, memory details, Ask Recall sources and application usage. Icon extraction and UI bitmap decoding share in-flight work and use bounded caches.

Rhine loads compact metadata for each of the five displayed local calendar days independently. A busy recent day can no longer consume the previous global record limit and empty the neighboring columns. OCR text is fetched only when the selected memory needs it. Local midnight boundaries are converted independently to preserve daylight-saving transitions.

The wall uses 0.82 row spacing and 448-pixel thumbnails. Expanding a card requests a 1200-pixel image; collapsing returns it to the wall resolution. Visible pictures take priority over nearby prefetch requests. Sheet realization is time-sliced, offscreen resources are evicted, and ordering and status text are updated only when they change. Empty cards only create their glass layer. A completed image no longer restarts a whole-wall animation pass.

While a card is opening, closing or being dragged, completed images wait without replacing the current image. Once the interaction settles, a low-priority queue presents at most two waiting images per dispatcher turn. Both current and waiting image references count toward the wall budget, and leaving the page releases pending images.

Image loading shares identical requests, preserves other callers when one request is canceled, and uses bounded encoded and decoded LRU caches. File/pack work is bounded separately from UI decoding so waiting for a UI decode does not monopolize the file worker slots. The limits remain 48 MB for encoded cache, 72 MB for decoded cache and 160 MB for images retained by wall sheets; these are separate overlapping accounting categories, not a total process-memory limit.

## Focused verification

Run the Rhine geometry and archive-query checks with:

```powershell
dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj -c Release -- --rhine-only
```

The generated review includes before/after measurements from the same isolated 249-record synthetic library at 1280 × 800, along with icon screenshots. `firstImageMs` starts after the internal wall build and is not end-to-end application startup. Loaded-image counts include retained prefetch images; the newer visible-image counters distinguish pictures on screen. CPU is expressed relative to one logical core. UI rendering callback intervals are scheduling measurements, not GPU presentation times or verified FPS. No real recording library is modified by these checks.

This delivery uses targeted compilation, geometry/query checks, image-path checks and visual samples rather than a full test suite. The installer is built from the reviewed candidate; applying it to the user's installed application is a separate step.
