#637 Release backdrop measurement

Run this from the authorized Terminal.app session after obtaining the shared desktop GUI lock. Pass the lock's exact run ID and acquisition ID. Build and sign the candidate in Release configuration first; the script refuses a Debug or unsigned bundle, a pre-existing Mado process, an undersized fixture, and output inside the checkout.

```sh
python3 scripts/perf/issue637-run.py \
  --app .build/dd-i637-release/Build/Products/Release/Mado.app \
  --image "$HOME/.picsee/testassets/generated/S3/noise-48mp.png" \
  --second-image "$HOME/.picsee/testassets/generated/S3/noise-100mp.png" \
  --out "$HOME/.picsee/device/i637-perf-<unique-run-id>" \
  --run-id '<gui-lock-run-id>' \
  --gui-acquisition-id '<gui-lock-acquisition-id>' \
  --iterations 40
```

The command launches the signed app, drives zoom and pan in one window and then two windows, captures thread CPU time and render wall time per backdrop update from signposts, samples process RSS, and terminates only the app process it started. It writes `meta.json`, `signposts.ndjson`, `rss.ndjson`, and `report.json` to the new output directory. A missing or incomplete trace exits nonzero and remains available for diagnosis.

`requestToPresentMs` ends when the bitmap is assigned to the NSView. It does not measure the WindowServer display time. The existing input-to-state-feedback p95 ≤100 ms target is not measured here, so the report says `unknown`; no pass claim follows from backdrop lag. GPU time, allocation count and true display-frame/hitch distribution also say `unknown` unless another profiler supplies them. RSS change is process-wide and is not a leak proof. Establish any blur-specific resource budget from measured baselines, not this script's defaults.

Offline parser check: `node --test scripts/perf/issue637-parse.test.mjs`.
