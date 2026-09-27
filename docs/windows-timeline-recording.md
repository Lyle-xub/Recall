# Windows timeline preview and recording recovery — 2026-09-27

This build addresses missing timeline preview actions, black flashes while scrubbing, weak image separation, and capture not resuming after Recall closes.

## Preview

- A persistent `TimelinePreviewView` follows the macOS `historyActions` layout: application icon, recorded time/title, star, recognized-text copy, and recording/transcript details. A search-return action appears when a query is retained.
- `FrameSurface` retains the currently decoded image and its metadata while loading another frame. Only the latest successful request can replace them. OCR selection and copy actions read the displayed frame, not the constructor's original frame.
- Invalid images retain the previous image and identify both the requested and displayed times. Repeated status notifications do not repeatedly retry the same failed path.
- The picture has a 22 px glass outer frame, visible rim and shadow, fitted to its actual aspect ratio. Toolbar text has stronger contrast on dark desktop backgrounds. Preview geometry reserves room for the search toolbar and timeline.
- Timeline queries are invalidated immediately when the cursor changes; delayed icon/database work cannot overwrite a newer cursor. A queued layout/timer refresh retains a pending scrub's preview intent.

## Recording

- A temporary startup/interruption error is separate from `Requested`. It no longer saves an explicit recording stop over the user's intention.
- A subsequent visible-to-hidden transition retries once. Explicit stop remains stopped. In-flight start/stop failures cannot overwrite a newer show/hide intent; persistent failures do not cause an unbounded retry loop.
- Planned recorder shutdown and callbacks from old segments do not interrupt a new session. Hide releases native/XAML backdrops and clears the interface pause in `finally`.
- Tray states distinguish recording, starting, automatically paused, stopped and interrupted. An interrupted request offers **Retry recording**. Initial tray status is synchronized even if startup events preceded window construction.
- Session lock and power suspension remain separate. Closing the UI cannot override either condition.
- `recording-diagnostics.json` in the existing data directory records state, capture activity and the last error, without screenshots, history or queries. Normal library/settings locations are unchanged.

## Acceptance

Environment: Windows 11 build 22621, 1280×800, 100% scale. Reference library: 243 synthetic fixtures. Source comparison: repository macOS `Views.swift` and native-image loading behavior.

- Release, win-x64, self-contained publish succeeded.
- 136 core checks passed, including latest-image cancellation/failure and recording lifecycle races.
- 14 native preview checks passed: both themes, portrait/wide aspect, failure recovery; 24 switching screenshots retained decoded content and settled on the newest image.
- 12 window/runtime/tray integration checks passed using the explicitly gated fake capture backend.
- Real pointer input verified star, details, Back and timeline drag; real Escape released HWND, DWM host backdrop and compositor target. Fake recording resumed after Escape.
- Existing dismissal and navigation regressions are included in the accompanying evidence.

Recording lifecycle integration uses fake start/stop delegates, not screen or microphone recording. Native encoder/device recovery with the user's actual capture settings still requires verification after installing this build. These results do not establish 90% macOS visual similarity or GPU frame rate.

Validation controls require `--visual-parity <directory> --validation-fake-capture`. A visual-parity launch never automatically resumes a saved request and does not collect real foreground-app usage. Production launch retains the real capture backend.

Scripts: `test-windows-timeline-preview.ps1`, `test-windows-recording-resume.ps1`, `test-windows-dismiss.ps1`, `test-windows-navigation.ps1`. The preview script expects the supplied synthetic portrait, wide and invalid-image fixtures.
