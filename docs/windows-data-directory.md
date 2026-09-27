# Windows data directory

New installations use `%LOCALAPPDATA%\Recall`, resolved by the same shared Core
as the CLI. An earlier Windows build used `%LOCALAPPDATA%\Recall\Data`; an
existing sole database at that nested path is reused in place by both clients.
The complete library stays together: SQLite and its WAL/SHM files, screenshots,
recordings, models, icons, settings, logs and protected provider-key files.

The normal Windows startup path prepares this directory before constructing
settings, model providers or MemoryStore. If only `%LOCALAPPDATA%\RewindReplica` exists,
it performs a same-volume whole-directory rename. Subsequent launches use the
new flat Recall directory. If legacy and Recall directories coexist, both flat
and nested Recall databases exist, or the move fails, startup stops with
an error identifying the paths; it does not merge libraries or open a newly
created empty database. An explicit `RECALL_DATA_DIR`, test/validation override,
or legacy WPF `--data-dir` remains authoritative and bypasses default migration.

Media paths in MemoryStore are relative to its root. BuiltinModels follows
`DataRoot/models` unless `REWIND_MODEL_ROOT` is explicitly set. Directory
migration does not rewrite account credentials or model service settings.

## Verification

The merged shared-Core tests use real SQLite fixtures to cover flat and nested
selection, byte preservation, repeated launch, explicit overrides, all three
conflicting layouts, unreadable occupied databases, location locks and legacy
model-only directories. They also verify that macOS/Linux do not apply Windows
nested-directory selection. The original Windows-only migrator is retired.

## Earlier Windows deployment

Release publish and seven isolated migration checks passed: the new default,
explicit-root bypass, complete directory movement including SQLite sidecars,
repeat-launch idempotence, missing legacy data, conflicting libraries, and a
blocked destination that must preserve the original library.

For the local deployment, Recall was closed normally. A complete independent
backup was made and each file verified with SHA-256 before moving the directory.
The installed build was compared to the accepted publish output. Post-migration
verification compares every data file to the backup, performs SQLite quick_check,
and compares all record counts. The application remains closed after migration.
