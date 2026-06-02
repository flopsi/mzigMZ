# mzigRead — Completion Gap Analysis

> **Date:** 2026-05-23
> **Scope:** mzigRead vs. Thermo Fisher CommonCore `RawFileReader` and `Data` DLLs
> **JSON sources:**
> - `F:/kimi_code/src/canddotnet/DLL_Reader/thermo/json/ThermoFisher.CommonCore.RawFileReader.json`
> - `F:/kimi_code/src/canddotnet/DLL_Reader/thermo/json/ThermoFisher.CommonCore.Data.json`

---

## 1. Executive Summary

mzigRead is a **focused, high-performance reader for modern Thermo RAW files (file revision ≥ 65)**. It successfully implements the "hot path" for Orbitrap / FT-ICR data but has significant gaps in legacy support, auxiliary packet types, instrument logs, and higher-level business-object abstractions.

| Area | Verdict |
|------|---------|
| Low-level RAW I/O (indices, headers, FT packets) | ✅ Production-ready |
| Legacy file support (rev < 65) | ❌ Explicitly rejected |
| Linear Trap / compressed / non-MS packets | ❌ Missing |
| Instrument logs (status, error, tune, method) | ❌ Missing |
| Typed FilterEnums / ScanStatistics / IRawData facade | ❌ Missing |

---

## 2. RawFileReader.dll — What Is Implemented

### 2.1 Core Reader (`mzigRead/src/raw_core/`)

| Component | Files | Status |
|-----------|-------|--------|
| File header + RAW info block | `raw_file.zig` | ✅ Partial (revision + creation time only) |
| Controller table + RunHeader offsets | `raw_file.zig` | ✅ Partial (key offsets only) |
| Scan index parsing (72/80/88 bytes) | `raw_file.zig` | ✅ All variants |
| ScanEventInfo parsing (24–136 bytes) | `scan_event.zig` | ✅ All variants |
| Reaction parsing (24/32/56 bytes) | `raw_file.zig` | ✅ All variants |
| InstrumentId parsing | `raw_file.zig` | ✅ Model, Serial, SW version |
| FT Profile decoding | `profile_packet.zig` | ✅ Segments, subsegments, calibrators |
| FT Centroid decoding | `advanced_packet.zig` | ✅ Accurate-mass + standard-mass |
| NoiseInfoPacket + expansion words | `advanced_packet.zig` | ✅ Resolution, SNR |
| Trailer event parsing | `trailer_events.zig` | ✅ Deduplication, filter string, charge |
| TIC/BPC chromatograms | `chromatogram.zig` | ✅ From scan-index metadata |

### 2.2 App State + GUI (`mzigRead/src/app_state.zig`, `src/gui/`)

| Feature | Status |
|---------|--------|
| Memory-mapped file open | ✅ |
| Scan list browsing | ✅ |
| Individual scan load (`loadScan`) | ✅ |
| Bulk scan load (`loadScanBulk`, `loadScanArena`) | ✅ |
| Spectrum display (centroid + profile) | ✅ |
| Chromatogram display | ✅ |
| Win32 GUI | ✅ |

---

## 3. RawFileReader.dll — Critical Gaps

### 3.1 Legacy & Auxiliary Packet Types

| Packet / Struct | Type ID | Status | Notes |
|-----------------|---------|--------|-------|
| `LinearTrapCentroidPacket` | 18 | ❌ Missing | Constant exists, no decoder |
| `LinearTrapProfilePacket` | 19 | ❌ Missing | Constant exists, no decoder |
| `StandardAccuracyPacket` | 5 | ❌ Missing | Old Orbitrap standard accuracy |
| `LowResSpDataPkt` / variants | 1, 15, 17, 24 | ❌ Missing | Low-resolution spectra |
| `HighResSpDataPkt` | 2 | ❌ Missing | High-resolution spectra (non-FT) |
| `ProfSpPkt` / `ProfSpPkt2` / `ProfSpPkt3` | 14, 16 | ❌ Missing | Older profile formats |
| `CompressedProfile` | 22, 23 | ❌ Missing | High/low res compressed |
| `ChannelUvPacket` / `MsAnalogPacket` | 12, 13 | ❌ Missing | Non-MS data |
| `AdjustableScanRateProfilePacket` | — | ❌ Missing | ASR packets |

### 3.2 File I/O Structs Not Parsed

| Struct | Status | Impact |
|--------|--------|--------|
| `FileHeaderStruct` (full 1356 bytes) | ⚠️ Partial | Only revision + FILETIME read |
| `RawFileInfoStruct` (full) | ⚠️ Partial | Only controller count/table |
| `RunHeaderStruct` (full 7576 bytes) | ⚠️ Partial | Only key offsets |
| `FilterInfoStruct` (all 10 versions) | ❌ Missing | Authoritative filter metadata |
| `MethodInfoStruct` | ❌ Missing | Method data |
| `UserIdStampStruct` | ❌ Missing | User info |
| `VirtualControllerInfoStruct` | ❌ Missing | Controller metadata |
| `HighMassAccuracyCentroidStruct` | ❌ Missing | 12-byte centroid struct |
| `ProfileDataPacket63` / `64` | ❌ Missing | Legacy profile packets |
| `OldLCQ` structs (59 total) | ❌ Missing | LCQ-era files unreadable |

