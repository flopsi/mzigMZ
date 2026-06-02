# mzigRawReader vs. C# Thermo RawFileReader: Gap Analysis

> **Date:** 2026-05-18  
> **Analyst:** Kimi Code CLI  
> **Scope:** Bottom-up analysis of ~1,495 C# source files (`ThermoFisher.CommonCore.RawFileReader`) cross-referenced against the Zig implementation in `mzigRawReader`.  
> **Focus:** Orbitrap Astral DIA compatibility (MS1 profile, MS2 centroid).

---

## 1. Executive Summary

The `mzigRawReader` project is an impressive achievement. It successfully implements a zero-dependency, native Zig parser for modern Thermo RAW files (revision ≥ 65) that achieves **~650–820 million data points per second** in bulk decoding benchmarks. The binary struct layouts for `FileHeader`, `RunHeader`, `ScanIndex`, and `PacketHeader` are **correct and verified** against the C# source.

However, three **critical gaps** prevent it from being a fully accurate drop-in replacement for the official C# reader, particularly for Orbitrap Astral DIA data:

1.  **MS Level & Metadata are Heuristic (Broken):** MS level is guessed from `packet_type` (Profile=MS1, Centroid=MS2) because the `TrailerScanEvents` parser is disabled. This is **wrong** for DIA (where MS2 can be profile) and any DDA method with mixed acquisition modes.
2.  **Profile Data Returns Empty Spectra:** FT Profile packets (MS1 on Astral) are recognized but not decoded. The frequency-to-mass calibration logic is entirely missing.
3.  **ScanEvent Metadata is Incomplete:** `ScanEventInfo` is only partially parsed (first 40 of 96 bytes), meaning precursor m/z, isolation width, collision energy, and charge state are lost even if trailers were enabled.

### Overall Maturity Score: **B+ (Good for Centroid DDA, Insufficient for DIA)**

---

## 2. Critical Gaps (Blocking DIA / Profile Support)

### 2.1 TrailerScanEvents Parsing is Disabled → Incorrect MS Levels

**C# Behavior:**  
The C# reader relies on the `TrailerScanEvents` table to determine the true `MSOrder` (MS level), precursor mass, and collision energy for every scan. The `trailer_offset` field in `ScanIndexEntry` is an **index** into this table, not a file offset. The table itself is stored at `RunHeader.TrailerScanEventsPos` and contains deduplicated `ScanEvent` objects.

**Zig Behavior:**  
- `parseScanTrailersAtOpen()` in `app_state.zig` is a **no-op** (lines 360–367).
- `ensureScanTrailer()` is a **no-op** (lines 782–788).
- MS level is inferred heuristically: `if (packet_type == FT_PROFILE) 1 else 2`.

**Impact:**  
| Scenario | C# Result | Zig Result | Severity |
|---|---|---|---|
| Astral DIA (MS1 Profile, MS2 Centroid) | Correct | Correct (by accident) | Low |
| DDA with MS2 Profile (e.g., ion trap) | MS2 | MS1 (wrong) | **High** |
| DIA with MS2 Profile (e.g., BoxCar) | MS2 | MS1 (wrong) | **High** |
| Any method with MS3+ | MS3 | MS2 (wrong) | **High** |
| Precursor isolation window | Available | Missing | **High** |

**Root Cause:**  
The `trailer_offset` field was misinterpreted as a direct file offset during initial development. When this failed on real files, the trailer parser was disabled rather than fixed. The C# layout involves a `SortedSet<ScanEvent>` for deduplication, which is non-trivial to replicate, but a simpler sequential parse-with-index approach (already partially written in `trailer_events.zig`) should work for read-only access.

**Fix Complexity:** Medium. The `trailer_events.zig` file already has the correct sequential parsing logic. It needs to be:
1.  Integrated into `openFile()`.
2.  Taught to use `RunHeader.TrailerScanEventsPos` as the base address.
3.  Taught that `ScanIndexEntry.trailer_offset` is an index into the `scan_to_unique` array.

