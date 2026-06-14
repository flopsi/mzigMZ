/// C#-compatible Adler32 implementation matching Thermo CommonCore behavior.
const std = @import("std");

/// C#-compatible Adler32 (seed=0 initial state, not standard seed=1).
pub fn calc_adler32(seed: u32, data: []const u8) u32 {
    const base: u32 = 65521;
    const nmax: usize = 5552;
    var num2 = seed & 0xFFFF;
    var num3 = (seed >> 16) & 0xFFFF;
    var i: usize = 0;
    var remaining = data.len;
    while (remaining > 0) {
        var n = @min(remaining, nmax);
        remaining -= n;
        while (n >= 8) {
            num2 += data[i];
            num3 += num2;
            num2 += data[i + 1];
            num3 += num2;
            num2 += data[i + 2];
            num3 += num2;
            num2 += data[i + 3];
            num3 += num2;
            num2 += data[i + 4];
            num3 += num2;
            num2 += data[i + 5];
            num3 += num2;
            num2 += data[i + 6];
            num3 += num2;
            num2 += data[i + 7];
            num3 += num2;
            i += 8;
            n -= 8;
        }
        if (n != 0) {
            for (0..n) |_| {
                num2 += data[i];
                num3 += num2;
                i += 1;
            }
        }
        num2 %= base;
        num3 %= base;
    }
    return (num3 << 16) | num2;
}

/// Compute RAW file checksum matching C# Thermo implementation.
/// Reads the file back to compute the checksum.
/// `allocator` is used for the 64MB I/O buffer; pass the caller's allocator
/// (e.g. GPA or Arena). For large files (≥64MB) the buffer is the dominant
/// allocation; do not pass a leaking/limited allocator here.
pub const ChecksumError = std.mem.Allocator.Error || std.Io.File.ReadPositionalError;

pub fn compute_raw_checksum(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    file_rev: u16,
    header_size: usize,
    file_length: u64,
) ChecksumError!u32 {
    const max_checksum_bytes: u64 = 10_485_760;
    const data_end = @min(file_length, max_checksum_bytes);
    if (data_end <= header_size) return 1;

    const header_buf = try allocator.alloc(u8, header_size);
    defer allocator.free(header_buf);
    _ = try file.readPositionalAll(io, header_buf, 0);
    if (file_rev >= 57 and header_buf.len > 151) {
        for (148..152) |j| header_buf[j] = 0;
    }
    const seed = if (file_rev >= 57) calc_adler32(0, header_buf) else 0;

    const chunk_size: usize = 64 * 1024 * 1024;
    var chunk_buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk_buf);

    var checksum = seed;
    var offset: u64 = header_size;
    while (offset < data_end) {
        const to_read = @min(chunk_buf.len, data_end - offset);
        _ = try file.readPositionalAll(io, chunk_buf[0..to_read], offset);
        checksum = calc_adler32(checksum, chunk_buf[0..to_read]);
        offset += to_read;
    }

    return checksum;
}

/// Read the stored checksum at offset 148.
pub fn read_stored_checksum(file: std.Io.File, io: std.Io) ChecksumError!u32 {
    var b: [4]u8 = undefined;
    _ = try file.readPositionalAll(io, &b, 148);
    return std.mem.readInt(u32, &b, .little);
}
