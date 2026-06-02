# Implementation Plan: P0–P3

> Derived from direct analysis of the C# decompiled source at
> `F:\kimi_code\src\canddotnet\DLL_Reader\thermo\decompiled` and the
> verified documentation at `…\thermo\docs`.

---

## P0 — FT Profile Packet Decoding (Critical)

**Goal:** `loadScan()` must return actual m/z + intensity arrays for
`PACKET_TYPE_FT_PROFILE` (21) instead of an empty spectrum.

### What the C# code does (`FtProfilePacket.cs`)

1. **Constructor** receives mass-calibration coefficients via delegate.
   - If ≥ 5 coefficients: `_coeff1 = array[2]`, `_coeff2 = array[3]`,
     `_coeff3 = array[4]`
   - If 4 coefficients: `_coeff1 = array[2]`, `_coeff2 = array[3]`
2. **Lazy expansion** when `SegmentPeaks` is first accessed:
   `ExpandProfileBlob()`.
3. **`UseFtProfileSubSegment`** flag is set from the packet header:
   ```csharp
   UseFtProfileSubSegment = (defaultFeatureWord & 0x40) == 0
                         && (defaultFeatureWord & 0x80) != 0;
   ```
   This determines whether each subsegment carries a 4-byte `massOffset`.
4. **`ExpandProfileBlob()`** reads the profile data blob sequentially:
   - For each segment, read `ProfileSegmentStruct` (24 bytes):
     - `BaseAbscissa` (f64) — start frequency
     - `AbscissaSpacing` (f64) — frequency step
     - `NumSubSegments` (u32)
     - `NumExpandedWords` (u32) — total expected points (incl. zeros)
   - Call `ProcessSubsegments()` for each segment.
   - If fewer points than `NumExpandedWords`, call `AddZeroPackets()`
     to pad with zero-intensity points.
5. **`ProcessSubsegments()`** for each subsegment:
   - Read `StartIndex` (u32) + `WordCount` (u32) = 8 bytes
   - If `UseFtProfileSubSegment`: read `massOffset` (f32) = +4 bytes
   - If `StartIndex < currentIndex`: remove overlapping last point
   - If `StartIndex > currentIndex`: insert zero-padded points
   - Read `WordCount` float intensities (4 bytes each)
   - For each point:
     - `freq = BaseAbscissa + index * AbscissaSpacing`
     - `mass = CalculateMass(massOffset, freq)`
6. **Mass conversion formulas:**
   ```csharp
   // 3-coefficient version
   double CalculateMass(float massOffset, double freq) {
       double num = freq * freq;
       return _coeff1 / freq + _coeff2 / num + _coeff3 / (num * num)
              + (double)massOffset;
   }

   // 2-coefficient version (when _coeff3 ≈ 0)
   double CalculateMassWithoutCoeff3(float massOffset, double freq) {
       return (_coeff1 + _coeff2 / freq) / freq + (double)massOffset;
   }
   ```
7. **Zero padding (`AddZeroPackets`):**
   - When profile data is sparse (compressed), insert zero-intensity
     points to maintain uniform spacing.
   - Mass monotonicity enforced: if `mass <= minMass`, increment by
     `1E-05` via `IncreaseMass()`.

### File Layout (FT Profile Packet)

| Offset | Content | Size |
|--------|---------|------|
| 0 | `PacketHeaderStruct` (8 × u32) | 32 bytes |
| 32 | Mass ranges (low/high f32 per segment) | 8 × NumSegments |
| 32+8×S | **Profile data blob** | NumProfileWords × 4 |
| | For each segment: `ProfileSegmentStruct` | 24 bytes |
| | For each subsegment: `StartIndex`(u32) + `WordCount`(u32) | 8 bytes |
| | If `UseFtProfileSubSegment`: `massOffset`(f32) | +4 bytes |
| | Profile intensities (float array) | WordCount × 4 |
| ... | Centroid data blob | NumCentroidWords × 4 |
| ... | Non-default feature words | ... |
| ... | Expansion words | ... |
| ... | Noise info | ... |
| ... | Debug info | ... |

### Zig Implementation Steps

#### Step P0.1 — Create `src/raw_core/profile_packet.zig`