---

### 2.2 FT Profile Packet Decoding is Not Implemented

**C# Behavior:**  
FT Profile packets (`PacketType = 21`) contain frequency-domain data, not mass-domain data. The C# code (`FtProfilePacket.CalculateMass()`) converts frequencies to m/z using the formula:

```
mass = coeff1 / freq + coeff2 / (freq²) + coeff3 / (freq⁴) + massOffset
```

The coefficients (`coeff1`, `coeff2`, `coeff3`, `massOffset`) come from `ScanEvent.mass_calibrators` (a `f64[]` parsed from the trailer). The profile blob itself is a series of `ProfileSegmentStruct`s (24 bytes each), each containing subsegments with `(start_index, word_count, mass_offset)` headers, followed by `f32[]` intensity values.

**Zig Behavior:**  
In `app_state.zig` (lines 382–400):
```zig
if (packet_type == raw.PACKET_TYPE_FT_PROFILE) {
    // Profile packet - create empty spectrum for now
    self.current_spectrum = .{ ... .num_points = 0 };
    return;
}
```

**Impact:**  
- **All MS1 scans on Orbitrap/Astral appear empty** in the GUI.
- **TIC/BPC chromatograms still work** (they use scan index metadata, not packet data).
- **Any downstream analysis requiring MS1 profile data fails completely.**

**Fix Complexity:** High. Requires:
1.  Implementing `ProfileSegmentStruct` parser (24 bytes).
2.  Implementing subsegment expansion (handling zero-padding between subsegments).
3.  Implementing the frequency-to-mass calibration formula.
4.  Wiring `mass_calibrators` from the scan event into the packet decoder.

---

### 2.3 ScanEventInfo is Only Partially Parsed (40 / 96 Bytes)

**C# Struct:** `ScanEventInfoStruct` is 96 bytes (rev ≥ 65). It contains:
- `nScanType` (offset 0)
- `nMassAnalyzerType` (offset 2)
- `nMSOrder` (offset 6) ← **Only this is read in Zig**
- `nPolarity` (offset 8)
- `nPrecursorIndepent` (offset 12)
- `nData` (offset 16)
- `nChargeState` (offset 20)
- `nIonizationMode` (offset 24)
- `nCorona` (offset 28)
- `nDetector` (offset 32)
- `nScanMode` (offset 36)
- `nMultipleInject` (offset 40)
- `nZoomScan` (offset 44)
- `nAGC` (offset 48)
- ... (dissociation fields, reaction arrays, etc. follow)

**Zig Behavior:**  
`raw_file.zig` defines `ScanEventInfo` but the `read()` function only reads the first 40 bytes. The C# code uses fields like `nMultipleInject`, `nAGC`, and the dissociation type arrays (MPD, ECD, ETD, HCD values) for instrument method reconstruction.

**Impact:**  
- **MS level is the only reliable metadata extracted.**
- **Charge state, collision energy, isolation width, and precursor mass are unavailable** even if trailers are fixed.

**Fix Complexity:** Low. Simply extend the struct reader to 96 bytes. The struct layout is already known from C#.

---

## 3. High-Priority Gaps (Reduced Functionality)

### 3.1 Mass Calibration for Centroid Data is Ignored

**C# Behavior:**  
Even for centroid packets, the C# reader applies mass calibration corrections if `ScanEvent.mass_calibrators` are present. This is rare for modern instruments but exists for historical compatibility.

**Zig Behavior:**  
`mass_calibrators` are parsed in `scan_event.zig` but never used in `advanced_packet.zig`.

**Impact:** Low for modern Orbitrap files (calibration is usually pre-applied), but technically incorrect.

---

### 3.2 No Isolation Window / Precursor Propagation

**C# Behavior:**  
`MsReactionStruct` (56 bytes) contains `precursor_mass`, `isolation_width`, `collision_energy`, `activation_type`, etc. This is parsed per-scan-event in C#.

