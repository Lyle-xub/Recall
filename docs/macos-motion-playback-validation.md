# Timeline, playback and app usage acceptance — 2026-09-27

## Scope

The glass archive should travel continuously to the requested timeline position before extracting its card. Opening the video detail page should move and resize the same image, with a reverse transition on return. The bottom-right play button should keep the selected screenshot visible while native playback prepares, without exposing an unready black video rectangle. App usage should distinguish categories, label the selected day correctly, retain its layout during date changes and mark days containing recorded usage.

## Baseline and isolated Mac fixture

- Starting commit: `347d5a5` on `feat/cross-platform-cli`.
- Host: Apple M1 Pro, macOS 27.2; native AppKit/SwiftUI/SceneKit/AVKit execution.
- The installed baseline GUI has the same macOS source as `6c57b11`. Its executable SHA-256 was `a312143e942a6c5dbc5bc0df0f729719f32bc89676bab4363f7a46b428977e70`.
- GUI testing uses the separate `local.recall.motion-playback-acceptance` bundle and a temporary synthetic library. Production recording and the user's library remain separate during development.
- The fixture contains 3,051 memories, a 12-second 960 × 600 H.264 movie with a burned-in time display and a screenshot at 5 seconds. It also contains 50 synthetic app-usage intervals spanning eight categories, empty dates, previous-month dates and a midnight boundary, including an interval covering the movie.
- Fixture scripts, manifest and raw test logs are local ignored artifacts under `.test-data/motion-playback-20260927/`.

The baseline GUI reproduced the unchanged Today label after pressing Previous day. With the selected screenshot at 5 seconds, the baseline player visibly began around 0.5 seconds because seeking could select an earlier keyframe. A single GUI screenshot did not capture the reported transient black rectangle; first-frame readiness is therefore also checked with native player tests.

## Implementation

- Timeline destinations carry a navigation generation separately from metadata requests. Retargeting uses the currently displayed camera position, and the mounted renderer reports settlement only after committing its final pose. Only the latest released gesture may open a card.
- Near-time resolution retains the currently visible metadata while motion starts. Intermediate row demands page the archive as it moves. Cross-day cards keep their node identity and animate lateral movement.
- Image navigation keeps one native selectable image surface mounted. Its position, size and corner radius interpolate from the visible thumbnail or history preview into the detail layout; reversal starts at the current presentation. Native settlement reveals the detail controls. Reduced motion applies the destination directly. OCR text selection and image dragging do not trigger navigation.
- Playback performs an exact, completed seek. The screenshot stays mounted underneath an initially transparent native player; native display readiness and valid fitted dimensions gate the handoff and audio start. Replacement, cancellation and failed playback cannot reveal or restart an old player.
- App usage uses a stable category palette with category symbols and text. Date navigation and an explicit return-to-today action are separate. The last report remains visibly attributed to its original day while a newer request loads; generation checks reject late responses.
- Calendar dots use effective foreground-usage intervals, including private activity and excluding unavailable intervals. Month queries run off the UI actor and are cached. Local-calendar boundaries handle midnight and daylight-saving changes.

## Validation

### Native GUI observations before the added image transition

- The actual bottom-right play button presented the burned-in movie time at 5.500 seconds on the first captured state, matching the selected screenshot. Repeating with a double click also presented the correct sought frame and rounded fit. No black rectangle appeared in those captured states; these are UI snapshots, not frame-by-frame recordings.
- Today changed to Yesterday (September 26), then September 25. Returning to Today restored September 27. Selecting August 25 in the previous month displayed the matching 7h 20m report.
- The empty September 25 report retained the chart, category area and Apps positions. The category colors and icons were visibly distinct; the selected weekday had a separate circular axis indicator.
- Calendar dots matched the synthetic records on September 16, 17, 20, 24, 26 and 27, and August 25 and 30. September 25 had no dot.
- Native scrolling moved the glass rack from Day 3 Row 1 through Row 152, with paging. The renderer-to-extraction ordering is covered separately by the mounted native integration test.

### Final source and image-transition acceptance

- Full Swift suite: **269 tests, 27 optional tests skipped, 0 failures**, 125.3 seconds. Log: `.test-data/motion-playback-20260927/full-suite-final.log`.
- The final transition/player/OCR selection subset passed **14 tests**. Mounted `NSHostingView` tests exercise forward/reverse geometry, repeated entry and reduced motion. They caught and prevented a queued history-completion callback from revealing detail controls before the detail image had settled.
- Native tests assert intermediate image rectangles and radii, one retained surface, cancellation, reloading after cancellation, OCR selection, keyboard/AX entry and exact sought player pixels. These provide temporal checks beyond GUI snapshots.
- Final Debug executable SHA-256: `8faac2d65aa1d4e05fe4eaabb833e19f75d0fb9519b9534873f0b9ba56d8e520`; the ad-hoc-signed fixture copy is `9d5a0a779290b683c4f7c6adb25c1ed990b713ed54d2b27e2e2b144528548d60`.
- In the actual Mac app, a pointer click on the history image opened the video detail page; Back restored the history picture. The accessible image action reopened it. Opening and immediately returning, followed by reopening, left the controls functional.
- Playing after the new transition showed burned-in time **5.417 seconds** in the first captured state (native progress approximately 5.38 seconds), with the fitted rounded image and native playback controls. Returning removed those controls and restored the poster.
- `git diff --check` passed.