```zig
const std = @import("std");
const raw = @import("raw_file");

pub const ProfileSegment = struct {
    base_abscissa: f64,      // start frequency
    abscissa_spacing: f64,   // frequency step
    num_subsegments: u32,
    num_expanded_words: u32, // total expected points
};

pub const ProfileSubsegment = struct {
    start_index: u32,
    word_count: u32,
    mass_offset: f32,        // only if UseFtProfileSubSegment
};

pub const ProfileError = error{
    Truncated,
    InvalidProfile,
    TooManyPoints,
};

/// Decode FT Profile packet into caller-provided buffers.
/// Returns number of (m/z, intensity) points decoded.
///
/// Parameters:
///   - bytes: packet data starting at header
///   - calibrators: mass calibration coefficients (from ScanEvent)
///   - mz_buf: output m/z buffer (must be large enough)
///   - intensity_buf: output intensity buffer
///   - use_subsegment: from header flag (defaultFeatureWord)
pub fn decodeFtProfile(
    bytes: []const u8,
    calibrators: []const f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    use_subsegment: bool,
) ProfileError!usize {
    // TODO: implement
}
```

**Key implementation notes:**
- Profile spectra can have ~4M points (vs ~65K for centroid). Buffer
  sizing in `app_state.zig` must be increased.
- The `calibrators` array comes from `ScanEvent.mass_calibrators`.
  Index mapping: `calibrators[2] = coeff1`, `calibrators[3] = coeff2`,
  `calibrators[4] = coeff3`.
- Choose mass conversion delegate based on `|coeff3| < 1e-15` (C# uses
  `double.Epsilon`).

#### Step P0.2 — Wire into `app_state.zig`

In `loadScan()` (around line 443), add a branch for
`PACKET_TYPE_FT_PROFILE`:

```zig
if (packet_type == raw.PACKET_TYPE_FT_PROFILE) {
    // Get calibrators from trailer event
    var calibrators: []const f64 = &[_]f64{};
    if (self.trailer_events) |te| {
        if (te.getEvent(scan_index)) |evt| {
            calibrators = evt.mass_calibrators;
        }
    }

    // Determine UseFtProfileSubSegment from header
    const use_subsegment = (h.default_feature_word & 0x40) == 0
                        and (h.default_feature_word & 0x80) != 0;

    // Grow buffers for profile data (up to ~4M points)
    const est_profile_points: usize = @intCast(h.num_profile_words);
    // ... grow reuse_mz, reuse_intensity if needed

    const num_points = try profile.decodeFtProfile(
        packet_slice,
        calibrators,
        self.reuse_mz.?,
        self.reuse_intensity.?,
        use_subsegment,
    );
    // ... copy to owned arrays, same pattern as centroid path
}
```

Also wire into `loadScanArena()` and `loadScanBulk()`.

#### Step P0.3 — Buffer sizing

Current buffers are sized for centroid data (~65K points). Profile
spectra need ~4M points. Update the estimate logic:

```zig
// In loadScan(), after reading header:
const est_points: usize = if (packet_type == raw.PACKET_TYPE_FT_PROFILE)
    @intCast(@max(64, h.num_profile_words))
else
    @intCast(@max(64, h.num_centroid_words * 4 / entry_size));
```

---

## P1 — Complete ScanEventInfo Parsing

**Goal:** Read all 136 bytes of `ScanEventInfoStruct` (rev ≥ 65) so
that charge state, scan mode, AGC, and other fields are available.

### Current State (`raw_file.zig:530-575`)

Only reads offsets 0–11 and 33. The full struct has many more fields.