### 3.3 Instrument Logs & Metadata

| Feature | Status |
|---------|--------|
| `StatusLog` parser | ❌ Missing |
| `ErrorLog` parser | ❌ Missing |
| `TuneData` parser | ❌ Missing |
| `InstrumentMethodFileReader` | ❌ Missing |
| `SequenceFileReader` | ❌ Missing |
| `Adler32` checksum validation | ❌ Missing |

### 3.4 Trailer Label Parsing

| Label | Meaning | Status |
|-------|---------|--------|
| 9 | Filter string | ✅ Parsed |
| 18 | Charge state | ✅ Parsed |
| All other labels | Scan event, data size, wavelength, CV, etc. | ❌ Ignored |

### 3.5 Enums & Constants

| DLL Enum | Zig Status |
|----------|------------|
| `SpectrumPacketType` | ⚠️ Raw `u32` constants only |
| `ScanFilterEnums` (`ActivationType`, `MassAnalyzerType`, etc.) | ⚠️ Raw `u8` fields only |
| `VirtualDeviceTypes` | ⚠️ Only `VIRTUAL_DEVICE_MS = 0` |
| `OldLcqEnums` | ❌ Missing |
| `RawFileConstants` | ❌ Missing |

---

## 4. CommonCore.Data.dll — Gaps Relevant to mzigRead

### 4.1 Missing Business Objects

| DLL Type | Status | Impact |
|----------|--------|--------|
| `ScanStatistics` | ⚠️ Partial | `ScanInfo` missing `MassResolution`, `ScanType`, `HasCentroidStream`, `HasNoiseTable` |
| `CentroidStream` | ⚠️ Partial | No formal type; `Spectrum` + `PeakFeatures` is ad-hoc |
| `SegmentedScan` | ❌ Missing | Profile data decoded flat; no segment structure |
| `LabelPeak` | ❌ Missing | No labeled-peak struct |
| `FileHeader` (business object) | ❌ Missing | Only offset 40 read ad-hoc |
| `RunHeader` (business object) | ⚠️ Partial | Only offsets/constants |
| `SampleInformation` | ❌ Missing | Sequence row mostly skipped |

### 4.2 Missing Typed Enums

| DLL Enum | Current Zig | Needed |
|----------|-------------|--------|
| `MassAnalyzerType` | `mass_analyzer_type: u8` | `enum(u8) { ITMS, FTMS, ... }` |
| `PolarityType` | `polarity: u8` | `enum(u8) { Positive, Negative, ... }` |
| `ScanDataType` | inferred heuristically | `enum(u8) { Centroid, Profile, ... }` |
| `ActivationType` | string-parsed from filter | `enum(u8) { CID, HCD, ETD, ECD, ... }` |
| `MSOrderType` | `ms_order: i8` | `enum(i8) { MS1 = 1, MS2 = 2, ... }` |
| `DetectorType` | `detector: u8` | `enum(u8) { ... }` |
| `IonizationModeType` | `ionization_mode: u8` | `enum(u8) { ... }` |
| `TriState` | ❌ Missing | `enum(u8) { True, False, Unknown }` |

### 4.3 Missing Interfaces

| Interface | Status |
|-----------|--------|
| `IRawData` / `IRawDataPlus` | ❌ No facade |
| `IScanFilter` | ❌ No filter builder/tester |
| `IScanEventExtended` | ❌ Missing |
| `IChromatogramRequest` | ❌ Missing |

---

## 5. Recommendations

### P0 — Immediate (This Week)

1. **Lift `file_revision < 65` gate** — struct-size constants already exist; test with older files.
2. **Add typed `FilterEnums`** — replace raw `u8` fields with proper Zig enums.
3. **Implement `LinearTrapCentroidPacket` decoder** — constant exists, decoder missing.

### P1 — Short-Term (2–4 Weeks)

1. Implement `LinearTrapProfilePacket` and `StandardAccuracyPacket` decoders.
2. Parse full `FileHeaderStruct` (1356 bytes) and `RunHeaderStruct` (7576 bytes).
3. Create formal `ScanStatistics`, `CentroidStream`, and `LabelPeak` structs.
4. Implement full trailer label parser (all known labels, not just 9 and 18).
5. Parse `FilterInfoStruct` (all versions) for authoritative metadata.

### P2 — Medium-Term (1–3 Months)

1. Add `SegmentedScan` support for legacy ion-trap data.
2. Implement XIC/SIC chromatogram generation.
3. Create `IRawData`-style facade decoupling byte parsing from business logic.
4. Parse `StatusLog`, `ErrorLog`, `TuneData`.

### P3 — Long-Term

1. UV / PDA / Analog packet decoders.
2. Compressed profile decoders.
3. Adler32 checksum validation.
4. Old LCQ layer (59 structs).

---

## 6. Verification

All claims derived from:
- `F:/kimi_code/src/canddotnet/DLL_Reader/thermo/json/ThermoFisher.CommonCore.RawFileReader.json`
- `F:/kimi_code/src/canddotnet/DLL_Reader/thermo/json/ThermoFisher.CommonCore.Data.json`
- `F:/kimi_code/src/zigging/mzigRead/src/raw_core/*.zig`
- `F:/kimi_code/src/zigging/mzigRead/src/app_state.zig`
- `F:/kimi_code/src/zigging/mzigRead/src/gui/*.zig`
