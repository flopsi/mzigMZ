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

**Packet binary layout (on disk)**
All sections are tightly packed little-endian:

```
Offset 0..31   : PacketHeader (32 bytes)
    u32 num_segments
    u32 num_profile_words       ×4 bytes = profile section size
    u32 num_centroid_words      ×4 bytes = centroid section size
    u32 default_feature_word    accurate-mass flag + default flags
    u32 num_non_default_feature_words
    u32 num_expansion_words     ×4 bytes = expansion section size
    u32 num_noise_info_words    ×4 bytes = noise section size
    u32 num_debug_info_words

Offset 32      : MassRange[]  (num_segments × 8 bytes: f32 low + f32 high)

After ranges   : Profile data (num_profile_words × 4 bytes)
                 ProfileSegmentStruct per segment (24 bytes each) +
                 subsegment headers + intensity words interleaved

After profile  : Centroid data (num_centroid_words × 4 bytes)
                 Per segment: u32 count + count entries
                 Standard entry: f32 mz + f32 intensity  (8 bytes = 2 words)
                 Accurate entry: f64 mz + f32 intensity  (12 bytes = 3 words)

After centroid : Feature words (num_non_default_feature_words × 4 bytes)
                 One word per peak with non-default charge or flags:
                 bits 0-17: peak index, bits 19-23: flags, bits 24-31: charge

After features : Expansion words (num_expansion_words × 4 bytes)
                 First word: header (>0 means HasWidths)
                 Remaining words: f32 resolution width per peak

After expansion: Noise info packets (num_noise_info_words × 4 bytes)
                 Each packet: f32 mass + f32 noise + f32 baseline (12 bytes = 3 words)
                 Decoded into `PeakFeatures.noise`, `baseline`, and `sn_ratio`.

After noise    : Debug info (num_debug_info_words × 4 bytes)
```

**default_feature_word bit meanings**
- Bit 6 (`0x40`): standard mass mode (set = standard, clear = may be accurate)
- Bit 16 (`0x10000`): accurate mass mode (set = accurate-mass f64 mz entries)
- Bits 19-23: default peak flags (fragmented, merged, reference, exception, modified)
- Accurate mass mode is active when bit 16 is set AND bit 6 is clear.

**Centroid entry sizes**
- Standard (8 bytes): `f32 mz` + `f32 intensity` — mz precision ~0.001
- Accurate-mass (12 bytes): `f64 mz` + `f32 intensity` — mz precision ~1e-9

**Expansion words (resolution widths)**
- First word is a header int: value > 0 indicates resolution widths follow
- Subsequent words: `f32` FWHM resolution per peak
- Decoder reads via `readResolutionWidths` and applies widths to `PeakFeatures.resolution`; encoder writes via `encodeCentroidPacket`

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

### Export Pipeline

**Export module**
Shared export pipeline in `src/export/`. All format writers consume a decoded `Spectrum` (m/z + intensity + PeakFeatures + bounds) and scan metadata (RT, MS level, filter string) from the existing decode pipeline. One decode, many outputs — no duplication.

**raw_file_writer.zig**
Writes `.raw` files from decoded spectra + scan table. For pure passthrough (round 1): copies unknown byte regions verbatim from the source mmap, re-encodes only the scan table and packet data from decoded state. See ADR-0001.

**Schema**
A description of a known `.raw` file layout: `file_revision` + scan index entry size + packet header layout + checksum formula. For a known schema, the scan table offset, packet region bounds, and per-entry layout are fixed, enabling bulk copy operations. Schemas are validated by inspecting the first 10–20 scans. See ADR-0002.

**Fast path**
The schema-based passthrough algorithm: validate the file against a known schema, then use `writeAll` to bulk-copy the pre-scan-table, packet, and trailer regions in three large writes. Re-encoded centroid packets are overwritten in-place via `writePositionalAll`. Used when schema detection succeeds. 5–20× faster than the slow path. See ADR-0002.

