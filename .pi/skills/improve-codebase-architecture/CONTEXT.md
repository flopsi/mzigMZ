# mzigRead — Domain Model

Mass spectrometry RAW file reader in Zig. Zero-copy, mmap-first, ground-truth-driven against ThermoRawFileParser (.NET).

## Core Concepts

### File Format

**Thermo RAW file**
Binary file format written by Thermo Fisher mass spectrometers (Orbitrap, Astral, etc.). Contains a memory-mapped scan index, per-scan packet data (centroid or profile), trailer labels (key-value per scan), and a ScanEvent table (mass calibration, collision energy, isolation width, etc.).

**Packet**
A variable-length binary record containing the mass spectrum for one scan. Two packet types:
- `FT_CENTROID` (type 20): peak list (mz + intensity + per-peak features)
- `FT_PROFILE` (type 21): raw time-of-flight / frequency data, optionally with embedded centroids

**Packet header**
32-byte header at the start of each packet: segment count, word counts (profile, centroid, expansion, noise), feature word. Determines packet size and decode strategy.

**Scan index**
Memory-mapped array of `ScanIndexEntry` structs at a fixed file offset. Each entry: data offset, packet type, scan number, and extended fields (RT, TIC, base peak m/z) for rev >= 65.

**ScanEvent table** (also: trailer scan events)
Per-scan event metadata table at the end of the file. Contains mass calibrators (polynomial coefficients), isolation width, collision energy, fragmentation type, and mass ranges. Deduced per unique event, then mapped to scan index positions via deduplication table.

**Trailer labels**
Per-scan key-value pairs at offsets stored in each `ScanIndexEntry.trailer_offset`. Two important ones: label 9 (filter string, e.g. `"FTMS + p NSI Full ms [400.0000-800.0000]"`), label 18 (charge state).

### Decoding

**Centroid decode**
Decodes the centroid word stream (variable-length entries: 8 bytes standard, 12 bytes for accurate-mass) into arrays of mz + intensity + PeakFeatures (charge, resolution, noise, baseline, SNR, flags).

**Profile decode** (FT_PROFILE packets)
Converts raw frequency counts to m/z using mass calibrators (polynomial coefficients from the ScanEvent). Optionally returns raw frequencies (before calibration) for custom re-calibration.

**SIMD min/max reduction**
After decode, a SIMD vectorised pass computes min/max m/z and max intensity across all peaks in a single pass through the data.

**ScanDecoder module**
The single-point-of-truth for the decode pipeline: reads packet header → estimates peak count → dispatches to centroid or profile decoder → SIMD min/max. Owned by `AppState.decoder`. Eliminates the four-way duplication that existed when the pipeline was inlined in each `loadScan*` method.

### Display State

**Spectrum**
In-memory representation of a decoded scan: `[]f64` m/z values, `[]f32` intensity values, `[]PeakFeatures` (centroid only), and scalar bounds (mz_min, mz_max, intensity_max).

**Spectrum cache**
LRU cache of 8 decoded spectra in `ScanDecoder`. Avoids re-decode when navigating between recently-viewed scans.

**ZoomState**
Current x-axis (m/z) and y-axis (intensity) viewport for the spectrum canvas. Preserved across scan loads.

**Chromatogram**
XIC-style data: `[]f64` retention times + `[]f64` TIC or base peak intensity, `[]u8` MS levels. Derived from scan index (no packet decode needed); MS level filter applied at render time.

### Application

**AppState**
Central state container for the viewer. Owns: RawFile (mmap + scan table), TrailerScanEvents, ScanDecoder, current spectrum, zoom, chromatograms, scan list, MS level filter.

**ViewMode**
Rendering style for spectrum peaks: `.stick` (vertical bars) or `.line` (connect-the-dots).

## Relationships

- `RawFile` (mmap + scan index) → parsed by `AppState` into `scans[]`
- `AppState` → delegates decode to `ScanDecoder`
- `ScanDecoder` → dispatches to `advanced_packet` (centroid) or `profile_packet` (profile)
- `ScanEvent table` → parsed into `TrailerScanEvents`; calibrators passed to profile decoder
- `Trailer labels` → parsed independently; used for filter strings and charge state

## Key Files

| File | Concern |
|------|---------|
| `raw_core/raw_file.zig` | File format constants, struct sizes, ScanIndexEntry, mmap readers |
| `raw_core/advanced_packet.zig` | Centroid packet decode, PacketHeader, PeakFeatures |
| `raw_core/profile_packet.zig` | Profile packet decode (calibrated m/z from frequencies) |
| `raw_core/scan_event.zig` | ScanEvent struct (polymorphic, variable-length) |
| `raw_core/trailer_events.zig` | TrailerScanEvents deduplication table |
| `scan_decoder.zig` | Decode pipeline (header → dispatch → SIMD bounds) |
| `app_state.zig` | Viewer state: open file, current scan, zoom, chromatograms |
| `gui/spectrum_canvas.zig` | Win32 spectrum rendering |
| `gui/chromatogram_canvas.zig` | Win32 TIC/XIC rendering |
| `gui/scan_list.zig` | Win32 MS level filter + scan list |

## Ground Truth / Verification

- **ThermoRawFileParser** (.NET) is the reference implementation. Every decode output must match it.
- Test files in `D:/000projects/test_files/` (12k-scan files, large Astral files).
- Architecture reports in `D:/tmp/mzigRead/`.
- The 8.6 GB Astral file (275,462 scans) parses in ~1s with 0 mismatches.

## Flagged Ambiguities

- "packet" vs "scan": a RAW file scan is stored as one or more packets. In this codebase, "scan" always means a row in the scan index; "packet" always means the binary record. Don't interchange them.
- "trailer" vs "ScanEvent": trailer labels (offset-based key-value) are one file structure; the ScanEvent table is a separate structure at file end. Both carry MS-level metadata.