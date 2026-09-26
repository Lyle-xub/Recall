# CLI validation and handoff — 2026-09-27

Work is isolated on `feat/cross-platform-cli`, based on
`feat/windows-visual-parity` at `12c9aac`. The original visual-development checkout
and README files are unchanged. See [CLI commands and library rules](cli.md).

## Verified locally

| Check | Result |
| --- | --- |
| Shared C# database, retrieval, privacy and model contracts | 85 assertions passed |
| Published macOS ARM64 CLI subprocess suite | 134 assertions passed |
| Native Mac store, desktop refresh, cleanup, usage and model tests | 25 tests passed |
| WinUI source compilation on Mac | 0 errors / 0 warnings |
| Self-contained Mac archive and SHA-256 manifest | Built with `scripts/build-cli.py` |
| Windows source package with extracted `Core/` | Built and ZIP integrity verified |

The subprocess suite covers desktop-produced records visible in CLI, CLI imports
visible in the desktop store, live-owner mutation routing, exclusive ownership,
concurrent start requests reaching one recorder, WAL readers, cleanup previews and
star protection, schema rejection without changing bytes, native Swift schema and
OCR preservation, exports, Unicode/literal search, real Tesseract OCR, grounded model
requests and transcript persistence through a local mock HTTP server. Mac tests
also exercise the actual `AppModel` refresh after a file-RPC mutation. Test libraries
are temporary directories; no real captured history is cleared.

The Windows recorder test uses the real shared coordinator with a fake capture
engine. It does not claim verification of physical recording, microphone permission
dialogs or Windows screen-capture consent through the CLI. Large model downloads
and native LLM inference were not executed for this validation.

Mac native OCR tests initially selected Apple's fallback recognizer because the new
worktree lacked the original checkout's ignored `native-runtimes` directory. That
fallback failed with an ICC-profile decoding error on the local beta OS. Reusing
the same installed offline OCR dependencies as the original checkout restored the
baseline and all selected tests passed. CLI standalone OCR was separately verified
against the public synthetic Aurora fixture through Tesseract.

## CI and portability fixes

All three published bundles passed on GitHub-hosted runners: 90 CLI assertions
on Windows, 102 on Linux and 134 on macOS ARM64, plus 85 shared-core assertions
on each. Mac CI also passed 11 native desktop/store/cleanup tests.
Linux includes real Tesseract OCR; Windows CI does not install an OCR engine.
The existing full Windows desktop build also passed in
[native build run 36264386680](https://github.com/Lyle-xub/Recall/actions/runs/36264386680).

Portability fixes found by CI:

- A test fixture's pooled SQLite connection kept the database handle open on Windows.
  The fixture now disables pooling before byte-for-byte schema-preservation checks.
- The Mac runner's default SDK could not compile existing glass API references.
  Both workflows now select Xcode 26.2; the packaging script checks for SDK 26+.
- Xcode 26.2 timed out on two large existing SwiftUI expressions that compiled under
  the local Swift 6.4 toolchain. Thumbnail and usage-chart expressions were factored
  into smaller functions without changing their styles or interaction behavior.

The final code validation runs at
[Shared library CLI run 36264717513](https://github.com/Lyle-xub/Recall/actions/runs/36264717513).
Its artifacts are the self-contained platform archives, each accompanied by a
SHA-256 file. No production release, notarization, README rewrite or branch merge
is part of this CLI handoff.

## Full desktop test limitation

The additional [full desktop run 36264717534](https://github.com/Lyle-xub/Recall/actions/runs/36264717534)
passed the Windows build, but its Mac suite reported 215 tests, 24 skips and three
failed timing assertions:

- `ArchiveReadabilityTests.testFastPointerBurstCoalescesEvenAcrossDistantCards`
- `ArchiveReadabilityTests.testFinalPointerSampleIsDeliveredAndExitCancelsPendingSample`
- `RecognitionStatusTests.testTransientQueueAndIdleNeverReachVisibleStatus`

These existing tests and their pointer/status implementations were not edited by
this CLI work. Their failure concerns scheduled UI callbacks on the hosted runner;
no claim is made that the full Mac desktop suite is green or that the baseline has
been independently rerun on that same runner. This remains a desktop follow-up,
separate from the passing three-platform CLI suite. Glass UI development is paused.

## Continue on another machine

```sh
git fetch origin
git switch --track origin/feat/cross-platform-cli
python3 scripts/build-cli.py
```

Use Python instead of `python3` where appropriate on Windows. macOS needs Xcode 26+
selected, Windows/Linux need .NET 10 SDK to build, and published bundles require
neither Python nor .NET at runtime. Copy the full distribution directory.

Start the compatible desktop to use `recording start/stop`, the desktop OCR queue
and media optimization. Existing older desktop builds do not implement the lease
and RPC protocol; close them before offline CLI writes, or upgrade both components
together. Read-only CLI commands do not need a running desktop. Linux supports data,
OCR, model and maintenance commands but has no native screen recorder in this repo.
