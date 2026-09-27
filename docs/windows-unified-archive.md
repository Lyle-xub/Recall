# Windows unified visual archives and CLI — 2026-09-28

Windows 0.4.26 and CLI 0.5.2 adopt the storage design of the current Mac app:
cards and replay share video samples, small immutable image tiles are packed,
and OCR coordinates are compressed losslessly. The macOS application sources
are unchanged. This is a Windows implementation using the shared C# core;
it does not replace the Mac library schema or its Swift adapter.

Upgrade the Windows application and CLI together before writing the new
archives. Older binaries do not understand the new packed payloads or compressed
OCR records; the new versions continue to read the previous formats.

## New recording

One serialized capture loop supplies the exact same native-resolution bitmap
to Media Foundation and the lossless OCR spool. Replay normally samples at
one frame per second; an application change or a due card can submit an
additional independently addressable sample. The timestamp returned by the
writer is stored with the card. It is not inferred later from a screenshot's
wall-clock timestamp.

The sink writer's video processor has frame-rate conversion disabled so
forced captures retain their original presentation times, including samples
less than a second apart. Readers validate the native presentation dimensions
and the decoder's declared display aperture before removing codec padding.

The native writer prefers an available hardware HEVC encoder with an installed
HEVC decoder. H.264 is the compatibility fallback. Hardware transforms are
enabled where supported; this is not a promise that every H.264 fallback uses
a GPU. The session reports its actual codec and any compatibility diagnostic.
Quality-based encoding replaces the old 720-pixel/100-kbps recording cap.
System audio and microphone retain independent tracks.

The original capture dimensions stay in the card reference and session.
Odd dimensions are padded only on the right/bottom to the next even size for
encoding, then cropped back when decoded. There is no resize of the OCR image.
Windows `.recallvideo` manifests include a media timescale; existing lowercase
Mac references without that field use their original 600-tick timescale.

A card switches from its PNG spool to a `.recallvideo` reference only after:

1. OCR has completed against the original pixels.
2. The video has finalized and its bytes have been flushed.
3. The native decoder finds the exact sample and verifies its dimensions.
4. The manifest and recovery receipt are durable and the database transaction
   commits the new reference.

Failure leaves the original image available. Recovery distinguishes an
uncommitted publication from a committed reference whose source still needs
retiring. An interrupted recording falls back to its preserved image sources.
Decoding does not hold the database gate; normal search and metadata updates
can proceed while a session's cards are verified.

Completed sessions are verified by one background worker. Repeated requests
for the same session are combined, including OCR completions that arrive
during verification. Rolling into the next recording segment does not wait
for every card to be decoded. Shutdown joins the worker; deferred cards keep
their original images and are discovered on the next startup.

## Existing images and OCR

Existing JPEG/PNG tile payloads are not transcoded during packing. Their
content hashes remain authoritative. Bounded SQLite segments under
`frames/packs` hold at most 32 MiB of image payload each; the catalog points
to committed segments. A reader still accepts old loose tiles. An optimizer
verifies the installed bytes before removing a loose copy. Batch reads bound
open segment handles and release them so Windows cleanup can reclaim files.
Packing reduces small-file overhead; tiny libraries can initially use more
physical bytes because of SQLite pages. Statistics separate logical payload
size from physical allocation.

Windows retains JPEG/PNG for independent screenshot encoding. This change
does not require installing a HEIC codec, and it does not claim that Windows
uses every Mac image codec. The main new-recording saving comes from avoiding
a second long-lived screenshot copy beside the video.

OCR region payloads use Brotli with a versioned envelope, decoded-size limit
and SHA-256 integrity check. Unicode text and the exact IEEE-754 coordinate
bits round-trip without rounding. Existing JSON remains readable; small
payloads keep JSON when it is smaller. Search text and the existing FTS index
remain searchable. `storage compact` also converts existing region payloads.
Mac continues to use its own native compression implementation.

## CLI, maintenance and ownership

CLI OCR/index/import can materialize packed images and exact video samples.
With a running Windows desktop, indexing uses its native reader. Offline
materialization uses FFmpeg, verifies the timestamp and dimensions, and cleans
temporary images on success, cancellation and failure. No nearest-frame
fallback is accepted. The ordinary Mac library path still uses its Swift helper.

Windows desktop indexing also uses the bundled OCR engines, including both
the main capture and any meeting image; it does not require a `tesseract`
executable on `PATH`. The desktop model automatically recognizes English and
Simplified Chinese. `eng`, `chi_sim`, and their combination select this native
path; unsupported languages return an explicit error without replacing OCR.

On Windows, `recall recording start` first uses an existing owner. Otherwise
it can start the installed desktop in background service mode, using the
requested library and the same native encoder. A portable desktop location
can be provided with `RECALL_WINDOWS_APP`. `recall service stop` gracefully
exits an instance started this way. An independently opened desktop is stopped
through its normal tray controls. Without an installed native engine, the
existing explicitly constrained portable screenshot service remains available.

