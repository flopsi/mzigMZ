/// High-level RAW file reader. Owns the memory-map for the entire
/// .raw file and resolves all file-shape metadata (file revision,
/// controller table, scan list, instrument id, creation time) once
/// at open. Two adapters: the GUI/bench open a `RawFile` and walk
/// the scan table, the CLI does one-shot lookups via `scanAt`.
///
/// Before this module existed, `app_state.openFile` re-implemented
/// the same flow as `raw_file.resolveScan` against the mmap. The
/// duplication is gone; both adapters call into this module.
const std = @import("std");
const raw = @import("raw_file");
const spec_file_header = @import("spec/file_header");
const spec_instrument_id = @import("spec/instrument_id");
const unicode = @import("unicode_utils");

pub const RawFileError = error{
    FileTooLarge,
    Truncated,
    InvalidRawFile,
    UnsupportedFileRevision,
    InvalidRawFileInfo,
    NoMsController,
    InvalidControllerOffset,
    InvalidRunHeader,
    TooManyScans,
    InvalidStringLength,
    InvalidScanNumber,
    ScanOutOfRange,
    ScanIndexMismatch,
    OffsetOverflow,
    /// Propagated from allocator failures (e.g. readWideStringSlice).
    /// Per zig-quality, allocation failures should NOT be silently converted
    /// to file-format errors.
    OutOfMemory,
};

const MAX_FILE_SIZE: u64 = 64 * 1024 * 1024 * 1024; // 64 GB
const MIN_FILE_SIZE: u64 = 8;
const MAX_SCAN_COUNT: usize = 10_000_000;

