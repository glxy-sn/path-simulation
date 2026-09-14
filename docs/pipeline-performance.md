# Pipeline performance

Results still wait for the complete privacy-redacted MP4. Segmentation runs before playback and retains the existing single color. No early-results mode was enabled.

## Enabled changes

- Detection batches feed the same decoded frames directly into the ordered tracker. Skipped frames use `grab()` instead of retrieving image arrays. Rendering remains a separate pass after fusion.
- Path and BEV renderers project coordinates once, keep a cursor per track and draw only new segments. Historical segments are no longer recomputed for every output frame.
- Video frames stream directly to H.264. A real capability probe selects VideoToolbox, then libx264. If neither encoder is available, OpenCV mp4v remains the fallback. There is no second transcoding pass. Encoder failure raises an error and incomplete output is not published.
- Privacy inference uses bounded, shape-compatible batches, default 2 frames. Each output frame receives its own mask. No stale-mask propagation is used.
- Fusion uses time-window and interval indexes before expensive appearance comparisons. Repeated appearance comparisons are cached within a fusion call. Candidate thresholds and assignment rules are unchanged. Rejected temporal diagnostics are compacted, so diagnostics are not byte-identical to older runs.
- Camera detection and tracking outputs are cached across jobs. Changes to calibration or render settings reuse those camera stages. Fusion, analytics and final video rendering still run again.
- Progress now distinguishes combined detection/tracking from final video preparation. Each job writes `performance.json` with wall-clock timings and camera cache hits. Nested timings overlap and must not be summed.
- The macOS results screen prefers readable local artifact URLs. History copies local files directly and downloads HTTP fallbacks to a temporary file instead of buffering whole videos in RAM.

## Local cache

Location: `<WORKDIR>/camera-cache-v1`. Entries expire after seven days and successful writes trim total size to 512 MB by default. Cache keys include the source file path, size, modification/change timestamps, effective trim range, model metadata, relevant detection/tracking settings, library versions and stage source code hashes.

The gzip JSON entries contain boxes, timestamps, anonymous track data and sampled appearance vectors needed by fusion. They contain no video frames or person crops and use no pickle deserialization. Corrupt or expired entries are treated as misses. Changing source file metadata, weights, tracking code or inference settings invalidates the entry. Delete this cache directory when retiring the associated footage if the vectors should also be removed.

## Defaults and tuning

Accuracy-sensitive defaults remain 1920 input size, 5 FPS, CPU ReID, one torch thread and fresh ReID extraction for every detection frame.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `PRISM_CAMERA_CACHE` | `1` | Set `0` to disable camera-stage caching |
| `PRISM_CAMERA_CACHE_MB` | `512` | Cache size cap |
| `PRISM_PRIVACY_BATCH` | `2` | Maximum frames per privacy inference batch |
| `PRISM_IMGSZ` | `1920` | Detection resolution, experimental candidate `1280` |
| `PRISM_PROC_FPS` | `5` | Sampling rate, experimental candidate `3` |
| `PRISM_REID_DEVICE` | `cpu` | CPU or an explicitly tested MPS runtime |
| `PRISM_TORCH_THREADS` | `1` | CPU torch threads, tested candidate `2` |
| `PRISM_REID_REFRESH_SEC` | `0` | Opt-in descriptor reuse window, tested candidate `0.4` |

Descriptor reuse is disabled by default. When enabled, only unambiguous boxes with at least 0.9 IoU can reuse a recent descriptor. Crowded matches or expired descriptors trigger new inference. This heuristic may change identity behavior and requires footage-specific validation.

## Short benchmark

Two cameras, four seconds each, from the same existing local job. These are wall-clock spot checks, not a long-video throughput guarantee or ground-truth accuracy evaluation. Runs were sequential, with no repeated statistical sampling. GPU/runtime warm-up can influence the differences.

| Run | Total seconds | Final videos | Camera cache hits |
| --- | ---: | --- | ---: |
| Previous pipeline | 15.19 | Yes | 0 |
| Optimized comparison | 11.99 | Yes | 0 |
| Repeat using camera cache | 4.72 | Yes | 2 |
| Final implementation verification | 11.75 | Yes | 0 |

The optimized and cached runs retained identical summary, observations, paths and identity-quality fields to the baseline: 10 tracks and 198 observations. Privacy masks from batch inference were pixel-identical to the old single-frame inference on one actual frame from each camera. VideoToolbox encoding succeeded.

Tuning experiments below excluded video rendering and therefore must not be compared directly to the full-pipeline totals above:

| Candidate | Processing including detection/tracking (seconds) | Observations versus baseline |
| --- | ---: | --- |
| 1280 input / 3 FPS | 2.81 | Changed, 11 tracks and 128 observations |
| ReID on MPS | 7.13 | Identical on this clip |
| Two CPU torch threads | 5.91 | Identical on this clip |
| ReID refresh every 0.4 seconds | 6.01 | Identical on this clip |

The lower resolution/FPS candidate changed the result, which is why it was not selected as the default. A four-second clip cannot establish identity quality across long occlusions or camera handovers, so ReID tuning also remains opt-in.

## Reproduce

From the backend directory, use the existing runtime and an existing job file:

```sh
.venv-runtime/bin/python scripts/benchmark_pipeline.py \
  --job /absolute/path/to/job.json \
  --output /private/tmp/foodcourt-benchmark \
  --label first --duration 4
```

Repeat with a new label and the same output directory to test cache reuse. Use `--no-render` for isolated inference comparisons or `--no-cache` to force fresh camera processing. Configure the model roots as in the app if weights are installed in Application Support. Outputs remain separate from production job results.
