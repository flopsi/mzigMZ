# mzigRead

## THE VISION
A **Thermo Orbitrap Astral Zoom DIA data-analysis software for proteomics and
metabolomics/lipidomics** — built on a Zig foundation that is dramatically faster
than every existing reader (measured ~1700× faster loading, ~500× faster writing
vs. Thermo native readers, OpenMS, fisher-py, et al.). mzigRead is the foundation
layer of that software: the world's fastest correct `.raw` reader/writer.

## THE DREAM
An **all-in-one MS data-analysis platform** spanning the full workflow:
1. **Theoretical work** — KMD / mass-defect analysis, in-silico digestion, de-novo
   sequencing research (the KMD dashboard).
2. **Raw-file analysis** — read, decode, and visualize real Astral Zoom `.raw`
   (10 GB+, multi-file experiments). *← current focus.*
3. **Export** — `.raw` → mzML, mzPeak, and a Zig-native format (**mzigml**).
4. **Visualization & statistics** — interactive plots of real data, plus import of
   Spectronaut and DIA-NN results for downstream analysis.

A 20-year vision in the field, now buildable with agentic coding. The layered
stack: **Reader (mzigRead)** → **Compute (spectrum_utils)** → **Analysis (KMD /
de-novo)** → **App (msViewer: Zig + Clay + sokol_gfx, native + WASM)**.

> **North-star rule:** every decision in this project is checked against the
> Vision and the Dream. If a change does not move us toward (or protect) them,
> question it. Keep the wedge small, but keep the direction true.

## Project Purpose
A high-performance Zig-based (v0.16) utility for reading and writing Thermo Fisher RAW mass spectrometry files, plus export to standard formats (mzML). Zero-copy, mmap-first reader; ground-truth-driven against ThermoRawFileParser (.NET). De-novo .raw writer with centroid encoding, backpatching, and checksum computation.

## Project Context
- Focuses on efficient I/O and memory-mapped files for large files (10 GB+).
- Implements custom buffering and parsing logic for speed.
- Designed for systems programming tasks where performance is critical.
- **Domain model**: see `CONTEXT.md` (this directory)
- **Architecture vocabulary**: see `D:/tmp/mzigRead/LANGUAGE.md`

## Behavioral Governance
Never assume or guess bindings for APIs.
Always read APIs first and then code.
Do not progress with "I think I understand,...", "I think I got...".
Slow down, read the code, read all the documents and APIs, then create a plan with a clear success criteria. Only then code. 

