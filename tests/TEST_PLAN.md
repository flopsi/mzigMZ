# Ground-Truth Verification Test Plan

> **Oracle**: ThermoRawFileParser (.NET, native Thermo DLLs) via `query` subcommand
> **Subject**: mzigRead decoder (centroid + profile)
> **Scope**: Reader correctness. Writer correctness is tested separately via passthrough round-trip.

## 1. Overview

This document defines the verification strategy for comparing mzigRead's decoded spectrum data against the canonical ThermoRawFileParser reference implementation. Every metric, tolerance, and test file is specified here. The test runner (`verify_ground_truth.zig`) implements this spec exactly.

## 2. Metrics

### 2.1 Correctness / Accuracy

| Metric | Unit | Description |
|--------|------|-------------|
| `peak_count_match_rate` | % | Scans where mzigRead and reference agree on peak count |
| `peak_count_diff_mean` | count | Mean absolute difference when counts differ |
| `peak_count_diff_max` | count | Worst single-scan count mismatch |
| `mz_mad` | Da | Mean absolute deviation of m/z values (aligned peaks only) |
| `mz_max_dev` | Da | Largest single m/z deviation observed |
| `mz_dev_p99` | Da | 99th percentile m/z deviation |
| `mz_exceed_count` | count | Number of peaks exceeding 0.001 Da tolerance |
| `intensity_mad` | fraction | Mean absolute relative intensity deviation |
| `intensity_max_dev` | fraction | Largest single relative intensity deviation |
| `intensity_exceed_count` | count | Number of peaks exceeding 0.1% relative tolerance |
| `ms1_peak_count_match_rate` | % | Peak count match rate, MS1 scans only |
| `ms2_peak_count_match_rate` | % | Peak count match rate, MS2 scans only |
| `ms1_mz_mad` | Da | m/z MAD, MS1 scans only |
| `ms2_mz_mad` | Da | m/z MAD, MS2 scans only |

**Alignment rule**: When peak counts differ, compare only the first N peaks (N = min of both counts). A peak count mismatch alone is a failure; the aligned metrics measure *how wrong* the shared subset is.

### 2.2 Completeness

| Metric | Unit | Description |
|--------|------|-------------|
| `scans_decoded` | count | Number of scans successfully decoded |
| `scans_in_file` | count | Total scans in the .raw file |
| `decode_failure_count` | count | Scans that failed to decode (error returned) |
| `decode_success_rate` | % | `scans_decoded / scans_in_file` |
| `ms1_scans_sampled` | count | Number of MS1 scans in sample |
| `ms2_scans_sampled` | count | Number of MS2 scans in sample |
| `ms3plus_scans_sampled` | count | Number of MS3+ scans in sample (informational) |

### 2.3 Memory

| Metric | Unit | Description |
|--------|------|-------------|
| `peak_rss_kb` | KB | Peak resident set size (OS-reported) |
| `mean_mem_per_scan_kb` | KB | `peak_rss / scans_decoded` |
| `heap_growth_rate` | KB/scan | RSS at end − RSS at start, divided by scan count |
| `allocation_count` | count | Total `alloc` / `free` pairs (if Zig tracking enabled) |

### 2.4 Speed

| Metric | Unit | Description |
|--------|------|-------------|
| `total_wall_ms` | ms | Wall-clock time for all sampled scans |
| `mean_decode_us` | µs | Mean per-scan decode time (mzigRead) |
| `median_decode_us` | µs | Median per-scan decode time |
| `p99_decode_us` | µs | 99th percentile per-scan decode time |
| `reference_wall_ms` | ms | ThermoRawFileParser total wall time (for baseline) |
| `speed_ratio` | × | `reference_wall_ms / total_wall_ms` (>1 = mzigRead faster) |

### 2.5 Reproducibility

| Metric | Unit | Description |
|--------|------|-------------|
| `run_to_run_mz_mad_stddev` | Da | Standard deviation of `mz_mad` across 3 runs |
| `run_to_run_peak_count_consistency` | % | % of scans with identical peak count across all runs |
| `deterministic_output` | bool | All 3 runs produce bit-identical output |

### 2.6 Robustness