### Full `ScanEventInfoStruct` Layout (from C#)

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| 0 | `IsValid` | u8 | |
| 1 | `IsCustom` | u8 | |
| 2 | `Corona` | u8 | |
| 3 | `Detector` | u8 | SFDetectorValid if detector value valid |
| 4 | `Polarity` | u8 | |
| 5 | `ScanDataType` | u8 | 0=centroid, 1=profile |
| 6 | `MSOrder` | i8 | **1-based** (MS=1, MS2=2, MS3=3) |
| 7 | `ScanType` | u8 | |
| 8 | `SourceFragmentation` | u8 | |
| 9 | `TurboScan` | u8 | |
| 10 | `DependentData` | u8 | |
| 11 | `IonizationMode` | u8 | |
| 12–15 | *(padding)* | | Align to f64 |
| 16–23 | `DetectorValue` | f64 | |
| 24 | `SourceFragmentationType` | u8 | |
| 25–26 | *(padding/flags)* | | |
| 27–30 | `ScanTypeIndex` | i32 | HIWORD=segment, LOWORD=scan type |
| 31 | `Wideband` | u8 | |
| 32 | `AccurateMassType` | u32 (enum) | With Pack=4, takes 4 bytes |
| 36 | `MassAnalyzerType` | u8 | ITMS=0, TQMS=1, SQMS=2, TOFMS=3, FTMS=4, Sector=5, ASTMS=6 |
| 37 | `SectorScan` | u8 | |
| 38 | `Lock` | u8 | |
| 39 | `FreeRegion` | u8 | |
| 40 | `Ultra` | u8 | |
| 41 | `Enhanced` | u8 | |
| 42 | `MultiPhotonDissociationType` | u8 | |
| 43–50 | `MultiPhotonDissociation` | f64 | |
| 51 | `ElectronCaptureDissociationType` | u8 | |
| 52–59 | `ElectronCaptureDissociation` | f64 | |
| 60 | `PhotoIonization` | u8 | |
| 61 | `PulsedQDissociationType` | u8 | |
| 62–69 | `PulsedQDissociation` | f64 | |
| 70 | `ElectronTransferDissociationType` | u8 | |
| 71–78 | `ElectronTransferDissociation` | f64 | |
| 79 | `HigherEnergyCIDType` | u8 | |
| 80–87 | `HigherEnergyCID` | f64 | |
| 88 | `SupplementalActivation` | u8 | |
| 89 | `MultiStateActivation` | u8 | |
| 90 | `CompensationVoltage` | u8 | |
| 91 | `CompensationVoltageType` | u8 | |
| 92 | `Multiplex` | u8 | |
| 93 | `ParamA` | u8 | |
| 94 | `ParamB` | u8 | |
| 95 | `ParamF` | u8 | |
| 96 | `SpsMultiNotch` | u8 | |
| 97 | `ParamR` | u8 | |
| 98 | `ParamV` | u8 | |
| 99–135 | *(remaining)* | | |

