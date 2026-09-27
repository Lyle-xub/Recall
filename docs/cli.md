# Recall CLI

The CLI opens the desktop application's library directly. It uses the same records,
OCR, transcripts, model settings and credentials; there is no separate CLI database
or import step for existing app data. The glass UI work remains on its own branch.

## Build and run

Install .NET 10 SDK and Python 3.12+. On macOS, also install Xcode Command Line Tools
with a macOS 26+ SDK (Xcode 26+); the native helper supports macOS 15+ at runtime. From the repository root:

```sh
python3 scripts/build-cli.py
./release/Recall-CLI-osx-arm64/recall --help
./release/Recall-CLI-osx-arm64/recall library info --json
```

The script builds for the host architecture. It produces a self-contained directory,
archive and SHA-256 manifest under `release/Recall-CLI-<rid>` (Windows: `recall.exe`).
Copy the **whole directory**, not only the launcher. No .NET installation is needed
to run a published bundle. Mac bundles include `recall-macos-core`, built from the
existing Swift store and decoder. Per-command native requests exit without creating
a GUI; the optional background service stays alive until stopped. Local Mac builds
are ad-hoc signed, not notarized releases.

For source development, use `dotnet run --project CLI -- ...`. Native Mac libraries
also require `swift build --package-path macOS --product Recall` and
`RECALL_MAC_CORE` pointing to the resulting `macOS/.build/debug/Recall` executable.

## Library selection and compatibility

| Platform | Default library |
| --- | --- |
| macOS | `~/Library/Application Support/RewindReplica` |
| Windows | `%LOCALAPPDATA%\RewindReplica` |
| Linux | `$XDG_DATA_HOME/RewindReplica`, otherwise `~/.local/share/RewindReplica` |

`--data-dir PATH` takes precedence over `RECALL_DATA_DIR`, which takes precedence
over these defaults. Use an absolute path for scripts. A missing library is an error
for read commands; only `library init` explicitly creates one. No command implicitly
migrates an existing database. Unknown schemas are rejected before a write.

Windows-format libraries work on all three platforms. macOS retains its native
schema, compressed OCR and media through the Swift adapter and therefore requires
macOS. This is shared local application data, not cross-device synchronization.
Linux can import existing images or capture screenshots through a headless service in an
authorized graphical session. X11 uses FFmpeg; compatible Wayland compositors use
`grim`. A plain SSH session without a display cannot capture a desktop. Native Mac
libraries and their recording pipeline still require macOS.

```sh
# An explicit disposable library, for a new installation or a test
recall --data-dir /tmp/recall-example library init
recall --data-dir /tmp/recall-example records import --image screenshot.png --app Research
# The user's existing desktop library: no --data-dir required
recall search "Aurora" --limit 20 --json
recall records get MEMORY_ID
recall records star MEMORY_ID
recall records trash MEMORY_ID
recall records restore MEMORY_ID
recall records export --output /path/to/new-export --app Research --limit 1000
```

`records star` toggles the existing star state. Export requires a new or empty
directory outside the live library and uses the existing desktop export format.
Default list/export limit is 100; use `--limit` (maximum 10,000) and `--offset` for
pages. Filters include `--app`, `--since`, `--until`, `--starred`, `--trash`, `--demo`,
`--query` and `--ascending`. Prefer ISO-8601 timestamps with a timezone.

## Recording, indexing and storage

```sh
recall recording status --json
recall recording start
recall recording stop
recall service start
recall service stop
recall tasks status
recall ocr image screenshot.png --language eng
recall index run --limit 100 --language eng
recall tasks resume TASK_ID
recall tasks result TASK_OR_REQUEST_ID
recall storage stats
recall storage check
recall storage cleanup --scope trash             # preview only
recall storage cleanup --scope older30 --yes     # permanent deletion
recall storage compact --yes
recall storage optimize
```

`recording start` uses the compatible desktop owner when one is running. Otherwise,
it starts a background owner for the selected library without opening the Recall
interface. `service start` starts that owner without requesting recording.
`recording stop` stops acquisition but leaves the owner available; `service stop`
exits a headless owner and refuses to quit a desktop application. A library must
already exist; starting the service never initializes or migrates it implicitly.

| Owner / platform | Capture path | Requirements and limits |
| --- | --- | --- |
| Running compatible desktop | Existing native recording coordinator | Same library; capture may be automatically paused while its UI is visible |
| macOS native library, no desktop | Native Mac helper, without UI | macOS screen-recording permission; microphone permission if enabled |
| Windows-format library on Windows | FFmpeg `gdigrab` screenshot service | Interactive desktop and FFmpeg on `PATH` |
| Windows-format library on Linux / X11 | FFmpeg `x11grab` screenshot service | Authorized `DISPLAY` and FFmpeg on `PATH` |
| Windows-format library on Linux / Wayland | `grim` screenshot service | A compositor supported by `grim` and its required permission |