| Metric | Unit | Description |
|--------|------|-------------|
| `file_revision` | number | .raw file revision tested (informational) |
| `file_size_mb` | MB | .raw file size |
| `early_scan_mz_mad` | Da | m/z MAD for first 10% of scans |
| `late_scan_mz_mad` | Da | m/z MAD for last 10% of scans |
| `calibration_drift_ratio` | × | `late_mz_mad / early_mz_mad` (>1 = late scans less accurate) |

## 3. Methodology

### 3.1 One file at a time

Each test run processes exactly **one** `.raw` file. No batch processing, no directory scanning, no parallel execution. This ensures:

- Maximum OS page cache for the mmap
- No contention for `ThermoRawFileParser.exe` (single .NET process)
- Clean, isolated memory measurements (RSS belongs to one file)
- Fair speed comparisons (no I/O queuing)

### 3.2 Sample size: 100 scans, stratified

| Stratum | Count | Selection |
|---------|-------|-----------|
| MS1 | 50 | Random without replacement from all MS1 scan indices |
| MS2 | 50 | Random without replacement from all MS2 scan indices |
| MS3+ | 0 | Informational only; not sampled unless file has < 50 MS2 scans, then backfill with MS1 |

If the file has fewer than 50 scans total, sample ALL scans. If fewer than 50 of either MS level, backfill with the other.

### 3.3 Reproducibility runs

Each file is tested **3 times** in sequence (not interleaved with other files). The first run is the primary; runs 2 and 3 measure run-to-run variance. The seed for random scan selection is **fixed** across runs so the same 100 scans are tested each time.

### 3.4 Environment control

- No other applications consuming significant CPU or I/O
- OS page cache cold for first run (file not recently accessed)
- `ThermoRawFileParser.exe` process killed between runs (no .NET JIT caching benefit)
- `zig build verify-ground-truth` runs in ReleaseFast mode

### 3.5 Comparison algorithm

For each sampled scan:

1. Decode with mzigRead → `Spectrum { mz: []f64, intensity: []f32 }`
2. Run `ThermoRawFileParser.exe query -i=<file> -n=<scan_num> -s` → capture stdout
3. Parse JSON → `{ mzs: []f64, intensities: []f64 }` (note: intensities are f64 in JSON)
4. Compare:
   ```
   if ours.len != ref.len:
       FAIL "peak count mismatch"
       align_len = min(ours.len, ref.len)
   else:
       align_len = ours.len
   
   for i in 0..align_len:
       mz_diff = abs(ours.mz[i] - ref.mzs[i])
       if mz_diff > MZ_TOLERANCE:
           FAIL m/z deviation
       
       int_rel_diff = abs(ours.intensity[i] - ref.intensities[i]) / max(abs(ref.intensities[i]), 1e-6)
       if int_rel_diff > INTENSITY_REL_TOLERANCE:
           FAIL intensity deviation
   ```

### 3.6 Tolerances

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `MZ_TOLERANCE` | 0.001 Da | 1 mDa — Orbitrap mass accuracy floor. Values within this are measurement noise, not decoder error. |
| `INTENSITY_REL_TOLERANCE` | 0.001 | 0.1% — reasonable for floating-point representation differences between Zig (f32) and .NET (f64→f32). |
| `SAMPLE_SIZE` | 100 | Balances statistical confidence with runtime (~2s/file reference, ~0.5s/file mzigRead). |

## 4. Test File Inventory

### 4.1 Minimum test set

| # | File | Expected Properties | Why |
|---|------|---------------------|-----|
| 1 | Small LC-MS/MS, rev 66 | ~12k scans, MS1+MS2, centroid | Baseline accuracy. Most common format. |
| 2 | Large Orbitrap | ~100k+ scans, MS1+MS2, centroid | Stress test: memory linearity, speed at scale. |
| 3 | Astral (if available) | High-res, many MS2, centroid | Newer format, different detector characteristics. |
| 4 | Profile mode file | Profile data, MS1 | Tests profile decoder path (frequency → m/z calibration). |
| 5 | Rev 65 file (if available) | Older file revision | Tests backward compatibility. |

### 4.2 Known files

From `D:/000projects/test_files/`:

| # | File | Size | Type | Use |
|---|------|------|------|-----|
| 1 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw` | 286 MB | Centroid MS1+MS2 | Baseline accuracy |
| 2 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_02.raw` | 285 MB | Centroid MS1+MS2 | Reproducibility pair |
| 3 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_03.raw` | 284 MB | Centroid MS1+MS2 | Triplicate consistency |
| 4 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y10-E40_02.raw` | 312 MB | Centroid MS1+MS2 | Different gradient |
| 5 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_01.raw` | 303 MB | Centroid MS1+MS2 | Different gradient |
| 6 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_02.raw` | 303 MB | Centroid MS1+MS2 | Reproducibility pair |
| 7 | `20240428_MP1_50SPD_IO25_LFQ_10pg_Y45-E05_03.raw` | 365 MB | Centroid MS1+MS2 | Triplicate consistency |
| 8 | `29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_1.raw` | 8.24 GB | Profile MS1 + Centroid MS2 | Profile decoder test + stress |
| 9 | `29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.raw` | 8.26 GB | Profile MS1 + Centroid MS2 | Reproducibility, calibration drift |

**Priority order** (Phase 1 generation): generate ground truth for all 9 files. For verification, test at minimum: #1 (baseline), #8 (profile + stress), #3 or #6 (triplicate consistency).

### 4.3 File discovery

The test runner accepts a single `.raw` file path. File selection is manual — the operator picks which file to test. The test plan lists *candidate* files; the runner doesn't auto-discover.

## 5. Reporting

### 5.1 Per-run output

```
=== verify-ground-truth: <filename> (run 1/3) ===
  file_revision = 66
  file_size     = 412 MB
  total_scans   = 12048 (MS1: 6024, MS2: 6024)

  Sampled 100 scans: 50 MS1, 50 MS2

  PASS  scan    1  MS1  150 peaks  mz_max_dev=0.0001
  PASS  scan   42  MS1  203 peaks  mz_max_dev=0.0003
  FAIL  scan  105  MS2   peak count: 89 vs 92 (ref)
  PASS  scan  207  MS2   45 peaks  mz_max_dev=0.0000
  ...
  PASS  scan 11900 MS2   12 peaks  mz_max_dev=0.0002

--- Summary (run 1) ---
  correctness:
    peak_count_match_rate     = 97.0%
    peak_count_diff_mean      = 3.0
    peak_count_diff_max       = 5
    mz_mad                    = 0.00012 Da
    mz_max_dev                = 0.0023 Da  ← exceeds tolerance!
    mz_dev_p99                = 0.0008 Da
    mz_exceed_count           = 1
    intensity_mad             = 0.0004
    intensity_max_dev         = 0.0012
    ms1_peak_count_match_rate = 100.0%
    ms2_peak_count_match_rate = 94.0%

  completeness:
    decode_success_rate       = 100.0%
    decode_failure_count      = 0

  memory:
    peak_rss_kb               = 45800 KB
    mean_mem_per_scan_kb      = 3.8 KB
    heap_growth_rate          = 0.4 KB/scan

  speed:
    total_wall_ms             = 487 ms
    mean_decode_us            = 4.2 µs
    p99_decode_us             = 15.8 µs
    reference_wall_ms         = 1823 ms
    speed_ratio               = 3.74×

  reproducibility:
    (after 3 runs)
    mz_mad_stddev             = 0.00003 Da
    deterministic             = true

  robustness:
    early_scan_mz_mad         = 0.00011 Da
    late_scan_mz_mad          = 0.00014 Da
    calibration_drift_ratio   = 1.27×
```

### 5.2 Machine-readable output (JSON)

A `verify_result.json` file is written for CI consumption and dashboarding:

```json
{
  "file": "20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw",
  "file_revision": 66,
  "file_size_mb": 412,
  "scans_in_file": 12048,
  "sample_size": 100,
  "runs": [
    {
      "run": 1,
      "correctness": { ... },
      "speed": { ... },
      "memory": { ... }
    }
  ],
  "aggregate": {
    "mean_mz_mad": 0.00012,
    "overall_pass_rate": 0.97,
    ...
  }
}
```

## 6. Implementation

### 6.1 Two-phase architecture

