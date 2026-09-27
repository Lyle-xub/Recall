# Windows unified visual archives and CLI — 2026-09-28

Windows 0.4.26 and CLI 0.5.2 adopt the storage design of the current Mac app:
cards and replay share video samples, small immutable image tiles are packed,
and OCR coordinates are compressed losslessly. The macOS application sources
are unchanged. This is a Windows implementation using the shared C# core;
it does not replace the Mac library schema or its Swift adapter.

## New recording

One serialized capture loop supplies the exact same native-resolution bitmap
to Media Foundation and the lossless OCR spool. Replay normally samples at
one frame per second; an application change or a due card can submit an
additional independently addressable sample. The timestamp returned by the
writer is stored with the card. It is not inferred later from a screenshot's
wall-clock timestamp.

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

Validation results are recorded after the complete local and remote runs.
Hosted Windows results do not certify every physical GPU/driver or establish
a universal compression ratio for real user libraries.

Native API references: [sink-writer input and encoding parameters](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsinkwriter-setinputmediatype),
[hardware transform selection](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-readwrite-enable-hardware-transforms),
[H.264 quality and GOP properties](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder).
