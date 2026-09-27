# Archive interaction and date picker validation — 2026-09-27

This pass follows the archive pagination work and the user's report of stutter
during dragging and scrolling, plus incorrectly wrapped date-picker text.
GPT-6-Sol with xhigh reasoning implements the core changes; the coordinating
agent reviews them and checks the application on the user's Mac.

## Baseline and method

Baseline source: `3c80106`. Machine: Apple M1 Pro, 16 GiB, macOS 27.2
(26B5091g), Debug build with the local Xcode beta toolchain.

The actual application runs as `Recall Archive Test.app`, with a separate bundle
identifier and the isolated 5 × 600 synthetic screenshot library described in
[pagination acceptance](macos-archive-pagination.md). Recording and audio are
disabled. The installed application and its library are preserved.

The coordinating agent used computer use for actual window input. A 25-second
`sample` recording overlapped six consecutive operations: scroll up eight pages,
down ten pages, drag downward, drag upward, scroll up ten pages, down eight
pages. The rack returned to its initial page. The sample is retained locally at
`.test-data/archive-interaction-20260927/active-scroll-before.sample.txt`.

Of 15,415 sampled main-thread stacks, 553 were in `advanceFrame`; 401 of these
were at the transaction commit, including 222 write-lock and 138 read-lock wait
stacks. This identifies rendering-lock contention as a candidate, not a frame
time or an FPS measurement. An earlier, mostly idle sample is not used as
performance evidence.

An opt-in automated benchmark creates a real SwiftUI `RootView`, native window
and Metal-backed `SCNView` with synthetic images and asynchronous database/image
loading. It calls only that test window's native event handlers, without posting
global input. It records input-handler duration, scene stages and renderer
callback intervals. Renderer callbacks measure render cadence, not the time a
frame is displayed by the compositor. Timing is diagnostic and is not a flaky
CI threshold.

## Implementation at `3b514e0`

- Wheel and drag input accumulate a destination. The display clock advances the
  camera with the existing ridge animation, replacing an implicit camera
  transaction and completion task for every input event. Cached picking follows
  the camera's current pose. An immediate click keeps extraction centered while
  the pending camera movement settles.
- Scene updates skip empty image transactions and unchanged camera/fog writes.
  Thumbnail identities remain stable when the underlying pixels are unchanged.
- Thumbnail preparation and cache rebalancing run on a utility worker with
  capacity reserved for details. Revision checks prevent stale cache plans from
  replacing a newer viewport or library. Thumbnails and at most two details
  continue to share the 96 MiB cache bound; scratch/GPU/process memory are
  separate from this cache accounting.
- Completed visible images can publish in bounded batches while other image
  reads remain pending. A 150 ms scheduling interval avoids indefinitely waiting
  for every card in a moving viewport; it is not a hard end-to-end deadline.
- The date popover has a full-width calendar, a separate time-input row and a
  full-width submit button. Opening initializes the controls from the current
  timeline position. AppKit manages the native popover focus without a custom
  window-activation helper.

The first GUI picker pass verified independent date and time changes and a
correct September 23, 01:00 timeline jump. It also caught a direct-menu focus
regression in an intermediate build; that build is not the final accepted
result. The final validation below supersedes that intermediate pass.

An experiment that deferred scene changes into an implicit transaction was
rejected. The full suite showed that native camera projection could still see
the previous transform while cached picking used the new transform. Its
intermediate binary (`45753d1…` SHA-256 prefix) also produced an inconsistent
wheel rendering measurement. Explicit commits are retained for actual frame,
page and texture changes; the optimization removes redundant input/empty
transactions instead. Those intermediate timing logs remain local diagnostic
evidence and are not the final performance result.

## First accepted optimization: matched native benchmark

The same harness was used for the baseline and both `3b514e0` runs:
start at row 300, 480 bidirectional wheel inputs, then 480 bidirectional drag
inputs, with a final visible-image completeness check after each phase. Each
input phase targets four seconds at 120 inputs/second; main-thread stalls extend
its actual elapsed time. Both implementations retained a maximum of 260 nodes.