**Phase 1 — Generate**: `src/tools/generate_ground_truth.zig`

One-time per file. Runs ThermoRawFileParser in MGF mode (`-f=0`, single invocation for all scans), parses the MGF output, extracts per-scan m/z + intensity arrays, saves them as JSON files:

```
tests/ground_truth/
  20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw/
    000001.json   ← scan 1: { mzs: [...], intensities: [...] }
    000002.json   ← scan 2
    ...
```

- Input: `.raw` file path
- Output: directory of per-scan JSON files (one per scan, zero-indexed)
- Usage: `zig build generate-ground-truth -- file.raw`
- MGF parsing: line-based, extract `scan=` from TITLE, parse m/z intensity pairs until END IONS

**Phase 2 — Verify**: `src/tools/verify_ground_truth.zig`

Fast, repeatable. Reads cached ground truth JSON files, decodes with mzigRead, compares.

- Input: `.raw` file path (looks for `tests/ground_truth/<filename>/`)
- Usage: `zig build verify-ground-truth -- file.raw`
- No external processes — pure Zig comparison
- If ground truth not found, prints instructions to run Phase 1 first

### 6.2 MGF format (reference output)

ThermoRawFileParser `-f=0` (MGF) produces one `BEGIN IONS...END IONS` block per scan:

```
BEGIN IONS
TITLE=controllerType=0 controllerNumber=1 scan=2
SCANS=2
RTINSECONDS=0.22423
PEPMASS=420.44101 0.000
153.12656 10.833
153.71457 6.614
...
END IONS
```

Parsing rules:
- Scan number extracted from TITLE line (`scan=<num>`)
- Header lines (TITLE, SCANS, RTINSECONDS, PEPMASS, CHARGE) are skipped
- Float pairs are m/z then intensity
- Blocks end at `END IONS` or next `BEGIN IONS` or EOF

### 6.3 Per-scan JSON format

Ground truth is stored as one JSON file per scan, matching the `query` output structure:

```json
{
  "mzs": [408.43, 412.22, ...],
  "intensities": [111.73, 124.59, ...]
}
```

This is the canonical format. Phase 1 converts MGF to this format once; Phase 2 reads it.

### 6.4 Build steps

```zig
// Phase 1: generate ground truth (one-time)
b.step("generate-ground-truth", "Generate ground truth from ThermoRawFileParser");

// Phase 2: verify against cached truth (repeatable, fast)
b.step("verify-ground-truth", "Verify mzigRead output against ground truth");
```

### 6.5 ThermoRawFileParser path

Hardcoded constant (per Q1 decision):

```zig
const TRFP_EXE = "D:/000projects/newRawFileReader/ThermoRawFileParser-master/ThermoRawFileParser-master/bin/x64/Release/net8.0/ThermoRawFileParser.exe";
```

## 7. Acceptance Criteria

The test infrastructure is **complete** when:

- [ ] `generate_ground_truth.zig` compiles and generates JSON for file #1 (small baseline)
- [ ] `verify_ground_truth.zig` compiles and compares against cached ground truth
- [ ] Both tools use `cli_args.getArgs()` for argument parsing
- [ ] Ground truth generation handles all 9 files (even if some scans fail — MGF parsing is robust)
- [ ] Verification reports all 28 metrics from Section 2
- [ ] Reproducibility runs (×3) are built into `verify_ground_truth.zig` via `--runs=3` flag
- [ ] JSON output (`verify_result.json`) is machine-readable
- [ ] No synthetic data — every comparison uses real Thermo .raw files

## 8. Open Questions

- [x] ThermoRawFileParser `.exe` path — hardcoded constant (Q1 resolved)
- [x] Test files — use `D:/000projects/test_files/`, 9 files available (Q2 resolved)
- [x] Profile decoder — yes, file #8 and #9 contain profile MS1 (Q3 resolved)
- [ ] Should MS2 matching check precursor m/z in addition to peak data?
- [ ] CI integration: can we check a small test file subset into the repo? (< 100 MB)
- [ ] Should ground truth generation use MGF (`-f=0`) or query JSON per-scan? MGF is faster (one invocation), JSON is more structured but requires per-scan calls.