**Slow path**
The generic per-scan decode+encode passthrough algorithm: for every scan, decode the packet to compute the re-encoded size, then re-encode and overwrite in-place. Used when schema detection fails or the file doesn't match a known layout. Correct but slow. See ADR-0002.

**Bulk copy**
A single `writeAll` (or `readPositionalAll`) over a large byte region, as opposed to many small per-scan I/O operations. The fast path uses bulk copy for the pre-scan-table region, the packet region, and the trailer region, reducing I/O syscall count from O(scans) to O(1) per region. See ADR-0002.

**Schema detection**
Inspecting the first 10–20 scans of a file to verify it matches a known schema: `file_revision` is recognised, scan index entries are well-formed, packet headers parse cleanly. One-time cost (microseconds) amortised over the entire file write. If detection fails, the writer falls back to the slow path. See ADR-0002.

**Centroid packet encoder** (`advanced_packet.zig`)
Reverse of the centroid decoder. Takes decoded `mz[]`, `intensity[]`, optional `PeakFeatures[]`, and produces a single-segment binary packet:
- Computes `default_feature_word` from accurate-mass flag + default flags
- Counts non-default features (charge != 0 or flags != default) to size the feature-words section
- Writes centroid entries in standard (8-byte) or accurate-mass (12-byte) format
- Writes expansion words if any peak has `resolution != 0`
- Writes noise info packets if provided
- The encoder always produces single-segment packets; multi-segment original packets are flattened into one segment on re-encode. This is valid but changes the on-disk byte layout.

**mzml_writer.zig** (`src/mzml/writer.zig`)
Streaming XML serializer: accumulates mzML document in a growable ArrayList buffer. Supports no/zlib/numpress compression, f32/f64 precision, indexed mzML with SHA-1 checksums. Writes spectra from SoA data (no AoS conversion) for the fast path. Verified on 275k-scan Astral files (11.6 GB output).

**Export pipeline architecture**
```
RawFile (mmap) → ScanDecoder.decode() → Spectrum
    ↓
    ├── raw_file_writer.zig   (.raw passthrough or modified)
    └── mzml_writer.zig       (.mzML XML)
```

**Progress reporting**
Long-running exports (`raw_file_writer.passthrough`, `mzml/streaming_convert`) accept an optional `core.progress.Reporter`. The reporter is a type-erased `(current, total)` callback used by the imguinz2 viewer's export modal to update a progress bar without coupling the core export modules to the UI. Existing CLI tools and tests call the wrapper entry points with no reporter.

### GUI Display Layer

**Win32 GDI viewer** (`src/gui/`, legacy fallback)
Retained as a buildable reference. Five modules: main_window, spectrum_canvas, chromatogram_canvas, scan_list, file_dialog. Uses `src/viewer/plot_math.zig` for coordinate mapping. This is the **positive control** — the imguinz2 viewer is validated by working first here, then porting.

**imguinz2 viewer** (`src/viewer_zgui/`, current dev target)
The new GPU-accelerated viewer using imguinz2 (GLFW + OpenGL3 + ImGui + ImPlot via the `dear_bindings` dcimgui wrapper). Same 4-region layout as the Win32 viewer (sidebar / chromatogram / spectrum / status bar), with a 1:1 module-per-panel architecture: main, scan_list_panel, spectrum_plot, chromatogram_plot, file_dialog, cycle_navigation, export_panel. All UI state is owned by a single `ViewerState` struct in `main.zig`; each panel owns a small `State` struct for its persisted view state. The export panel drives async `.raw`/mzML exports and reports progress through `core.progress.Reporter`. Built and verified with real .raw data 2026-06-12 — see `D:/tmp/mzigRead/HANDOFF-imguinz2-real-data.md` for the full handoff.

**Pure-logic modules** (`src/viewer/`)
Shared by both viewers. `plot_math.zig` (coordinate mapping + ZoomState). No allocation, no I/O, no GUI framework dependency.

### Application

