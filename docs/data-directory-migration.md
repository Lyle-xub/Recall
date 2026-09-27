# Recall data-directory migration — 2026-09-28

Default application data now uses the Recall name consistently:

| Platform | Default directory |
| --- | --- |
| macOS | `~/Library/Application Support/Recall` |
| Windows | `%LOCALAPPDATA%\Recall` |
| Linux | `$XDG_DATA_HOME/Recall`, or `~/.local/share/Recall` |

`memory.sqlite`, media, settings and built-in models stay together under that
directory. The desktop, CLI, legacy Windows entry point and demo export script
use the new default. `--data-dir` and `RECALL_DATA_DIR` preserve explicit library
selection. Explicit model-location overrides remain supported. Application and
signing identifiers are unchanged to preserve existing authorization identity.

## Upgrade behavior

The old default sibling `RewindReplica` is relocated only when it exists, the
new destination does not exist, and the library is not in use. This is a
same-volume, atomic directory rename that refuses to replace a destination.
There is no full-library copy, schema conversion, FTS rebuild or user-text
replacement. WAL/SHM files, packed media databases, model receipts, settings,
pending work and historical diagnostics remain with their original library.

Both runtimes share a location lock outside the two folder names; live default
library readers and writers hold shared access while migration requires
exclusive access. Existing owner leases, older Recall processes and active
model engines are checked before moving. Media references and active cleanup
state must remain safe after relocation. Conflicting directories, unsupported
absolute media references or an in-use library produce an actionable error
without moving the original library. WinUI startup errors do not recursively
attempt to resolve the same failed default directory.

Explicit custom directories are never automatically relocated. Missing-library
reads still fail without creating a database. Help, version and invalid CLI
commands do not trigger a default-directory migration. Compatibility references
to the old directory name are intentionally retained for discovery and tests;
historical validation documents continue to describe their original paths.

## Local regression

- Swift: `DefaultLibraryTests` plus
  `NativeCLIIntegrationTests.testReadCommandsPreserveMacSchemaAndCompressedOCR`:
  **10 tests passed**.
- .NET migration checks: **22 assertions passed** on macOS after the Windows handoff correction.
- Existing CLI suite: **233 assertions passed** in the final independent run.
- Shared-core database, retrieval, privacy and model contracts: **85 checks passed**.
- Source review and `git diff --check` passed.

The first CLI suite run, concurrent with Swift compilation, timed out in the
existing `DurableChecks` request-timing check. The final independent rerun passed;
the test was not weakened or changed. Raw logs are retained in ignored
`.test-data/default-library-*.log` files. The real-library acceptance is recorded below.

## Windows directory-handle correction

The first Windows CLI CI run caught an actual platform-specific migration
failure: Windows refuses to rename a directory while the migrator itself keeps
its child writer-lease file open. After media validation closes its SQLite
handles, Windows now releases that internal lease immediately before the move;
the external exclusive location lease and model-engine leases stay held.
Unix retains its internal lease throughout the rename.

Regression coverage checks that new readers/writers remain excluded during
this Windows handoff, older reader or writer handles preserve the source on
failure, and migration succeeds after those handles close. Move failures due
to access denial are reported as an actionable conflict.

## Installed Mac acceptance

The signed application was rebuilt and installed at `/Applications/Recall.app`.
CLI version `0.5.1-c1164a6` was installed with all 214 manifest entries verified;
the prior application and CLI version were retained for rollback. The source
commit is `c1164a63a526d1e8e2c1cba6f89143c3802680bc`; the Swift application was
built from `717c784`, whose macOS sources are identical to that commit.

After normally quitting the old application, a SQLite backup was saved and the
installed CLI migrated the existing default library to
`~/Library/Application Support/Recall`. Before reopening the GUI, verification
confirmed:

- The same directory inode and device, demonstrating an in-place rename.
- Identical row hashes across ten audited tables, including all **28,809 frames**,
  **320 sessions**, **3,608 transcripts** and **1,640 app-usage rows**.
- Identical inode and size for all **29,456 media and model files**.
- Byte-identical settings and a successful SQLite integrity check.
- The legacy default directory no longer exists; both built-in models are
  installed under the new root.

The installed GUI then opened the collection with **28,809 memories / 34 apps**.
Its Storage settings show the new Recall directory, and both Qwen3 and Whisper
show **Ready / Works offline**. The application was left open with recording
paused. The installed CLI also recognizes the GUI owner at the new location.

Raw receipts, database backup and before/after hashes are retained locally in
ignored `.test-data/data-directory-20260928/`; private record content is not
committed. The installed application executable SHA-256 is
`b7f5766c96f90c9b8b5e2c594df10d950cc18c90043da9056e9f6408fcd06888`.

## Platform CI

[Shared library CLI, source c1164a6](https://github.com/Lyle-xub/Recall/actions/runs/36339237556)
passed on all three platforms:

- macOS: **287 CLI assertions**, plus **15 native adapter / storage tests**.
- Windows: **242 CLI assertions**, including the real Windows migration handoff.
- Linux: **245 CLI assertions**, **85 shared-core checks** and private-desktop
  capture / OCR / maintenance / export validation.

The first native Windows build failed its existing 3.5-second video smoke-test
finalization assertion. The current source rerun passed without changes to
capture code. That smoke test uses an explicit temporary library and never
enters default-directory migration.

The first native macOS run at c1164a6 failed the existing
`ResponsivenessTests.testRapidRequestsCoalesceAndDoNotApplyStaleResults` timing
assertion (`[0, 100]` versus `[100]`); the test sleeps for 3 ms while its worker
sleeps for 20 ms. The same Swift source passed the preceding 717c784 run and the
unchanged c1164a6 rerun. No test was weakened or skipped to obtain a pass.

[Native desktop validation, source c1164a6](https://github.com/Lyle-xub/Recall/actions/runs/36339237568)
passed its Windows build / video smoke checks and, on rerun, its complete
macOS Swift suite. At the time of this acceptance record, the remote macOS
release-package build is still running; the same Swift source already passed
[the preceding native macOS build](https://github.com/Lyle-xub/Recall/actions/runs/36338746034).
The locally built, signed and installed macOS package passed verification above.
