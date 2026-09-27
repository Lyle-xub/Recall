# Foreground performance and distant timeline navigation — 2026-09-27–28

## Scope and diagnosis

The user reported Recall page and animation stutter while Biu Player was open.
The installed baseline was `0f0fd32` (the same product source as `50e8088`),
running on an Apple M1 Pro with 16 GiB memory and macOS 27.2.

Local process inspection caught Biu's cloud-video worker software-encoding with
`libx264`, `preset fast`, and 30 fps output, using approximately 358–490% CPU
(100% is one logical CPU). Recall's saved-screen OCR was also active. System
samples showed CPU, GPU and memory pressure; they do not establish an
application-specific compatibility fault or attribute all GPU use to Recall.
Biu's jobs start and finish independently. Neither its settings nor its jobs
were changed during this work.

Opening Recall already stops accepting new captures, but previously did not
defer the next saved-screen OCR job while the user interacted with the page.
The existing background recovery interval considered thermal and low-power
state, but not local input or memory-pressure notifications.

## Implementation

- A process-local budget watches Recall's own window input and native animation
  settlement. It uses one extensible idle sleeper and publishes state changes
  only at budget boundaries; pointer events do not publish SwiftUI model state.
- Saved-screen OCR waits before admitting its next job and checks again after
  the asynchronous database read. Work already admitted finishes and commits.
  Pending records remain durable, including cancellation during cleanup.
- Critical memory pressure defers new background jobs. Warning pressure leaves
  them making progress with a longer recovery interval; normal-state recovery
  is debounced so obsolete callbacks cannot undo newer pressure.
- Visible thumbnail decoding retains four workers during interaction. Nearby
  speculative loading and hover detail wait; stationary hover resumes when the
  budget recovers. Memory pressure reduces visible decoding to two workers.
  Explicitly opened detail images remain available. The shared thumbnail/detail
  cache limit stays at 96 MiB; this excludes transient and GPU allocations.
- Native motion holds the interaction budget through settlement, cancellation,
  hidden views and teardown. Stopping the budget cannot restart a loader or
  display clock.
- System memory pressure temporarily disables the scene's depth-of-field pass;
  recovery restores it without restarting animation. Normal interaction retains
  the original scene quality to avoid a visible blur change at every idle edge.

This does not suspend every kind of background work. For example, an already
running OCR job and explicit user requests are allowed to complete. No capture
quality, OCR accuracy, saved screenshot, Biu setting or user library content is
changed by this policy.

## Validation method

Five focused tests cover input coalescing, pressure recovery, cancellation,
the database-read race, durable work restoration, in-flight commit, initial
native binding, motion leases, stopped-state guards, visible loading, explicit
detail and stationary hover recovery. Twenty repeated rounds passed (100 test
executions). An early test-hook over-fulfillment was corrected before repeats.

The opt-in archive benchmark hosts the real SwiftUI page and SceneKit renderer
in a synthetic native window. The harness now dispatches AppKit window events,
matches the actual overlay window level and rejects runs without a visibly
presented window. Both comparison versions use this same corrected harness.
Original occluded-window measurements are discarded. Separate profiler runs
are diagnostic only and excluded from timing comparisons.

Renderer callback intervals are not physical display FPS. The synthetic page
has no OCR backlog, so it cannot measure the benefit of deferring OCR. The
remaining dense cold-scroll loading cost is explicitly assessed separately
from the scheduling policy.

An adjacent baseline/candidate diagnostic pair filled every final viewport
(164/164 after wheel input, 165/165 after dragging), with 260 resident nodes.
Cold wheel elapsed time was 43.08/33.60 seconds and renderer callback p95 was
130.46/44.56 ms; hot drag elapsed time was 4.015/3.995 seconds and callback p95
was 13.60/15.08 ms. These numbers are **not an accepted speedup claim**: the
production OCR worker dropped from roughly 155% CPU in the baseline to idle by
the candidate's end, and Biu's encoder was absent in this pair. The candidate
also still changed depth of field during interaction; the final implementation
narrows that adjustment to memory pressure. Raw adjacent logs are
`visible-A-head.log` and the corresponding B run in the ignored artifact folder.

