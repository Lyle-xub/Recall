# Windows data directory

Recall now defaults to `%LOCALAPPDATA%\Recall\Data`. This replaces the legacy
`%LOCALAPPDATA%\RewindReplica` name. The complete library lives below the new
root: SQLite and its WAL/SHM files, screenshots, recordings, models, icons,
settings, logs and protected provider-key files.

The normal Windows startup path prepares this directory before constructing
settings, model providers or MemoryStore. If only the legacy directory exists,
it performs a same-volume whole-directory rename. Subsequent launches use the
new directory. If both locations exist, or the move fails, startup stops with
an error identifying the paths; it does not merge libraries or open a newly
created empty database. An explicit `RECALL_DATA_DIR`, test/validation override,
or legacy WPF `--data-dir` remains authoritative and bypasses default migration.

Media paths in MemoryStore are relative to its root. BuiltinModels follows
`DataRoot/models` unless `REWIND_MODEL_ROOT` is explicitly set. Directory
migration does not rewrite account credentials or model service settings.

## Verification

Release publish and seven isolated migration checks passed: the new default,
explicit-root bypass, complete directory movement including SQLite sidecars,
repeat-launch idempotence, missing legacy data, conflicting libraries, and a
blocked destination that must preserve the original library.

For the local deployment, Recall was closed normally. A complete independent
backup was made and each file verified with SHA-256 before moving the directory.
The installed build was compared to the accepted publish output. Post-migration
verification compares every data file to the backup, performs SQLite quick_check,
and compares all record counts. The application remains closed after migration.
