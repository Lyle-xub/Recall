# Rhine warm reopen and date dock

This update targets reopening Recall from the tray or shortcut while the process
is still running. It preserves the existing archive view, decoded images and
scroll position. It does not introduce a persistent cold-start cache.

## Implementation

- `MemoryStore.ArchiveRevision` is a process-local generation for the visible
  archive projection. Insert, trash, restore, star, image-path and metadata
  changes invalidate it. OCR-only and end-time writes do not. Retention and
  committed cleanup update the generation; failed writes do not.
- A warm reopen with an unchanged generation performs no archive index query.
  A changed generation queries metadata in the background and reconciles by
  frame ID, retaining surviving cards, bitmaps and the visible scroll anchor.
  A generation captured before querying ensures concurrent writes remain dirty.
- Hidden or obsolete queries and image completions cannot publish into a newer
  view generation. Immediate hide/show does not reuse a canceled refresh task.
- Initial archive population occurs on demand, rather than composing the page
  in the window constructor and again on Show. Existing native backdrop detach
  and recording resume behavior are retained.
- The date dock uses one 38 DIP glass capsule with a matching 19 DIP radius.
  The 30 DIP arrow buttons have transparent resting backgrounds, accessible
  names, tooltips and ordinary hover/focus feedback, without separate glass.

## Focused verification

Release publish and 95 targeted geometry, motion and archive checks passed.
Both builds were measured with the same synthetic 249-record library at
1280 × 800, using the real WinUI overlay. No private history was used.

| Scenario | Previous build | This build |
| --- | --- | --- |
| Five unchanged reopens | Retained 160 decoded images, queried again | Retained 160 decoded images; zero additional index queries or wall builds |
| New screenshot while hidden | Wall builds increased from 1 to 2; 36 images loaded at the settled sample | Wall builds remained 1; all 160 prior images reused, 165 loaded at the settled sample |
| New-record application | Full wall rebuild | 222 sheets reused; incremental UI reconciliation took 3.38 ms in this fixture |

The fixture also covers deletion while hidden, immediate hide/show, preserving
a sought archive position, date-arrow navigation, light/dark dock appearance,
native Escape dismissal, and recording transitions with a simulated capture
backend. The latter checks the coordinator, not microphone/screen capture.

Timing in the accompanying report named `roundTripMs` includes command transport
and polling. It is not GPU frame time or the exact time until the window is
visible. No general FPS improvement is inferred from these measurements.

The installer and cumulative source patch are delivered without replacing the
currently running installation automatically.