**Total: 136 bytes** (confirmed by C# `Marshal.SizeOf()`).

### Critical Corrections

1. **MSOrder is 1-based, NOT 0-based.**
   - C#: `MSOrder = 1` means MS1
   - Current Zig code: `@intCast(bytes[offset + 6])` → treats as 0-based
   - **Fix:** `scan.ms_level = @intCast(evt.info.ms_order);` should be
     `scan.ms_level = @intCast(evt.info.ms_order);` — but verify this is
     already correct. The verified docs say MSOrder is 1-based. Check if
     the current code subtracts 1 anywhere.

2. **ScanDataType at offset 5:**
   - 0 = centroid, 1 = profile
   - Can be used to cross-check packet type.

### Zig Implementation Steps

#### Step P1.1 — Extend `ScanEventInfo` struct

Add all fields that are currently missing. The struct doesn't need to
hold all 136 bytes as named fields — we can read the ones we need and
skip the rest. But for completeness and future use, add:

```zig
pub const ScanEventInfo = struct {
    // Already present:
    is_valid: u8,                    // offset 0
    is_custom: u8,                   // offset 1
    corona: u8,                      // offset 2
    detector: u8,                    // offset 3
    polarity: u8,                    // offset 4
    scan_data_type: u8,              // offset 5  (0=centroid, 1=profile)
    ms_order: i8,                    // offset 6  (1-based!)
    scan_type: u8,                   // offset 7
    source_fragmentation: u8,        // offset 8
    turbo_scan: u8,                  // offset 9
    dependent_data: u8,              // offset 10
    ionization_mode: u8,             // offset 11

    // NEW fields:
    detector_value: f64,             // offset 16
    source_fragmentation_type: u8,   // offset 24
    scan_type_index: i32,            // offset 27
    wideband: u8,                    // offset 31
    accurate_mass_type: u32,         // offset 32 (enum, 4 bytes)
    mass_analyzer_type: u8,          // offset 36
    sector_scan: u8,                 // offset 37
    lock: u8,                        // offset 38
    free_region: u8,                 // offset 39
    ultra: u8,                       // offset 40
    enhanced: u8,                    // offset 41
    // ... activation types and energies at offsets 42–98

    // Activation energies (f64 values):
    multi_photon_dissociation: f64,      // offset 43
    electron_capture_dissociation: f64,  // offset 51
    pulsed_q_dissociation: f64,          // offset 62
    electron_transfer_dissociation: f64, // offset 71
    higher_energy_cid: f64,              // offset 80

    // More byte flags:
    supplemental_activation: u8,     // offset 88
    multi_state_activation: u8,      // offset 89
    compensation_voltage: u8,        // offset 90
    compensation_voltage_type: u8,   // offset 91
    multiplex: u8,                   // offset 92
    param_a: u8,                     // offset 93
    param_b: u8,                     // offset 94
    param_f: u8,                     // offset 95
    sps_multi_notch: u8,             // offset 96
    param_r: u8,                     // offset 97
    param_v: u8,                     // offset 98

    pub fn read(bytes: []const u8, offset: usize) RawResolveError!ScanEventInfo {
        if (offset + raw.SCAN_EVENT_INFO_SIZE > bytes.len)
            return RawResolveError.Truncated;
        return .{
            .is_valid = bytes[offset + 0],
            .is_custom = bytes[offset + 1],
            .corona = bytes[offset + 2],
            .detector = bytes[offset + 3],
            .polarity = bytes[offset + 4],
            .scan_data_type = bytes[offset + 5],
            .ms_order = @intCast(bytes[offset + 6]),
            .scan_type = bytes[offset + 7],
            .source_fragmentation = bytes[offset + 8],
            .turbo_scan = bytes[offset + 9],
            .dependent_data = bytes[offset + 10],
            .ionization_mode = bytes[offset + 11],
            .detector_value = @bitCast(std.mem.readInt(u64, bytes[offset + 16 ..][0..8], .little)),
            .source_fragmentation_type = bytes[offset + 24],
            .scan_type_index = std.mem.readInt(i32, bytes[offset + 27 ..][0..4], .little),
            .wideband = bytes[offset + 31],
            .accurate_mass_type = std.mem.readInt(u32, bytes[offset + 32 ..][0..4], .little),
            .mass_analyzer_type = bytes[offset + 36],
            .sector_scan = bytes[offset + 37],
            .lock = bytes[offset + 38],
            .free_region = bytes[offset + 39],
            .ultra = bytes[offset + 40],
            .enhanced = bytes[offset + 41],
            .multi_photon_dissociation = @bitCast(std.mem.readInt(u64, bytes[offset + 43 ..][0..8], .little)),
            .electron_capture_dissociation = @bitCast(std.mem.readInt(u64, bytes[offset + 51 ..][0..8], .little)),
            .pulsed_q_dissociation = @bitCast(std.mem.readInt(u64, bytes[offset + 62 ..][0..8], .little)),
            .electron_transfer_dissociation = @bitCast(std.mem.readInt(u64, bytes[offset + 71 ..][0..8], .little)),
            .higher_energy_cid = @bitCast(std.mem.readInt(u64, bytes[offset + 80 ..][0..8], .little)),
            .supplemental_activation = bytes[offset + 88],
            .multi_state_activation = bytes[offset + 89],
            .compensation_voltage = bytes[offset + 90],
            .compensation_voltage_type = bytes[offset + 91],
            .multiplex = bytes[offset + 92],
            .param_a = bytes[offset + 93],
            .param_b = bytes[offset + 94],
            .param_f = bytes[offset + 95],
            .sps_multi_notch = bytes[offset + 96],
            .param_r = bytes[offset + 97],
            .param_v = bytes[offset + 98],
        };
    }
};
```

#### Step P1.2 — Verify MSOrder is 1-based

Check `app_state.zig:402`:
```zig
scan.ms_level = @intCast(evt.info.ms_order);
```

If `ms_order` is 1 (MS1), then `ms_level` becomes 1 — this is correct.
If `ms_order` is 2 (MS2), then `ms_level` becomes 2 — correct.

**No change needed** if the current code already works this way. But
verify against the `test_trailer_phase1.zig` output on a real file.

#### Step P1.3 — Propagate charge state

Charge state is NOT directly in `ScanEventInfoStruct`. It comes from:
1. The **centroid feature words** (for centroid data)
2. The **filter string** trailer label (label 18)
3. The **reaction data** (for MSn)

The current code already reads reactions. For charge state from centroid
feature words, see P2.

---

## P2 — Wire Feature Word Decoding

**Goal:** `decodeSimplifiedCentroidsIntoBuffers()` should actually decode
feature words into `PeakFeatures` instead of ignoring the buffer.

### Current State (`advanced_packet.zig:150-151`)

```zig
pub fn decodeSimplifiedCentroidsIntoBuffers(
    bytes: []const u8,
    data_offset: u64,
    mz_buf: []f64,
    intensity_buf: []f32,
    _features_buf: ?[]PeakFeatures,
) PacketError!usize {
    _ = _features_buf;  // ← EXPLICITLY IGNORED
    // ...
}
```

### Where Feature Words Live in the Packet

From `AdvancedPacketBase.cs` and the flow diagram:

The packet layout after the header and mass ranges is:
1. **Profile data blob** (`num_profile_words × 4` bytes)
2. **Centroid data blob** (`num_centroid_words × 4` bytes)
3. **Non-default feature words** (`num_non_default_feature_words × 4` bytes)
4. **Expansion words** (`num_expansion_words × 4` bytes)
5. **Noise info** (`num_noise_info_words × 4` bytes)
6. **Debug info** (`num_debug_info_words × 4` bytes)

The **feature words** are in section 3, NOT interleaved with centroid
data. The simplified centroid decoder only reads m/z + intensity from
the centroid blob.

For the **default feature word**, every peak gets the same features
(from `header.default_feature_word`). For **non-default feature words**,
only some peaks have different features — the rest use the default.

### `PeakFeatures` Decoding (from `advanced_packet.zig:45-55`)

Already implemented but never called:
```zig
pub fn decodePeakFeatures(feature_word: u32) PeakFeatures {
    const charge_raw: u32 = feature_word & 0xF;
    const res_raw: u32 = (feature_word >> 4) & 0xFFF;
    const sn_raw: u32 = (feature_word >> 16) & 0xFFF;
    return .{
        .charge = if (charge_raw == 0) 0 else @intCast(charge_raw),
        .resolution = res_raw * 100,
        .sn_ratio = @floatFromInt(sn_raw),
        .monoisotopic = (feature_word & 0x10000000) != 0,
    };
}
```

### Implementation Steps

#### Step P2.1 — Decode default features for all peaks

In `decodeSimplifiedCentroidsIntoBuffers()`, after the centroid decode
loop, fill the features buffer:

```zig
if (_features_buf) |features_buf| {
    const default_features = decodePeakFeatures(h.default_feature_word);
    for (0..out_index) |i| {
        features_buf[i] = default_features;
    }

    // TODO: handle non-default feature words
    // Non-default features are stored after the centroid blob.
    // The format is: for each non-default peak, store its index
    // and its feature word. Need to verify exact format from C#.
}
```

#### Step P2.2 — Handle non-default feature words (if needed)

The non-default feature section contains feature words for peaks that
don't use the default. The exact format needs verification from the C#
`ExpandCentroidData()` or `ExpandLabelData()` methods in
`AdvancedPacketBase.cs`.

From a quick reading, the non-default features are stored as pairs of
(index, feature_word) after the centroid data. The count is
`num_non_default_feature_words`.

For a **simplified** implementation (sufficient for most use cases),
using only the default feature word gives charge state for most peaks.
Non-default features are typically only for peaks with unusual charge
states or resolutions.

#### Step P2.3 — Propagate charge to `ScanInfo`

In `loadScan()`, after decoding, extract charge from the first peak's
features (or the most common charge):

```zig
// After decoding, if features are available:
if (features.len > 0 and features[0].charge > 0) {
    self.scans[scan_index].charge_state = features[0].charge;
}
```

---

## P3 — Test Infrastructure

**Goal:** Create automated tests that verify parser correctness against
known-good output from the C# RawFileReader.

### Step P3.1 — Create `src/tests/` directory

```
src/tests/
├── test_fixture.zig      # Shared test helper
├── test_trailer_events.zig
├── test_profile_decode.zig
├── test_metadata.zig
└── test_utils.zig
```

### Step P3.2 — Create `TestFixture` helper

```zig
const std = @import("std");

pub const TestFixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    test_data_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, test_data_dir: []const u8) TestFixture {
        return .{
            .allocator = allocator,
            .io = io,
            .test_data_dir = test_data_dir,
        };
    }

    /// Open a .raw file from the test data directory
    pub fn openRawFile(self: TestFixture, file_name: []const u8) !std.Io.File {
        const path = try std.fs.path.join(self.allocator, &.{ self.test_data_dir, file_name });
        defer self.allocator.free(path);
        return try std.Io.Dir.openFile(std.Io.Dir.cwd(), self.io, path, .{});
    }

    /// Compare two f64 slices with tolerance
    pub fn expectF64SliceEqual(expected: []const f64, actual: []const f64, tolerance: f64) !void {
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual, 0..) |e, a, i| {
            if (@abs(e - a) > tolerance) {
                std.debug.print("Mismatch at index {d}: expected {e}, got {e}\n", .{ i, e, a });
                return error.TestExpectedEqual;
            }
        }
    }
};
```

### Step P3.3 — Generate golden files from C#

Create a small C# program (or use the existing `DumpTrailer` tool) that:

1. Opens a test `.raw` file
2. For each scan, outputs:
   - Scan number
   - MS level
   - Packet type
   - Number of points
   - First 10 (m/z, intensity) pairs
   - Precursor m/z, isolation width, CE
   - Charge state
3. For MS1 profile scans, outputs:
   - First 10 (m/z, intensity) pairs from profile data
   - Mass calibrators used

Store golden files as JSON/CSV in `test_data/golden/`.

### Step P3.4 — Add `zig build test-all` step

In `build.zig`:

```zig
// ---- test suite module ----
const test_suite_mod = b.createModule(.{
    .root_source_file = b.path("src/tests/test_suite.zig"),
    .target = target,
    .optimize = optimize,
});
// Add all imports...

const test_suite = b.addTest(.{
    .root_module = test_suite_mod,
});

const test_all_step = b.step("test-all", "Run full test suite (requires test data)");
test_all_step.dependOn(&b.addRunArtifact(test_suite).step);
```

### Step P3.5 — Example test: TrailerScanEvents

```zig
test "trailer scan events match golden" {
    const fixture = TestFixture.init(std.testing.allocator, std.io.getStdErr().writer(), "test_data");
    // Open test.raw
    // Parse trailers
    // Compare MS levels, scan types against golden file
}
```

---

## Build Order & Dependencies

```
P1.1 (extend ScanEventInfo)
    │
    ▼
P0.1 (profile_packet.zig) ──► P0.2 (wire into app_state)
    │                              │
    │                              ▼
    │                         P0.3 (buffer sizing)
    │                              │
    ▼                              ▼
P2.1 (feature words) ◄───────────┘
    │
    ▼
P2.2 (non-default features) [optional]
    │
    ▼
P1.2 (verify MSOrder 1-based)
P1.3 (propagate charge)
    │
    ▼
P3.1–P3.5 (test infrastructure)
```

---

## Files to Modify / Create

| Action | File |
|--------|------|
| **Create** | `src/raw_core/profile_packet.zig` |
| **Create** | `src/tests/test_fixture.zig` |
| **Create** | `src/tests/test_trailer_events.zig` |
| **Create** | `src/tests/test_profile_decode.zig` |
| **Create** | `src/tests/test_metadata.zig` |
| **Create** | `src/tests/test_suite.zig` (test root) |
| **Modify** | `src/raw_core/raw_file.zig` — extend `ScanEventInfo` |
| **Modify** | `src/raw_core/advanced_packet.zig` — wire feature decoding |
| **Modify** | `src/app_state.zig` — add profile branch, buffer sizing, charge propagation |
| **Modify** | `build.zig` — add profile_packet module, test suite step |
| **Modify** | `src/raw_core/scan_event.zig` — if `ScanEventInfo` fields change |
| **Modify** | `src/raw_core/trailer_events.zig` — if dedup needs new fields |

---

## Verification Checklist

After each phase, verify with the `test-trailer-phase1` executable and
benchmark suite:

- [ ] `zig build test` passes
- [ ] `zig build test-all` passes (if test data available)
- [ ] `zig build bench` produces same performance for centroid data
- [ ] `test-trailer-phase1 <file.raw>` shows correct MS levels
- [ ] Profile scans show non-empty spectra with plausible m/z ranges
- [ ] Charge state appears in GUI scan list for centroid data
