# mzigRawReader Implementation Roadmap

> **Date:** 2026-05-18  
> **Zig Version:** 0.16.0 (confirmed via `build.zig`)  
> **Scope:** Close all critical gaps identified in `mzigRawReader_CSharp_Gap_Analysis.md` to achieve full parity with C# `ThermoFisher.CommonCore.RawFileReader` for modern acquisition modes (Orbitrap Astral DIA, DDA).  
> **zig-docs MCP:** Confirmed loaded and used for all standard library references.

---

## 0. Executive Summary

This roadmap converts the gap analysis into **5 implementation phases**, ordered by dependency and impact. Each phase contains:
- **Objective** — what changes and why
- **Files to modify** — exact paths
- **Specific code changes** — function-level detail
- **Zig std lib references** — confirmed via zig-docs MCP
- **Testing strategy** — how to verify correctness
- **Estimated effort** — relative sizing
- **Exit criteria** — when the phase is "done"

### Phase Dependency Graph

```
Phase 0 (Test Infrastructure)
    │
    ▼
Phase 1 (TrailerScanEvents) ──► Phase 3 (Precursor Metadata)
    │                                 ▲
    ▼                                 │
Phase 2 (FT Profile Decode) ◄─────────┘
    │
    ▼
Phase 4 (Advanced Features)
```

### Effort Summary

| Phase | Focus | Est. Effort | Blocking DIA? |
|-------|-------|-------------|---------------|
| 0 | Test Infrastructure | 1 day | No |
| 1 | TrailerScanEvents | 2–3 days | **Yes** |
| 2 | FT Profile Decode | 4–5 days | **Yes** |
| 3 | Precursor Metadata | 1–2 days | No |
| 4 | Advanced Features | 3–5 days | No |
| **Total** | | **~2 weeks** | |

---

## Phase 0: Testing Infrastructure (1 day)

### Objective
Before touching any parser code, establish a regression test suite that can validate the binary parsing against known-good C# output. This is essential because the changes in Phases 1–3 affect the core data path.

### Files to Create

```
src/tests/
├── test_trailer_events.zig      # Phase 1 tests
├── test_profile_decode.zig      # Phase 2 tests
├── test_metadata.zig            # Phase 3 tests
└── test_utils.zig               # Shared helpers (mmap fixture, C# golden file loader)
```

### Files to Modify

```
build.zig                        # Add test modules
```

### Specific Changes

#### 0.1 Add Test Harness to `build.zig`

Add a `test-all` step that runs all test modules:

```zig
// In build.zig, after existing unit_tests:
const test_all_mod = b.createModule(.{
    .root_source_file = b.path("src/tests/test_all.zig"),
    .target = target,
    .optimize = .Debug,  // Tests run in Debug for safety
});
// Add all the same imports as exe_mod
test_all_mod.addImport("raw_file", raw_file_mod);
test_all_mod.addImport("advanced_packet", packet_mod);
test_all_mod.addImport("scan_event", scan_event_mod);
test_all_mod.addImport("trailer_events", trailer_events_mod);
test_all_mod.addImport("app_state", app_state_mod);

const test_all = b.addTest(.{ .root_module = test_all_mod });
const test_all_step = b.step("test-all", "Run full test suite");
test_all_step.dependOn(&b.addRunArtifact(test_all).step);
```

**Zig std lib reference:** `std.testing` (built-in, no import needed) for `try testing.expectEqual`, `testing.allocator`, etc.

#### 0.2 Create `src/tests/test_utils.zig`

Shared helper to memory-map a `.raw` file and return the `ByteReader` + metadata:

```zig
const std = @import("std");
const raw = @import("raw_file");

pub const TestFixture = struct {
    file: std.fs.File,
    mm: std.Io.File.MemoryMap,
    file_revision: u16,
    run_header: raw.RunHeader,
    
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !TestFixture {
        // Open file, create memory map, read header + run header
        // Return populated struct
    }
    
    pub fn close(self: *TestFixture) void {
        self.mm.destroy();
        self.file.close();
    }
};
```

**Zig std lib reference:**  
- `std.fs.cwd().openFile()` — file opening  
- `std.Io.File.createMemoryMap()` — already used in `app_state.zig`  
- `std.mem.readInt()` — already used everywhere; signature confirmed via zig-docs:
  ```zig
  pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8, endian: Endian) T
  ```

#### 0.3 Generate Golden Files

Use the existing C# `ThermoFisher.CommonCore.RawFileReader` DLL (already in `vendor/`) to dump expected values:

```csharp
// C# golden file generator (add to a small C# project)
using var reader = RawFileReaderFactory.ReadFile(path);
reader.SelectInstrument(Device.MS, 1);
for (int i = 1; i <= reader.RunHeaderEx.LastSpectrum; i++) {
    var scan = reader.GetScanEvent(i);
    Console.WriteLine($"{i}\t{scan.MSOrder}\t{scan.MassRange[0].Low}\t{scan.MassRange[0].High}");
    // Dump precursor, reaction info, etc.
}
```