pub const RawFile = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    // File handles and mmap (lifetime = RawFile lifetime)
    file_handle: std.Io.File,
    mm: std.Io.File.MemoryMap,
    file_size: u64,

    // File-shape metadata resolved at open
    file_revision: u16,
    raw_info_offset: u64,
    ms_controller_index: usize,
    controller_offset: u64,
    first_spectrum: i32,
    last_spectrum: i32,
    spectrum_pos: u64,
    packet_pos: u64,
    num_scans: usize,

    // Scan table location within the mmap
    scan_table_start: u64, // offset of first scan index entry
    scan_table_size: u64, // num_scans * scanIndexSize
    trailer_scan_events_pos: u64, // 0 if not present in this file
    trailer_extra_pos: u64, // 0 if not present in this file
    num_trailer_extra: u32,

    // Allocated strings (freed in deinit)
    creation_time_iso: ?[]u8,
    instrument_model: ?[]u8,
    instrument_serial: ?[]u8,
    software_version: ?[]u8,

    /// Open a .raw file: mmap it, validate the signature, resolve the
    /// controller table, parse the scan index entries, and read
    /// instrument + creation-time metadata. The returned `RawFile`
    /// owns the mmap and the allocated strings; call `deinit` to free.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) RawFileError!RawFile {
        const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch {
            return error.InvalidRawFile;
        };
        errdefer file.close(io);

        const file_size = (file.stat(io) catch return error.Truncated).size;
        if (file_size > MAX_FILE_SIZE) return error.FileTooLarge;
        if (file_size < MIN_FILE_SIZE) return error.Truncated;

        var mm = std.Io.File.createMemoryMap(file, io, .{
            .len = std.math.cast(usize, file_size) orelse return error.FileTooLarge,
            .protection = .{ .read = true },
        }) catch return error.InvalidRawFile;
        errdefer mm.destroy(io);

        // Signature check: Finnigan (legacy) or OLE2 (modern).
        if (!isValidRawSignature(mm.memory)) return error.InvalidRawFile;

        const file_revision = try raw.readU16Mm(mm.memory, raw.FILE_REV_OFFSET);
        if (file_revision < 65) return error.UnsupportedFileRevision;

        const creation_time_iso = readCreationTimeIso(allocator, mm.memory, file_size);
        errdefer if (creation_time_iso) |s| allocator.free(s);

        // Sequence row metadata: instrument model fallback (may be a method path).
        var pos: u64 = raw.FILE_HEADER_SIZE;
        const seq_meta = readSequenceRowMetadata(allocator, mm.memory, &pos, file_revision) catch |err| {
            if (creation_time_iso) |s| allocator.free(s);
            return err;
        };
        errdefer if (seq_meta.inst) |s| allocator.free(s);
        errdefer if (seq_meta.method) |s| allocator.free(s);

        try skipAutoSamplerConfig(mm.memory, &pos, file_revision);

        const raw_info_offset = pos;
        const result = try resolveMsController(mm.memory, raw_info_offset);
        const controller_offset = result.controller_offset;

        // Authoritative instrument identity (overrides sequence-row model if present).
        const inst_id = readInstrumentId(allocator, mm.memory, controller_offset, file_revision) catch |err| blk: {
            std.log.warn("Failed to read InstrumentId: {s}, using sequence row fallback", .{@errorName(err)});
            break :blk raw.InstrumentId{ .model = null, .serial = null, .software_version = null };
        };
        errdefer if (inst_id.model) |s| allocator.free(s);
        errdefer if (inst_id.serial) |s| allocator.free(s);
        errdefer if (inst_id.software_version) |s| allocator.free(s);

        const first_spectrum = try raw.readI32Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_FIRST_SPECTRUM) catch return error.OffsetOverflow);
        const last_spectrum = try raw.readI32Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_LAST_SPECTRUM) catch return error.OffsetOverflow);
        if (first_spectrum <= 0 or last_spectrum < first_spectrum) {
            return error.InvalidRunHeader;
        }

        const spectrum_pos_i64 = try raw.readI64Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_SPECT_POS) catch return error.OffsetOverflow);
        const packet_pos_i64 = try raw.readI64Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_PACKET_POS) catch return error.OffsetOverflow);
        const trailer_pos_i64 = try raw.readI64Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_TRAILER_SCAN_EVENTS_POS) catch return error.OffsetOverflow);
        const trailer_extra_pos_i64 = raw.readI64Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_TRAILER_EXTRA_POS) catch return error.OffsetOverflow) catch -1;
        const num_trailer_extra = raw.readI32Mm(mm.memory, std.math.add(u64, controller_offset, raw.RUN_HEADER_NUM_TRAILER_EXTRA) catch return error.OffsetOverflow) catch 0;
        if (spectrum_pos_i64 <= 0 or packet_pos_i64 <= 0) {
            return error.InvalidRunHeader;
        }
        const spectrum_pos = std.math.cast(u64, spectrum_pos_i64) orelse return error.InvalidRawFileInfo;
        const packet_pos = std.math.cast(u64, packet_pos_i64) orelse return error.InvalidRawFileInfo;

        const scan_span = std.math.sub(i32, last_spectrum, first_spectrum) catch return error.OffsetOverflow;
        const scan_count_i32 = std.math.add(i32, scan_span, 1) catch return error.OffsetOverflow;
        const num_scans: usize = std.math.cast(usize, scan_count_i32) orelse return error.TooManyScans;
        if (num_scans > MAX_SCAN_COUNT) return error.TooManyScans;

        const scan_index_size = raw.scan_index_size(file_revision);
        const scan_table_size = std.math.mul(u64, num_scans, scan_index_size) catch return error.OffsetOverflow;
        const scan_table_end = std.math.add(u64, spectrum_pos, scan_table_size) catch return error.OffsetOverflow;
        if (scan_table_end > mm.memory.len) return error.Truncated;

        // Prefer InstrumentId.Model over sequence row Inst (which may be a method path).
        // The sequence-row strings are owned by us regardless — free them if we don't use them.
        if (seq_meta.method) |s| allocator.free(s);
        const final_model: ?[]u8 = blk: {
            if (inst_id.model) |m| {
                if (seq_meta.inst) |s| allocator.free(s);
                break :blk m;
            }
            break :blk seq_meta.inst;
        };
        const final_serial: ?[]u8 = inst_id.serial;
        const final_software_version: ?[]u8 = inst_id.software_version;

        return .{
            .io = io,
            .allocator = allocator,
            .file_handle = file,
            .mm = mm,
            .file_size = file_size,
            .file_revision = file_revision,
            .raw_info_offset = raw_info_offset,
            .ms_controller_index = result.ms_controller_index,
            .controller_offset = controller_offset,
            .first_spectrum = first_spectrum,
            .last_spectrum = last_spectrum,
            .spectrum_pos = spectrum_pos,
            .packet_pos = packet_pos,
            .num_scans = num_scans,
            .trailer_scan_events_pos = if (trailer_pos_i64 > 0)
                std.math.cast(u64, trailer_pos_i64) orelse return error.InvalidRawFileInfo
            else
                0,
            .trailer_extra_pos = if (trailer_extra_pos_i64 > 0)
                std.math.cast(u64, trailer_extra_pos_i64) orelse return error.InvalidRawFileInfo
            else
                0,
            .num_trailer_extra = if (num_trailer_extra > 0)
                std.math.cast(u32, num_trailer_extra) orelse return error.InvalidRawFileInfo
            else
                0,
            .scan_table_start = spectrum_pos,
            .scan_table_size = scan_table_size,
            .creation_time_iso = creation_time_iso,
            .instrument_model = final_model,
            .instrument_serial = final_serial,
            .software_version = final_software_version,
        };
    }

    /// Free the mmap, close the file handle, and free allocated strings.
    pub fn deinit(self: *RawFile) void {
        if (self.creation_time_iso) |s| self.allocator.free(s);
        if (self.instrument_model) |s| self.allocator.free(s);
        if (self.instrument_serial) |s| self.allocator.free(s);
        if (self.software_version) |s| self.allocator.free(s);
        self.mm.destroy(self.io);
        self.file_handle.close(self.io);
    }

    /// Look up a single scan by scan number. Returns an error if the
    /// scan is out of range. Does a linear search if the file uses a
    /// non-sequential scan table (rev < 65 files); otherwise reads
    /// the entry at `scan_table_start + (scan_number - first_spectrum) * size`.
    pub fn scan_at(self: RawFile, scan_number: i32) RawFileError!raw.ScanIndexEntry {
        if (scan_number < self.first_spectrum or scan_number > self.last_spectrum) {
            return error.InvalidScanNumber;
        }
        const scan_index_size = raw.scan_index_size(self.file_revision);
        const zero_based_i32 = std.math.sub(i32, scan_number, self.first_spectrum) catch return error.OffsetOverflow;
        const zero_based: u64 = std.math.cast(u64, zero_based_i32) orelse return error.OffsetOverflow;
        const row_offset = std.math.mul(u64, zero_based, scan_index_size) catch return error.OffsetOverflow;
        const offset: u64 = std.math.add(u64, self.scan_table_start, row_offset) catch return error.OffsetOverflow;
        const entry_end = std.math.add(u64, offset, scan_index_size) catch return error.OffsetOverflow;
        if (entry_end > self.mm.memory.len) {
            return error.Truncated;
        }
        const entry_offset = std.math.cast(usize, offset) orelse return error.OffsetOverflow;
        const entry = raw.parse_scan_index(self.mm.memory, entry_offset, self.file_revision) catch |err| switch (err) {
            raw.RawResolveError.Truncated => return error.Truncated,
            raw.RawResolveError.InvalidRawFileInfo => return error.InvalidRawFileInfo,
            else => return error.OffsetOverflow,
        };
        if (entry.scan_number == scan_number) return entry;

        // File uses a non-sequential scan table: linear-scan for the entry.
        var pos = self.scan_table_start;
        const table_end = std.math.add(u64, self.scan_table_start, self.scan_table_size) catch return error.OffsetOverflow;
        while (true) {
            const pos_entry_end = std.math.add(u64, pos, scan_index_size) catch return error.OffsetOverflow;
            if (pos_entry_end > table_end) break;
            const pos_usz = std.math.cast(usize, pos) orelse return error.OffsetOverflow;
            const candidate = raw.parse_scan_index(self.mm.memory, pos_usz, self.file_revision) catch |err| switch (err) {
                raw.RawResolveError.Truncated => return error.Truncated,
                raw.RawResolveError.InvalidRawFileInfo => continue,
                else => return error.OffsetOverflow,
            };
            if (candidate.scan_number == scan_number) return candidate;
            pos = pos_entry_end;
        }
        return error.InvalidScanNumber;
    }

    /// Absolute byte offset of the packet for `scan_number` in the file.
    /// Returns `null` if the scan is out of range.
    pub fn packet_offset(self: RawFile, scan_number: i32) RawFileError!u64 {
        const entry = try self.scan_at(scan_number);
        return std.math.add(u64, self.packet_pos, entry.data_offset) catch return error.OffsetOverflow;
    }

    /// Read-only view of the mmap slice. Used by callers that need to
    /// walk the scan table or read packet bodies directly.
    pub fn memory(self: RawFile) []const u8 {
        return self.mm.memory;
    }
};

