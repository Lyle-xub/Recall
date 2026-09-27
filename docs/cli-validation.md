# CLI validation and handoff — 2026-09-27

Work is isolated on `feat/cross-platform-cli`, based on
`feat/windows-visual-parity` at `12c9aac`. The original visual-development checkout
and README are unchanged. See [CLI commands and library rules](cli.md).

## Completed behavior

- `recording start` can launch a headless owner; `service start` remains idle.
  Concurrent starts share one owner. Native Mac shutdown drains work without
  entering AppKit's nested quit loop.
- Index jobs persist per-record progress and request receipts. Cancellation,
  bounded RPC waits, late acknowledgements and stale-owner recovery retain an
  inspectable outcome instead of replaying an uncertain mutation.
- Native inference shares one owner per user/engine, verifies process and model
  identity, and prevents cross-library model deletion or replacement during use.
- Portable capture refuses unsupported exclusion/display/audio requirements.
  Portable optimization preserves dimensions and OCR, validates encoded output
  and skips unrecognized/active media. Incomplete exports are not published.
- Configuration preserves unrelated fields. Cleanup retains a recovery journal
  when database deletion commits but physical media deletion is interrupted;
  a later writable open retries only safe, unreferenced media paths.

## Local acceptance

| Check | Result |
| --- | --- |
| Published Mac ARM64 CLI, real Tesseract, native helper and real models | 206 assertions passed |
| Shared C# database, retrieval, privacy and model contracts | 85 assertions passed |
| Swift native CLI and storage cleanup | 15 tests passed |
| Independent maintenance acceptance, Debug and published bundle | 16 checks passed per build |
| Independent native owner / OCR / export acceptance, Debug and published bundle | 12 checks passed per build |
| WinUI source compilation on Mac | 0 errors / 0 warnings |
| Self-contained Mac archive and 214-file SHA-256 manifest | Verified |

The independent maintenance checks used actual FFmpeg/FFprobe and an intentionally
invalid encoder result. They confirmed unchanged original media on failure, full
image dimensions, preserved OCR/search, pending-image protection, complete exports,
settings preservation and owner shutdown. The native process checks used a temporary
Mac-format library and a synthetic Aurora image, exercising actual Tesseract OCR,
configuration, star mutation, job receipts, export, service exit and SQLite integrity.
No user history was modified or captured by these checks.

The published bundle used the already-installed Qwen3-1.7B-Q8_0 model and native
llama-server: two concurrent grounded answers reused one model process, completed
in 10.2 seconds, and used approximately 3,986 MiB engine RSS. Native Whisper base
transcribed a generated speech fixture and persisted its transcript in 1.2 seconds.
The test-owned engine processes exited afterwards. These are observations on this
Mac, not cross-platform performance guarantees; no model download was required.

## Hosted CI