Both native and portable optimizers can pack legacy tiles and compress OCR.
They preserve pending original spools and every recording used by video-backed
cards. Cleanup follows transitive media dependencies, including references
shared across sessions; malformed references stop cleanup instead of allowing
it to guess. Exports copy referenced recordings and materialize packed tiles
into independent loose payloads under the export directory.

Standalone image optimization checks every primary and meeting-image user.
After encoding, it checks them again inside the same transaction that updates
the references. A new OCR retry, pending shared reference or unified-session
change keeps the original image; abandoned candidate files are removed.

## Validation

The storage regression suite covers legacy reads, exact-sample promotion
gates, checksum damage, segment recovery, interrupted publication, shared-video
cleanup, independent exports and updates concurrent with native verification.
CLI archive tests use real FFmpeg decoding, including an exact 0.3-second color
change, a nonexistent sample, Mac/Windows timescales and odd-size crop handling.

Windows-native image tests exercise Media Foundation writer/reader round trips,
asymmetric pixels, timestamp selection, padding, cancellation and concurrency.
The application smoke test captures the CI desktop, completes OCR, promotes a
card, decodes its original dimensions and verifies an independent export.
`test-windows-cli-archive.ps1` additionally checks automatic native startup,
real capture, indexing, export, maintenance protection and graceful shutdown
through the packaged CLI. These use isolated libraries, not user records.

Local shared-core validation passed 327 checks and the complete CLI suite
passed 368 checks, including the real Mac native service lifecycle. Seventeen
deterministic receipt checks passed ten consecutive runs; they cover successful
and failed completion during owner exit and reject unverified acknowledgements.
The native CI workflow retains synthetic video/timestamp
evidence under `windows-image-tests`, desktop smoke evidence under
`windows-smoke`, and CLI lifecycle results in
`windows-cli-archive/acceptance.json`. The CLI matrix additionally runs the
packaged distribution on Windows, macOS and Linux.
Hosted Windows results do not certify every physical GPU/driver or establish
a universal compression ratio for real user libraries.

### Accepted build evidence

Implementation commit: `82caf01a4229c2b8c3a5c7da5feab24b0ea55316`.
The [Windows native job](https://github.com/Lyle-xub/Recall/actions/runs/36350015180/job/108706757887)
and all three jobs in the [CLI matrix](https://github.com/Lyle-xub/Recall/actions/runs/36350015185)
passed against that exact commit. The unchanged Mac desktop also passed its
[native regression and build job](https://github.com/Lyle-xub/Recall/actions/runs/36350015180/job/108706757664).

| Environment | Verified result |
| --- | --- |
| Windows native desktop | 328 shared-core checks, 9 image archive checks, 29 Media Foundation/worker checks, and 24 application smoke checks |
| Windows CLI with native desktop | 16 real capture-to-shutdown checks, including native auto-start, exact video card, bundled OCR, export, maintenance protection, process exit and library reopen |
| Packaged Windows CLI | 342 process and interoperability assertions |
| Packaged macOS CLI | 387 assertions, 15 Swift integration/cleanup tests and 28 terminal/JSON checks |
| Packaged Linux CLI | 345 assertions, isolated Xvfb/FFmpeg capture and OCR/export, and 28 terminal/JSON checks |
| Unchanged Mac desktop | 294 registered tests: 29 skipped, 0 failures; release build passed with the CI-only ad-hoc signature |
| Legacy Windows WPF entry point | Release cross-build on the Mac host: 0 warnings, 0 errors |

The Windows runner actually selected H.264 and captured 1024 × 768 pixels.
Its retained `unified-archive.json` confirms exact native decoding, release of
the original OCR spool and independent decoding from the exported library.
Synthetic native-video evidence preserves submitted and decoded timestamps at
0, 1.375 and 2.625 seconds, plus a rapid sequence at 0, 0.125, 0.375, 1 and
1.375 seconds. The reader correctly crops the decoder's declared padding to
the original 641 × 359 pixels; missing samples are rejected.

Build outputs: [Windows installer and portable ZIP](https://github.com/Lyle-xub/Recall/actions/runs/36350015180/artifacts/10941219791),
[Windows CLI and checksum](https://github.com/Lyle-xub/Recall/actions/runs/36350015185/artifacts/10942385311),
and [native validation evidence](https://github.com/Lyle-xub/Recall/actions/runs/36350015180/artifacts/10942155937).
These are Actions artifacts with finite retention; the workflow links above
also retain the associated build and test logs.

Native API references: [sink-writer input and encoding parameters](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsinkwriter-setinputmediatype),
[hardware transform selection](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-readwrite-enable-hardware-transforms),
[H.264 quality and GOP properties](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder),
[disabling frame-rate conversion](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-xvp-disable-frc),
[valid video display aperture](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-minimum-display-aperture-attribute).