Final regression and native observations are recorded below.

## Additional request: distant timeline cards

The user also reported a long wait for cards after a large timeline jump. The
near-time query already read the destination, but same-day navigation replaced
its records with the starting page to preserve the outgoing picture. Only the
target identity and row survived. Intermediate page reads then had to fetch
the destination again. Across days, destination metadata could survive but
image loading still followed only the current viewport. The extraction-sized
preview did not start until camera settlement.

The coordinating agent prepared a second isolated Mac library with 3,052
synthetic memories, including 3,000 `.recallvideo` references to a local test
movie. This exercises native video frame extraction rather than only PNG
decoding. Recording, microphone and audio capture are disabled in this fixture.
Its paths and baseline executable hashes are recorded in the ignored
`.test-data/far-navigation-20260927/manifest.json`.

The budget-only baseline rendered the video cards and completed a 25-page
native scroll into the row 386–468 metadata window. The tool's operation time
includes input delivery and observation and is not a navigation-latency metric.
Attempts to operate the date popover did not produce verified target changes;
those interactions are excluded from timing evidence. Distant target
ordering and readiness are therefore checked with mounted native integration
tests as well as final application observations.

The implementation retains one bounded destination page alongside the current
page, and prepares at most 24 destination images. The selected card's 1600-pixel
preview receives the first available decoder slot and shares the existing four
slots (two under memory pressure). Its pixels also populate the detail preview
cache, avoiding another extraction after the camera settles. Intermediate
pages retain this preparation; arrival reuses the resolved destination records.

Decoder completions refill individual slots instead of waiting for an entire
batch. Repeated intent generations for the same immutable path share one read.
Cancelled or obsolete reads keep their occupied slots until they actually
finish, preventing rapid retargeting or root changes from exceeding the limit.
Cache installation is serialized, with preview priority. Inserts already below
the memory cap avoid asynchronous rebalance work; an over-budget plan checks
the current protected paths without restarting for every viewport update.

Navigation intent is separate from the displayed timeline date. Cancellation
clears that intent, so later maintenance cannot reopen a dismissed card. Archive
path merges update both bounded pages and preparation references, and a fresh
near-time query resolves any changed rank or representative record before the
next settlement. Old generations cannot extract a replacement target.

The combined targeted run passed 20 tests. Deterministic gates cover independent
slot refill, 100 generations sharing one preview, stopped/root-replaced reads,
stale result rejection, destination protection during intermediate paging,
cache rebalance during 2,000 viewport changes, maintenance during A-to-B intent,
cancelled intent, and archive path/rank changes at the page boundaries.

The real-movie test produced its first preview in 0.219 seconds and reused it
for extraction in 0.0076 seconds, with exactly one preview decode. The mounted
SwiftUI/SceneKit test initialized at row 20, navigated toward row 550 and then
retargeted row 530. Destination pixels reached the renderer after 0.750 seconds,
while the camera was at row 533.55 on its first journey; only the final row 530
card opened, at 3.323 seconds. These are local functional observations, not
before/after speedup claims or a latency promise for large production videos.
The latter integration test uses PNGs; the separate movie test exercises the
actual `.recallvideo` extraction/cache path.

Three repeated rounds of budget/destination tests passed all 42 executions.
For stable CI coverage, the final mounted test explicitly holds its native
clock at row 20 until destination pixels arrive, and checks that the source
metadata is still mounted. It then releases the clock, runs the actual native
motion, retargets and verifies final extraction. This separates the scheduling
contract from machine-dependent timing. The natural-clock numbers above remain
diagnostic evidence from the earlier run, not mandatory CI thresholds.

## Final acceptance