**AppState**
Central state container for the viewer. Owns: RawFile (mmap + scan table), TrailerScanEvents, ScanDecoder, current spectrum, zoom, chromatograms, scan list, MS level filter. There is no global singleton; the imguinz2 viewer owns its `AppState` instance inside `ViewerState`, and the legacy Win32 GUI passes `*AppState` explicitly to the helpers that need it.

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
| `raw_core/raw_file_reader.zig` | High-level RawFile opener (mmap, signature, controller, scan table) |
| `scan_decoder.zig` | Decode pipeline (header → dispatch → SIMD bounds) |
| `app_state.zig` | Viewer state: open file, current scan, zoom, chromatograms (no global singleton) |
| `core/progress.zig` | Type-erased progress `Reporter` for long-running exports |
| `export/raw_file_writer.zig` | .raw passthrough writer (scan table + packet re-encode, unknown regions verbatim; fast-path for known schemas, slow-path fallback) |
| `src/mzml/writer.zig` | Streaming mzML XML serializer (functional, verified on 275k-scan files) |
| `tools/check_checksum.zig` | Verify Adler32 checksum at offset 148 (Spectronaut compatibility) |
| `tools/dump_packet_header.zig` | Diagnostic: dump 32-byte packet header for a given scan |
| `tools/verify_profile.zig` | Profile encoder round-trip harness |
| `tools/verify_passthrough.zig` | Passthrough writer + verify-passthrough harness |
| `tools/passthrough.zig` | Passthrough writer (write-only, no verification) |
| `gui/` (main_window.zig, spectrum_canvas.zig, chromatogram_canvas.zig, scan_list.zig, file_dialog.zig) | Win32 GDI viewer (legacy fallback) |
| `viewer_zgui/` (main.zig, scan_list_panel.zig, spectrum_plot.zig, chromatogram_plot.zig, file_dialog.zig, cycle_navigation.zig, export_panel.zig) | imguinz2 viewer (current dev target) — see HANDOFF-imguinz2-real-data.md |
| `viewer/plot_math.zig` | Pure coordinate-mapping functions (shared by both viewers) |

## Ground Truth / Verification

- **ThermoRawFileParser** (.NET) is the reference implementation. Every decode output must match it.
- **No synthetic spectra, ever.** Tests, verifications, and ground-truth comparisons must use real Thermo `.raw` files. Synthetic input (hand-crafted mz/intensity arrays, fake packet headers, made-up scan tables) hides bugs because the synthetic structure is always simpler than reality. The Astral benchmark (8.6 GB, 275,462 scans) and the 12k-scan LC-MS/MS files in `D:/000projects/test_files/` are the canonical inputs. If a test needs a "spectrum", it must `RawFile.open()` one and decode it. There is no exception.
- Test files in `D:/000projects/test_files/` (12k-scan files, large Astral files).
- Architecture reports in `D:/tmp/mzigRead/`.
- Architecture decisions in `docs/adr/`.
- Decompiled Thermo DLLs and JSON mappings in `D:/000projects/thermo/` (FileIoStructs for binary layout reference).
- Legacy writer reference: `D:/000projects/mzigWrite/src/roundtrip_raw.zig` — passthrough mode copies profile packets verbatim and bulk-copies the packet region. Architectural inspiration for the fast path (see ADR-0002).
- The 8.6 GB Astral file (275,462 scans) parses in ~1s with 0 mismatches.
- Passthrough verification: re-read + compare all scans against original, open in Spectronaut.
- Checksum verification: `check-checksum` confirms the Adler32 at offset 148 matches a freshly-computed value. Spectronaut rejects files with stale checksums.

## Flagged Ambiguities

- "packet" vs "scan": a RAW file scan is stored as one or more packets. In this codebase, "scan" always means a row in the scan index; "packet" always means the binary record. Don't interchange them.
- "trailer" vs "ScanEvent": trailer labels (offset-based key-value) are one file structure; the ScanEvent table is a separate structure at file end. Both carry MS-level metadata.