| Metric | Baseline | `3b514e0` run | `3b514e0` repeat |
| --- | ---: | ---: | ---: |
| Wheel input p95 | 32.986 ms | 6.126 ms | 2.357 ms |
| Wheel phase elapsed | 33.505 s | 21.937 s | 21.134 s |
| Wheel render-callback interval p95 | 25.453 ms | 49.679 ms | 49.656 ms |
| Wheel stop to complete and settled | 2.891 s | 3.424 s | 3.836 s |
| Drag input p95 | 17.207 ms | 0.070 ms | 0.066 ms |
| Drag phase elapsed | 6.635 s | 4.138 s | 4.047 s |
| Drag render-callback interval p95 | 25.050 ms | 12.535 ms | 11.803 ms |
| Drag stop to complete and settled | 3.023 s | 1.838 s | 1.834 s |

Every final stopped viewport filled completely: 164/164 after wheel input and
165/165 after dragging. The baseline rendered few images during the cold wheel
phase (readiness samples 0%, 0%, 0%, 38%), whereas final runs showed roughly
12–68%. During final dragging, readiness was approximately 90–100%. Input is
identical, but the amount of textured content rendered during it is not.

These results support lower input latency and substantially improved dragging.
They do **not** show uniformly smoother cold scrolling: its rendering tail and
post-stop fill time remain worse than the baseline in this benchmark. The
remaining cold-load long frames are an explicit limitation, not discarded
outliers, and no stable 60 FPS claim is made.

Logs are `.test-data/archive-interaction-matched-before.log`,
`archive-interaction-matched-after-final.log` and
`archive-interaction-matched-after-repeat.log`. Earlier `after`/`implicit` logs
are diagnostic iterations and are not substituted for this comparison.

### Additional cold-scroll investigation

After the correctness work passed, a fresh adjacent baseline of unchanged
`ceb6ea7` measured a 25.04 ms wheel render-callback p95 rather than the earlier
49.7 ms. This demonstrates run-to-run sensitivity; the earlier measurements are
retained and are not replaced with the more favorable number.

A diagnostic process sample found main-thread transaction-lock waits and render
queue work in `C3DImageGetTextureRawData` / the bitmap-cache mutex. The sampled
benchmark itself missed the ten-second image-fill requirement (110/164), so that
instrumented run is retained as diagnostic failure and excluded from timing
comparisons. Sampling is not assumed to be free.

Passing the existing `CGImage` directly to artwork materials was then tried in
two assignments, without changing pixels, resolution, publication cadence or
scene timing. It passed the material/identity checks but measured 45.84 and
50.28 ms wheel callback p95, with no demonstrated benefit. That experiment was
reverted; passing tests alone are not evidence of a performance improvement.
Re-running the original implementation afterward measured 46.18 ms, reinforcing
the need for adjacent repeats instead of attributing every difference to code.

A second experiment prepared independent artwork materials with SceneKit before
installing them, using at most two workers and only resident identities. Both
the asynchronous API and the SDK-supported secondary-thread synchronous API
were tested. Cancellation, page replacement, renderer replacement, appearance
changes and the original full-resolution color output passed five regressions.
However, only 2–4% of images were ready during wheel input. The asynchronous
version's callback p95 was 28.88 ms, but its wheel phase took 24.25 s and its
post-stop fill took 6.94 s. Combining completed installs into one commit did not
fix the poor readiness. The synchronous version still spent a median 204 ms
(p95 245 ms) preparing a resource, took 28.59 s for wheel input and 6.92 s to fill
afterward. This disproved the intermediate hypothesis that only asynchronous
dispatch was delaying preparation. Lower callback times with fewer displayed
images were not accepted as a win. The entire preparation queue and its tests
were withdrawn; experiment logs and source are retained only under ignored
`.test-data/`, including `archive-cold-wheel-prepared-sync.log`.

