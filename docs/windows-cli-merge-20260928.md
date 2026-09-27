# Windows desktop and shared CLI integration — 2026-09-28

The integration merges Windows desktop commit `7fbf1d6` into CLI/macOS commit
`1897e63`, retaining both histories and the shared `Core` project. Their common
ancestor is `12c9aac`. The Windows commit changes 100 files; the merge resolves
seven conflicted paths and also updates automatically merged call sites whose
runtime contracts changed. macOS application sources are unchanged.

## Integrated behavior

- Windows retains its new liquid-glass resources, virtualized archive, bounded
  image pipeline, timeline preview, video orientation/audio fixes and recording
  recovery. Shader sources and license notices remain in the package.
- `MemoryStore` combines lightweight archive projection and revision tracking
  with active-session retention protection, transactional cleanup and recovery.
- GUI and CLI use the same data-directory resolver and ownership locks. New
  Windows libraries use `Recall`; a sole existing `Recall/Data/memory.sqlite`
  is reused in place. Multiple libraries fail with a conflict. Explicit roots
  remain authoritative; macOS/Linux do not apply Windows nested-path selection.
- Windows no longer compiles a duplicate `AppPaths` or directory migrator.
  WinUI, WPF and tests reference shared Core; image tests reference the relocated
  `ScreenManifest` through Core as well.
- The desktop IPC recording controller distinguishes requested intent from
  actual capture. Failed starts return `capture_failed`, faulted status exposes
  its error, and an explicit retry can recover. A visible UI may legitimately
  accept a request in an automatically paused state.
- Storage settings retain the Windows redesign and the CLI branch's shared
  maintenance exclusion. Shutdown drains recording diagnostics before releasing
  the database and CLI ownership.

## Validation coverage

Local macOS-hosted .NET checks:

- 198 shared-core / Windows logic checks, including new recording IPC cases.
- 45 archive checks, including 20,431 indexed fixture rows, cancellation,
  retention, revision tracking and rollback. These checks are now also called
  by the default test entry point.
- 25 targeted migration assertions and 237 complete CLI assertions.
- XML source/project references and staged diff checks passed.

The first complete CLI invocation lacked `DOTNET_HOST_PATH` for the locally
unregistered SDK; rerunning with the SDK path passed without changing tests.
Logs remain in ignored `.test-data/windows-cli-merge-20260928/`.

CI now runs native image-archive tests and a Windows integration session using
240 synthetic images and the explicitly gated fake capture backend. That
session exercises recording recovery, navigation, dismissal, the real packaged
CLI communicating with the running WinUI owner, and normal shutdown. Forced
termination or a retained owner receipt fails validation. The existing native
smoke test separately exercises actual screen capture, OCR and MP4 finalization
on the hosted Windows desktop.

Fake-capture integration does not certify hardware recovery, pointer feel or
GPU frame rate. No user's real Windows library is opened by these checks, and
the Mac installation and actual data directory are not changed by this merge.

## Remote acceptance

Integration source: `a314d0c85bd69d690f7d66e9d753c3b6dd917fdb`.

[Shared CLI workflow](https://github.com/Lyle-xub/Recall/actions/runs/36341470003)
passed on every platform: **290 macOS**, **245 Windows** and **248 Linux** CLI
assertions. Shared-core checks passed **243 on macOS/Linux** and **244 on Windows**;
the platform count differs because native AAC checks and symlink checks are
platform-specific. The macOS adapter/storage suite passed all **15 tests**.

The Windows job of the
[native workflow](https://github.com/Lyle-xub/Recall/actions/runs/36341469998)
passed the self-contained build and installer, **9 image seam checks**, and the
existing **12 real capture/OCR/MP4 smoke checks**. New native integration passed:

- 12 recording/window/tray cases using fake capture.
- 10 return paths and 10 dismissals across classic and Rhine pages.
- 17 dismissal/reopen cases with 12 lifecycle assertions.
- 5 real packaged-CLI-to-WinUI IPC checks, including startup fault reporting,
  retry and explicit stop.
- Normal shutdown with exit code zero and no retained CLI owner receipt.

The complete native workflow passed on both platforms. macOS executed **294
Swift tests**, with **29 existing conditional skips** and **zero failures**, then
successfully built and archived the release application. Both workflows passed
on the original integration run without a retry or weakened assertions.

`main` is advanced to this validated integration history with this documentation
as a separate documentation-only acceptance commit. The existing feature and
integration branches are retained. No release tag or local app installation is
created by this code merge.
