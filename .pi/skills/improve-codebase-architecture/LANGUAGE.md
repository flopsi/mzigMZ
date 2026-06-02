# Language

Shared vocabulary for every suggestion this skill makes. Use these terms exactly — don't substitute "component," "service," "API," or "boundary." Consistent language is the whole point.

## Terms

**Module**
Anything with an interface and an implementation. Deliberately scale-agnostic — applies equally to a function, class, package, or tier-spanning slice.
_Avoid_: unit, component, service.

**Interface**
Everything a caller must know to use the module correctly. Includes the type signature, but also invariants, ordering constraints, error modes, required configuration, and performance characteristics.
_Avoid_: API, signature (too narrow — those refer only to the type-level surface).

**Implementation**
What's inside a module — its body of code. Distinct from **Adapter**: a thing can be a small adapter with a large implementation (a Postgres repo) or a large adapter with a small implementation (an in-memory fake). Reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth**
Leverage at the interface — the amount of behaviour a caller (or test) can exercise per unit of interface they have to learn. A module is **deep** when a large amount of behaviour sits behind a small interface. A module is **shallow** when the interface is nearly as complex as the implementation.

**Seam** _(from Michael Feathers)_
A place where you can alter behaviour without editing in that place. The *location* at which a module's interface lives. Choosing where to put the seam is its own design decision, distinct from what goes behind it.
_Avoid_: boundary (overloaded with DDD's bounded context).

**Adapter**
A concrete thing that satisfies an interface at a seam. Describes *role* (what slot it fills), not substance (what's inside).

**Leverage**
What callers get from depth. More capability per unit of interface they have to learn. One implementation pays back across N call sites and M tests.

**Locality**
What maintainers get from depth. Change, bugs, knowledge, and verification concentrate at one place rather than spreading across callers. Fix once, fixed everywhere.

## Principles

- **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, mockable, swappable parts — they just aren't part of the interface. A module can have **internal seams** (private to its implementation, used by its own tests) as well as the **external seam** at its interface.
- **The deletion test.** Imagine deleting the module. If complexity vanishes, the module wasn't hiding anything (it was a pass-through). If complexity reappears across N callers, the module was earning its keep.
- **The interface is the test surface.** Callers and tests cross the same seam. If you want to test *past* the interface, the module is probably the wrong shape.
- **One adapter means a hypothetical seam. Two adapters means a real one.** Don't introduce a seam unless something actually varies across it.

## Relationships

- A **Module** has exactly one **Interface** (the surface it presents to callers and tests).
- **Depth** is a property of a **Module**, measured against its **Interface**.
- A **Seam** is where a **Module**'s **Interface** lives.
- An **Adapter** sits at a **Seam** and satisfies the **Interface**.
- **Depth** produces **Leverage** for callers and **Locality** for maintainers.

## Rejected framings

- **Depth as ratio of implementation-lines to interface-lines** (Ousterhout): rewards padding the implementation. We use depth-as-leverage instead.
- **"Interface" as the TypeScript `interface` keyword or a class's public methods**: too narrow — interface here includes every fact a caller must know.
- **"Boundary"**: overloaded with DDD's bounded context. Say **seam** or **interface**.

---

## Domain Terms (mzigRead)

Project-specific vocabulary for this codebase. Use these exactly when discussing the decode pipeline, file format, or viewer state. Generic architecture terms above take precedence for cross-project suggestions.

**Packet**
Binary record containing one scan's mass spectrum. Two variants: FT_CENTROID (type 20, peak list) and FT_PROFILE (type 21, raw frequencies). Distinct from **scan** — a scan is a row in the scan index; a packet is the binary data.
_Avoid_: scan (when referring to the binary data), spectrum record.

**PacketHeader**
32-byte header at the start of each packet. Contains word counts (segment, profile, centroid, expansion, noise) and a feature word. Determines packet size and decode strategy (centroid vs profile, accurate-mass vs standard).

**Centroid decode**
Decodes the centroid word stream (variable-length entries: 8 bytes standard, 12 bytes accurate-mass) into arrays of m/z + intensity + PeakFeatures. One of two decode paths in ScanDecoder.

**Profile decode**
Converts raw TOF/frequency data to m/z using mass calibrators (polynomial coefficients from the ScanEvent). One of two decode paths in ScanDecoder. Optionally returns raw frequencies before calibration for custom re-calibration.

**SIMD min/max reduction**
Vectorised pass after decode computing min/max m/z and max intensity across all peaks. Process 4× f64 for m/z bounds, 8× f32 for intensity max. Tail scalar loop for remainder.

**Spectrum**
In-memory representation of a decoded scan: `[]f64` m/z, `[]f32` intensity, `[]PeakFeatures` (centroid only), and scalar bounds (mz_min, mz_max, intensity_max). Owned by AppState via the decoder's cache.

**Spectrum cache**
LRU cache of 8 decoded spectra in ScanDecoder. Round-robin slot eviction. Avoids re-decode on navigation between recently-viewed scans. Managed entirely by ScanDecoder — AppState holds it via `decoder.cache`.

**Destination**
Enum encoding ownership of decoded data: `.owned` (caller frees), `.arena` (arena frees), `.reuse_buffers` (grow-only, no free), `.reuse_with_freq` (also populates frequency array for profile re-calibration). Controls ScanDecoder's buffer allocation strategy.

**DecodeIntermediate**
Intermediate result from ScanDecoder: num_points + slices into internal buffers + computed bounds. Caller post-processes based on Destination (ownership copy, label parse, cache update).

**ScanDecoder module**
Single-point-of-truth for the decode pipeline: packet header read → peak count estimate → dispatch to centroid or profile decoder → SIMD bounds. Extracted from four inline copies in AppState's `loadScan*` methods. Owned by AppState.

**PeakFeatures**
Per-peak metadata: charge, resolution (FWHM), interpolated noise level, interpolated baseline level, SNR, and flags (fragmented, merged, reference, exception, saturated). Decoded from centroid packet's feature words and expansion/noise sections.

**ScanEvent**
Per-scan event metadata from the ScanEvent table at file end. Contains mass calibrators (polynomial coefficients), isolation width, collision energy, fragmentation type, mass ranges, reactions, and name. Deduplicated per unique event via TrailerScanEvents.

**TrailerScanEvents**
Deduplication table mapping scan index → unique ScanEvent. Built by parsing the ScanEvent table at file end, comparing events for equality, storing one copy per unique event and an index per scan. Used by ScanDecoder for mass calibrators.

**Trailer labels**
Per-scan key-value pairs at offsets in each ScanIndexEntry.trailer_offset. Two important ones: label 9 (filter string, e.g. `"FTMS + p NSI Full ms [400.0000-800.0000]"`), label 18 (charge state). Distinct from ScanEvent — different file structure, different metadata.

**Ground truth**
ThermoRawFileParser (.NET) as the reference implementation. Every decode output must match it. The 8.6 GB Astral file (275,462 scans) is the primary verification target.

**Mmap-first**
Using memory-mapped I/O as the primary file access. The OS handles demand paging; ScanDecoder reads from `mm.memory[offset..]` slices — no pread syscalls in the hot path.

**ZoomState**
Current x-axis (m/z) and y-axis (intensity) viewport for the spectrum canvas. Preserved across scan loads.

**Chromatogram**
TIC or BPC data: `[]f64` retention times + `[]f64` intensity + `[]u8` MS levels. Derived from scan index fields (no packet decode needed). MS level filter applied at render time.

## Project-Specific Principles

- **Deletion test for pass-through modules**: if a module's deletion means the same logic appears in every caller, the module was earning its keep. Applied to chromatogram.zig (deleted, inlined into AppState) and ByteReader pass-through (deleted, inlined).
- **Four-way duplication is the signal for extraction**: ScanDecoder was extracted after four `loadScan*` methods each had an inline copy of the decode pipeline. This is the empirical rule-of-three for this codebase.
- **Ground truth drives decode correctness**: no speculative optimisation until output matches ThermoRawFileParser. The Astral benchmark is the gate.
- **Reuse buffers: borrow, don't copy**: ScanDecoder borrows AppState's allocation state via `setReuseBuffers()` rather than owning independent memory. This keeps allocation lifetime in one place.

## Relationships (mzigRead)

- `RawFile` (mmap + scan index) → parsed by `AppState` into `scans[]`
- `AppState` → delegates decode to `ScanDecoder`
- `ScanDecoder` → dispatches to `advanced_packet` (centroid) or `profile_packet` (profile)
- `ScanEvent table` → parsed into `TrailerScanEvents`; calibrators passed to profile decoder
- `Trailer labels` → parsed independently; used for filter strings and charge state
- `Spectrum cache` lives in `ScanDecoder`, owned by `AppState.decoder`
