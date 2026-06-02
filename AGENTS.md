# mzigRead

## Project Purpose
A high-performance Zig-based utility for reading Thermo Fisher RAW mass spectrometry files. Zero-copy, mmap-first, ground-truth-driven against ThermoRawFileParser (.NET).

## Project Context
- Focuses on efficient I/O and memory-mapped files for large files (10 GB+).
- Implements custom buffering and parsing logic for speed.
- Designed for systems programming tasks where performance is critical.
- **Domain model**: see `.pi/skills/improve-codebase-architecture/CONTEXT.md`
- **Architecture vocabulary**: see `.pi/skills/improve-codebase-architecture/LANGUAGE.md`

## Project Layout
```
src/
├── main.zig                        (viewer entry point)
├── app_state.zig                   (application state)
├── scan_decoder.zig                (C1: extracted decode pipeline)
├── raw_core/                       (file format parsing)
│   ├── advanced_packet.zig         (centroid decode, PacketHeader, PeakFeatures)
│   ├── raw_file.zig                (format constants, ScanIndexEntry, mmap readers)
│   ├── profile_packet.zig          (profile decode, frequency→m/z calibration)
│   ├── scan_event.zig              (ScanEvent struct, variable-length)
│   ├── trailer_events.zig          (TrailerScanEvents deduplication table)
│   └── raw_file_reader.zig
├── gui/                            (Win32 UI)
│   ├── main_window.zig
│   ├── spectrum_canvas.zig
│   ├── chromatogram_canvas.zig
│   └── scan_list.zig
├── tools/
│   ├── bench.zig                   (benchmark harness)
│   └── debug/                      (development utilities)
│       ├── debug_mass.zig
│       ├── debug_meta.zig
│       ├── debug_profile.zig
│       └── debug_scan_dump.zig
└── tests/
    ├── test_all.zig                (full test suite)
    ├── test_trailer_phase1.zig
    └── test_trailer_label.zig
```

## Reference Data
- **Test files**: `D:/000projects/test_files/` — 12k-scan LC-MS/MS files and large Orbitrap/Astral files
- **Architecture reports**: `D:/tmp/mzigRead/` — HTML architecture review reports (round 1 & round 2)

## Behavioral Governance
This project follows the **Karpathy-Inspired Behavioral Guidelines** established in the workspace root.
- Core principles: Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution.
- Refer to root `CLAUDE.md` for global constraints.

## Tech Stack
- Language: Zig 0.16
- Build System: `zig build`

## Key Conventions
- **"scan"** = a row in the scan index; **"packet"** = the binary record containing spectrum data. Do not interchange.
- **"trailer"** = offset-based key-value pairs per scan; **"ScanEvent"** = the per-scan event table at file end. Different structures.
- Ground truth: decode output must match ThermoRawFileParser (.NET) for the same scan.