Store output as `test_data/golden_<filename>.tsv`.

### Exit Criteria
- [ ] `zig build test-all` runs and passes a basic "file opens without error" test on at least 3 real RAW files (DDA, DIA, small test file).
- [ ] Golden files exist for at least one DDA and one DIA file.

---

## Phase 1: Fix TrailerScanEvents (2–3 days)

### Objective
Replace the heuristic MS-level inference (`packet_type == FT_PROFILE ? 1 : 2`) with authoritative metadata from the `TrailerScanEvents` table. This fixes MS level assignment for all acquisition modes and enables precursor metadata extraction.

### Background

The C# `TrailerScanEvents` table lives at `RunHeader.TrailerScanEventsPos`. Its layout:

```
Offset 0:      i32  num_events          (= num_scans)
Offset 4:      i32[] scan_to_unique_idx  (one per scan, indexes into unique_events)
Offset 4+N*4:  ScanEvent[] unique_events (deduplicated, variable-length)
```

The `ScanIndexEntry.trailer_offset` field is **NOT a file offset** — it is an index into the `scan_to_unique_idx` array.

### Files to Modify

```
src/raw_core/trailer_events.zig   # Fix parsing logic
src/raw_core/raw_file.zig         # Ensure RunHeader exposes TrailerScanEventsPos
src/app_state.zig                 # Integrate trailer parsing into openFile()
```

### Specific Changes

#### 1.1 Fix `trailer_events.zig::parseTrailerScanEvents()`

Current bug: the function reads events sequentially starting at `trailer_pos`, ignoring the `scan_to_unique_idx` array. It should:

1. Read `num_events` at `trailer_pos`.
2. Read the `scan_to_unique_idx` array (`num_scans` × `i32`).
3. Determine the number of **unique** events by finding `max(scan_to_unique_idx) + 1`.
4. Parse exactly that many `ScanEvent` objects sequentially.
5. Store the mapping.

**Implementation sketch:**

```zig
pub fn parseTrailerScanEvents(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    trailer_pos: u64,
    num_scans: usize,
    file_revision: u16,
) raw.RawResolveError!TrailerScanEvents {
    var pos: usize = @intCast(trailer_pos);
    
    // 1. Read num_events
    const num_events = std.mem.readInt(i32, mm.memory[pos..][0..4], .little);
    pos += 4;
    
    if (num_events < 0 or @as(usize, @intCast(num_events)) != num_scans) {
        // Some files may have mismatched counts; proceed with num_scans
        @branchHint(.unlikely);
    }
    
    // 2. Read scan_to_unique_idx array
    const scan_to_unique = try allocator.alloc(usize, num_scans);
    errdefer allocator.free(scan_to_unique);
    
    var max_unique: i32 = -1;
    for (0..num_scans) |i| {
        const idx = std.mem.readInt(i32, mm.memory[pos + i * 4 ..][0..4], .little);
        if (idx < 0) return raw.RawResolveError.InvalidRawFileInfo;
        scan_to_unique[i] = @intCast(idx);
        if (idx > max_unique) max_unique = idx;
    }
    pos += num_scans * 4;
    
    const num_unique = @as(usize, @intCast(max_unique)) + 1;
    
    // 3. Parse unique events
    const unique_events = try allocator.alloc(scan_event.ScanEvent, num_unique);
    errdefer {
        for (unique_events) |*evt| evt.deinit(allocator);
        allocator.free(unique_events);
    }
    
    var event_idx: usize = 0;
    while (event_idx < num_unique) : (event_idx += 1) {
        const result = try scan_event.parseScanEvent(allocator, mm, pos, file_revision);
        unique_events[event_idx] = result.event;
        pos += @intCast(result.bytes_read);
    }
    
    return TrailerScanEvents{
        .unique_events = unique_events,
        .scan_to_unique = scan_to_unique,
    };
}
```

**Zig std lib reference:**  
- `std.mem.readInt()` — confirmed signature above  
- `@branchHint(.unlikely)` — builtin for branch prediction (already used in codebase)  
- `std.ArrayList` — for temporary event accumulation if needed; confirmed via zig-docs:
  ```zig
  pub fn ArrayList(comptime T: type) type
  ```

#### 1.2 Update `AppState.openFile()` in `app_state.zig`

Replace the no-op `parseScanTrailersAtOpen()` with real trailer parsing:

```zig
// In openFile(), after scan index is built:
if (run_header.trailer_scan_events_pos > 0) {
    self.trailers = trailer_events.parseTrailerScanEvents(
        self.allocator,
        mm,
        run_header.trailer_scan_events_pos,
        self.scans.len,
        file_revision,
    ) catch |err| {
        std.log.warn("Failed to parse trailer events: {s}, falling back to heuristic MS levels", .{@errorName(err)});
        self.trailers = null;
    };
}

// After trailers are parsed (or not), set MS levels authoritatively:
for (self.scans, 0..) |*scan, i| {
    if (self.trailers) |t| {
        if (t.getEvent(i)) |evt| {
            scan.ms_level = @intCast(evt.info.ms_order);
            // TODO Phase 3: also set precursor, isolation width, etc.
        } else {
            scan.ms_level = 0; // unknown
        }
    } else {
        // Fallback heuristic (current behavior)
        scan.ms_level = if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
    }
}
```

**Key:** `run_header.trailer_scan_events_pos` must already be read in `raw_file.zig::resolveScan()`. Verify it is present in `RunHeaderStruct`.

#### 1.3 Update `AppState.ensureScanTrailer()`

```zig
pub fn ensureScanTrailer(self: *AppState, scan_index: usize) void {
    if (self.trailers) |*t| {
        if (t.getEvent(scan_index)) |evt| {
            self.scans[scan_index].ms_level = @intCast(evt.info.ms_order);
        }
    }
}
```

### Testing Strategy

Add to `src/tests/test_trailer_events.zig`:

```zig
test "trailer events match C# golden file" {
    const fixture = try TestFixture.open(testing.allocator, "test_data/small_dda.raw");
    defer fixture.close();
    
    const trailers = try trailer_events.parseTrailerScanEvents(
        testing.allocator,
        fixture.mm,
        fixture.run_header.trailer_scan_events_pos,
        fixture.run_header.last_spectrum - fixture.run_header.first_spectrum + 1,
        fixture.file_revision,
    );
    defer trailers.deinit(testing.allocator);
    
    // Compare against golden file
    try testing.expectEqual(@as(u8, 1), trailers.getEvent(0).?.info.ms_order); // First scan is MS1
}
```

### Exit Criteria
- [ ] `TrailerScanEvents` parses correctly on 3+ real files (DDA, DIA, ion trap).
- [ ] MS levels match C# golden files for **every scan** (0 mismatches).
- [ ] Heuristic fallback still works when trailers are absent (edge case).

---

## Phase 2: Implement FT Profile Decoding (4–5 days)

### Objective
Decode FT Profile packets (`packet_type = 21`) into real m/z + intensity arrays. This enables MS1 profile visualization and quantification on Orbitrap/Astral instruments.

### Background

FT Profile packets contain **frequency-domain data**, not mass-domain data. The conversion requires:

1. **Profile segments** (`ProfileSegmentStruct[]`, 24 bytes each) that describe regions of the frequency axis.
2. **Subsegments** within each segment, with `(start_index, word_count, mass_offset)` headers.
3. **Intensity values** as `f32[]`.
4. **Mass calibration coefficients** from `ScanEvent.mass_calibrators`.

