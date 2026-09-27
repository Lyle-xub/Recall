# Rhine archive pagination acceptance — 2026-09-27

The archive retains its one-day-per-column layout and date navigation while
allowing every distinct screenshot in a day to be reached by scrolling. The
previous 48-record daily truncation is removed. Implementation was delegated to
GPT-6-Sol with xhigh reasoning; review, independent completeness checks and the
on-device GUI acceptance were performed by the coordinating agent.

## Implementation bounds

- Five day columns retain up to 96 metadata records each, plus at most two pinned
  records. SQL counts, stable ranks and pages share one short read snapshot;
  ordinary browsing does not hydrate the entire library.
- Same-day image paths are deduplicated, with deterministic timestamp/ID ordering.
  Stable anchors preserve existing card positions across insertions, deletions
  and storage optimization. Timeline requests resolve the exact ordinal before
  loading the surrounding page.
- SceneKit reconciles a 52-row viewport per column in eight-row buckets, with at
  most 260 ordinary card nodes plus two protected nodes. Day labels and static
  geometry are reused. Continuous scroll demands are coalesced so small input
  updates cannot indefinitely cancel an in-flight metadata page.
- Screenshot thumbnails and at most two detail images share a 96 MiB cache
  budget; four decoders run concurrently. This budget is not a bound on total
  process memory, decoding scratch space or SceneKit/GPU resources.
- Footer preparation has at most two workers and 262 pending identities. Text
  drawing and SceneKit image conversion run in the background; each prepared
  material is handed exclusively to the main actor. Obsolete results cannot
  overwrite a newer title, star state or card identity.

## Independent completeness fixture

The isolated library contains five days, September 23–27 in Asia/Shanghai, with
600 distinct screenshot paths per day and ten older duplicate-path rows per day.
There are 3,050 database rows and 3,000 visible archive records. Images are
synthetic Aurora documents; distinct paths use hard links to 16 original images.
This deliberately exercises record/path cardinality, rather than thousands of
different image contents.

`ArchivePaginationAcceptanceTests` is separate from the implementation tests and
reads this GUI fixture without changing it. Its model mutation checks use a
temporary database copy. At source `0e17dc2`, all three tests passed in 4.764 s:

| Check | Observed result |
| --- | --- |
| Forward and backward page traversal | All 3,000 expected IDs in each direction |
| Duplicate handling | Exactly 600 slots in each of five columns |
| Resident metadata | At most 480 records |
| Natural scene demand | All 3,000 IDs became actual SceneKit card nodes |
| Resident scene nodes | Maximum 260 |
| Bottom and fast jump across unloaded pages | Exact final row 599 reached |
| Oldest timeline target | Exact final record in each of all five days |
| Model behavior | Accumulated day clicks, reload anchoring, insertion anchoring, latest-request application and timeline extraction passed |

The independent scene loop invokes the store synchronously to verify node
completeness. Production metadata loading is asynchronous; this loop is not an
interaction-latency benchmark.

## Local performance observations

Apple M1 Pro, 16 GiB, macOS 27.2 (26B5091g), Debug build:

| Operation | Timing |
| --- | --- |
| 52 metadata queries over the 5 × 600 fixture | Median 28.86 ms, p95 30.04 ms, max 38.61 ms |
| 10,000-card daily SQL fixture | Cold 45.74 ms, median 48.44 ms, max 49.29 ms |
| Eight-row main-thread scene step | Median 4.35 ms, p95 4.63 ms, max 4.66 ms |
| Large-jump main-thread reconciliation | Median 14.13 ms, max 27.50 ms |

Main-thread scene timings exclude asynchronous footer preparation and are not
screen FPS measurements. Profiling identified SceneKit bitmap/color conversion
as the dominant old reconciliation cost; moving footer preparation off the main
actor reduced the measured scene work.

A ten-minute GUI sampling session collected 1,175 RSS samples at approximately
0.5-second intervals. Maximum observed process RSS was 733.94 MiB and the last
sample was 283.42 MiB. This includes application/framework memory and should not
be confused with the 96 MiB screenshot cache or treated as a leak proof.

## Real Mac GUI acceptance

`Recall Archive Test.app` uses a unique bundle identifier and an explicit
`--data-dir` under `.test-data/archive-pagination-20260927/live-library`.
Recording, microphone and system audio remain disabled. The installed
`/Applications/Recall.app` and its library were preserved.

The first GUI pass used the production Debug binary from `0e17dc2`, SHA-256
`c0e93ced2aeb8e521fe5bde66755bf70e15f204897145f078d34ea5032238a47`.
Computer-use actions on the actual Mac window verified:

1. Downward scroll beyond the initial pages reached September 27, row 600 of 600;
   clicking it expanded the matching title, timestamp and screenshot.
2. Upward scrolling reloaded earlier pages. Opening another card showed row 203
   and its matching image, rather than reusing the previous row-600 content.
3. Collapse returned to the rack. Two consecutive previous-day clicks selected
   September 25. Scrolling to the bottom then opened that day's row 600 correctly;
   the five neighboring day columns remained available.
4. A scene drag did not accidentally leave a card expanded. Opening and cancelling
   Settings returned to the collapsed archive, with recording still paused.
5. Normal Quit stopped only the test process. SQLite integrity was `ok`, all
   3,050 rows remained, and no library owner remained. The installed Recall
   process was still running.

This pass also found that the explicit **Jump to date** menu did not reveal the
hidden timeline panel in Rhine mode. The menu/panel fix and its subsequent
acceptance are recorded below with the final automated checks.

Screenshots were inspected through computer use. No global event-injection
script or system permission changes were used. Local fixtures, process samples
and logs are ignored Git outputs, not release contents.

## Automated checks and follow-up findings

At `0e17dc2`, the complete local Swift suite passed 240 tests with 26 conditional
skips and no failures in 95.522 s. The existing pointer scheduling regressions
remain included; see [pointer acceptance](macos-pointer-validation.md) for the
controlled scheduler, cancellation mutation and repeated native-event checks.

[CLI run 36291127786](https://github.com/Lyle-xub/Recall/actions/runs/36291127786)
passed on Windows, Linux and macOS. The Windows native job also passed in
[native run 36291127758](https://github.com/Lyle-xub/Recall/actions/runs/36291127758).
That run's macOS suite found one failure in the maintenance/pinned-record test:
waiting on an old debounce task could finish before its replacement applied the
current page. This hosted failure was retained and investigated rather than
being dismissed after a successful local run.

The follow-up at `3c80106` uses refresh revisions and waits for the current
debounce/worker chain to become idle. Covered scroll requests preserve required
maintenance refreshes and apply their result at the latest viewport position.
Three controlled regressions failed with eight assertions when the guards were
removed; the restored implementation passed 80 targeted test executions across
20 rounds. The complete local suite passed 243 tests, 26 conditional skips and
zero failures in 97.488 s. Independent fixture acceptance passed again: three
tests in 4.665 s, all 3,000 scene identities, maximum 260 resident nodes, and exact
row 599. Its 52 SQL queries measured 27.974 ms median, 29.644 ms p95 and 31.745 ms
maximum, separately from interaction/rendering work.

The matching final production binary has SHA-256
`ad0135b020e7cb9363cb2050c6620ca1c34f55b708f7bb99d423998e6a52002c`.
On the actual Mac, the explicit menu now revealed the timeline and date popover;
the oldest September 27 record opened correctly, timeline dragging changed its
cursor, and selecting September 25 at 01:00 loaded that day's final page. This
pass exposed a cramped graphical date-picker label, addressed in the subsequent
interaction and picker optimization.

[Native run 36291994404](https://github.com/Lyle-xub/Recall/actions/runs/36291994404)
passed both macOS and Windows, including macOS packaging.
[CLI run 36291994393](https://github.com/Lyle-xub/Recall/actions/runs/36291994393)
passed all three operating systems.

The subsequent interaction/date-picker work retains these pagination bounds.
Independent final acceptance at `ceb6ea7` passed all three fixture tests again
in 4.890 s: all 3,000 IDs in both directions and as scene nodes, at most 480
metadata records and 260 nodes, and exact oldest row 599. See
[interaction validation](macos-interaction-validation.md) for the final Mac
interaction, timing comparisons, remaining cold-scroll limitation and green
macOS/Windows native plus three-platform CLI checks.

## Reproduction

```sh
swift test --package-path macOS
RECALL_ARCHIVE_PAGINATION_FIXTURE="$PWD/.test-data/archive-pagination-20260927/live-library" \
  swift test --package-path macOS --filter ArchivePaginationAcceptanceTests
```

The fixture builder is retained locally at
`.test-data/archive-pagination-20260927/make-fixture.py`. The baseline full-suite
log is `.test-data/archive-pagination-full.log`; independent results are in
`.test-data/archive-pagination-20260927/final-acceptance.log` and
`final-source-acceptance.log`. Refresh regressions, deliberate mutation and the
full suite are retained there as `refresh-{targeted,mutation,repeated,full}.log`.
