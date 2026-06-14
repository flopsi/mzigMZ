/// .raw file passthrough writer.
/// Copies all binary regions verbatim from the source mmap,
/// re-encoding only packet data in-place within original data_size bounds.
/// If a re-encoded packet exceeds the original data_size, falls back to verbatim copy.
/// All other regions are preserved byte-for-byte.
const std = @import("std");
const advanced = @import("advanced_packet");
const profile = @import("profile_packet");
const raw = @import("raw_file");
const reader = @import("raw_file_reader");
const trailer_events = @import("trailer_events");
const wp = @import("writer_primitives");
const schema = @import("schema");

pub const RawFileWriterError = error{
    CreateFailed,
    WriteFailed,
    ReadFailed,
    ScanTableMismatch,
    OutOfMemory,
    SystemResources,
    Unexpected,
    InputOutput,
    AccessDenied,
    LockViolation,
    WouldBlock,
    Canceled,
    Unseekable,
    IsDir,
    NotOpenForReading,
    InvalidRawFileInfo,
    OffsetOverflow,
};

pub const VerifyPassthroughError = reader.RawFileError || error{ ScanTableMismatch, OutOfMemory } || advanced.PacketError || profile.ProfileError;

fn mapRawResolveError(err: raw.RawResolveError) RawFileWriterError {
    return switch (err) {
        raw.RawResolveError.Truncated => error.ReadFailed,
        raw.RawResolveError.InvalidRawFileInfo => error.InvalidRawFileInfo,
        raw.RawResolveError.OffsetOverflow => error.OffsetOverflow,
        raw.RawResolveError.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Checked addition for packet base offset + file-derived data_offset.
fn checkedPacketOffset(packet_pos: usize, data_offset: u64) RawFileWriterError!usize {
    const packet_pos_u64 = std.math.cast(u64, packet_pos) orelse return error.OffsetOverflow;
    const sum = std.math.add(u64, packet_pos_u64, data_offset) catch return error.OffsetOverflow;
    return std.math.cast(usize, sum) orelse return error.OffsetOverflow;
}

/// Checked multiplication/addition for scan-table entry offsets.
fn checkedScanOffset(scan_table_start: usize, scan_idx: usize, scan_index_size: u64) RawFileWriterError!usize {
    const scan_index_size_usz = std.math.cast(usize, scan_index_size) orelse return error.OffsetOverflow;
    const product = std.math.mul(usize, scan_idx, scan_index_size_usz) catch return error.OffsetOverflow;
    return std.math.add(usize, scan_table_start, product) catch return error.OffsetOverflow;
}

/// Re-encode context for a single scan.
const ScanEncodeInfo = struct {
    orig_entry: raw.ScanIndexEntry,
    new_size: u32,
    encode_verbatim: bool,
};

/// Write a passthrough copy of `source` to `out_path`.
/// Auto-detects schema and uses fast path when possible; falls back to slow path.
pub fn passthrough(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: *const reader.RawFile,
    trailers: ?trailer_events.TrailerScanEvents,
    out_path: []const u8,
) RawFileWriterError!void {
    const detected = schema.detect_schema(
        source.memory(),
        source.file_revision,
        source.scan_table_start,
        source.scan_table_size,
        raw.scan_index_size(source.file_revision),
        source.packet_pos,
        source.num_scans,
        source.trailer_scan_events_pos,
    ) catch |err| blk: {
        std.log.warn("Schema detection failed ({s}), using slow path", .{@errorName(err)});
        break :blk null;
    };
    if (detected) |s| {
        std.log.info("Schema detected (rev {d}), using fast path", .{s.file_revision});
        return passthrough_fast(allocator, io, source, trailers, out_path, s);
    }
    std.log.info("No schema match, using slow path", .{});
    return passthrough_slow(allocator, io, source, trailers, out_path);
}

/// Write a passthrough copy of `source` to `out_path`.
/// Packet data is re-encoded in-place: original data_offset is preserved,
/// data_size is updated to the encoded size. If encoded size exceeds original
/// data_size, the scan is copied verbatim instead.
pub fn passthrough_slow(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: *const reader.RawFile,
    trailers: ?trailer_events.TrailerScanEvents,
    out_path: []const u8,
) RawFileWriterError!void {
    const out_file = std.Io.Dir.createFile(.cwd(), io, out_path, .{ .read = true }) catch |e| {
        std.log.err("Failed to create {s}: {s}", .{ out_path, @errorName(e) });
        return error.CreateFailed;
    };
    defer out_file.close(io);

    var write_buf: [64 * 1024]u8 = undefined;
    var buffered = out_file.writer(io, &write_buf);
    const w = &buffered.interface;

    const src_mm = source.memory();
    const scan_table_start = std.math.cast(usize, source.scan_table_start) orelse return error.OffsetOverflow;
    const scan_table_size = std.math.cast(usize, source.scan_table_size) orelse return error.OffsetOverflow;
    const packet_pos = std.math.cast(usize, source.packet_pos) orelse return error.OffsetOverflow;
    const scan_index_size = raw.scan_index_size(source.file_revision);
    const num_scans = source.num_scans;

    // --- Pass 1: decode+encode every scan to compute exact new sizes ---
    var scan_infos = try allocator.alloc(ScanEncodeInfo, num_scans);
    defer allocator.free(scan_infos);

    // Temp decode/encode buffers (grow as needed)
    // Start at 4096; pre-grown per-scan from header metadata
    var mz_buf = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_buf);
    var inten_buf = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_buf);
    var feat_buf = try allocator.alloc(advanced.PeakFeatures, 4096);
    defer allocator.free(feat_buf);
    var freq_buf = try allocator.alloc(f64, 4096);
    defer allocator.free(freq_buf);
    var encode_buf = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(encode_buf);

    // Diagnostic counters
    var verbatim_not_ft: usize = 0;
    var verbatim_parse_fail: usize = 0;
    var verbatim_oob: usize = 0;
    var verbatim_decode_fail: usize = 0;
    var verbatim_oversized: usize = 0;
    var verbatim_encode_fail: usize = 0;
    var verbatim_multi_segment: usize = 0;
    var re_encoded: usize = 0;

    for (0..num_scans) |scan_idx| {
        const offset = checkedScanOffset(scan_table_start, scan_idx, scan_index_size) catch |e| {
            std.log.warn("Scan-table offset overflow for scan {d}: {s}", .{ scan_idx, @errorName(e) });
            scan_infos[scan_idx] = .{
                .orig_entry = std.mem.zeroes(raw.ScanIndexEntry),
                .new_size = 0,
                .encode_verbatim = true,
            };
            verbatim_parse_fail += 1;
            continue;
        };
        const entry = raw.parse_scan_index(src_mm, offset, source.file_revision) catch |e| {
            std.log.warn("Failed to parse scan index at offset {d}: {s}", .{ offset, @errorName(e) });
            scan_infos[scan_idx] = .{
                .orig_entry = std.mem.zeroes(raw.ScanIndexEntry),
                .new_size = 0,
                .encode_verbatim = true,
            };
            verbatim_parse_fail += 1;
            continue;
        };
        scan_infos[scan_idx].orig_entry = entry;

        const packet_type = entry.packet_type & 0xFFFF;
        const is_centroid = packet_type == raw.PACKET_TYPE_FT_CENTROID or
            packet_type == raw.PACKET_TYPE_LINEAR_TRAP_CENTROID;
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;

        if (!is_centroid and !is_profile) {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_not_ft += 1;
            continue;
        }

        // FT_PROFILE packets: copy verbatim.
        if (is_profile) {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_not_ft += 1;
            continue;
        }

        const packet_offset = checkedPacketOffset(packet_pos, entry.data_offset) catch {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };
        const header_end = std.math.add(usize, packet_offset, 32) catch {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };
        if (header_end > src_mm.len) {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        }
        const header_bytes = src_mm[packet_offset..header_end];
        const h = advanced.read_header(header_bytes, 0) catch |err| {
            std.log.warn("readHeader failed for passthrough scan {d}: {s}", .{ scan_idx, @errorName(err) });
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };
        const remaining_bytes = std.math.sub(usize, src_mm.len, packet_offset) catch {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };
        const actual_size = std.math.cast(usize, @min(
            advanced.packet_size_from_header(h) catch |err| {
                std.log.warn("packetSizeFromHeader failed for passthrough scan {d}: {s}", .{ scan_idx, @errorName(err) });
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_oob += 1;
                continue;
            },
            remaining_bytes,
        )) orelse {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };

        const packet_end = std.math.add(usize, packet_offset, actual_size) catch {
            scan_infos[scan_idx].new_size = entry.data_size;
            scan_infos[scan_idx].encode_verbatim = true;
            verbatim_oob += 1;
            continue;
        };

        if (is_centroid or (is_profile and h.num_centroid_words > 0)) {
            // Decode as centroid
            const res = advanced.reencode_centroid(
                allocator,
                src_mm[packet_offset..packet_end],
                h,
                &mz_buf,
                &inten_buf,
                &feat_buf,
                &encode_buf,
            ) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_decode_fail += 1;
                continue;
            };

            if (res.encoded_size > actual_size) {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_oversized += 1;
                continue;
            }

            scan_infos[scan_idx].new_size = std.math.cast(u32, res.written) orelse return error.OffsetOverflow;
            scan_infos[scan_idx].encode_verbatim = false;
            re_encoded += 1;
        } else {
            // Pure profile packet: decode with freq, re-encode
            // Multi-segment packets: fall back to verbatim copy (per-subsegment mass_offset not preserved).
            // TODO: preserve per-subsegment mass_offset in profile re-encode.
            if (h.num_segments > 1) {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_multi_segment += 1;
                continue;
            }

            // Pre-grow buffers: profile points ≤ num_profile_words in worst case
            const max_points: usize = @max(4096, h.num_profile_words);
            if (max_points > freq_buf.len) {
                freq_buf = try allocator.realloc(freq_buf, max_points);
                mz_buf = try allocator.realloc(mz_buf, max_points);
                inten_buf = try allocator.realloc(inten_buf, max_points);
            }
            var calibrators: []const f64 = &[_]f64{};
            if (trailers) |te| {
                if (te.get_event(scan_idx)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0 and (h.default_feature_word & 0x80) != 0;

            const n = profile.decode_ft_profile_with_freq(
                src_mm[packet_offset..packet_end],
                calibrators,
                freq_buf,
                mz_buf,
                inten_buf,
                use_subsegment,
            ) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_decode_fail += 1;
                continue;
            };

            if (n > freq_buf.len) {
                freq_buf = try allocator.realloc(freq_buf, n * 2);
                mz_buf = try allocator.realloc(mz_buf, n * 2);
                inten_buf = try allocator.realloc(inten_buf, n * 2);
            }

            const mass_range_low_offset = std.math.add(usize, packet_offset, 32) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_oob += 1;
                continue;
            };
            const mass_range_high_offset = std.math.add(usize, packet_offset, 36) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_oob += 1;
                continue;
            };
            const mass_low = @as(f32, @bitCast(std.mem.readInt(u32, src_mm[mass_range_low_offset..][0..4], .little)));
            const mass_high = @as(f32, @bitCast(std.mem.readInt(u32, src_mm[mass_range_high_offset..][0..4], .little)));

            const encoded_size = profile.encoded_profile_size(n, 0, 0, 0, 0) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_encode_fail += 1;
                continue;
            };
            if (encoded_size > actual_size) {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_oversized += 1;
                continue;
            }
            if (encoded_size > encode_buf.len) {
                encode_buf = try allocator.realloc(encode_buf, encoded_size * 2);
            }

            const written = profile.encode_ft_profile(
                encode_buf[0..encoded_size],
                freq_buf[0..n],
                inten_buf[0..n],
                mass_low,
                mass_high,
                null,
                null,
                null,
            ) catch {
                scan_infos[scan_idx].new_size = entry.data_size;
                scan_infos[scan_idx].encode_verbatim = true;
                verbatim_encode_fail += 1;
                continue;
            };

            scan_infos[scan_idx].new_size = std.math.cast(u32, written) orelse return error.OffsetOverflow;
            scan_infos[scan_idx].encode_verbatim = false;
            re_encoded += 1;
        }
    }

    std.log.info("Pass 1: re-encoded={d}  verbatim(not_ft={d} parse_fail={d} oob={d} decode_fail={d} oversized={d} encode_fail={d} multi_seg={d})", .{ re_encoded, verbatim_not_ft, verbatim_parse_fail, verbatim_oob, verbatim_decode_fail, verbatim_oversized, verbatim_encode_fail, verbatim_multi_segment });

    // --- Write pre-scan-table bytes ---
    w.writeAll(src_mm[0..scan_table_start]) catch return error.WriteFailed;

    // --- Write updated scan table (preserve original data_offset, update data_size) ---
    for (scan_infos) |info| {
        var new_entry = info.orig_entry;
        new_entry.data_size = info.new_size;
        var entry_bytes: [88]u8 = undefined; // max entry size (rev 65+)
        raw.serialize_scan_index_entry(&entry_bytes, 0, new_entry, scan_index_size, source.file_revision) catch |err| return mapRawResolveError(err);
        w.writeAll(entry_bytes[0..scan_index_size]) catch return error.WriteFailed;
    }

    // --- Write everything after scan table verbatim (packets + trailing data) ---
    const after_scan_table = std.math.add(usize, scan_table_start, scan_table_size) catch return error.OffsetOverflow;
    w.writeAll(src_mm[after_scan_table..]) catch return error.WriteFailed;

    buffered.flush() catch |e| {
        std.log.err("Failed to flush output: {s}", .{@errorName(e)});
        return error.WriteFailed;
    };

    // --- Pass 2: overwrite packet regions in-place via positional writes ---
    for (scan_infos, 0..) |info, scan_idx| {
        if (info.encode_verbatim) continue;

        const packet_offset = checkedPacketOffset(packet_pos, info.orig_entry.data_offset) catch continue;
        const packet_type = info.orig_entry.packet_type & 0xFFFF;
        const is_centroid = packet_type == raw.PACKET_TYPE_FT_CENTROID or
            packet_type == raw.PACKET_TYPE_LINEAR_TRAP_CENTROID;
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;

        const header_end = std.math.add(usize, packet_offset, 32) catch continue;
        if (header_end > src_mm.len) continue;
        const h = advanced.read_header(src_mm[packet_offset..header_end], 0) catch continue;
        const remaining_bytes = std.math.sub(usize, src_mm.len, packet_offset) catch continue;
        const actual_size = std.math.cast(usize, @min(
            advanced.packet_size_from_header(h) catch continue,
            remaining_bytes,
        )) orelse continue;
        const packet_end = std.math.add(usize, packet_offset, actual_size) catch continue;

        var written: usize = 0;
        if (is_centroid or (is_profile and h.num_centroid_words > 0)) {
            const res = advanced.reencode_centroid(
                allocator,
                src_mm[packet_offset..packet_end],
                h,
                &mz_buf,
                &inten_buf,
                &feat_buf,
                &encode_buf,
            ) catch continue;

            written = res.written;
        } else {
            var calibrators: []const f64 = &[_]f64{};
            if (trailers) |te| {
                if (te.get_event(scan_idx)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0 and (h.default_feature_word & 0x80) != 0;
            const n = profile.decode_ft_profile_with_freq(
                src_mm[packet_offset..packet_end],
                calibrators,
                freq_buf,
                mz_buf,
                inten_buf,
                use_subsegment,
            ) catch continue;
            if (n > freq_buf.len) {
                freq_buf = allocator.realloc(freq_buf, n * 2) catch continue;
                mz_buf = allocator.realloc(mz_buf, n * 2) catch continue;
                inten_buf = allocator.realloc(inten_buf, n * 2) catch continue;
            }
            const mass_range_low_offset = std.math.add(usize, packet_offset, 32) catch continue;
            const mass_range_high_offset = std.math.add(usize, packet_offset, 36) catch continue;
            const mass_low = @as(f32, @bitCast(std.mem.readInt(u32, src_mm[mass_range_low_offset..][0..4], .little)));
            const mass_high = @as(f32, @bitCast(std.mem.readInt(u32, src_mm[mass_range_high_offset..][0..4], .little)));
            const encoded_size = profile.encoded_profile_size(n, 0, 0, 0, 0) catch continue;
            if (encoded_size > encode_buf.len) {
                encode_buf = allocator.realloc(encode_buf, encoded_size * 2) catch continue;
            }
            written = profile.encode_ft_profile(
                encode_buf[0..encoded_size],
                freq_buf[0..n],
                inten_buf[0..n],
                mass_low,
                mass_high,
                null,
                null,
                null,
            ) catch continue;
        }

        if (written == 0) continue;

        // Overwrite packet bytes in-place at original offset
        out_file.writePositionalAll(io, encode_buf[0..written], packet_offset) catch |e| {
            std.log.warn("Failed to overwrite packet at offset {d}: {s}", .{ packet_offset, @errorName(e) });
            continue;
        };
    }

    // --- Recompute and write the file checksum at offset 148 ---
    // src_mm.len is at most the file size (<= 64 GB), so it always fits u64.
    // src_mm.len is bounded by the mmap length, which always fits u64.
    const file_length: u64 = @as(u64, src_mm.len);
    wp.write_checksum_at148(allocator, out_file, io, source.file_revision, file_length) catch |e| {
        std.log.err("Failed to write checksum at offset 148: {s}", .{@errorName(e)});
        return error.WriteFailed;
    };
}

/// Fast-path passthrough (per ADR-0002).
///
/// Single-pass writer for files that match a known schema. Skips the
/// Pass 1 decode-encode loop by doing everything in a single sweep:
/// 1. Bulk `writeAll` of the entire source file (preserves all regions)
/// 2. Per-scan overwrite of re-encoded centroid packets via `writePositionalAll`
/// 3. Scan table update (data_size only, data_offset preserved)
/// 4. Checksum recompute and write
///
/// Profile packets are copied verbatim by step 1 (no re-encoding), which
/// matches the legacy `mzigWrite` approach and preserves the full advanced
/// packet structure that Spectronaut and other 3rd-party tools require.
///
/// Caller must ensure the file matches a known schema (use `schema.detectSchema`).
pub fn passthrough_fast(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: *const reader.RawFile,
    trailers: ?trailer_events.TrailerScanEvents,
    out_path: []const u8,
    file_schema: schema.FileSchema,
) RawFileWriterError!void {
    _ = trailers; // unused in fast path (no per-scan trailer decisions)

    const out_file = std.Io.Dir.createFile(.cwd(), io, out_path, .{ .read = true }) catch |e| {
        std.log.err("Failed to create {s}: {s}", .{ out_path, @errorName(e) });
        return error.CreateFailed;
    };
    defer out_file.close(io);

    var write_buf: [256 * 1024]u8 = undefined;
    var buffered = out_file.writer(io, &write_buf);
    const w = &buffered.interface;

    const src_mm = source.memory();
    const scan_table_start = std.math.cast(usize, source.scan_table_start) orelse return error.OffsetOverflow;
    const packet_pos = std.math.cast(usize, source.packet_pos) orelse return error.OffsetOverflow;
    const scan_index_size = raw.scan_index_size(source.file_revision);
    const num_scans = source.num_scans;

    // Pre-allocated encode buffers (grow on demand)
    var mz_buf = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_buf);
    var inten_buf = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_buf);
    var feat_buf = try allocator.alloc(advanced.PeakFeatures, 4096);
    defer allocator.free(feat_buf);
    var encode_buf = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(encode_buf);

    // Track new data_size per scan for the scan table update
    var new_sizes = try allocator.alloc(u32, num_scans);
    defer allocator.free(new_sizes);

    // 1. Bulk copy the entire source file (one big writeAll)
    w.writeAll(src_mm) catch return error.WriteFailed;

    // 2. Walk every scan; for centroid scans, decode+re-encode and overwrite in-place
    var re_encoded: usize = 0;
    var verbatim_count: usize = 0;
    for (0..num_scans) |scan_idx| {
        const entry_offset = checkedScanOffset(scan_table_start, scan_idx, scan_index_size) catch continue;
        const entry = raw.parse_scan_index(src_mm, entry_offset, source.file_revision) catch continue;

        const packet_type = entry.packet_type & 0xFFFF;
        const is_centroid = packet_type == raw.PACKET_TYPE_FT_CENTROID or
            packet_type == raw.PACKET_TYPE_LINEAR_TRAP_CENTROID;

        if (!is_centroid) {
            // Profile and other non-centroid packets: copied verbatim by the bulk write
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        }

        // Centroid: decode+re-encode and overwrite in-place
        const packet_offset = checkedPacketOffset(packet_pos, entry.data_offset) catch continue;
        const header_end = std.math.add(usize, packet_offset, 32) catch continue;
        if (header_end > src_mm.len) {
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        }
        const header_bytes = src_mm[packet_offset..header_end];
        const h = advanced.read_header(header_bytes, 0) catch |err| {
            std.log.warn("readHeader failed for slow-path scan {d}: {s}", .{ scan_idx, @errorName(err) });
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        };
        const remaining_bytes = std.math.sub(usize, src_mm.len, packet_offset) catch continue;
        const actual_size = std.math.cast(usize, @min(
            advanced.packet_size_from_header(h) catch |err| {
                std.log.warn("packetSizeFromHeader failed for slow-path scan {d}: {s}", .{ scan_idx, @errorName(err) });
                new_sizes[scan_idx] = entry.data_size;
                verbatim_count += 1;
                continue;
            },
            remaining_bytes,
        )) orelse {
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        };
        const packet_end = std.math.add(usize, packet_offset, actual_size) catch continue;

        // Pre-size decode buffers: max_peaks is a safe upper bound derived from header.
        const accurate = h.accurate_mass_centroids();
        const entry_size: u64 = if (accurate) 12 else 8;
        const centroid_bytes = std.math.mul(usize, @as(usize, h.num_centroid_words), 4) catch continue;
        const max_peaks: usize = @max(4096, (centroid_bytes / entry_size) + 1);
        if (max_peaks > mz_buf.len) {
            const new_cap = max_peaks * 2;
            mz_buf = allocator.realloc(mz_buf, new_cap) catch {
                new_sizes[scan_idx] = entry.data_size;
                verbatim_count += 1;
                continue;
            };
            inten_buf = allocator.realloc(inten_buf, new_cap) catch {
                new_sizes[scan_idx] = entry.data_size;
                verbatim_count += 1;
                continue;
            };
            feat_buf = allocator.realloc(feat_buf, new_cap) catch {
                new_sizes[scan_idx] = entry.data_size;
                verbatim_count += 1;
                continue;
            };
        }

        const n = advanced.decode_simplified_centroids_into_buffers(
            src_mm[packet_offset..packet_end],
            0,
            mz_buf,
            inten_buf,
            feat_buf,
            allocator,
        ) catch {
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        };
        std.debug.assert(n <= mz_buf.len); // max_peaks is a safe upper bound

        var num_non_default: usize = 0;
        var has_widths = false;
        const features = if (n > 0) feat_buf[0..n] else null;
        if (features) |f| {
            const default_flags = f[0].flags;
            for (f) |feat| {
                if (feat.charge != 0 or !std.meta.eql(feat.flags, default_flags)) {
                    num_non_default += 1;
                }
                if (feat.resolution != 0) has_widths = true;
            }
        }

        const encoded_size = advanced.encoded_centroid_size(n, accurate, num_non_default, has_widths, 0);
        if (encoded_size > actual_size) {
            // Re-encoded packet doesn't fit; keep original
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        }
        if (encoded_size > encode_buf.len) {
            encode_buf = allocator.realloc(encode_buf, encoded_size * 2) catch {
                new_sizes[scan_idx] = entry.data_size;
                verbatim_count += 1;
                continue;
            };
        }

        const written = advanced.encode_centroid_packet(
            encode_buf[0..encoded_size],
            mz_buf[0..n],
            inten_buf[0..n],
            features,
            accurate,
            null,
        ) catch {
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        };

        out_file.writePositionalAll(io, encode_buf[0..written], packet_offset) catch {
            new_sizes[scan_idx] = entry.data_size;
            verbatim_count += 1;
            continue;
        };
        new_sizes[scan_idx] = std.math.cast(u32, written) orelse return error.OffsetOverflow;
        re_encoded += 1;
    }

    buffered.flush() catch |e| {
        std.log.err("Failed to flush output: {s}", .{@errorName(e)});
        return error.WriteFailed;
    };

    // 3. Update scan table entries (data_size only, data_offset preserved)
    // We must rewrite the scan table in place so the data_size reflects the
    // re-encoded size. The original bytes are still in the file (from step 1)
    // so we overwrite just the data_size field.
    const file_schema_rev = file_schema.file_revision;
    for (0..num_scans) |scan_idx| {
        const entry_offset = checkedScanOffset(scan_table_start, scan_idx, scan_index_size) catch continue;
        const orig_entry = raw.parse_scan_index(src_mm, entry_offset, source.file_revision) catch continue;
        if (orig_entry.data_size == new_sizes[scan_idx]) continue; // no change
        // Re-serialize with new data_size
        var entry_bytes: [88]u8 = undefined; // max entry size (rev 65+)
        const mutated = raw.ScanIndexEntry{
            .data_size = new_sizes[scan_idx],
            .trailer_offset = orig_entry.trailer_offset,
            .scan_type_index = orig_entry.scan_type_index,
            .scan_number = orig_entry.scan_number,
            .packet_type = orig_entry.packet_type,
            .number_packets = orig_entry.number_packets,
            .data_offset = orig_entry.data_offset,
            .start_time = orig_entry.start_time,
            .tic = orig_entry.tic,
            .base_peak_intensity = orig_entry.base_peak_intensity,
            .base_peak_mass = orig_entry.base_peak_mass,
            .low_mass = orig_entry.low_mass,
            .high_mass = orig_entry.high_mass,
            .cycle_number = orig_entry.cycle_number,
        };
        raw.serialize_scan_index_entry(&entry_bytes, 0, mutated, scan_index_size, source.file_revision) catch continue;
        out_file.writePositionalAll(io, entry_bytes[0..scan_index_size], entry_offset) catch continue;
    }

    // 4. Recompute and write the file checksum at offset 148
    // src_mm.len is at most the file size (<= 64 GB), so it always fits u64.
    // src_mm.len is bounded by the mmap length, which always fits u64.
    const file_length: u64 = @as(u64, src_mm.len);
    wp.write_checksum_at148(allocator, out_file, io, source.file_revision, file_length) catch |e| {
        std.log.err("Failed to write checksum at offset 148: {s}", .{@errorName(e)});
        return error.WriteFailed;
    };

    std.log.info("Fast path: re-encoded={d}  verbatim={d}  file_revision={d}", .{ re_encoded, verbatim_count, file_schema_rev });
}

