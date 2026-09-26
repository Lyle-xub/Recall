# Recall CLI

The CLI opens the desktop application's library directly. It uses the same records,
OCR, transcripts, model settings and credentials; there is no separate CLI database
or import step for existing app data. The glass UI work remains on its own branch.

## Build and run

Install .NET 10 SDK and Python 3.12+. On macOS, also install Xcode Command Line Tools
with a macOS 15+ SDK. From the repository root:

```sh
python3 scripts/build-cli.py
./release/Recall-CLI-osx-arm64/recall --help
./release/Recall-CLI-osx-arm64/recall library info --json
```

The script builds for the host architecture. It produces a self-contained directory,
archive and SHA-256 manifest under `release/Recall-CLI-<rid>` (Windows: `recall.exe`).
Copy the **whole directory**, not only the launcher. No .NET installation is needed
to run a published bundle. Mac bundles include `recall-macos-core`, built from the
existing Swift store and decoder. Its headless entry point exits before creating a
GUI. Local Mac builds are ad-hoc signed, not notarized releases.

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
Linux has no desktop recorder in this repository; use `records import` for ingestion.

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
recall tasks status
recall ocr image screenshot.png --language eng
recall index run --limit 100
recall storage stats
recall storage check
recall storage cleanup --scope trash             # preview only
recall storage cleanup --scope older30 --yes     # permanent deletion
recall storage compact --yes
recall storage optimize
```

Recording start/stop and media optimization require the updated macOS or WinUI
desktop from this branch running with the same data directory. They control that
application's existing coordinator and background jobs. The CLI does not launch a
second recorder or force the GUI open. Recording can remain automatically paused
while the app interface is visible; the status reports requested and active states
separately. Legacy desktop builds and the legacy WinForms shell do not expose this
protocol: close them before offline mutations, or upgrade to the compatible desktop.

When the compatible desktop is running, `index run` queues its native OCR pipeline.
`--id` retries a particular memory. Offline indexing uses Tesseract installed on
`PATH` (or `RECALL_TESSERACT`) and holds the library's exclusive task lease. Install
the language data needed by `--language`; the default is `eng`. It processes up to
`--limit` pending/failed records; repeat for subsequent batches. Offline Windows
packed images require the desktop decoder; the command reports `unsupported_media`
instead of marking an unread image indexed. The Mac helper uses the app decoder.

`storage compact` compacts SQLite/FTS; `storage optimize` is the desktop's existing
image/video compression job and reports acceptance, not completion. Inspect
`tasks status` for progress. Cleanup protects starred memories and active sessions
by default. `--include-starred --yes` explicitly includes stars. `--dry-run` and
`--yes` are mutually exclusive. Database updates and media removal reuse each
platform's existing store maintenance logic.

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
`6` operation failure; `130` cancellation. `--help` and `--version` never require
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
bundles on Windows, macOS and Linux, including actual OCR on Mac/Linux. Model HTTP
and recording ownership tests use local mock engines; permission dialogs, physical
screen/audio recording and downloaded LLM inference still need platform smoke tests.