The portable service captures still screenshots and runs OCR. It does not provide
native video/audio recording or the full desktop's application metadata. Audio
transcription of supplied files remains available separately. Unsupported capture
requirements and missing engines are errors; no synthetic fallback frames are
created. `RECALL_FFMPEG` and `RECALL_GRIM` select explicit backend executables.
Portable capture refuses a nonempty application exclusion list or a saved display
selection, because it cannot enforce those native rules. Default settings exclude
password managers. Keep the native recorder for application-aware exclusions. For
an explicitly chosen whole-display session, `config set excluded-apps '[]'` clears
the exclusions; all visible content on that display may then be captured.

Legacy desktop builds do not expose the ownership protocol. Close an older desktop
before CLI writes to its library, or upgrade both components. Reads do not need a
running desktop. The default-library write guard detects known legacy owners;
it is not a substitute for stopping arbitrary old software that writes the same
custom directory.

`index run` snapshots up to `--limit` pending/failed record IDs, or the explicit
`--id`, and records a durable task. It processes each record through the current
owner or offline adapter, using the requested Tesseract `--language`. Install that
language's data and Tesseract on `PATH`, or set `RECALL_TESSERACT`. Native Mac images
are decoded through the Swift store; unsupported packed media is reported as an
error rather than marked recognized. Progress events go to stderr; `--json` keeps
one result envelope on stdout.

Use `tasks status` to inspect index jobs and owner request receipts. A failed or
cancelled indexing command includes its task ID, completed count and resume command.
`tasks resume` continues unfinished records. If a request's completion is uncertain,
inspect its durable receipt with `tasks result` before retrying a mutation such as
`records star`, which toggles state. Cancelling a waiting client does not roll back
an already running owner operation.

`storage compact` compacts SQLite/FTS. `storage optimize` uses the native optimizer
when available; the portable path recompresses supported still images with FFmpeg.
Install both `ffmpeg` and `ffprobe` for portable optimization; their executable
overrides are `RECALL_FFMPEG` and `RECALL_FFPROBE`.
Portable optimization preserves dimensions and existing OCR, skips images awaiting
OCR and leaves video recompression to the native desktop. Completed replacements
are retained after interruption; rerun the command to continue. Inspect the result
for completed/skipped work, saved bytes and platform-specific limits.

Cleanup protects starred memories and active sessions by default.
`--include-starred --yes` explicitly includes stars. `--dry-run` and `--yes` are
mutually exclusive. Exports use a separate staging directory and only publish the
requested destination after the export completes. Export requires a new or empty
directory outside the live library.

## Settings

```sh
recall config show
recall config set capture-interval 3
recall config set retention-days 0
recall config set system-audio false
recall config set microphone false
recall config set transcription-enabled false
```

`config set` changes the selected library's settings through its current owner, or
under an exclusive offline lease. `capture-interval` is an integer from 1 to 3600
seconds. `retention-days` accepts 0 to 36500; 0 keeps all records. Changing retention
also applies the native retention policy to existing unstarred records, moving
eligible records to trash. Permanent removal is a separate cleanup command.
Boolean values are `true` and `false`. Model endpoints can be selected per command
with the options below; saved credentials are never printed by `config show`.
`excluded-apps` accepts a JSON array: application names for Windows-format libraries
(for example, `'["1Password","Bitwarden"]'`) or bundle identifiers for native Mac
libraries (for example, `'["com.1password.1password"]'`). The Mac desktop's separate
name-based exclusions are retained.

## Models and transcription

```sh
recall config show
recall models catalog
recall models download chat
recall models list --endpoint http://127.0.0.1:11434/v1
recall ask "What did I decide about Aurora?"
recall transcribe recording.wav --session SESSION_ID --save --yes
recall sessions transcript SESSION_ID --json
```

Use the exact model IDs returned by `models catalog` (`chat` and `speech`). `ask` retrieves real memories and time-adjacent transcripts and
uses the existing model client's evidence boundaries. `transcribe` emits timestamped
lines; persistence requires an existing session plus `--save --yes`. Model endpoints
follow the desktop's `settings.json` by default. Overrides are `--endpoint`, `--model`,
`--online`, `--builtin`, `--key-env`. An overridden online endpoint requires explicit
`--online` and HTTPS. Local endpoints remain restricted by the existing model client.

