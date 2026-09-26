# Storage settings and cleanup validation — 2026-09-26

Storage settings now reuse one library-level measurement, display the previous result while refreshing, and avoid restarting scans for every optimizer batch. A completed optimization or cleanup requests one fresh measurement. Concurrent invalidations coalesce into one follow-up scan.

Maintenance uses its own writable SQLite connection instead of holding the capture/UI store's recursive mutex. Discovery, session lookup, filesystem inspection, video encoding, index compaction and cleanup all run off the main actor. Storage-page visibility permits automatic optimization; browsing other views still defers automatic work. Unknown-size phases show their activity and processed tile count instead of a frozen 0% bar.

Clear storage pauses capture and awaits outstanding indexing/maintenance work, revalidates the confirmed snapshot, reports cleanup phases, and reloads the library asynchronously. The toggle label and switch occupy opposite sides of the same row. Empty Trash uses this same asynchronous flow. All-recordings cleanup also handles completed recordings with no remaining cards, with session IDs included in recovery journals. New records and newly protected/shared files remain excluded at commit time.

## Authorized local cleanup

The app was normally quit before maintenance. A captured ID set authorized deletion of 17,034 legacy memories; the 125 memories recorded in the new unified format were explicitly retained. Native cleanup removed 209 associated recordings and then 16 old, empty recordings. The two newer unified sessions remain. Models, settings and application-usage history were preserved.

- Main cleanup: 17,034 memories / 209 recordings, 3,923,956,916 media bytes reclaimed; completed journal recovery check passed.
- Empty recordings: 16 recordings, another 9,641,984 media bytes reclaimed; all retained frame IDs matched the snapshot exactly.
- Exact `StorageUsageReader.scan` after cleanup: 2,074,791,936 allocated bytes in 0.00307 seconds. This was a warm, post-cleanup scan of the much smaller library, not a claim about cold scans of a large history.
- Subsequent audit after normal OCR resumed: 2,043,490,304 allocated bytes, including 1,982,386,176 model bytes. 125 retained frames, two sessions, zero legacy IDs and zero pending cleanup journals. Remaining temporary screenshots continue to be released as recognition completes.

Maintenance drivers and ID snapshots were kept local under ignored test data; the one-shot Swift drivers were removed from the source tree.

## Validation

- Initial full debug suite: 210 tests, 23 optional/environment-dependent skips, zero failures.
- Final release suite covering cleanup, maintenance, tile packing, visual archives and optimizer pause/retry: 24 tests, zero failures.
- Additional application-level cleanup test: passed. It verifies star protection, UI library refresh and storage refresh through `AppModel.clearStorage`.
- Regression tests cover coalesced scans, cached first display, main-actor responsiveness, storage-page work gating, cleanup quiescence, WAL reader availability during a held cleanup transaction, empty-recording snapshot protection, and interrupted empty-recording journal recovery.
- Native UI: inspected the formal library's storage chart and left/right cleanup toggle; invoked Optimize while settings were open and confirmed completion and refreshed usage. In a separate synthetic library, Clear Trash removed three test memories, returned to settings and showed “Cleared 3 memories · 12 KB freed.”
- Release executable installed into `release/Recall-Rhine-Unified.app` with the existing stable signing identity; deep/strict code-signature verification passed.
