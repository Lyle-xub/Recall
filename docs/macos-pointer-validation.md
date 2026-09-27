# macOS archive pointer validation — 2026-09-27

This follow-up repairs archive pointer scheduling on `feat/cross-platform-cli`.
The implementation was delegated to GPT-6-Sol with xhigh reasoning; final review
and independent local acceptance were performed by the coordinating agent.

## Baseline and cause

The user's Mac is Apple Silicon running macOS 27.2 (26B5091g). Before the change,
11 selected archive/status tests passed, and the complete local Swift suite ran
219 tests with 23 opt-in tests skipped and no failures. The earlier hosted Mac
runs intermittently failed the trailing-pointer assertions after fixed 40–50 ms
sleeps. A single successful local run did not establish that scheduling was safe.

Two implementation issues were identified: the old task began its relative sleep
only when the main actor scheduled it, and cancellation after the sleep completed
could leave an old callback able to consume a newer pending sample. The old tests
also assumed that a burst finished within one frame and that their continuation
would resume after the delivery task.

The repair retains a 60 Hz leading/trailing coalescer, uses a monotonic absolute
deadline, and invalidates obsolete callbacks with a generation counter. Semantic
regressions use a controlled scheduler; native integration checks still exercise
AppKit windows and events with the production scheduler.

## Local GUI acceptance setup

A separate `Recall Pointer Test.app` uses a unique bundle identifier and a library
under `.test-data/pointer-acceptance-20260927/live-library`. The library contains
16 synthetic Aurora screenshots imported through the published CLI. Recording,
microphone and system audio are disabled. The installed Recall application and
its existing library are preserved.

The test application executes the compiled production Recall binary with an
explicit `--data-dir`. Computer-use actions target only this test instance.
This is an on-device GUI check, in addition to the automated native event tests;
it does not claim validation of audio, screen-recording permissions or every
physical mouse/trackpad device.

## Accepted behavior and evidence

- Source repair: `8ca1824`.
- Targeted local suite: 19 tests passed (coalescer, readability and ridge motion).
- Independent repeated checks: 20 rounds, 180 test executions, zero failures in
  38.51 seconds, including the production scheduler/native-window event test.
- Complete local suite: 226 tests, 23 opt-in skips, zero failures in 91.31 seconds;
  all four recognition-status tests also passed.
- Mutation check: removing only the generation guard caused the race regression
  to fail twice: an old callback delivered the new sample early and cancelled its
  timer. The guard was restored before the full suite and GUI build.
- The exact Debug binary used by the GUI test has SHA-256
  `31efdcc2a0fb083d587f0067a81d10488f20ebbcc039ffcc282a4bb02ccd031b`.

On the user's display, computer-use actions verified:

1. The isolated native window showed 16 test records and recording paused.
2. Expanding sample 3 showed its matching image and identity; a coordinate mouse
   click on Back returned it to the stack.
3. Dragging the real SceneKit surface did not accidentally expand a record.
4. Scrolling visibly repositioned the stack while preserving the collapsed state.
5. A coordinate mouse click on a card after scrolling opened sample 15, rather
   than restoring the formerly selected sample 3.
6. Returning to the stack, opening Settings and closing it left every card
   collapsed; system audio and microphone remained disabled.
7. Normal Quit exited the test process. The library reported no owner and SQLite
   integrity `ok`; the installed Recall process remained running.

The screenshots were reviewed through the computer-use tool. No global event
injection script or accessibility-permission change was used. The GUI actions are
observational acceptance; timer ordering and sub-frame cancellation are covered by
the deterministic regressions and the real native-event callback test.

## Hosted checks

[CLI run 36288107659](https://github.com/Lyle-xub/Recall/actions/runs/36288107659)
passed all three platforms at source commit `8ca1824`: Windows 143 CLI assertions,
Linux 153, Mac 194, and 85 shared-core assertions per platform. Mac also passed
15 native library integration tests.

[Native run 36288107654](https://github.com/Lyle-xub/Recall/actions/runs/36288107654)
passed its complete hosted Swift test step and the Windows desktop build, but the
Mac distribution step failed while `actool` compiled the layered icon: its asset
runtime crashed on the macOS 15 host. Commit `52a55dd` moves the native desktop
build to macOS 26 with the same Xcode 26.2 selection. The separate CLI workflow
continues to test macOS 15 compatibility.

[Native rerun 36289366102](https://github.com/Lyle-xub/Recall/actions/runs/36289366102)
passed both desktop jobs, including the full Swift suite, Mac icon compilation,
distribution packaging and uploaded artifacts. This closes the earlier packaging
failure; it was separate from the repaired pointer scheduling.

## Reproduce the automated checks

```sh
swift test --package-path macOS --filter 'ArchivePointerCoalescerTests|ArchiveReadabilityTests|ArchiveRidgeMotionTests'
swift test --package-path macOS
```

Local logs are in `.test-data/pointer-{targeted,full,generation-mutation}.log`.
Independent repeat logs and the synthetic GUI library are under
`.test-data/pointer-acceptance-20260927/`. These local test outputs are ignored by
Git and are not part of a release. The production application in `/Applications`
was not replaced or upgraded by this validation.