## Project Layout
```
src/
├── main.zig                        (entry point — Win32 GDI viewer (legacy fallback))
├── app_state.zig                   (application state)
├── file_state.zig                  (loaded-file state)
├── view_state.zig                  (view/selection state)
├── scan_decoder.zig                (C1: extracted decode pipeline)
├── build_timestamp.zig             (generated build stamp)
├── raw_core/                       (file format parsing + writer support)
│   ├── advanced_packet.zig         (centroid decode, PacketHeader, PeakFeatures)
│   ├── raw_file.zig                (format constants, ScanIndexEntry, ScanEventInfo, Reaction)
│   ├── raw_file_reader.zig
│   ├── profile_packet.zig          (profile decode, frequency→m/z calibration)
│   ├── scan_event.zig              (ScanEvent struct, variable-length)
│   ├── trailer_events.zig          (TrailerScanEvents deduplication table)
│   ├── checksum.zig                (Adler32 checksum for Spectronaut compatibility)
│   ├── schema.zig                  (known-layout detection — fast/slow path, ADR-0002)
│   ├── spectrum_pool.zig           (pooled Spectrum allocation)
│   ├── unicode_utils.zig            (UTF-16LE → UTF-8 conversion)
│   ├── filter_string.zig            (filter string parsing algorithms)
│   ├── writer_primitives.zig       (u16/u32/u64/f64 positional I/O helpers)
├── spec/                           (declarative binary-layout specs — ADR-0003)
│   ├── file_header.zig
│   ├── run_header.zig
│   ├── raw_info.zig
│   ├── scan_event_info.zig
│   ├── reaction.zig
│   ├── instrument_id.zig
│   ├── packet_header.zig
│   ├── filter_string.zig            (filter string grammar — activation types, MS levels)
│   └── scan_index.zig
├── core/                           (unified intermediate representation + shared helpers)
│   ├── types.zig                   (MsRun, Scan, Precursor, CVParam — format-agnostic)
│   ├── converter.zig               (AppState → MsRun bridge)
│   ├── instrument_utils.zig        (mass analyzer inference from filter strings + packet types)
│   └── progress.zig                (type-erased progress Reporter for long-running exports)
├── export/                         (format writers — shared Spectrum input)
│   └── raw_file_writer.zig         (.raw passthrough + modified export)
├── mzml/                           (mzML format export)
│   ├── types.zig                   (mzML-specific Spectrum, RunInfo, InstrumentConfiguration)
│   ├── cv.zig                      (PSI-MS controlled vocabulary, comptime lookup)
│   ├── base64.zig                  (base64 encode/decode, little-endian mzML compliance)
│   ├── numpress.zig                (MS-Numpress linear/PIC/SLOF compression)
│   ├── writer.zig                  (streaming XML serializer, indexed mzML)
│   └── streaming_convert.zig       (end-to-end .raw → mzML streaming converter)
├── raw_writer/                     (de-novo .raw file creation)
│   └── writer.zig                  (RawFileWriter state machine: init → addScan → finalize)
├── gui/                            (Win32 GDI viewer — retained, not active dev target)
│   ├── main_window.zig            (top-level window + message loop)
│   ├── spectrum_canvas.zig        (spectrum GDI rendering)
│   ├── chromatogram_canvas.zig    (TIC/BPC GDI rendering)
│   ├── scan_list.zig              (scan listbox)
│   ├── file_dialog.zig            (GetOpenFileName wrapper)
│   └── win32_common.zig           (Win32 API helpers)
├── viewer/                         (pure-logic modules used by GUI — no Win32 dep)
│   └── plot_math.zig               (coordinate mapping, ZoomState — pure)
├── viewer_zgui/                    (imguinz2 viewer — current dev target, NOT consumed by msViewer)
│   ├── main.zig                    (entry, layout, menu, status bar, file dialog wiring; owns ViewerState)
│   ├── scan_list_panel.zig         (ImGui table over file_state.ScanInfo)
│   ├── spectrum_plot.zig           (ImPlot wrapper for *advanced.Spectrum, owns f64 mirror + State)
│   ├── chromatogram_plot.zig       (ImPlot wrapper for *Chromatogram, supports TIC and BPC + State)
│   ├── file_dialog.zig             (Win32 GetOpenFileNameW wrapper)
│   ├── cycle_navigation.zig        (MS1/MS2 parent/child navigation helpers)
│   └── export_panel.zig            (export progress modal + async worker)
├── tools/                          (build tools and diagnostics)
│   ├── bench.zig                   (benchmark harness)
│   ├── passthrough.zig             (write-only passthrough)
│   ├── verify_passthrough.zig      (passthrough + verify)
│   ├── verify_encode.zig           (centroid encoder round-trip)
│   ├── verify_profile.zig          (profile encoder round-trip)
│   ├── check_checksum.zig          (verify Adler32 at offset 148)
│   ├── dump_packet_header.zig      (diagnostic: 32-byte header dump)
│   ├── generate_ground_truth.zig   (emit ground-truth fixtures)
│   ├── sample_ground_truth.zig     (sample scans for ground truth)
│   ├── verify_ground_truth.zig     (compare decode vs ground truth)
│   ├── cli_args.zig                (shared CLI argv parsing)
│   ├── convert_to_mzml.zig          (.raw → mzML streaming converter CLI)
│   └── debug/                      (development utilities)
│       ├── debug_mass.zig
│       ├── debug_meta.zig
│       ├── debug_profile.zig
│       └── debug_scan_dump.zig
└── tests/                          (integration test executables)
    ├── test_trailer_phase1.zig
    ├── test_schema.zig             (schema detection on real .raw files)
    └── test_spectrumref_format.zig  (GOTCHAS.md G3 regression: spectrumRef cross-reference)

tests/                              (repo-root integration harness)
├── all.zig                         (aggregates inline tests across modules)
├── TEST_PLAN.md
└── ground_truth/                   (ground-truth fixtures)
```