The first full local run encountered an existing independent VisionKit test
failure: `TimelineTests.testNativeLiveTextSupportsWordRangeSelection` received
an XPC 4097 error from `com.apple.mediaanalysisd.service.public` after 125 seconds.
An isolated repeat returned no expected recognized word after 97.6 seconds.
This test calls `ImageAnalyzer` directly, without `AppModel`, the new budget,
or Recall's OCR queue. The test source was not weakened or changed. Rerunning
with this single system-service test explicitly excluded passed **284 tests,
28 optional skips, zero failures**, in 61.9 seconds. Its original failure remains
part of the acceptance record. `VisibleRecognitionTests` exercised actual
saved-screen OCR and durable database commit with Recall open and passed in
0.89 seconds.

On the actual Mac, the final Debug candidate was run in both isolated app
fixtures. The video-reference library completed 25-page forward/reverse wheel
gestures, loaded row 386–468 metadata, and expanded row 420 with the correct
video-frame image. The motion library completed forward/back detail transitions
for the 3200×2000 image with 300 text regions. The right-side Play button started
the test movie from its five-second poster; the observed frame read 5.500 seconds
and the normal AVPlayer controls appeared. No black rectangle was present in
that observation; a screenshot is not a frame-by-frame flicker measurement.

An auxiliary Debug GUI OCR probe seeded 24 synthetic pending records, but its
worker requests were deferred after a timeout, so that run is not accepted as
evidence of OCR pause/resume. The synthetic records were restored afterward.
The real-queue XCTest above and deterministic gate tests remain the validated
evidence for that behavior. No pending records were injected into the user's
library. Both test apps exited normally after GUI acceptance.

The Developer ID Release build from `ed691c8` was installed to
`/Applications/Recall.app` on 2026-09-28 at 00:46 +08:00. Its designated
requirement remains `studio.rewind.replica` with team `GXVN75MDQN`.
The Release and installed executable SHA-256 are both
`f6e1e2b254471a445f00b8fb9a02e200cb23392ea94744cf0d02eb2514947ee6`.
The previous application, settings and SQLite backup are retained in the ignored
`.test-data/install-macos-interactive-20260928/` directory, with a JSON receipt.

The previous process was no longer running immediately before replacement,
despite recording earlier in this session. The installed application was opened
and then hidden with recording still unrequested; no automatic recording restart
was forced. Settings matched the pre-install snapshot, the database quick check
passed, and the record count remained 27,943. The actual installed OCR initially
deferred two jobs, then successfully resumed PPOCR processing (30.3, 27.2 and
3.8 second observations). Thus runtime recovery was observed, but those variable
cold-start/contended times do not establish an OCR throughput improvement.

The first native CI run passed the Windows job and all Mac tests except the
mounted motion fixture. Its Reduce Motion environment advanced directly to
row 550 despite stopping the animation clock. Forcing Reduce Motion on locally
reproduced that failure. The test host now explicitly uses the SDK-exported
`_accessibilityReduceMotion` override with false; the original row-20, source-page
and final extraction assertions remain. Three navigation tests and three further
mounted repetitions passed after this test-only correction. Product sources and
the installed executable are unchanged. The Mac/Linux/Windows CLI matrix for
`ed691c8` passed in run `36334229414`.

Final CI at `aba2287cdd6947892dd3a6e01b26431ff8a0bfab` completed successfully:

- [Native desktop builds](https://github.com/Lyle-xub/Recall/actions/runs/36335071679)
  passed on Mac and Windows, including Release packaging and artifact upload.
  The Mac suite reported **285 tests, 29 skips, zero failures**, in 74.2 seconds.
  Skips are opt-in checks or require local fixtures/runtime preparation; the
  bundled OCR test is the additional skip compared with the local run.
  The unchanged Live Text selection test passed in 1.546 seconds on this runner.
- [CLI matrix](https://github.com/Lyle-xub/Recall/actions/runs/36335071686)
  passed on macOS, Linux and Windows.

The installed `ed691c8` build and validated `aba2287` have identical
`macOS/Sources` contents. The latter changes only the motion test fixture and
this validation record, so another installation is unnecessary. The local
Live Text service failure remains documented above despite its CI success.