The initial completion run
[36286656941](https://github.com/Lyle-xub/Recall/actions/runs/36286656941)
passed Mac (194 CLI assertions and 15 native integration tests) and Linux
(153 CLI assertions), with 85 shared-core assertions on all three platforms.
Its Windows packaged test exposed an inherited output-handle bug during concurrent
headless service startup. Source commit `29f4147` corrects it using a native Windows
launcher that inherits no caller handles. Real child-process regressions cover
inheritable file handles, Unicode/space paths, empty arguments, embedded quotes and
trailing backslashes. The 30-second command timeout was retained.

The correction is validated by
[final CLI run 36287203829](https://github.com/Lyle-xub/Recall/actions/runs/36287203829):
all three jobs passed. Windows passed 143 CLI assertions, Linux 153, and Mac 194;
all platforms passed 85 shared-core assertions, and Mac passed 15 native integration
tests. The run publishes the self-contained platform archives and their SHA-256
files.

Linux also passed actual capture, OCR, search, stop, optimization and export inside
a private Xvfb desktop containing only generated Aurora text. Its uploaded
`Recall-CLI-Linux-capture-evidence` artifact records two frames, a successful search,
two optimization completions, SQLite integrity `ok`, and 15.44 seconds elapsed in the final run.
The script creates a new display; it never records the user's current desktop.

Windows CI does not install an OCR engine. Its capture coordinator tests use a fake
capture engine. The actual FFmpeg/X11 capture path is exercised only in Linux CI.
The lightweight model tests on hosted runners use a local mock HTTP service;
real Qwen/Whisper execution was verified separately on the local Mac as above.

## Desktop regression boundary

The pointer timing issue below was subsequently repaired in `8ca1824` and tested
on the user's Mac: 226 Swift tests with zero failures, followed by 20 rounds of
critical pointer checks and actual native GUI interaction. See the
[macOS pointer validation report](macos-pointer-validation.md) for current evidence.

The following describes the historical failures before that repair.

The additional
[desktop run 36286656950](https://github.com/Lyle-xub/Recall/actions/runs/36286656950)
passed the full Windows build. Its Mac suite ran 219 tests, skipped 24, and failed
`ArchiveReadabilityTests.testFinalPointerSampleIsDeliveredAndExitCancelsPendingSample`.
At final source commit `29f4147`,
[desktop run 36287203763](https://github.com/Lyle-xub/Recall/actions/runs/36287203763)
again ran 219 Mac tests, skipped 24, and failed the related
`ArchiveReadabilityTests.testFastPointerBurstCoalescesEvenAcrossDistantCards`.
These tests expect a scheduled trailing pointer sample within 40–50 milliseconds.

These tests and their pointer implementation were not changed by the CLI work.
Both had already failed in
[earlier desktop run 36264717534](https://github.com/Lyle-xub/Recall/actions/runs/36264717534).
Those historical runs were not green. A same-runner baseline comparison was not
performed; the follow-up adds deterministic race coverage and native integration
checks. Broader glass UI development remains paused.

## Distribution and remaining platform checks

The local Mac ARM64 archive was rebuilt from source commit `29f4147`:

- File: `release/Recall-CLI-osx-arm64.tar.gz` (35,786,023 bytes).
- SHA-256: `b0473b88f79fa83d86b98a8f20602462a4741182b145fd207a411973a4ec255d`.
- Its internal manifest verifies all 214 payload files. The archive contains both
  the `recall` launcher and `recall-macos-core` helper.

The basic CLI archive includes the self-contained .NET application and, on Mac,
the Swift adapter. It does not include native model runtime binaries or weights.
Supply them through the documented runtime/model directories, or select a configured
model endpoint. Copy the complete extracted distribution directory.

Mac builds are ad-hoc signed, not notarized. Native Mac screen/microphone permission
flows, physical Windows console capture, Wayland compositor compatibility and native
audio capture still require platform smoke tests. Portable recording currently
supports still screenshots and OCR, not native video/audio or application metadata.

Older desktop builds do not implement the ownership/RPC protocol. Stop them before
offline CLI writes, or build compatible desktop and CLI versions together. Read-only
CLI commands do not need a running desktop. A compatible headless service can now
start without opening the UI; Linux supports FFmpeg/X11 or compatible grim/Wayland
capture in an authorized graphical session.

No production release, notarization, README rewrite or branch merge is part of
this handoff. The two obsolete local branches `feat/rhine-glass-replica` and
`backup/main-before-release-20260926` were deleted after verifying their tips were
already ancestors of `main`; neither branch existed on the remote.

## Reproduce

```sh
git fetch origin
git switch --track origin/feat/cross-platform-cli
python3 scripts/build-cli.py
dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj
dotnet run --project CLI.Tests/Recall.Cli.Tests.csproj
swift test --package-path macOS --filter 'NativeCLIIntegrationTests|StorageCleanupTests'
```

Use Python instead of `python3` where appropriate on Windows. Building needs .NET 10
SDK and Python; Mac additionally needs an SDK from Xcode 26+. Published bundles do
not need Python or .NET at runtime. The documented `RECALL_CLI_BINARY`,
`RECALL_MAC_CORE` and `RECALL_OCR_FIXTURE` overrides test the published bundle and
real OCR. For real models, also supply an already-installed runtime/model directory
and a generated `RECALL_REAL_AUDIO` speech fixture.
