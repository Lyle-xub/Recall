# Unified visual archive and background load — 2026-09-26

## Implementation

New recordings use one hardware-encoded HEVC stream for both native-resolution cards and replay. The capture size, three-second OCR sampling, application-change captures, and original-pixel OCR inputs are unchanged. Replay keeps its one-frame-per-second cadence; an OCR capture between replay samples is additionally encoded and stores its exact presentation timestamp. No historical screenshot is transcoded into this format.

The production encoder uses quality 0.5, a maximum 60-second keyframe interval, no frame reordering, and five-second movie fragments. Hardware encoding is required; H.264 is the compatibility fallback. Cards resolve a small immutable reference to that recording. Two decoder slots and two cached video generators bound concurrent seeks. Existing viewport thumbnails remain memory-only (96 MiB cache budget, two detail images).

Lossless source PNGs remain on disk until OCR commits and the movie finishes successfully. Linking the reference uses a synchronized file and a database transaction before releasing the source. Interrupted open recordings retain their source images and return to normal image indexing. A completed movie whose cards were not yet linked is finalized after restart. Shared media ownership protects recordings during individual-card/session deletion, and export materializes ordinary PNGs.

New OCR metadata stores text and double-precision coordinates in a lossless binary/LZFSE payload. New region IDs are frame-local ordinals; existing arbitrary IDs and UUIDs retain their exact values. Historical JSON remains readable. This change does not remove text, reduce OCR input resolution, or change its models.

## CPU and backlog correction

The first live trial exposed a regression in the previous performance build: `.background` process QoS made the local OCR worker too slow on this machine. A cold request exceeded its deadline; subsequent frames took roughly 10–13 seconds and lossless originals accumulated. Lower instantaneous CPU alone was not an acceptable result.

The worker now uses `.utility`, still with two ONNX intra-op threads, one inter-op thread, disabled spinning, and two Accelerate threads. The existing thermal/low-power recovery intervals remain. Pending captures run oldest first, enabling exact line-cache reuse across adjacent screenshots and preventing starvation. Video-backed recognition caches text rather than retaining six full source PNGs; legacy image results also have a 32 MiB byte limit.

Six consecutive 3024×1964 dense Chinese interface captures were fed to persistent native workers in the same order:

| Worker configuration | Wall time including startup | Process CPU time | Text and boxes |
| --- | ---: | ---: | --- |
| Two threads, background QoS | 90.95 s | 72.23 s | Identical |
| Two threads, utility QoS | 14.69 s | 22.31 s | Identical |
| One thread, utility QoS | 21.65 s | 20.69 s | Identical |

These are local component measurements under the machine's current workload. Part of the background-QoS run overlapped a build, and the scheduler/core choice contributes to the difference. Utility QoS increases short-term CPU parallelism compared with background throttling, while completing this work much sooner; it is not a claim that every instantaneous CPU sample is lower. The two-thread configuration was retained to avoid an indefinitely growing queue at the existing capture interval.

For the signed application's independent test library, two-second process-CPU deltas included Recall and its child processes (100% means one logical CPU):

| Test phase | Measured duration | Mean CPU | Peak CPU | Peak summed RSS |
| --- | ---: | ---: | ---: | ---: |
| Background catch-up, window hidden | 180.64 s | 102.53% | 165.87% | 789.97 MiB |
| Native capture + system audio + OCR catch-up | 121.72 s | 106.66% | 188.15% | 807.34 MiB |

The first phase briefly overlapped the release test build; the second ran without another benchmark. The test enabled system audio, disabled microphone/transcription, and retained the prior interrupted segment's recovery work. These figures are not a hard application-wide limit: transcription, model inference, different screen content, thermal state, or simultaneous maintenance can change them. RSS is a process sum, not a measurement of physical memory pressure. No six-second UI-watchdog stall report was generated.

All 196 test captures eventually indexed successfully, with zero lossless source PNGs left. During the final 162.85-second recording, dense changing text still created a short queue; it cleared about 95 seconds after capture stopped. The older 162.94-second interrupted segment correctly used image archives instead of trusting its unfinished movie. This validation establishes recovery and eventual catch-up, not sustained real-time OCR for arbitrary continuously changing screens.

## Storage comparison

The engineering target is approximately 14–15 GB per 240 recorded hours (one screen, eight hours/day, 30 days), or 58–63 MB per recorded hour. This is a workload target, not a verified universal property of Rewind or a guarantee for arbitrary screen content.