/// Verify that a passthrough file matches the original on decoded metadata.
/// Opens both files, walks every scan, and compares decoded peak data.
/// Returns the number of mismatched scans (0 = perfect match).
pub fn verify_passthrough(
    allocator: std.mem.Allocator,
    io: std.Io,
    original_path: []const u8,
    passthrough_path: []const u8,
) VerifyPassthroughError!usize {
    var orig = try reader.RawFile.open(allocator, io, original_path);
    defer orig.deinit();
    var copy = try reader.RawFile.open(allocator, io, passthrough_path);
    defer copy.deinit();

    if (orig.num_scans != copy.num_scans) {
        std.log.err("Scan count mismatch: orig={d} copy={d}", .{ orig.num_scans, copy.num_scans });
        return error.ScanTableMismatch;
    }

    var mismatches: usize = 0;

    // Reusable decode buffers (grow on demand) — eliminates ~1.6 M allocs on large files.
    var mz_orig = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_orig);
    var inten_orig = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_orig);
    var mz_copy = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_copy);
    var inten_copy = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_copy);
    var feat_orig = try allocator.alloc(advanced.PeakFeatures, 4096);
    defer allocator.free(feat_orig);
    var feat_copy = try allocator.alloc(advanced.PeakFeatures, 4096);
    defer allocator.free(feat_copy);

    var scan_num = orig.first_spectrum;
    while (scan_num <= orig.last_spectrum) : (scan_num += 1) {
        const orig_entry = orig.scan_at(scan_num) catch |e| {
            std.log.warn("scan={d}: orig.scanAt failed: {s}", .{ scan_num, @errorName(e) });
            mismatches += 1;
            continue;
        };
        const copy_entry = copy.scan_at(scan_num) catch |e| {
            std.log.warn("scan={d}: copy.scanAt failed: {s}", .{ scan_num, @errorName(e) });
            mismatches += 1;
            continue;
        };

        // Compare metadata (excluding data_size which may change by design)
        if (orig_entry.data_offset != copy_entry.data_offset or
            orig_entry.trailer_offset != copy_entry.trailer_offset or
            orig_entry.scan_type_index != copy_entry.scan_type_index or
            orig_entry.scan_number != copy_entry.scan_number or
            orig_entry.packet_type != copy_entry.packet_type or
            orig_entry.number_packets != copy_entry.number_packets or
            orig_entry.start_time != copy_entry.start_time or
            orig_entry.tic != copy_entry.tic or
            orig_entry.base_peak_intensity != copy_entry.base_peak_intensity or
            orig_entry.base_peak_mass != copy_entry.base_peak_mass or
            orig_entry.low_mass != copy_entry.low_mass or
            orig_entry.high_mass != copy_entry.high_mass or
            orig_entry.cycle_number != copy_entry.cycle_number)
        {
            std.log.warn("scan={d}: metadata mismatch", .{scan_num});
            mismatches += 1;
            continue;
        }

        // For FT_CENTROID and FT_PROFILE, decode and compare peak-level data
        const packet_type = orig_entry.packet_type & 0xFFFF;
        const is_centroid = packet_type == raw.PACKET_TYPE_FT_CENTROID or
            packet_type == raw.PACKET_TYPE_LINEAR_TRAP_CENTROID;
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;

        if (!is_centroid and !is_profile) continue;

        const orig_packet_offset = try orig.packet_offset(scan_num);
        const copy_packet_offset = try copy.packet_offset(scan_num);
        const orig_header_end = std.math.add(usize, orig_packet_offset, 32) catch continue;
        const copy_header_end = std.math.add(usize, copy_packet_offset, 32) catch continue;
        const orig_header = orig.memory()[orig_packet_offset..orig_header_end];
        const copy_header = copy.memory()[copy_packet_offset..copy_header_end];
        const orig_h = advanced.read_header(orig_header, 0) catch |err| {
            std.log.warn("scan={d}: failed to read original packet header: {s}", .{ scan_num, @errorName(err) });
            mismatches += 1;
            continue;
        };
        const copy_h = advanced.read_header(copy_header, 0) catch |err| {
            std.log.warn("scan={d}: failed to read copy packet header: {s}", .{ scan_num, @errorName(err) });
            mismatches += 1;
            continue;
        };

        const orig_remaining = std.math.sub(u64, orig.file_size, orig_packet_offset) catch continue;
        const orig_size = std.math.cast(usize, @min(
            try advanced.packet_size_from_header(orig_h),
            orig_remaining,
        )) orelse continue;
        const copy_remaining = std.math.sub(u64, copy.file_size, copy_packet_offset) catch continue;
        const copy_size = std.math.cast(usize, @min(
            try advanced.packet_size_from_header(copy_h),
            copy_remaining,
        )) orelse continue;
        const orig_packet_end = std.math.add(usize, orig_packet_offset, orig_size) catch continue;
        const copy_packet_end = std.math.add(usize, copy_packet_offset, copy_size) catch continue;

        // Grow reusable buffers if this scan needs more space
        var max_peaks: usize = 4096;
        if (orig_h.num_centroid_words > 0 or copy_h.num_centroid_words > 0) {
            const cw = @max(orig_h.num_centroid_words, copy_h.num_centroid_words);
            const cw_bytes = std.math.mul(usize, @as(usize, cw), 4) catch continue;
            max_peaks = @max(max_peaks, (cw_bytes / 8) + 1);
        }
        if (orig_h.num_profile_words > 0 or copy_h.num_profile_words > 0) {
            max_peaks = @max(max_peaks, @max(orig_h.num_profile_words, copy_h.num_profile_words));
        }
        if (max_peaks > mz_orig.len) {
            const new_cap = max_peaks * 2;
            mz_orig = try allocator.realloc(mz_orig, new_cap);
            inten_orig = try allocator.realloc(inten_orig, new_cap);
            mz_copy = try allocator.realloc(mz_copy, new_cap);
            inten_copy = try allocator.realloc(inten_copy, new_cap);
            feat_orig = try allocator.realloc(feat_orig, new_cap);
            feat_copy = try allocator.realloc(feat_copy, new_cap);
        }

        if (is_centroid or (is_profile and orig_h.num_centroid_words > 0)) {
            const accurate = orig_h.accurate_mass_centroids();
            const n1 = advanced.decode_simplified_centroids_into_buffers(
                orig.memory()[orig_packet_offset..orig_packet_end],
                0,
                mz_orig,
                inten_orig,
                feat_orig,
                allocator,
            ) catch |e| {
                std.log.warn("scan={d}: orig centroid decode failed: {s}", .{ scan_num, @errorName(e) });
                mismatches += 1;
                continue;
            };
            const n2 = advanced.decode_simplified_centroids_into_buffers(
                copy.memory()[copy_packet_offset..copy_packet_end],
                0,
                mz_copy,
                inten_copy,
                feat_copy,
                allocator,
            ) catch |e| {
                std.log.warn("scan={d}: copy centroid decode failed: {s}", .{ scan_num, @errorName(e) });
                mismatches += 1;
                continue;
            };
            if (n1 != n2) {
                std.log.warn("scan={d}: centroid peak count orig={d} copy={d}", .{ scan_num, n1, n2 });
                mismatches += 1;
                continue;
            }
            var scan_bad = false;
            const tol: f64 = if (accurate) 1e-9 else 0.001;
            for (0..n1) |i| {
                if (@abs(mz_orig[i] - mz_copy[i]) > tol) scan_bad = true;
                if (@abs(inten_orig[i] - inten_copy[i]) > 0.001) scan_bad = true;
            }
            if (scan_bad) {
                std.log.warn("scan={d}: centroid data differs", .{scan_num});
                mismatches += 1;
            }
        } else {
            // Pure profile: compare frequencies and intensities
            const n1 = profile.decode_ft_profile(
                orig.memory()[orig_packet_offset..orig_packet_end],
                &[_]f64{},
                mz_orig,
                inten_orig,
                false,
            ) catch |e| {
                std.log.warn("scan={d}: orig profile decode failed: {s}", .{ scan_num, @errorName(e) });
                mismatches += 1;
                continue;
            };
            const n2 = profile.decode_ft_profile(
                copy.memory()[copy_packet_offset..copy_packet_end],
                &[_]f64{},
                mz_copy,
                inten_copy,
                false,
            ) catch |e| {
                std.log.warn("scan={d}: copy profile decode failed: {s}", .{ scan_num, @errorName(e) });
                mismatches += 1;
                continue;
            };
            if (n1 != n2) {
                std.log.warn("scan={d}: profile point count orig={d} copy={d}", .{ scan_num, n1, n2 });
                mismatches += 1;
                continue;
            }
            var scan_bad = false;
            for (0..n1) |i| {
                if (@abs(mz_orig[i] - mz_copy[i]) > 0.001) scan_bad = true;
                if (@abs(inten_orig[i] - inten_copy[i]) > 0.001) scan_bad = true;
            }
            if (scan_bad) {
                std.log.warn("scan={d}: profile data differs", .{scan_num});
                mismatches += 1;
            }
        }
    }

    return mismatches;
}