A final, smaller experiment merged screenshot installation into the existing
explicit camera-frame transaction. Four controlled checks passed, including
latest-publication coalescing, inactive/replaced nodes, publication from the last
frame callback and windowless rendering. An adjacent original-source run gave
25.17 ms wheel callback p95, a 14.27 s wheel phase and 2.904 s post-stop fill. Two
candidate runs gave 24.98 / 25.26 ms, 12.38 / 13.21 s, and 2.956 / 2.989 s,
respectively. Both filled 164/164 wheel and 165/165 drag images, but frame cadence
was unchanged and the phase durations overlapped the unchanged implementation's
earlier 12.66–14.27 s range. This experiment was also withdrawn. The retained
source is `ceb6ea7`; no artwork-preparation queue or extra frame-install state
is included. The accepted benefits and the remaining cold-scroll limitation
are those in the first matched benchmark above.
The adjacent logs are `archive-cold-wheel-image-commit-before.log`,
`archive-cold-wheel-image-commit-after.log` and
`archive-cold-wheel-image-commit-repeat.log` under `.test-data/`.

## Date picker layout

The 360-point component was rendered in native hosting windows with `en_US` and
`zh_CN` locale settings, in both light and dark appearance. All four images were
independently inspected: the title stays horizontal, the calendar and month
navigation fit, and the time row and submit button remain fully visible.
The controls retain the application's existing English labels while the native
date/time formats follow the chosen locale.

Images are retained locally in `.test-data/archive-picker-renders/`. The native
layout regression checks both controls' bounds. This component check supplements
the real application popover interaction; it does not replace it.

## Final real Mac interaction

The coordinating agent tested production source `3b514e0`, binary SHA-256
`223c0e23402edfafcb54162ca89a9139a071e167f115a0a9b03263b399033959`,
in the isolated application on the user's Mac:

- The explicit menu opened the new popover in the real application. Its title
  stayed horizontal, and the calendar, separate time row and button were fully
  visible at the native window size.
- A 20-page wheel operation loaded the middle of the archive. Subsequent upward
  scrolling and downward/upward drags left the application responsive and did
  not accidentally expand a card.
- Clicking a visible card after scrolling expanded Day 3, row 262 at 12:16 PM.
  Its complete image and actions stayed centered. Rewind opened the matching
  recorded screen and timeline.
- From the timeline, changing time to 01:00 and then date to September 23
  preserved both inputs. Submit moved the actual cursor to September 23 at
  01:00, and returning to the archive loaded that day's oldest page.
- Normal Quit terminated only the test application. SQLite integrity remained
  `ok`, all 3,050 rows remained, and no owner file remained. The installed
  application was still running with its original process ID.

Two attempted final `sample` captures encountered the computer-use tool's
`noWindowsAvailable` error partway through the action sequence. The test process
was still alive and no crash report was found. Raising/re-reading the window
restored interaction, and the remaining checks above completed. These incomplete
captures (`active-scroll-after*.sample.txt`) are excluded from before/after
performance comparisons; the matched native benchmark is the timing evidence.

The GUI observations establish functionality and layout, not a measured display
frame rate. The isolated synthetic library also does not represent every
possible user screenshot, codec or recording workload.

The final scheduler-test follow-up at `1e91b5a` keeps the same production waits
and has binary SHA-256
`9dc379a02866ea074069b7ad6fd8c5687744e5ad0cffb559534d6b03b8559b28`.
That exact binary was copied into the isolated test application, launched again,
and its menu-opened date popover was visually checked. Normal Quit and the
unchanged database/process checks passed again. The installed Recall was not
replaced by this development build.

After the additional recording-test follow-up, the retained test application
contains source `ceb6ea7`, binary SHA-256
`665b425341c4f392092343f9c28a438432238ce099ecc174874c057ce13d4ba8`.
Its startup showed the same paused fixture and 3,050 records; normal Quit passed.
The interaction and date-picker implementation remains the one measured above.

