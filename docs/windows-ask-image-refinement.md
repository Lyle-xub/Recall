# Windows Ask Recall and archived image refinement

## Ask Recall

The Windows page now follows the structure of `macOS/Sources/Rewind/AskView.swift`: a sparkle/title row with the selected model and New conversation action; a current app/date scope row with Clear scope; a centered empty state; conversation cards labeled You and Recall with copy and horizontal source cards; an error/retry row; a five-line composer with a round send/stop button; and a local/online privacy label. The view keeps completed conversation turns while navigating away and back. New conversation clears them and cancels any active answer.

The question lookup now passes the active app and date scope to `MemoryStore.Retrieve`, so the label and retrieved sources describe the same range. The model control opens Settings → Models. Source cards use the app icon, title, local timestamp, and a direct memory action. The answer supports text selection, and the source list remains reachable when a long response scrolls. A pending answer follows new text only while the user remains near the bottom.

`AskView.Diagnostics` exposes page dimensions, empty/conversation state, scope, model, send availability, and error visibility for visual validation. `ValidationConversation` accepts **explicit synthetic frames** to exercise long-answer scrolling and three source cards without starting a model request. It must be called only by the local visual-parity fixture workflow.

## Archived image seams

The old `.recallframe` loader scaled each 384-pixel tile separately with bicubic interpolation. A synthetic, opaque uniform image exposed the cause: an internal tile join in the scaled preview had alpha **191**, while the source pixel had alpha **255**. The loader now places tiles at native resolution with source-copy compositing and scales the assembled image once. The full-image resize uses `TileFlipXY` edge sampling; this also avoids fading the outermost pixels. `MemoryImages` only caches the resulting PNG and WinUI bitmap, so the correction belongs in `ImageArchive`.

An isolated Windows image regression project lives in `Windows/Rewind.ImageTests`. `dotnet run --project Windows/Rewind.ImageTests/Rewind.ImageTests.csproj -c Release` passed **9 checks**, covering dimensions and boundary colors at native size, a 601-pixel thumbnail, encoded display PNG, and a continuous ramp crossing two tile boundaries. The former algorithm's measured internal alpha is printed by the test for comparison. The new opaque boundaries read alpha 255 and match their source color.

The local visual-parity fixture includes `parity-seam-gradient` with `archive: true`, an off-white field and continuous gradient/rules across 384-pixel boundaries. It is stored under `D:/RecallDevelopment/optimization-validation/fixtures` and is intended for an actual All memories screenshot after import through the fixture session. The synthetic test does not inspect personal captures.

## Validation boundary

The image regression has passed. The first Ask UI capture confirmed the overall 1050-pixel card, but showed the default icon/control appearance and an initial scroll extent error. Those were changed to the custom sparkle, plain composer input, explicit round send control, and a layout-complete bottom scroll. Final visual and interaction acceptance in both light and dark themes remains the responsibility of the local UI validation run; this document does not assign a parity percentage.

The image loader briefly holds the native assembled bitmap while producing a thumbnail. For the archive limit of 40 million pixels, that bitmap can reach about 160 MB; thumbnail loads remain bounded by `MemoryImages`' existing two-request semaphore. Performance on unusually large monitors remains worth observing in the UI run.