> NOTE: The legacy Win32 GDI viewer (`src/gui/`) is retained as a fallback.
A separate GPU-based viewer (Clay layout + sokol_gfx rendering, native + WASM)
is planned in the sibling repo `D:/000projects/msViewer/`. The pure-logic
`src/viewer/` modules are the intended migration seam. The in-tree imguinz2
viewer (`src/viewer_zgui/`) is an **interim** target — verified end-to-end with
real data 2026-06-12 — that exercises the data layer (AppState, FileState,
ScanDecoder) before the sibling repo's GPU viewer is built on top of it. See
`D:/tmp/mzigRead/HANDOFF-imguinz2-real-data.md` for status.

## Project Root Hygiene

**The project root is for source code, build files, and config only.**
Never create documentation, planning, analysis, checklists, gotchas, language
references, handoff docs, PRDs, validation reports, screenshots, archives, or
any other working files in the project root. All of these go in
`D:/tmp/mzigRead/`. The only markdown files allowed in the root are
`AGENTS.md` and `CONTEXT.md` (project context).

This keeps the root navigable, reduces pre-loaded context tokens, and prevents
stale planning docs from being mistaken for active project context.
- **Test files**: `D:/000projects/test_files/` — 12k-scan LC-MS/MS files and large Orbitrap/Astral files
- **Architecture reports**: `D:/tmp/mzigRead/` — HTML architecture review reports (round 1 & round 2)
- **Architecture decisions**: `D:/tmp/mzigRead/docs/adr/` — ADRs for hard-to-reverse design choices
  - `0001-byte-identical-passthrough.md` — pure passthrough: copy unknown regions verbatim
  - `0001-explicit-setup-pointer-only-for-hard-dependencies.md`
  - `0002-schema-based-fast-path.md` — fast-path/slow-path for known vs unknown file layouts
  - `0003-declarative-structural-spec.md` — declarative `src/spec/` binary-layout specs
  - `0004-pivot-to-gdi-viewer.md` — Win32 GDI viewer as active front-end (superseded)
- **Planning & analysis**: `D:/tmp/mzigRead/` — CHECKLIST.md, GOTCHAS.md, LANGUAGE.md, REFACTOR_PLAN.md, handoff docs, PRDs, validation reports
- **Decompiled reference**: `D:/000projects/thermo/` — Thermo DLLs (FileIoStructs for binary layout)