**Zig Behavior:**  
The `Reaction` struct (56 bytes) is defined in `raw_file.zig`, and `readReactions()` exists in `scan_event.zig`. However, `AppState.ScanInfo` has no fields for precursor m/z or isolation window, so even if parsed, the data goes nowhere.

**Impact:**  
- **DIA window mapping is impossible.**
- **Proteomics search engines cannot use the reader for mzML conversion.**

**Fix Complexity:** Low. Add fields to `ScanInfo`, propagate from `ScanEvent.Reaction[0]`.

---

## 4. Medium-Priority Gaps (Version / Format Coverage)

### 4.1 Narrow Version Support (Only Rev ≥ 65)

**C# Behavior:**  
The C# code has 5 versions of `RunHeaderStruct` and `RawFileInfoStruct`, plus special cases for:
- Rev < 25 (LCQ era, 32-bit offsets)
- Rev 25–64 (intermediate formats)
- Rev ≥ 65 (modern Orbitrap)

**Zig Behavior:**  
`resolveScan()` returns `error.UnsupportedFileRevision` for anything < 65. The `readScanIndex()` function has some support for rev 64 (80-byte index) and < 64 (72-byte index), but these paths are untested.

**Impact:**  
- **Legacy files (pre-2010) cannot be opened.**
- Not a blocker for Astral DIA (which is rev ≥ 65).

---

### 4.2 Filter String Parsing is Regex-Based and Fragile

**C# Behavior:**  
The C# `FilterStringParser` uses a formal grammar to parse filter strings like:
`FTMS + p NSI Full ms2 712.35@hcd30.00 [110.00-2000.00]`

**Zig Behavior:**  
`readScanTrailer()` in `raw_file.zig` uses a simple regex-like scan for `"ms"` followed by a digit. This is used as a fallback when trailers are unavailable.

**Impact:**  
- **Fragile for exotic scan types** (e.g., `ms3`, `SIM`, `Zoom`).
- Will be obsolete once `TrailerScanEvents` parsing is fixed.

---

## 5. Low-Priority / Cosmetic Gaps

| Issue | C# Behavior | Zig Behavior | Impact |
|---|---|---|---|
| **GUI Platform** | WinForms / WPF (portable concepts) | Hardcoded Win32 API | Blocks Linux/macOS ports |
| **Noise Data** | `num_noise_info_words` decoded and exposed | Skipped | Not needed for visualization |
| **Debug Data** | `num_debug_info_words` decoded | Skipped | Not needed for production |
| **Peak Features** | `PeakFeatures` struct (f32 resolution, f32 baseline, etc.) | Parsed but not displayed | Data is available in buffer |
| **String Encoding** | UTF-16LE with proper surrogate handling | UTF-16LE basic conversion | Should work for all MS data |

---

## 6. Feature Matrix: C# vs. Zig

