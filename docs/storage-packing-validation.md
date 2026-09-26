# Screenshot storage compaction — 2026-09-26

This change reduces filesystem and index overhead while preserving existing
screenshot bytes. It builds on the CPU/thread-limit and background pacing work in
[background-performance-validation.md](background-performance-validation.md).

## Layout and scheduling

- Content-addressed PNG/HEIC tiles now live in SQLite segments under
  `frames/packs/`. A segment holds at most 32 MiB of tile payload; SQLite metadata
  and page allocation add overhead beyond that limit. Content deduplication and
  the existing screenshot manifests remain unchanged.
- Payload tables use ordinary rowid tables with 64 KiB pages. The small catalog
  keeps binary hash keys on small pages. A measured prototype using
  `WITHOUT ROWID` for the large BLOB payloads wasted overflow pages; the final
  layout avoids that cost. SQLite documents the relevant tradeoff in its
  [WITHOUT ROWID guidance](https://www.sqlite.org/withoutrowid.html).
- The main database interns image/tile paths once and stores integer pairs in
  the two association indexes. A view and insert/delete triggers preserve the
  existing `image_tiles` SQL interface. Unused interned names are reclaimed.
- Old tiles migrate in batches of up to 128 on a background task with the
  existing adaptive recovery intervals. Opening the interface cancels automatic
  migration/index compaction and pauses new batches. An explicit request to
  continue optimization while open overrides that pause. SQLite progress
  callbacks make long schema-copy/vacuum work cancellable as well.
- Shared reader connections cache at most eight segments per library, with
  1 MiB SQLite page caches. The shared UI cache holds at most two libraries and
  18 MiB of declared cost. Prepared queries are reused. Decoding happens outside
  the reader lock; removing a segment also closes its cached reader.

No capture interval, OCR input, OCR model, retention policy, transcript, or
existing image quality was changed by this storage patch. The roughly 2 GB of
fixed local model files is unrelated to accumulated recording growth and was
not removed or counted as a saving. Event-driven capture, as used in
[Screenpipe's capture implementation](https://raw.githubusercontent.com/screenpipe/screenpipe/main/crates/screenpipe-engine/src/event_driven_capture.rs),
would require separate validation of short-lived text and one-character changes;
this patch addresses measured storage overhead without changing capture coverage.

## Recovery and compatibility

The segment transaction is durable before the catalog publishes each key. During
migration, every packed tile is read back and compared with its original bytes
before its loose file is removed. A failed publication retains originals; retry
repairs unpublished segment contents. Catalog writer transactions serialize
separate connections. Reclamation takes a fresh writer lock and rechecks live
keys so a concurrent install cannot lose a republished tile.

Main-database staging receipts continue to protect interrupted frame saves.
Cleanup removes packed tiles only after the owning metadata transaction commits,
and retains shared tiles referenced by another frame. Startup/maintenance can
finish interrupted deletion. Migration schema changes are transactional, and a
persistent marker retries physical space reclamation after interrupted
[VACUUM](https://www.sqlite.org/lang_vacuum.html).

The new build reads both loose and packed tiles, including partially migrated
libraries. This is forward migration compatibility: older builds do not know the
new packed format and should not be run against a migrated library.

## Measurements

All migration measurements used disposable copies. The original library was
opened read-only for a SQLite backup and immutable sample files. It was not
migrated by the development session. The sample includes 160 complete saved
screenshots with 5,009 unique tiles; its database is a full index snapshot, not
an index restricted to those 160 screenshots. Private test data was kept under
ignored `.test-data/storage-packing/`; completed library copies were removed
after validation. Measurement results and logs remain there.

Actual allocated disk bytes were measured, including the packed catalog and
segment overhead, rather than just summing encoded image lengths.

| Measurement | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| 160 screenshots, allocated bytes | 42,016,768 | 35,487,744 | 15.5% |
| Screenshot files, same sample | 5,169 | 164 | 96.8% |
| Full index snapshot, allocated bytes | 763,367,424 | 456,036,352 | 40.3% |

Do not combine these percentages or extrapolate them to the whole live library:
the screenshot sample and database have different scopes, and videos/models are
excluded. Migration of this sample plus the full index used 7.30 process CPU
seconds over 19.54 wall seconds including recovery pauses. The peak sampled at
250 ms intervals was 99.2% CPU, where 100% means one logical CPU. This measures
the migration test process, not total system load or a worst-case bound.

The final read comparison alternated legacy and packed reads of 40
deterministically scattered screenshots at 560 px. Decoded tile caching was
disabled for both layouts; the normal bounded database connection cache stayed
enabled. This was run after prepared-query and connection reuse were added.

| Read measurement | Loose files | Packed segments |
| --- | ---: | ---: |
| Total elapsed | 8.913 s | 8.449 s |
| Process CPU time | 4.459 s | 4.383 s |
| Median preview load | 217.9 ms | 210.0 ms |
| P95 preview load | 258.4 ms | 254.7 ms |

The final layout has comparable/slightly better measured read latency. OS file
cache state and other running applications were not controlled. These are
component measurements, not UI FPS or a guarantee that every workload is faster.
The first read measurements embedded in `benchmark-results.json` predate the
query-cache improvement; `final-read-results.json` records the final comparison.

## Validation

- Debug regression run: 58 passed, six optional checks skipped, zero failures.
  Coverage includes tile packing, archive recovery, shared-tile cleanup, OCR,
  indexing, navigation/readability, presentation, and background responsiveness.
- Final release storage run: 21 passed, two optional checks skipped, zero failures.
  The separate opt-in release read comparison also passed.
- Fault injection aborts catalog publication after the segment commit, then
  verifies original files survive and migration succeeds after reopening.
  Additional checks cover partial migration/restart, corrupt bytes, unsafe paths,
  segment rollover/reclamation, and independent concurrent writer connections.
- Pixel comparison passes for a migrated screenshot; metadata checksums cover
  every column of frames, OCR payloads, sessions, and transcripts. Original
  metadata and recognized text are identical before and after migration.
- The signed `release/Recall-Rhine-Compact.app` opened an isolated 160-memory
  packed library. Native UI checks verified real screenshot display, expanded
  text readability, English actions, and card collapse. Its strict/deep code
  signature verification passed. The test instance was then closed.

Functional checks:

```sh
swift test --package-path macOS --filter 'TilePackTests|PackedScreenTests|StorageCleanupTests|StorageOptimizationTests|ImageArchiveTests|VisibleRecognitionTests|BackgroundPerformanceTests|ResponsivenessTests|OverlayPresentationTests|ArchiveNavigationTests|ArchiveReadabilityTests'
```

The opt-in migration benchmark requires a separately prepared disposable library
copy containing `memory.sqlite`, complete selected manifests/tiles,
`sample-manifests.json` (a JSON array of relative manifest paths), and a
`.benchmark-copy` marker. Never point its writable root at a live user library.
Use a fresh copy to measure migration again.

```sh
RECALL_STORAGE_BENCHMARK_ROOT=/absolute/path/to/disposable-copy \
swift test --package-path macOS -c release --filter TileStorageBenchmarkTests/testIsolatedLibraryMigrationBenchmark

RECALL_STORAGE_READ_COPY=/absolute/path/to/migrated-copy \
RECALL_STORAGE_READ_ORIGINAL=/absolute/path/to/matching-legacy-files \
swift test --package-path macOS -c release --filter TileStorageBenchmarkTests/testReadOnlyFinalLayoutAgainstOriginalFiles
```