### Signed installation

- Source commit: `c40c0e18a9eee372d454cd5f55288bba2e7d700e`.
- `scripts/build-macos.sh` completed successfully. The Developer ID signature verified with `codesign --verify --deep --strict`; its designated requirement matches the previous installation (team `GXVN75MDQN`).
- Updated `/Applications/Recall.app` at 16:39 Asia/Shanghai. Installed executable SHA-256: `676eeeec65a48166584e2fbfbff7e037e28c05264e36a65554a94e98fc03ffa8`.
- The old application exited through its normal Quit action, allowing capture to finish. The previous bundle, SQLite snapshots and settings are retained under `.test-data/install-macos-motion-20260927/` with a JSON receipt.
- The restarted application displayed the same 20,687 memories. Settings remained identical. Its prior recording request was restored; CLI control confirmed `active: true`, `requested: true`, `owner: desktop`, with no error.
- Commit `c40c0e1` passed both remote workflows: [native macOS and Windows builds](https://github.com/Lyle-xub/Recall/actions/runs/36306745555) and [CLI checks on macOS, Windows and Linux](https://github.com/Lyle-xub/Recall/actions/runs/36306745577).

## Follow-up: image-transition performance

The user reported stutter after trying the installed transition. A second isolated fixture adds a 3200 × 2000 screenshot with 300 selectable OCR regions and its own recorded-usage interval. It is generated by `.test-data/motion-playback-20260927/seed-dense-transition.py`; the synthetic library now has 3,052 memories. The GUI baseline for this follow-up is the signed Release implementation from `c40c0e1`.

Each animation tick previously resized and laid out the native image, its OCR hit regions and shadow. The revised implementation lays out a backing surface at the larger endpoint size, then changes only layer composition during flight. It preserves the same image, selection and 0.48-second motion. The display link requests the current screen's supported refresh rate instead of fixing it at 60 Hz. Actual backing-layer coordinates, including AppKit's anchor and flipped coordinates, are covered by regression assertions.

The same opt-in Debug benchmark opens a real 1440 × 900 native window at 2× backing scale, uses a decoded 3200 × 2000 image and 300 OCR regions, and completes 24 alternating transitions. No sampling profiler runs during the measurements:

| Metric | Baseline | Optimized run 1 | Optimized run 2 |
| --- | ---: | ---: | ---: |
| Image layouts | 675 | 36 | 36 |
| OCR layouts | 675 | 24 | 24 |
| Animation work median | 0.476 ms | 0.247 ms | 0.238 ms |
| Animation work p95 | 1.606 ms | 0.574 ms | 0.582 ms |
| Animation work maximum | 13.358 ms | 3.097 ms | 2.446 ms |
| Display-link callback interval p95 | 17.219 ms | 12.183 ms | 12.046 ms |

Callback intervals measure main-thread delivery, **not physical screen FPS**. The interval improvement also includes requesting the host's 120 Hz capability instead of 60 Hz. The measured transition duration remained approximately 0.48 seconds. Raw logs are `transition-perf-before.log`, `transition-perf-after-corrected.log` and `transition-perf-after-repeat.log` in the local artifact directory. An earlier intermediate transform implementation failed actual-layer geometry assertions and is excluded from these results.

- Relevant regression tests: **15 passed**. Full suite: **271 tests, 28 optional skipped, 0 failures**, 113 seconds (`full-suite-composition.log`). The extra optional skip is the explicitly invoked performance benchmark above.
- Final Debug SHA-256: `d8fb64006fabced65cddd51b0cef79f00de4f4bef8a3d0a5247eb543e57187a8`; signed fixture SHA-256: `88098a3c05dff41e210a74f6c85acf096c05ab362ab21d854b729818ecb35415`.
- Actual Mac pointer testing selected five lines from the dense OCR fixture without navigating, then opened details from the image's blank area. The selected text stayed aligned and preserved through forward and reverse transitions. Immediate open-and-back returned cleanly.
- The original movie fixture still presented burned-in time **5.417 seconds** after entering details and pressing Play, with correctly fitted rounded video and no black rectangle in that captured state.

### Performance build installation

- Source commit: `0f0fd320c017c7f7abf5de7df67bd2fa794a0802`. Release packaging completed; `codesign --verify --deep --strict` passed, with the same Developer ID designated requirement as the previous installation.
- Installed `/Applications/Recall.app` at 2026-09-27T17:16:55.537358+08:00. Executable SHA-256: `0427577d91c49649f65ddb8a3e9ca19f4d501c2fdc096942af076b119b250e89`.
- The previous `c40c0e1` application quit normally. Its bundle, closed-library SQLite snapshot and settings are retained in `.test-data/install-macos-composition-20260927/`, alongside the installation receipt. The snapshot passed SQLite `quick_check`.
- Restart displayed all 21,384 existing memories. Settings were unchanged; restoring the previous recording request resulted in `active: true`, `requested: true`, `owner: desktop`, with no error. A subsequent read counted 21,390 memories.
- Commit `0f0fd32` passed both remote workflows: [native macOS and Windows builds](https://github.com/Lyle-xub/Recall/actions/runs/36308609122) and [CLI checks on macOS, Windows and Linux](https://github.com/Lyle-xub/Recall/actions/runs/36308609096).