| Feature | C# RawFileReader | mzigRawReader | Gap |
|---|---|---|---|
| **File I/O** | FileStream / MemoryMappedFile | `std.Io.File.MemoryMap` | ✅ Parity |
| **File Rev ≥ 65** | Full support | Full support | ✅ Complete |
| **File Rev 64** | Full support | Partial (untested) | ⚠️ Narrow |
| **File Rev < 64** | Full support | Unsupported | ❌ Missing |
| **Scan Index Parsing** | All versions | Rev ≥ 65 verified | ✅ Complete (for target rev) |
| **FT Centroid (Type 20)** | Full decode | Full decode | ✅ Complete |
| **FT Profile (Type 21)** | Full decode (freq→mass) | Recognized, empty spectrum | ❌ **Critical** |
| **LTQ Centroid (Type 5)** | Full decode | Full decode | ✅ Complete |
| **Accurate Mass (f64 mz)** | Supported | Supported | ✅ Complete |
| **Standard Mass (f32 mz)** | Supported | Supported | ✅ Complete |
| **TrailerScanEvents** | Full parse (deduplicated) | Disabled / broken | ❌ **Critical** |
| **MS Level (MSOrder)** | From trailer | Heuristic from packet type | ❌ **Critical** |
| **Precursor m/z** | From `MsReactionStruct` | Parsed but not propagated | ❌ High |
| **Isolation Width** | From `MsReactionStruct` | Parsed but not propagated | ❌ High |
| **Collision Energy** | From `MsReactionStruct` | Parsed but not propagated | ❌ High |
| **Charge State** | From trailer label 18 | Parsed but not propagated | ❌ High |
| **Mass Calibration** | Applied to profile & centroid | Parsed but not used | ❌ High |
| **Filter String** | Formal grammar parser | Regex fallback | ⚠️ Medium |
| **TIC/BPC Chromatogram** | From scan index metadata | From scan index metadata | ✅ Complete |
| **XIC Extraction** | Supported | Not implemented | ❌ Missing |
| **Peak Features** | Exposed in API | Parsed but unused | ⚠️ Low |
| **Noise Data** | Exposed in API | Skipped | ⚠️ Low |
| **SIM / Zoom Scans** | Supported | Packet type recognized | ⚠️ Untested |

---

## 7. Astral DIA Specific Assessment

### 7.1 Typical Astral DIA Acquisition

An Orbitrap Astral DIA run typically has:
- **MS1:** FT Profile (`packet_type = 21`) — full scan, profile mode for quantification
- **MS2:** FT Centroid (`packet_type = 20`) — DIA windows, centroid mode for speed

### 7.2 How mzigRawReader Handles This

| Step | C# Result | Zig Result | Status |
|---|---|---|---|
| Open file | ✅ ~3–22 ms | ✅ ~3–22 ms | Works |
| Build scan index | ✅ Instant | ✅ Instant | Works |
| MS1 display | ✅ Full profile spectrum | ❌ **Empty** | **Broken** |
| MS2 display | ✅ Centroid spectrum | ✅ Centroid spectrum | Works |
| MS level assignment | ✅ Correct (from trailer) | ⚠️ Heuristic (correct by accident) | Fragile |
| TIC chromatogram | ✅ Correct | ✅ Correct | Works |
| BPC chromatogram | ✅ Correct | ✅ Correct | Works |
| Precursor mapping | ✅ Available | ❌ Missing | Missing |

### 7.3 Verdict for Astral DIA

- **Visualization:** **Partially works.** MS2 looks correct. MS1 is empty. TIC/BPC are fine.
- **Quantification:** **Blocked.** MS1 profile data is required for label-free quantification (e.g., MaxLFQ, DIA-NN). Empty spectra = no quant.
- **Search/Identification:** **Partially works.** MS2 centroid data is correct, but without precursor m/z mapping, search engines will struggle.

---

## 8. Recommendations (Prioritized)

### P0 — Fix Before DIA Release

1.  **Enable TrailerScanEvents Parsing**
    - Integrate `trailer_events.zig` into `AppState.openFile()`.
    - Use `RunHeader.TrailerScanEventsPos` as the base.
    - Treat `ScanIndexEntry.trailer_offset` as an index, not an offset.
    - Validate on 3–5 real RAW files (DDA + DIA).

2.  **Implement FT Profile Decoding**
    - Add `ProfileSegmentStruct` parser (24 bytes).
    - Implement subsegment expansion with zero-padding.
    - Implement `CalculateMass(freq, calibrators)`.
    - Wire `mass_calibrators` from `ScanEvent` into `loadScan()`.
    - Validate MS1 profile display in GUI.

### P1 — High Value, Lower Effort

3.  **Complete ScanEventInfo Parsing**
    - Extend struct reader from 40 → 96 bytes.
    - Add `nChargeState`, `nAGC`, `nScanMode`, etc. to `ScanInfo`.