// =============================================================================
// Internal helpers — adapted from the pread-based versions in raw_file.zig
// to operate on a memory-mapped slice.
// =============================================================================

fn isValidRawSignature(mm: []const u8) bool {
    const is_finnigan = mm.len >= 2 and mm[0] == 0x01 and mm[1] == 0xA1;
    const OLE2_MAGIC = [8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
    const is_ole2 = mm.len >= 8 and std.mem.eql(u8, mm[0..8], &OLE2_MAGIC);
    return is_finnigan or is_ole2;
}

fn readCreationTimeIso(allocator: std.mem.Allocator, mm: []const u8, file_size: u64) ?[]u8 {
    const needed = spec_file_header.CREATION_TIME_HIGH_OFFSET + 4;
    if (file_size < needed) return null;
    const ft_low = std.mem.readInt(u32, mm[spec_file_header.CREATION_TIME_LOW_OFFSET..spec_file_header.CREATION_TIME_HIGH_OFFSET], .little);
    const ft_high = std.mem.readInt(u32, mm[spec_file_header.CREATION_TIME_HIGH_OFFSET..needed], .little);
    const filetime = (@as(u64, ft_high) << 32) | ft_low;
    if (filetime == 0) return null;
    return fileTimeToIso8601(allocator, filetime) catch null;
}

fn fileTimeToIso8601(allocator: std.mem.Allocator, filetime: u64) !?[]u8 {
    if (filetime == 0) return null;
    const windows_epoch_offset: i128 = 116444736000000000;
    const hundred_ns_per_sec: i128 = 10000000;
    const unix_ts = @divFloor(@as(i128, filetime) - windows_epoch_offset, hundred_ns_per_sec);
    if (unix_ts < 0) return null;

    const es = std.time.epoch.EpochSeconds{ .secs = std.math.cast(u64, unix_ts) orelse return null };
    const yd = es.getEpochDay();
    const year_day = yd.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

fn readU32Slice(mm: []const u8, offset: u64) RawFileError!u32 {
    const end = std.math.add(u64, offset, 4) catch return error.OffsetOverflow;
    if (end > mm.len) return error.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return error.OffsetOverflow;
    return std.mem.readInt(u32, mm[usz_offset..][0..4], .little);
}

fn skipWideStringSlice(mm: []const u8, pos: *u64) RawFileError!void {
    const chars = try readU32Slice(mm, pos.*);
    if (chars > raw.MAX_STRING_CHARS) return error.InvalidStringLength;
    pos.* = std.math.add(u64, pos.*, 4) catch return error.OffsetOverflow;
    const bytes = std.math.mul(u64, chars, 2) catch return error.OffsetOverflow;
    pos.* = std.math.add(u64, pos.*, bytes) catch return error.OffsetOverflow;
}

fn readWideStringSlice(allocator: std.mem.Allocator, mm: []const u8, pos: *u64) RawFileError!?[]u8 {
    const chars = try readU32Slice(mm, pos.*);
    pos.* = std.math.add(u64, pos.*, 4) catch return error.OffsetOverflow;
    if (chars == 0) return null;
    if (chars > raw.MAX_STRING_CHARS) return error.InvalidStringLength;
    const bytes = std.math.mul(u64, chars, 2) catch return error.OffsetOverflow;
    const end = std.math.add(u64, pos.*, bytes) catch return error.OffsetOverflow;
    if (end > mm.len) return error.Truncated;
    const pos_usz = std.math.cast(usize, pos.*) orelse return error.OffsetOverflow;
    const bytes_usz = std.math.cast(usize, bytes) orelse return error.OffsetOverflow;
    const wide_slice = mm[pos_usz..][0..bytes_usz];
    pos.* = end;
    const chars_usz = std.math.cast(usize, chars) orelse return error.InvalidStringLength;
    return unicode.utf16_le_to_utf8_alloc(allocator, wide_slice, chars_usz) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Truncated, // surrogate errors are data format issues
    };
}

fn readSequenceRowMetadata(
    allocator: std.mem.Allocator,
    mm: []const u8,
    pos: *u64,
    file_revision: u16,
) RawFileError!struct { inst: ?[]u8, method: ?[]u8 } {
    pos.* = std.math.add(u64, pos.*, raw.SEQ_ROW_INFO_SIZE) catch return error.OffsetOverflow;

    // Skip first 9 strings: CalLevel, SampleName, SampleId, Comment, 5 UserTexts
    var n: usize = 0;
    while (n < 9) : (n += 1) try skipWideStringSlice(mm, pos);

    // Read Inst (10th string, index 9)
    const inst = try readWideStringSlice(allocator, mm, pos);

    // Read Method (11th string, index 10)
    const method = try readWideStringSlice(allocator, mm, pos);

    // Skip remaining strings in the first batch (RawFileName, Path = 2 strings)
    n = 0;
    while (n < 2) : (n += 1) try skipWideStringSlice(mm, pos);

    if (file_revision >= 25) {
        try skipWideStringSlice(mm, pos); // Vial
        try skipWideStringSlice(mm, pos); // CalibFile
    }
    if (file_revision >= 41) {
        try skipWideStringSlice(mm, pos); // Barcode
        pos.* = std.math.add(u64, pos.*, 4) catch return error.OffsetOverflow; // BarcodeStatus int
    }
    if (file_revision >= 58) {
        n = 0;
        while (n < 15) : (n += 1) try skipWideStringSlice(mm, pos);
    }

    return .{ .inst = inst, .method = method };
}

fn skipAutoSamplerConfig(mm: []const u8, pos: *u64, file_revision: u16) RawFileError!void {
    if (file_revision >= 36) {
        pos.* = std.math.add(u64, pos.*, raw.AUTO_SAMPLER_CONFIG_SIZE) catch return error.OffsetOverflow;
        try skipWideStringSlice(mm, pos); // TrayName
    }
}

const MsControllerResult = struct {
    ms_controller_index: usize,
    controller_offset: u64,
};

fn resolveMsController(mm: []const u8, raw_info_offset: u64) RawFileError!MsControllerResult {
    const controller_count_i32 = try raw.readI32Mm(mm, std.math.add(u64, raw_info_offset, raw.RAW_INFO_NUM_CONTROLLERS) catch return error.OffsetOverflow);
    if (controller_count_i32 <= 0 or controller_count_i32 > 64) {
        return error.InvalidRawFileInfo;
    }
    const controller_count: usize = std.math.cast(usize, controller_count_i32) orelse return error.InvalidRawFileInfo;

    var i: usize = 0;
    while (i < controller_count) : (i += 1) {
        // SAFETY: i is a loop index bounded by controller_count <= 64, so it fits u64.
        const entry_base = blk: {
            const table_base = std.math.add(u64, raw_info_offset, raw.RAW_INFO_CONTROLLER_TABLE_CURRENT) catch return error.OffsetOverflow;
            const entry_offset = std.math.mul(u64, @as(u64, @intCast(i)), raw.RAW_INFO_CONTROLLER_SIZE_CURRENT) catch return error.OffsetOverflow;
            break :blk std.math.add(u64, table_base, entry_offset) catch return error.OffsetOverflow;
        };
        const device_type = try raw.readI32Mm(mm, std.math.add(u64, entry_base, raw.RAW_INFO_CONTROLLER_TYPE) catch return error.OffsetOverflow);
        if (device_type == raw.VIRTUAL_DEVICE_MS) {
            const off = try raw.readI64Mm(mm, std.math.add(u64, entry_base, raw.RAW_INFO_CONTROLLER_OFFSET) catch return error.OffsetOverflow);
            if (off <= 0) return error.InvalidControllerOffset;
            return .{
                .ms_controller_index = i,
                .controller_offset = std.math.cast(u64, off) orelse return error.InvalidControllerOffset,
            };
        }
    }
    return error.NoMsController;
}

fn readInstrumentId(
    allocator: std.mem.Allocator,
    mm: []const u8,
    controller_offset: u64,
    file_revision: u16,
) RawFileError!raw.InstrumentId {
    if (file_revision < 45) {
        return raw.InstrumentId{ .model = null, .serial = null, .software_version = null };
    }

    var pos = std.math.add(u64, controller_offset, raw.RUN_HEADER_STRUCT_SIZE) catch return error.OffsetOverflow;

    // InstIdInfoStruct (IsValid u32 + AbsorbanceUnit u32)
    const inst_info_end = std.math.add(u64, pos, spec_instrument_id.INST_ID_INFO_SIZE) catch return error.OffsetOverflow;
    if (inst_info_end > mm.len) return error.Truncated;
    pos = inst_info_end;
    // is_valid is at offset 0; we read it for parity with the original
    // pread-based version but don't gate on it (the original didn't either).
    _ = try readU32Slice(mm, std.math.sub(u64, pos, 8) catch return error.OffsetOverflow);

    // ChannelLabels array: count + strings
    const channel_count = try raw.readI32Mm(mm, pos);
    if (channel_count < 0 or channel_count > 256) return error.InvalidStringLength;
    pos = std.math.add(u64, pos, 4) catch return error.OffsetOverflow;
    var n: i32 = 0;
    while (n < channel_count) : (n += 1) {
        try skipWideStringSlice(mm, &pos);
    }

    // Name (we don't need it, but must skip)
    try skipWideStringSlice(mm, &pos);

    // Model
    const model = try readWideStringSlice(allocator, mm, &pos);

    // SerialNumber
    const serial = try readWideStringSlice(allocator, mm, &pos);

    // SoftwareVersion
    const software_version = try readWideStringSlice(allocator, mm, &pos);

    // HardwareVersion (skip)
    try skipWideStringSlice(mm, &pos);

    // Flags (rev >= 32)
    if (file_revision >= 32) {
        try skipWideStringSlice(mm, &pos);
    }

    // AxisLabelX and AxisLabelY (rev >= 37)
    if (file_revision >= 37) {
        try skipWideStringSlice(mm, &pos);
        try skipWideStringSlice(mm, &pos);
    }

    return .{
        .model = model,
        .serial = serial,
        .software_version = software_version,
    };
}
