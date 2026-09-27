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
- .NET migration checks: **21 assertions passed**.
- Existing CLI suite: **233 assertions passed** in the final independent run.
- Shared-core database, retrieval, privacy and model contracts: **85 checks passed**.
- Source review and `git diff --check` passed.

The first CLI suite run, concurrent with Swift compilation, timed out in the
existing `DurableChecks` request-timing check. The final independent rerun passed;
the test was not weakened or changed. Raw logs are retained in ignored
`.test-data/default-library-*.log` files. Real-library installation and platform
CI results are recorded below once completed.