The same three consecutive completed office sessions were used for every candidate: 304 native screenshots over 901.115 seconds. The current Compact comparison includes its packed screenshots, replay, original audio, database, transcripts, and application-usage records. The unified comparison includes video, card references, original audio, compressed OCR/database metadata, transcripts, and usage records. Allocation is measured after the writers close, using actual allocated file bytes, not just compressed payload length. Fixed local models (about 1.98 GB) are excluded from monthly growth; no persistent thumbnail cache is omitted.

| Settled library component | Compact | Unified production encoder |
| --- | ---: | ---: |
| Screenshots / card references | 68,976,640 B | 1,245,184 B |
| Replay / shared native video | 12,046,336 B | 8,556,544 B |
| Audio | 430,080 B | 430,080 B |
| Database and other metadata | 21,389,312 B | 4,620,288 B |
| Total per recorded hour | 410.86 MB | 59.33 MB |
| Extrapolation to 240 hours | 98.61 GB | 14.24 GB |

The candidate screen images were decoded from existing archives in a disposable copy. Between historical screenshot observations, the production encoder benchmark holds the last image at its normal replay cadence. It cannot recreate unseen intermediate motion. The measured 14.24 GB is therefore an extrapolation from this office sample, not a month-long recording, and does not include a growing queue of unprocessed original PNGs. Video playback, rapid animation, dense constantly changing text, microphone audio, and unusual OCR delays can increase growth. The real-capture trial separately checks this limitation.

The two normally completed **real** recordings contain 142 cards over 433.675 seconds at 3024×1964. After OCR finished, an audited copy containing all their media, text, transcripts/usage metadata, and ownership references allocated 2,519,040 B of visual media, 212,992 B of audio, 581,632 B of references, and 2,154,496 B of database/other files: **45.39 MB per recorded hour**. It excludes the deliberately interrupted segment, which retained its existing image fallback; the original test library and all 196 records remained intact. This short office capture is another workload sample, not a replacement for the broader 15-minute comparison or a month-long guarantee.

Hardware H.264 quality 0.55/keyframe 15 seconds used about 97.36 MB/hour for visual media in the candidate loop; HEVC 0.55/15 used 79.95, HEVC 0.55/60 used 42.58, and HEVC 0.5/60 used 33.99. Extending the 0.55 keyframe interval from 60 to 90 seconds barely changed size and increased random-seek latency, so it was rejected. Candidate-loop allocation includes temporary writer preallocation; the settled production-library table above is the delivery metric.

## Validation and reproduction

Private samples and detailed logs remain in ignored `.test-data/unified-archive`; recognized text is not included in this document. The formal user library was only read for comparisons. Live capture uses a separate test library and signed `release/Recall-Rhine-Unified.app`.

- Debug regression: 101 tests, eight optional skips, zero failures. Coverage includes original OCR, visible text, ordered background indexing, packed storage, cleanup, recording lifecycle, overlay/Dock presentation, card rendering, ridge motion, search, and UI data loading.
- Release regression: 37 tests, four optional skips, zero failures; the completed live-recording budget audit passed separately.
- Native video tests cover a forced application-change frame inside the one-second replay cadence, full-size cards and replay, exact OCR metadata, PNG export, search, shared-file deletion, and interrupted-recording recovery.
- Sixty random production card reads (including six full-resolution images) used 0.605 seconds of process CPU; median latency was 62.23 ms and p95 was 99.57 ms. These reads exercise the bounded shared-video decoder across three recordings, without a warmed card-image cache.
- Native UI validation expanded a newly recorded video-backed card, showed its recognized-text ready state, navigated to its timestamp, and played the native recording. The Chinese screenshot text remained visually legible. The isolated test app was quit normally after indexing completed; pre-existing Recall instances were left running.
- The delivery bundle passes `codesign --verify --deep --strict` with the existing stable signing identity. Validation uses the system signing service; sandbox-only verification cannot resolve that certificate chain.

```sh
swift test --package-path macOS --filter 'VisualArchiveTests|BackgroundPerformanceTests|RecordingLifecycleTests|StorageCleanupTests|ArchiveRenderingTests|OverlayPresentationTests'
RECALL_VISUAL_BENCHMARK=/absolute/path/to/private/benchmark \
swift test --package-path macOS -c release --filter VisualCodecBenchmarkTests
```

The optional codec tests require an explicitly prepared disposable sequence/copy. Their outputs are not the user's formal library. Completed budget directories are intentionally not overwritten.