After withdrawing the additional cold-scroll experiments, a standard build
reproduced that exact SHA-256. The final application pass then navigated to
September 25, scrolled down 20 pages and up eight pages, and dragged in both
directions. Clicking the visible central card opened Day 3, row 220 at 13:40
with the full image centered; its Rewind action opened the matching recorded
screen. The menu-opened date picker fit completely and initialized to September
25 at 13:40. Normal Quit completed, database integrity stayed `ok`, no owner file
remained and installed Recall still had its original process ID. This last pass
uses the final binary, not a candidate build.

## Automated acceptance

The first hosted run at `3b514e0` exposed two timing assumptions in existing
tests: the new partial-image deadline could legitimately fire before an old
cohort test's fixed sleep completed, and recognition-status sleeps could
overshoot their intended debounce window on a busy host. Neither failure was
accepted by retrying until green.

At `1e91b5a`, publication and recognition tests use injected waits and explicit
completion gates. Production defaults remain a 150 ms absolute image-publication
deadline and a 180 ms recognition debounce. Separate tests still verify partial
publication while image reads are blocked. Recognition tests deliberately
release cancelled callbacks and wait for their actual tasks, checking that they
cannot revive a dismissed view or overwrite a newer selection.

The next hosted run passed those checks but exposed another pre-existing
wall-clock assumption in `RecordingLifecycleTests`: a requested 5 ms sleep could
last longer than the tested 30 ms recording-resume delay. At `ceb6ea7`, explicit
gates now control resume, slow start and slow stop. A new regression checks that
a stale resume must wait again after reopening, and that manual pause/shutdown
prevent late callbacks from starting recording. The production state/revision
logic is unchanged, with its original 300 ms default delay.

- Targeted publication/status checks: 13 tests passed; 20 repeated rounds of the
  five scheduling regressions passed all 100 executions.
- Recording lifecycle: all six tests passed in 20 repeated rounds (120
  executions). Logs: `.test-data/recording-lifecycle-repeat/`.
- Complete local Swift suite at `ceb6ea7`: 248 tests, 27 conditional skips, zero
  failures, 91.351 s. Log: `.test-data/recording-lifecycle-full-final.log`.
- Independent acceptance of the real GUI fixture at `1e91b5a`: three tests passed in
  4.908 s. All 3,000 identities were reached in both directions and became real
  scene nodes; resident metadata stayed at most 480, nodes at most 260, and the
  oldest target remained row 599. Log:
  `.test-data/archive-pagination-20260927/interaction-final-acceptance.log`.
- After all experimental source was withdrawn, 16 archive rendering/readability/
  footer checks passed in 3.219 s. The coordinating agent independently repeated
  all three fixture acceptance tests at `ceb6ea7`: zero failures in 4.890 s,
  all 3,000 identities in both directions and in actual scene nodes, maximum
  260 nodes, and exact bottom row 599. Its 52 SQL queries measured 29.019 ms
  median, 33.933 ms p95 and 159.179 ms maximum. These query timings do not measure
  rendering. Log:
  `.test-data/archive-pagination-20260927/interaction-final-ceb6ea7-acceptance.log`.

At `ceb6ea7`, [native run 36295366982](https://github.com/Lyle-xub/Recall/actions/runs/36295366982)
passed macOS and Windows, including packaging. [CLI run 36295366952](https://github.com/Lyle-xub/Recall/actions/runs/36295366952)
passed macOS, Windows and Linux.

## Reproduction

```sh
RECALL_ARCHIVE_INTERACTION_BENCHMARK=1 \
  swift test --package-path macOS \
  --filter ArchiveInteractionPerformanceTests
```

The benchmark is skipped unless explicitly enabled. Ordinary full-suite and
pointer/paging correctness checks run independently of these timing samples.