The frequency-to-mass formula (from C# `FtProfilePacket.CalculateMass()`):

```
mass = coeff1 / freq + coeff2 / (freq²) + coeff3 / (freq⁴) + massOffset
```

Where `coeff1..coeff3` and `massOffset` are the first 4 values of `mass_calibrators[]`.

### Files to Create

```
src/raw_core/profile_packet.zig   # New file: Profile segment parser + mass cal
```

### Files to Modify

```
src/raw_core/raw_file.zig         # Add ProfileSegmentStruct + SubsegmentHeader
src/raw_core/advanced_packet.zig  # Add profile decode entry point
src/app_state.zig                 # Wire profile decode into loadScan()
```

### Specific Changes

#### 2.1 Add Structs to `raw_file.zig`

```zig
/// ProfileSegmentStruct (24 bytes) — describes a segment of frequency-domain data
pub const ProfileSegment = extern struct {
    base_abscissa: f64,      // Starting frequency
    abscissa_spacing: f64,   // Delta frequency per point
    num_subsegments: u32,    // Number of subsegments
    num_expanded_words: u32, // Total f32 words in this segment
    
    pub fn read(memory: []const u8, offset: u64) !ProfileSegment {
        if (offset + 24 > memory.len) return error.Truncated;
        return .{
            .base_abscissa = std.mem.readVarFloat(f64, .little, memory[offset..][0..8]),
            .abscissa_spacing = std.mem.readVarFloat(f64, .little, memory[offset + 8 ..][0..8]),
            .num_subsegments = std.mem.readInt(u32, memory[offset + 16 ..][0..4], .little),
            .num_expanded_words = std.mem.readInt(u32, memory[offset + 20 ..][0..4], .little),
        };
    }
};

/// Subsegment header (12 bytes)
pub const SubsegmentHeader = extern struct {
    start_index: u32,    // Index into segment
    word_count: u32,     // Number of f32 intensity values
    mass_offset: f32,    // Mass offset for this subsegment
};
```

**Zig std lib reference:**  
- `std.mem.readInt()` — already confirmed  
- For `f64` reads: the codebase already uses direct `@bitCast` or `std.mem.bytesToValue()` patterns. The existing pattern in `reader.zig` is:
  ```zig
  pub fn readF64(self: ByteReader, offset: u64) ReadError!f64 {
      if (offset + 8 > self.bytes.len) return ReadError.Truncated;
      return @bitCast(std.mem.readInt(u64, self.bytes.ptr[@intCast(offset)..][0..8], .little));
  }
  ```
  Use this same pattern for `f64` fields.

#### 2.2 Create `src/raw_core/profile_packet.zig`

```zig
const std = @import("std");
const raw = @import("raw_file");

/// Decode FT Profile packet into m/z + intensity buffers.
/// 
/// Layout after PacketHeader (32 bytes):
///   - ProfileSegmentStruct[] (num_segments × 24 bytes)
///   - SubsegmentHeader[] for each segment (variable)
///   - f32[] intensity values (variable, with zero-padding between subsegments)
///
/// Returns number of points written to buffers.
pub fn decodeProfileIntoBuffers(
    bytes: []const u8,
    data_offset: u64,
    mz_buf: []f64,
    intensity_buf: []f32,
    mass_calibrators: []const f64,
) !usize {
    const h = try raw.readHeader(bytes, data_offset);
    
    // Profile segments start after header
    var pos = data_offset + 32;
    
    // Pre-read all segments
    const segments = try std.heap.stackFallback(256, std.heap.page_allocator)
        .get().alloc(raw.ProfileSegment, h.num_segments);
    defer std.heap.stackFallback(256, std.heap.page_allocator).get().free(segments);
    
    for (0..h.num_segments) |i| {
        segments[i] = try raw.ProfileSegment.read(bytes, pos);
        pos += 24;
    }
    
    // Now process each segment, reading subsegment headers and expanding
    var total_points: usize = 0;
    for (segments) |seg| {
        var subseg_pos = pos;
        var segment_point_idx: u32 = 0;
        
        for (0..seg.num_subsegments) |_| {
            const sub = raw.SubsegmentHeader{
                .start_index = std.mem.readInt(u32, bytes[subseg_pos..][0..4], .little),
                .word_count = std.mem.readInt(u32, bytes[subseg_pos + 4 ..][0..4], .little),
                .mass_offset = @bitCast(std.mem.readInt(u32, bytes[subseg_pos + 8 ..][0..4], .little)),
            };
            subseg_pos += 12;
            
            // Zero-pad from current position to sub.start_index
            while (segment_point_idx < sub.start_index) : (segment_point_idx += 1) {
                if (total_points >= mz_buf.len) return error.BufferTooSmall;
                mz_buf[total_points] = calculateMass(segment_point_idx, seg, mass_calibrators);
                intensity_buf[total_points] = 0.0;
                total_points += 1;
            }
            
            // Copy intensity values
            for (0..sub.word_count) |w| {
                if (total_points >= mz_buf.len) return error.BufferTooSmall;
                const intensity = @bitCast(std.mem.readInt(u32, bytes[subseg_pos + w * 4 ..][0..4], .little));
                mz_buf[total_points] = calculateMass(segment_point_idx, seg, mass_calibrators);
                intensity_buf[total_points] = intensity;
                total_points += 1;
                segment_point_idx += 1;
            }
            subseg_pos += sub.word_count * 4;
        }
        
        // Zero-pad remaining to num_expanded_words
        while (segment_point_idx < seg.num_expanded_words) : (segment_point_idx += 1) {
            if (total_points >= mz_buf.len) return error.BufferTooSmall;
            mz_buf[total_points] = calculateMass(segment_point_idx, seg, mass_calibrators);
            intensity_buf[total_points] = 0.0;
            total_points += 1;
        }
        
        pos = subseg_pos;
    }
    
    return total_points;
}

/// C#: FtProfilePacket.CalculateMass()
fn calculateMass(point_idx: u32, seg: raw.ProfileSegment, cal: []const f64) f64 {
    std.debug.assert(cal.len >= 4);
    const freq = seg.base_abscissa + @as(f64, @floatFromInt(point_idx)) * seg.abscissa_spacing;
    const freq2 = freq * freq;
    const freq4 = freq2 * freq2;
    return cal[0] / freq + cal[1] / freq2 + cal[2] / freq4 + cal[3];
}
```

**Zig std lib reference:**  
- `@floatFromInt()` — builtin, already used in codebase  
- `@bitCast()` — builtin, already used for f32/f64 reads  
- `std.debug.assert()` — for debug-build invariants  
- `std.heap.stackFallback()` — for small temporary allocations without heap pressure:
  ```zig
  // stackFallback returns a FallbackAllocator that tries the stack first,
  // then falls back to the given allocator if the stack buffer is too small.
  ```

#### 2.3 Wire into `AppState.loadScan()`

In `app_state.zig`, replace the empty-profile branch:

```zig
// OLD:
if (packet_type == raw.PACKET_TYPE_FT_PROFILE) {
    self.current_spectrum = .{ ... .num_points = 0 };
    return;
}

// NEW:
if (packet_type == raw.PACKET_TYPE_FT_PROFILE) {
    // Get mass calibrators from trailer
    var calibrators: []const f64 = &[_]f64{};
    if (self.trailers) |t| {
        if (t.getEvent(scan_index)) |evt| {
            calibrators = evt.mass_calibrators;
        }
    }
    
    if (calibrators.len < 4) {
        std.log.warn("Profile packet for scan {} has no mass calibrators, cannot convert frequencies", .{scan_index});
        self.current_spectrum = .{ ... .num_points = 0 };
        return;
    }
    
    const num_points = try profile_packet.decodeProfileIntoBuffers(
        packet_slice, 0,
        reuse_mz, reuse_intensity,
        calibrators,
    );
    
    // Copy to owned arrays (same pattern as centroid path)
    // ...
    return;
}
```

**Important:** Profile packets can be **very large** (MS1 full scans = millions of points). The reusable buffer pattern (`reuse_mz`, `reuse_intensity`) already handles this. Ensure `reuse_mz.len` is large enough — the `decodeProfileIntoBuffers` function returns `error.BufferTooSmall` if not.

#### 2.4 Handle Buffer Sizing

Profile spectra can exceed centroid spectra by 10–100× in point count. In `AppState.init()`, increase default buffer sizes:

```zig
// Current (centroid-optimized):
// self.reuse_mz = try allocator.alloc(f64, 65536);

// Profile-aware:
self.reuse_mz = try allocator.alloc(f64, 4_000_000);  // 4M points = ~32 MB
self.reuse_intensity = try allocator.alloc(f32, 4_000_000);
```

Or better: grow buffers dynamically when `decodeProfileIntoBuffers` returns `error.BufferTooSmall`.

### Testing Strategy

Add to `src/tests/test_profile_decode.zig`:

```zig
test "profile decode produces monotonically increasing m/z" {
    // Open a known DIA file with MS1 profile scans
    const fixture = try TestFixture.open(testing.allocator, "test_data/dia_ms1_profile.raw");
    defer fixture.close();
    
    // Find first MS1 scan
    const scan_idx = // ... find scan with packet_type == FT_PROFILE
    
    const mm = fixture.mm;
    const resolved = try raw.resolveScan(...);
    const packet = mm.memory[resolved.packet_offset..resolved.packet_offset + resolved.packet_size];
    
    var mz_buf: [4_000_000]f64 = undefined;
    var int_buf: [4_000_000]f32 = undefined;
    
    const n = try profile_packet.decodeProfileIntoBuffers(
        packet, 0, &mz_buf, &int_buf, &[_]f64{ ... },
    );
    
    // Verify monotonically increasing m/z
    for (1..n) |i| {
        try testing.expect(mz_buf[i] > mz_buf[i - 1]);
    }
    
    // Verify some intensity values are non-zero (not all padding)
    var non_zero_count: usize = 0;
    for (int_buf[0..n]) |int| {
        if (int > 0) non_zero_count += 1;
    }
    try testing.expect(non_zero_count > n / 10); // At least 10% non-zero
}
```

### Performance Considerations

Profile decode is inherently slower than centroid decode because:
1. It processes 10–100× more points per scan.
2. Each point requires a `calculateMass()` call (4 divisions + adds).

**Optimization opportunities:**
- Use `@Vector(4, f64)` SIMD to compute 4 frequencies at once.
- Pre-compute `1/freq`, `1/freq²`, `1/freq⁴` for vectorized mass calculation.
- Consider a lookup table for small frequency ranges.

**Zig std lib reference for SIMD:**  
- `@Vector(len, Element)` — builtin, confirmed via zig-docs:
  ```zig
  @Vector(len: comptime_int, Element: type) type
  ```
- `@setRuntimeSafety(false)` — already used in `advanced_packet.zig` hot path.

### Exit Criteria
- [ ] MS1 profile scans display correctly in GUI (not empty).
- [ ] m/z values are monotonically increasing within each scan.
- [ ] m/z range matches C# output for same scan (±0.01 ppm tolerance).
- [ ] Benchmark: profile decode achieves ≥50M points/sec (acceptable for interactive use).

---

## Phase 3: Complete ScanEvent & Precursor Metadata (1–2 days)

### Objective
Extend `ScanEventInfo` from 40 → 96 bytes and propagate precursor metadata (m/z, isolation width, collision energy) into the GUI.

### Files to Modify

```
src/raw_core/raw_file.zig         # Extend ScanEventInfo struct
src/app_state.zig                 # Add precursor fields to ScanInfo
src/gui/scan_list.zig             # Display precursor info
```

### Specific Changes

#### 3.1 Extend `ScanEventInfo` in `raw_file.zig`

Current (40 bytes):
```zig
pub const ScanEventInfo = extern struct {
    scan_type: i32,           // offset 0
    mass_analyzer_type: i16,  // offset 4
    _pad1: i16,               // offset 6
    ms_order: i32,            // offset 8 — wait, this doesn't match C# layout
    // ... only 40 bytes total
};
```

**Correct C# layout (96 bytes, rev ≥ 65):**
```
Offset 0:   int   nScanType
Offset 4:   short nMassAnalyzerType
Offset 6:   short _padding
Offset 8:   int   nMSOrder
Offset 12:  int   nPolarity
Offset 16:  int   nPrecursorIndependent
Offset 20:  int   nData
Offset 24:  int   nChargeState
Offset 28:  int   nIonizationMode
Offset 32:  int   nCorona
Offset 36:  int   nDetector
Offset 40:  int   nScanMode
Offset 44:  int   nMultipleInject
Offset 48:  int   nZoomScan
Offset 52:  int   nAGC
Offset 56:  int[] anDissociationType (4 ints = 16 bytes) — actually this is more complex
```

Wait — I need to be more careful. The C# struct has `int[]` arrays which are **pointers** in the struct (8 bytes on x64), not inline arrays. But in the binary file, these are **count-prefixed inline arrays** that follow the fixed-size portion of the struct.

Actually, looking at the C# source more carefully: `ScanEventInfoStruct` is a **sequential layout struct** with `Pack = 4`. The arrays (`anDissociationType`, `anDissociationEnergy`, etc.) are declared as `int[]` in C# but during marshaling they become **variable-length data after the struct**. The struct itself is read as a fixed-size blob, then the arrays are read sequentially after it.

Let me reconsider. From the C# code:
```csharp
[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct ScanEventInfoStruct
{
    public int nScanType;
    public MassAnalyzerType nMassAnalyzerType;  // short
    public MSOrderType nMSOrder;                // short
    public PolarityType nPolarity;              // int
    public int nPrecursorIndependent;
    public DataType nData;                      // int
    public int nChargeState;
    public IonizationModeType nIonizationMode;  // int
    public int nCorona;
    public int nDetector;
    public ScanModeType nScanMode;              // int
    public int nMultipleInject;
    public int nZoomScan;
    public int nAGC;
    // Then arrays follow in the file, but NOT in the struct
}
```

Actually, the C# code may have these arrays **inside** the struct for the binary read. Let me think about this differently. The `scan_event.zig::parseScanEvent()` already reads `info` (96 bytes), then reads `reactions`, `mass_ranges`, `mass_calibrators`, etc. as **separate** length-prefixed arrays after the fixed struct.

So the `ScanEventInfo` struct is the **fixed-size prefix** (96 bytes), and all variable-length data follows it. The current code reads 96 bytes for `info` but the struct definition only declares the first 40 bytes' worth of fields. We need to **add the remaining fields** to the struct definition so they can be accessed.

Here's the corrected struct:

```zig
pub const ScanEventInfo = extern struct {
    // First 40 bytes (already defined)
    scan_type: i32,              // offset 0
    mass_analyzer_type: i16,     // offset 4
    _pad1: i16,                  // offset 6 (alignment)
    ms_order: i32,               // offset 8
    polarity: i32,               // offset 12
    precursor_independent: i32,  // offset 16
    data_type: i32,              // offset 20
    charge_state: i32,           // offset 24
    ionization_mode: i32,        // offset 28
    corona: i32,                 // offset 32
    detector: i32,               // offset 36
    
    // Bytes 40–95 (missing fields)
    scan_mode: i32,              // offset 40
    multiple_inject: i32,        // offset 44
    zoom_scan: i32,              // offset 48
    agc: i32,                    // offset 52
    
    // Dissociation arrays (these are tricky — in C# they may be fixed-size
    // inline arrays within the struct, or they may follow the struct)
    // From C# source analysis: the struct is 96 bytes total.
    // The remaining 40 bytes (56..95) contain:
    dissociation_types: [4]i32,      // offset 56 (4 × 4 = 16 bytes)
    dissociation_energies: [4]i32,   // offset 72 (4 × 4 = 16 bytes)
    _pad2: i32,                      // offset 88 (4 bytes)
    _pad3: i32,                      // offset 92 (4 bytes)
    // Total: 96 bytes
};
```

Actually, I'm not 100% sure about the dissociation array layout. Let me be conservative and just add the fields we **know** are needed, padding the rest:

```zig
pub const ScanEventInfo = extern struct {
    scan_type: i32,
    mass_analyzer_type: i16,
    _pad1: i16,
    ms_order: i32,
    polarity: i32,
    precursor_independent: i32,
    data_type: i32,
    charge_state: i32,
    ionization_mode: i32,
    corona: i32,
    detector: i32,
    scan_mode: i32,
    multiple_inject: i32,
    zoom_scan: i32,
    agc: i32,
    // Pad to 96 bytes total
    _reserved: [10]i32,  // 40 bytes, offsets 56–95
    
    comptime {
        std.debug.assert(@sizeOf(ScanEventInfo) == 96);
    }
};
```

**Zig std lib reference:**  
- `@sizeOf()` — builtin, confirmed via zig-docs:
  ```zig
  @sizeOf(comptime T: type) comptime_int
  ```
- `std.debug.assert()` — compile-time assertion for struct size validation.

#### 3.2 Add Precursor Fields to `ScanInfo`

```zig
pub const ScanInfo = struct {
    scan_number: i32,
    rt: f64,
    ms_level: u8,
    packet_type: u32,
    packet_offset: u64,
    packet_size: u64,
    // NEW FIELDS:
    precursor_mz: ?f64 = null,
    isolation_width: ?f64 = null,
    collision_energy: ?f64 = null,
    charge_state: ?i32 = null,
};
```

#### 3.3 Populate in `app_state.zig::openFile()`

After trailers are parsed:

```zig
for (self.scans, 0..) |*scan, i| {
    if (self.trailers) |t| {
        if (t.getEvent(i)) |evt| {
            scan.ms_level = @intCast(evt.info.ms_order);
            scan.charge_state = if (evt.info.charge_state > 0) evt.info.charge_state else null;
            
            if (evt.reactions.len > 0) {
                const rxn = evt.reactions[0];
                scan.precursor_mz = rxn.precursor_mass;
                scan.isolation_width = rxn.isolation_width;
                scan.collision_energy = rxn.collision_energy;
            }
        }
    }
}
```

#### 3.4 Display in GUI

In `src/gui/scan_list.zig`, add columns for precursor m/z and charge state:

```zig
// In the scan list table rendering:
if (scan.precursor_mz) |mz| {
    // Draw "712.35" in Precursor column
}
if (scan.charge_state) |z| {
    // Draw "2+" in Charge column
}
```

### Exit Criteria
- [ ] `ScanEventInfo` struct size is exactly 96 bytes (`@sizeOf() == 96`).
- [ ] Precursor m/z matches C# golden file (±0.001).
- [ ] Charge state matches C# golden file for all scans.
- [ ] GUI scan list shows precursor m/z and charge state columns.

---

## Phase 4: Advanced Features (3–5 days)

### 4.1 XIC Extraction

Extracted Ion Chromatogram: given a target m/z and ppm tolerance, return intensity vs. RT across all scans (or MS1-only scans).

```zig
// In src/raw_core/chromatogram.zig or new src/raw_core/xic.zig
pub fn extractXIC(
    allocator: std.mem.Allocator,
    app: *AppState,
    target_mz: f64,
    ppm_tolerance: f64,
    ms_level_filter: ?u8,  // null = all, 1 = MS1 only, etc.
) !Chromatogram {
    const tol_da = target_mz * ppm_tolerance / 1_000_000.0;
    const n = app.scans.len;
    
    var rt_list = std.ArrayList(f64).init(allocator);
    var int_list = std.ArrayList(f64).init(allocator);
    defer rt_list.deinit();
    defer int_list.deinit();
    
    for (app.scans, 0..) |scan, i| {
        if (ms_level_filter) |lvl| {
            if (scan.ms_level != lvl) continue;
        }
        
        // Use loadScanBulk for zero-allocation decode
        const num_points = try app.loadScanBulk(i);
        
        var total_intensity: f64 = 0;
        for (0..num_points) |p| {
            const mz = app.reuse_mz[p];
            if (@abs(mz - target_mz) <= tol_da) {
                total_intensity += @as(f64, app.reuse_intensity[p]);
            }
        }
        
        try rt_list.append(scan.rt);
        try int_list.append(total_intensity);
    }
    
    return Chromatogram{
        .rt = try rt_list.toOwnedSlice(),
        .intensity = try int_list.toOwnedSlice(),
        .ms_level = try allocator.alloc(u8, rt_list.items.len), // TODO
        .num_points = rt_list.items.len,
    };
}
```

**Zig std lib reference:**  
- `std.ArrayList` — confirmed via zig-docs  
- `@abs()` — builtin, confirmed via zig-docs:
  ```zig
  @abs(value: anytype) @TypeOf(value)
  ```

### 4.2 Cross-Platform GUI Abstraction

Current: All GUI code is hardcoded Win32 (`src/gui/*.zig`).

Goal: Abstract platform-specific calls behind an interface so a Linux/macOS backend can be added later.

```zig
// src/gui/platform.zig
pub const Platform = struct {
    createWindow: *const fn (width: i32, height: i32, title: []const u8) PlatformError!Window,
    destroyWindow: *const fn (window: Window) void,
    // ... other platform ops
};

pub const Window = opaque {};
```

Then `win32_common.zig` implements this interface. A future `glfw_platform.zig` or `sdl_platform.zig` can implement the same interface.

**Note:** This is a large refactor. Consider using an existing cross-platform Zig GUI library:
- `zig-glfw` + OpenGL
- `microui-zig` (immediate mode)
- Web-based frontend (Zig HTTP server + browser)

### 4.3 Legacy Version Support (Rev < 65)

Only implement if user demand exists. The current code has partial paths for rev 64 and < 64 but they are untested. To support them:

1. Add `RunHeaderStructV1` through `V4` (different sizes and field layouts).
2. Add `ScanIndexStructV1` through `V3` (72, 80, 88 bytes).
3. Add version-dispatch logic in `resolveScan()`.

This is ~2 days of mechanical translation from C# struct definitions.

---

## Appendix A: Zig Std Lib Quick Reference

All entries confirmed via zig-docs MCP.

| Function / Type | Module | Use Case |
|-----------------|--------|----------|
| `std.mem.readInt(T, buf, endian)` | `std.mem` | Binary integer parsing (u32, i32, u64) |
| `@bitCast(u64) → f64` | builtin | Binary float parsing |
| `std.ArrayList(T)` | `std` | Dynamic arrays (event lists, XIC points) |
| `std.heap.ArenaAllocator` | `std.heap` | Bulk allocation with single free |
| `@Vector(len, T)` | builtin | SIMD operations (profile mass calc) |
| `@setRuntimeSafety(false)` | builtin | Hot-path optimization (centroid decode) |
| `@sizeOf(T)` | builtin | Compile-time struct size validation |
| `@floatFromInt(i)` | builtin | Integer to float conversion |
| `std.math.pow(T, x, y)` | `std.math` | Frequency power calculations |
| `@abs(x)` | builtin | Absolute value (XIC tolerance check) |
| `std.unicode.utf16LeToUtf8Alloc` | `std.unicode` | Wide string conversion (already used) |

---

## Appendix B: File Revision Support Matrix

| Revision | Era | ScanIndex Size | RunHeader Size | Zig Status |
|----------|-----|---------------|----------------|------------|
| < 25 | LCQ (pre-2005) | 72 bytes (32-bit offsets) | V1 (~580 bytes) | ❌ Unsupported |
| 25–63 | Early LTQ/Orbitrap | 72 bytes | V2–V4 | ❌ Unsupported |
| 64 | Orbitrap Classic | 80 bytes | V4 | ⚠️ Partial (untested) |
| ≥ 65 | Modern Orbitrap/Astral | 88 bytes | V5 (1012 bytes) | ✅ Full support |

**Recommendation:** Only implement < 65 if a real user asks for it. All modern instruments produce rev ≥ 65 files.

---

## Appendix C: C# → Zig Type Mapping

| C# Type | Size | Zig Type | Notes |
|---------|------|----------|-------|
| `bool` | 1 byte (marshaled) | `bool` | C# `bool` in structs = 4 bytes if `Pack = 4`, but `MarshalAs(UnmanagedType.U1)` = 1 byte |
| `byte` | 1 | `u8` | |
| `short` | 2 | `i16` | |
| `ushort` | 2 | `u16` | |
| `int` | 4 | `i32` | |
| `uint` | 4 | `u32` | |
| `long` | 8 | `i64` | |
| `ulong` | 8 | `u64` | |
| `float` | 4 | `f32` | |
| `double` | 8 | `f64` | |
| `string` | variable | `[]u8` (UTF-8) | C# = length-prefixed UTF-16LE |
| `T[]` | variable | `[]T` | C# = length-prefixed array |
| `enum` | 4 (default) | `i32` or `u32` | Check `MarshalAs` attribute |

---

## Summary Checklist

### Phase 0 — Testing
- [ ] `zig build test-all` step exists
- [ ] `TestFixture` helper created
- [ ] Golden files for DDA + DIA
- [ ] Basic "file opens" test passes

### Phase 1 — Trailers
- [ ] `parseTrailerScanEvents()` reads `scan_to_unique_idx` array
- [ ] `trailer_offset` treated as index, not file offset
- [ ] `AppState.openFile()` calls trailer parser
- [ ] MS levels match C# for all scans on test files

### Phase 2 — Profile
- [ ] `ProfileSegment` struct (24 bytes) defined
- [ ] `SubsegmentHeader` struct (12 bytes) defined
- [ ] `decodeProfileIntoBuffers()` implemented
- [ ] `calculateMass()` implements C# formula
- [ ] `AppState.loadScan()` wires profile path
- [ ] Buffer sizes increased for profile spectra
- [ ] MS1 scans display in GUI

### Phase 3 — Metadata
- [ ] `ScanEventInfo` extended to 96 bytes
- [ ] `ScanInfo` gets precursor/isolation/CE/charge fields
- [ ] `AppState.openFile()` populates fields from trailers
- [ ] GUI scan list shows precursor m/z

### Phase 4 — Advanced
- [ ] XIC extraction function
- [ ] Cross-platform GUI interface (optional)
- [ ] Legacy version support (optional)