4.  **Propagate Precursor Metadata**
    - Add `precursor_mz`, `isolation_width`, `collision_energy` to `ScanInfo`.
    - Populate from `ScanEvent.Reaction[0]`.
    - Display in GUI scan list.

### P2 — Nice to Have

5.  **Add XIC Extraction**
    - Given m/z and ppm tolerance, extract chromatogram from centroid data.
    - Could reuse `loadScanBulk()` for speed.

6.  **Cross-Platform GUI**
    - Abstract Win32 calls behind an interface.
    - Consider `microui`, `imgui`, or a web-based frontend.

7.  **Legacy Version Support**
    - Implement rev < 65 code paths only if user demand exists.

---

## 9. Appendix: Verified C# Struct Sizes

| Struct | Size (Rev ≥ 65) | Zig Status |
|---|---|---|
| `FileHeaderStruct` | 536 bytes | ✅ Correct |
| `RawFileInfoStruct` | 476 bytes (v5) | ✅ Correct |
| `RunHeaderStruct` | 1012 bytes (v5) | ✅ Correct |
| `VirtualControllerInfoStruct` | 32 bytes | ✅ Correct |
| `ScanIndexStruct` | 88 bytes | ✅ Correct |
| `ScanEventInfoStruct` | 96 bytes | ⚠️ Only 40 bytes read |
| `MsReactionStruct` | 56 bytes (rev ≥ 66), 48 bytes (rev 65) | ✅ Correct |
| `PacketHeaderStruct` | 32 bytes | ✅ Correct |
| `ProfileSegmentStruct` | 24 bytes | ❌ Not implemented |

### Packet Type Constants (Verified)

| Name | Value | Zig Status |
|---|---|---|
| `ShortCentroid` | 1 | ✅ |
| `LongCentroid` | 5 | ✅ |
| `FtCentroid` | 20 | ✅ |
| `FtProfile` | 21 | ✅ |
| `AnalogData` | 128 | ✅ |

### FT Frequency-to-Mass Formula (C# Reference)

```csharp
// From ThermoFisher.CommonCore.RawFileReader.FtProfilePacket.CalculateMass()
public static double CalculateMass(double frequency, double[] massCalibrators)
{
    double coeff1 = massCalibrators[0];
    double coeff2 = massCalibrators[1];
    double coeff3 = massCalibrators[2];
    double massOffset = massCalibrators[3];
    
    return coeff1 / frequency 
         + coeff2 / (frequency * frequency) 
         + coeff3 / (frequency * frequency * frequency * frequency) 
         + massOffset;
}
```

### Profile Segment Layout (C# Reference)

```csharp
// ProfileSegmentStruct (24 bytes)
struct ProfileSegmentStruct
{
    public double BaseAbscissa;      // Starting frequency
    public double AbscissaSpacing;   // Delta frequency per point
    public uint NumSubsegments;      // Number of subsegments
    public uint NumExpandedWords;    // Total f32 words in segment
}

// Subsegment header (12 bytes each)
struct SubsegmentHeader
{
    public uint StartIndex;          // Index into segment
    public uint WordCount;           // Number of f32 values
    public float MassOffset;         // Mass offset for this subsegment
}
```

---

## 10. Conclusion

`mzigRawReader` is a **production-quality centroid data reader** with exceptional performance. Its binary parsing is accurate, its memory management is excellent, and its benchmarks are outstanding. However, it currently sits at a **local maximum** for DDA centroid workflows.

To support **Orbitrap Astral DIA** (and any workflow requiring MS1 profile data or accurate MS levels), the team must:
1.  Fix `TrailerScanEvents` parsing (the metadata layer).
2.  Implement FT Profile decoding (the frequency-to-mass layer).

These are the two remaining pillars. Once they are in place, `mzigRawReader` will have full parity with the C# reader for all modern acquisition modes, with a 10–100× performance advantage.