## Tech Stack
- Language: Zig 0.16
- Build System: `zig build`
- Zig standard library `D:\000projects\mzigRead\.pi\skills\zig-quality\sources\std`
- imguinz2 (vendored) — GLFW + OpenGL3 + ImGui + ImPlot via `dear_bindings` (dcimgui). The imguinz2 vendor path is `D:\000projects\mzigRead\zig-pkg\imguinz2-...\` and is **invoked** by `zig build run-zgui`. It is **not** a published module; the imguinz2 viewer (`src/viewer_zgui/`) is an in-tree dev target and is **not** consumed by msViewer (msViewer uses its own GPU stack).
- **Two viewers, one data layer:**
  - `raw-orbitrap-viewer` (Win32 GDI, legacy/positive control) — `zig build run`
  - `raw-zgui-viewer` (imguinz2/GLFW+OpenGL3, current dev target) — `zig build run-zgui`

## Published modules (msViewer link) — DO NOT BREAK

> **Note (2026-06-14):** The sibling `msViewer` repo is considered **legacy**
> and will be decoupled/replaced. The modules below remain published in
> `build.zig` so any future consumer can use them, but active development of the
> imguinz2 viewer now lives in-tree in `src/viewer_zgui/`.

The sibling repo `D:/000projects/msViewer/` consumes this reader as a
`build.zig.zon` **path dependency** (single source of truth — no copied files).
That link works ONLY because `build.zig` publishes these modules via
`b.addModule(...)`:

| Published module | Source file | Why msViewer needs it |
|------------------|-------------|-----------------------|
| `raw_file`  | `src/raw_core/raw_file.zig` | mmap reader, `ScanIndexEntry` (tic/base_peak/rt), `ScanEvent` (ms_order), `ScanEventInfo`, `Reaction`. Transitively pulls the `spec/*` layer. |
| `plot_math` | `src/viewer/plot_math.zig`  | pure coordinate mapping / `ZoomState` for plots (no Win32 dep). |
| `scan_decoder` | `src/scan_decoder.zig` | spectrum packet decoder — msViewer uses it to decode and plot the selected scan (Issue 17). Pulls `advanced_packet` + `profile_packet` + `trailer_events` + `spectrum_pool`. |

**Breakage rule:** Never downgrade these three from `b.addModule` back to
`b.createModule`, never rename the published names (`"raw_file"`, `"plot_math"`),
and never move the source files without updating msViewer's `build.zig`. A path
dependency can only see modules published with `addModule`; a private
`createModule` is invisible across repos and breaks msViewer **silently** (it
still builds here). The `build.zig` call sites carry matching
`PUBLISHED MODULE — DO NOT downgrade` comments. If you add new reader
capabilities msViewer needs, publish them the same way and add a row here.

## Key Conventions

> **Before reading further, see [`D:/tmp/mzigRead/GOTCHAS.md`](D:/tmp/mzigRead/GOTCHAS.md)** for a catalog of
> known traps, footguns, and silent-failure modes across the codebase.
> Each gotcha cites a file:line. New gotchas should be added there, not here.
> The most critical: G2 (Numpress PIC sign loss), G3 (spectrumRef format
> mismatch), G4 (trailer_offset duality), G7 (DecodeResult borrow lifetime),
> G18 (encoder default flags inference).
>
> For the **action list** (what to fix next, in priority order, with
> verification criteria for each item), see [`D:/tmp/mzigRead/CHECKLIST.md`](D:/tmp/mzigRead/CHECKLIST.md).

- **Tests follow zig best practices**: put tests next to the code whenever possible. minimize number of external files for testing. 
- **No synthetic data.** Tests, verifications, and ground-truth comparisons must use real Thermo `.raw` files. Synthetic input (hand-crafted mz/intensity arrays, fake packet headers, made-up scan tables) hides bugs because the synthetic structure is always simpler than reality. Use the test files in `D:/000projects/test_files/` (12k-scan LC-MS/MS, 8.6 GB Astral) for all verification. The `verify-encode`, `verify-profile`, `verify-passthrough`, and `check-checksum` tools are the canonical tests; they read real bytes and compare against real ground truth.
- **"scan"** = a row in the scan index; **"packet"** = the binary record containing spectrum data. Do not interchange.
- **"trailer"** = offset-based key-value pairs per scan; **"ScanEvent"** = the per-scan event table at file end. Different structures.
- **"schema"** = a known `.raw` file layout (file revision + scan index size + packet header layout + checksum formula). Files matching a known schema can use the fast-path passthrough; others fall back to the slow path. See ADR-0002.
- **Supported `.raw` revisions:** The reader accepts files with `file_revision >= 65`. Fast-path schema detection is active for revisions **65–66**; newer revisions fall back to the slow decode+encode path. Legacy revisions `< 65` are rejected at open time. See `docs/raw-version-mapping.md` for the full revision support table.
- **"fast path"** = bulk `writeAll` of the pre-scan-table, packet, and trailer regions for known-schema files. 5–20× faster than per-scan decode+encode.
- **"slow path"** = per-scan decode+encode for unknown-schema files. Correct but slow.
- Ground truth: decode output must match ThermoRawFileParser (.NET) for the same scan.
- **CLI arg parsing:** Command-line *tools* and the imguinz2 viewer (`src/viewer_zgui/main.zig`) should use `src/tools/cli_args.zig` (`cli.getArgs`) rather than raw `GetCommandLineW` boilerplate. Note: the legacy Win32 GDI viewer (`raw-orbitrap-viewer`) is the exception — it uses the Win32 entry path.
- **"MsRun"** = unified intermediate representation (IR) in `src/core/types.zig`. Format-agnostic bridge between the .raw reader and all format writers (mzML, mzigml, mzPeak). Uses SoA (Structure of Arrays) for peak data: mz[] and intensity[] as separate slices.
- **"streaming convert"** = the fast path for .raw → mzML. Reads one scan at a time via `loadScanBulk`, accesses decoded data via `decoder.mzBuffer()/intensityBuffer()`, writes XML directly to a buffered file writer. No intermediate MsRun or AoS conversion. Memory proportional to output buffer size (48KB flush threshold).
- **"raw passthrough"** = copy a .raw file with packet re-encoding (byte-identical for known schemas via ADR-0002 fast path). Distinct from "raw writer" which creates a new .raw from scratch.
- **"raw writer"** = de-novo .raw file creation (`src/raw_writer/writer.zig`). Centroid-only, rev 66. Writes FileHeader, SequenceRow, AutoSamplerConfig, RawFileInfo, RunHeader placeholders; encodes scans as FT_CENTROID packets; accumulates scan index + trailer events; backpatches RunHeader on finalize; computes Adler32 checksum post-finalize.
- **Quality gates satisfied** — public API uses `snake_case`, declares named error sets, uses `std.math.cast` for file-derived casts, and uses `std.math.add`/`std.math.mul` for file-derived offset/size arithmetic.
- **mzML spectrum ID format**: `controllerType=0 controllerNumber=1 scan=N` — matches ThermoRawFileParser output for cross-tool compatibility.
- **Pool-steal optimization**: decoded data lives in `SpectrumPool` grow-only buffers. The `cacheSpectrumSteal` path transfers ownership from pool to spectrum cache without copying — eliminates per-scan `@memcpy`/`dupe`. The `currentSpectrum()` getter returns a reference to the cached (stolen) entry.

## Test-First Discipline

This project uses **vertical-slice TDD** — one test → one implementation → repeat:

```
RED:   Write ONE test for the next behavior → test fails
GREEN: Write minimal code to pass → test passes
```

**Rules:**
- One test at a time. Never write all tests first, then all code.
- **No synthetic data.** Every test that needs a spectrum must open a real `.raw` file from `D:/000projects/test_files/` and decode it. Synthetic input hides bugs.
- Write the regression test **before** the fix. Watch it fail, then make it pass.
- Run the full test suite after each cycle, not just the new test.

## Post-Session mzML Regression Check

**After every major session, a comparison against the canonical mzML reference outputs in `D:\000projects\thermo\raw_parsed\` is MANDATORY.** These references are produced independently from the Thermo/RawFileReader stack and are the ground truth for `.raw` → mzML correctness.

### Reference files

| Source `.raw` | Reference mzML |
|---------------|----------------|
| `D:\000projects\test_files\20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw` | `D:\000projects\thermo\raw_parsed\20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.mzML` |
| `D:\000projects\test_files\29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.raw` | `D:\000projects\thermo\raw_parsed\29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.mzML` |

### Required steps

1. Regenerate mzML with the current build:
   ```bash
   zig build convert-to-mzml -- D:/000projects/test_files/20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw D:/tmp/mzigread_session_20240428.mzML
   zig build convert-to-mzml -- D:/000projects/test_files/29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.raw D:/tmp/mzigread_session_29082025.mzML
   ```
2. Compare each generated file against its reference in `D:\000projects\thermo\raw_parsed\`.
3. Investigate and resolve any differences. Acceptable differences must be explicitly documented in the session notes; unexplained differences are regressions and must be fixed before the session is considered complete.
4. If the reference files themselves are updated, document the reason and the new checksum in the session notes.

### Why this is mandatory

`zig build test` and `zig build test-integration` validate internal consistency and cross-references, but they do not prove that the exported mzML bytes match the Thermo reference. This comparison is the final correctness gate for any change that touches the reader, decoder, or mzML writer.

## Filter String Handling

The Thermo **filter string** (e.g. `FTMS + p NSI Full ms [350.0000-1800.0000]`,
`ITMS + c NSI d Full ms2 538.2920@hcd27.00 [90.0000-1110.0000]`) is not a
cosmetic label. It is the canonical source for:

- MS level (`Full ms`, `ms2`, `ms3`, ...)
- Mass analyzer (`FTMS`, `ITMS`, `ASTMS`, ...)
- Activation type (`hcd`, `cid`, `etd`, `ecd`, ...)
- Source ionization mode (`NSI`, `cNSI`, `ESI`, `APCI`, ...)
- Scan event geometry (isolation m/z, normalized collision energy, scan range)

Downstream search engines and quant tools (DIA-NN, Spectronaut, OpenMS, MSGF+)
parse this string, so it must be present and correct in mzML exports.

### Where the string comes from

The string is built from the per-scan `ScanEvent` table
(`src/raw_core/scan_event.zig`) and stored on
`file_state.ScanInfo.filter_string` when a file is loaded
(`src/file_state.zig`). It is then carried through the core IR
(`src/core/converter.zig` → `core.Scan.filter_string`) and emitted by both
mzML writers:

- Non-streaming: `src/mzml/writer.zig` writes `MS:1000512 filter string`.
- Streaming: `src/mzml/streaming_convert.zig` already consumed the string for
  analyzer/activation/source inference; the fix was to actually populate and
  forward it.

### Why it was missing

`streaming_convert.zig` had all the parser logic (analyzer from `FTMS`/`ASTMS`,
activation from `@hcd`/`@cid`, source from `NSI`/`cNSI`/`ESI`), but
`ScanInfo.filter_string` was never populated, so every inference silently fell
back to defaults. The non-streaming writer never emitted the cvParam at all.

### Ionization mode completeness

Thermo's `ScanEventInfo.ionization_mode` enum is larger than the original
mapping. The full set used by the builder is:

| Value | Mode |
|------:|------|
| 0 | EI |
| 1 | CI |
| 2 | FAB |
| 3 | ESI |
| 4 | APCI |
| 5 | NSI |
| 6 | TSP |
| 7 | FD |
| 8 | MALDI |
| 9 | GD |
| 10 | (empty) |
| 11 | PSI |
| 12 | cNSI |
| 13 | IM1 |
| 14 | IM2 |

`cNSI` (value 12) in particular appears on newer nano-spray sources and was
missing from the original mapping; this produced incorrect
`MS:1000073 ESI`/`MS:1000075 MALDI` source CV params for those files.

### GUI status

- Legacy Win32 GDI viewer (`src/gui/spectrum_canvas.zig`) already displays
  `filter_string` if populated.
- imguinz2 viewer (`src/viewer_zgui/`) does not display it yet; that is a
  pending UI task.

### Verification

Filter-string correctness is proven by the Post-Session mzML Regression Check
against `D:\000projects\thermo\raw_parsed\`. Specifically:

- Small file (`20240428_MP1_50SPD_IO25_LFQ_10pg_Y05-E45_01.raw`, 12,333
  scans): every spectrum ID, MS level, precursor `spectrumRef`, filter string,
  and 10 random scan m/z-intensity arrays match the ThermoRawFileParser
  reference.
- Large file (`29082025_AMP5_CF_HT_100ng_60SPD_2Th_3ms__AGC500_2.raw`,
  275,445 scans): spot-checked random scans match reference arrays and filter
  strings, including `cNSI` events.

## Zig 0.16 Quick Sanity Check

If you see any of these in new code, it's pre-0.16 drift — stop and fix:

```
ArrayList(...).init(          → .empty + .deinit(gpa) + .append(gpa, v)
GeneralPurposeAllocator       → std.heap.DebugAllocator(.{}) = .init
std.fs.cwd()                  → std.Io.Dir.cwd(io)
std.fs.File                   → std.Io.File
std.posix.getenv              → init.minimal.env
std.process.argsAlloc         → init.minimal.args
std.os.environ                → init.minimal.env
std.Thread.Pool               → std.Io.async
@Type(.{                      → @Struct, @Int, @Enum, @Fn, @Tuple, @Pointer, @Union
root_source_file              → module API in build.zig
```

Full 0.16 idioms in `.pi/skills/zig-quality/references/0.16-idioms.md`.