Credentials come from `RECALL_API_KEY` / the named `--key-env`, or the current user's
desktop credential store (Windows DPAPI / macOS Keychain). Saved desktop keys are
never sent to a CLI-overridden endpoint or printed by `config show`.

Built-in model files use the desktop `models` directory, or `REWIND_MODEL_ROOT`.
Downloads use the existing resumable download and SHA-256 validation. Native
llama/whisper binaries and model weights are **not included** in the basic CLI
archive. Supply platform-compatible `runtimes/llama/llama-server` and
`runtimes/whisper/whisper-cli` (Windows: `.exe`), or set `REWIND_RUNTIME_ROOT`.
The repository's `scripts/prepare-native-runtimes.py` supports Mac ARM64 and
Windows x64; Linux engines must be installed separately. No model weights are
downloaded implicitly. Use `doctor` to inspect paths. Native model execution
requires adequate memory and is not covered by the lightweight CI model mock.

Built-in inference uses one process owner per user and engine. A CLI can reuse a
compatible desktop's ready chat service when it has the same model file identity;
it never stops the desktop's engine when the command exits. If another client is
loading a model or owns a non-shared engine, the command reports `busy` instead of
loading another copy. Recorded process identities allow a later CLI invocation to
recover an abandoned engine without treating a reused PID as the original process.

## Interoperability and concurrency

The shared C# core is in `Core/`; WinUI and the CLI reference it. The Mac helper calls
the existing Swift `MemoryStore`, not a rewritten SQLite schema. Existing libraries
are opened in read-only or maintenance mode without startup migrations.

A per-library `.recall-control` directory carries protocol-v1 JSON requests and
responses. An OS-released file lease (`flock` on Unix, a byte-range lock on Windows)
permits one compatible desktop owner or one offline CLI writer. The desktop owns
the lease for its lifetime, serializes control requests and refreshes UI state after
CLI writes. Read commands use SQLite WAL readers and remain available during capture.
After a crash, the kernel releases the lease; the PID file itself is not a lock.
Shutdown stops accepting CLI requests before draining native tasks and releasing
ownership. This protocol uses no TCP listener or cloud service.

Do not retry a timed-out mutation automatically: its operation may already have
completed. Inspect the current record/task state first. Captured evidence is local
data; only explicit configured model calls send their requested context to an endpoint.

## Output and exit status

Human output is indented JSON. `--json` emits one compact stdout envelope:

```json
{"ok":true,"result":{"integrity":"ok"}}
{"ok":false,"error":{"code":"not_found","message":"Memory not found.","exitCode":3}}
```

Exit codes: `0` success; `2` usage; `3` missing record/file/library; `4` unsupported
platform/schema or unavailable service/engine; `5` busy/conflict/confirmation;
`6` operation failure or an uncertain timed-out request; `130` cancellation. `--help` and `--version` never require
a library. Library-specific metadata retains platform fields; common memory IDs,
text, normalized OCR rectangles and wire ISO timestamps are consistent.

## Validation

```sh
dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj
dotnet run --project CLI.Tests/Recall.Cli.Tests.csproj
swift test --package-path macOS --filter 'NativeCLIIntegrationTests|StorageCleanupTests'
```

Set `RECALL_CLI_BINARY` to test a published executable instead of the framework build.
Set `RECALL_MAC_CORE` for native Mac checks and `RECALL_OCR_FIXTURE` to
`docs/macos-visual-reference/fixtures/frames/parity-2-0.png` for real Tesseract OCR.
Tests create isolated temporary libraries and never delete real application records.
The `Shared library CLI` GitHub Actions workflow builds and exercises published
bundles on Windows, macOS and Linux, including actual OCR on Mac/Linux. Linux also
runs a real FFmpeg capture, Tesseract OCR, search, stop, optimization and export
round trip in a private Xvfb display containing only a generated scene:

```sh
# Linux: install FFmpeg, Tesseract, Xvfb, python3-tk and DejaVu fonts first
python3 scripts/test-cli-capture.py --cli release/Recall-CLI-linux-x64/recall
```

This script creates its own display and never records the user's current desktop.
It removes its temporary library by default; `--keep-library` retains synthetic
evidence. Windows physical-console capture, Wayland compositor compatibility, Mac
permission prompts and native audio capture require their platform smoke tests.
The lightweight CI model service is a mock. To exercise already-installed native
models locally, set `RECALL_REAL_AUDIO` to a generated speech fixture along with
`REWIND_MODEL_ROOT` and `REWIND_RUNTIME_ROOT`; no model download is implicit.
See [validation and platform limits](cli-validation.md) for measured results.
