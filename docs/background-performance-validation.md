# Background processing performance — 2026-09-26

The running Recall process was sampled during a reported system slowdown. A process snapshot showed approximately 94% CPU in Recall and 237% in its local OCR worker (100% represents one logical CPU). The three-second native sample put the main application's busy background stack in screenshot tile encoding, including HEIC and repeated crop decoding/conversion. The main UI thread was mostly waiting on the event loop.

## Changes

- Local ONNX OCR uses two intra-op threads instead of four. Inter-op parallelism stays at one and thread spinning remains disabled. The worker runs at background QoS with Accelerate limited to two threads. Models, detection resolution, text recognition, and coordinates are unchanged.
- Local speech transcription also uses at most two CPU threads and background QoS.
- Normalize each screenshot to sRGB once before tiling. Previously each tile drew a crop of the original ImageIO image, repeating expensive source work. Copy only each tile's packed rows for hashing.
- Keep PNG tiles of 16 KiB or less lossless instead of starting another HEIC encode. Larger opaque tiles still compare PNG and HEIC sizes. The encoded tile cache holds up to 1,024 entries within the existing 32 MiB cost limit.
- Successful screenshot indexing and storage optimization jobs get recovery time proportional to their duration. Normal recovery is half the job duration, bounded to 0.15–5 seconds; low-power mode and elevated thermal state increase it. Indexing deadlines persist across briefly empty queues. All saved captures remain queued, and indexing continues while the interface is open.
- Actual overlay visibility now controls the archive renderer and image loader. Background library updates do not rebuild a hidden SceneKit scene. Reopening applies the latest records.

## Measurements

Six locally copied 3024×1964 screenshots were processed in the same order. Source captures, recognized contents, hashes, and sample logs remain in the ignored `.test-data` directory. No original library records were changed for the benchmark.

| Measurement, six screenshots | Before | After |
| --- | ---: | ---: |
| Screenshot packing wall time | 13.65 s | 5.69 s |
| Screenshot packing process CPU time | 8.37 s | 2.33 s |
| Unique tiles / HEIC tiles | 281 / 281 | 281 / 209 |
| Packed manifest + unique tile bytes | 1,274,716 | 1,807,062 |
| OCR worker wall time, including startup | 10.15 s | 15.88 s |
| OCR worker process CPU time | 25.78 s | 23.72 s |
| OCR average CPU, CPU time / wall time | 254% | 149% |

Packing uses approximately 72% less CPU time and completes approximately 58% sooner in this sample. OCR spreads its work over more time, reducing average parallel CPU use by approximately 41%. Every recognized string and bounding box was identical between the old and rebuilt native workers. The small lossless tiles increase archive size by approximately 0.51 MiB across these six images; this is an intentional storage/responsiveness tradeoff.

These are component measurements under the current machine's workload, not a guarantee about whole-application CPU, UI FPS, or all recordings. Indexing can take longer to catch up, particularly under heat or low-power mode. No frames are intentionally dropped by the new pacing policy. The normalized full-frame bitmap adds transient working memory (about 23 MiB at the tested resolution); the persistent encoded cache's byte budget did not increase.

## Validation

- 31 regression tests passed; five optional environment-dependent checks were skipped. Coverage includes original OCR/dimensions, tile orientation and edges, shared tile ownership, export, interrupted writes, recording pause/resume, search responsiveness, and overlay presentation.
- New integration checks verify that a real hosted archive scene stops updating while hidden and resumes with new records; a three-frame indexing queue yields even on exact cache hits and still commits every saved frame.
- Release configuration screenshot benchmark passed separately. Release test executables do not contain the bundled OCR runtime, so OCR integration tests run in the normal debug configuration, which resolves the prepared native runtime. The initial release-suite attempt correctly reported the missing test runtime; the complete debug regression run passed.
- The native OCR worker was rebuilt from source and compared against the previous packaged worker. The new application includes that rebuilt binary, not just the updated Swift executable.

Reproduce functional checks:

```sh
python3 scripts/prepare-neural-ocr.py
swift test --package-path macOS --filter 'BackgroundPerformanceTests|PackedScreenTests|VisibleRecognitionTests|RecordingLifecycleTests|StorageOptimizationTests|ResponsivenessTests|ArchiveRenderingTests|OverlayPresentationTests'
```

Reproduce the packing benchmark with an **absolute** path to a private PNG sample directory:

```sh
RECALL_PERFORMANCE_SAMPLES=/absolute/path/to/samples \
swift test --package-path macOS -c release --filter BackgroundPerformanceTests/testScreenshotPackingBenchmark
```
