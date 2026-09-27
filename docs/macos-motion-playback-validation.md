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
- `git diff --check` passed. The signed Release build and installation receipt are recorded separately after packaging.
