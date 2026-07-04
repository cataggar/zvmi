//! Minimal Zstandard support for COSI output.
//!
//! This intentionally implements only the small subset needed by this repo:
//! - optional leading skippable frame carrying a 16-byte image identifier,
//! - a single-segment zstd frame,
//! - raw (uncompressed) data blocks only.
//!
//! The result is spec-compliant and decodable by the real `zstd` CLI, trading
//! compression ratio for implementation simplicity and correctness. Zig 0.16's
//! stdlib exposes `std.compress.zstd.Decompress` but no corresponding zstd
//! encoder API, so this raw-block writer remains necessary for `cosi.zig`.

const std = @import("std");

pub const zstd_magic: u32 = 0xFD2F_B528;
pub const skippable_magic: u32 = 0x184D_2A50;
pub const skippable_payload_len: u32 = 16;
pub const max_block_size: usize = 128 * 1024;

pub const Error = std.Io.Writer.Error || error{
    BlockTooLarge,
};

pub const DecodeError = std.mem.Allocator.Error || error{
    BadMagic,
    BadSkippableFrame,
    ReservedBitSet,
    UnsupportedFrame,
    UnsupportedChecksum,
    UnsupportedDictionary,
    UnsupportedBlockType,
    BlockTooLarge,
    Truncated,
    SizeMismatch,
    TrailingBytes,
};

pub fn frameHeaderSize() usize {
    return 4 + 1 + 8;
}

pub fn encodedSize(uncompressed_size: u64, include_skippable: bool) u64 {
    const blocks = @max(@as(u64, 1), std.math.divCeil(u64, uncompressed_size, max_block_size) catch unreachable);
    return (if (include_skippable) 8 + skippable_payload_len else 0) + frameHeaderSize() + blocks * 3 + uncompressed_size;
}

pub fn writeSkippableFrame(writer: *std.Io.Writer, payload: [skippable_payload_len]u8) Error!void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], skippable_magic, .little);
    std.mem.writeInt(u32, header[4..8], skippable_payload_len, .little);
    try writer.writeAll(&header);
    try writer.writeAll(&payload);
}

pub fn writeFrameHeader(writer: *std.Io.Writer, uncompressed_size: u64) Error!void {
    var header: [frameHeaderSize()]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], zstd_magic, .little);
    header[4] = 0xE0; // FCS=8 bytes, single-segment, no checksum/dict.
    std.mem.writeInt(u64, header[5..13], uncompressed_size, .little);
    try writer.writeAll(&header);
}

pub fn writeRawBlock(writer: *std.Io.Writer, bytes: []const u8, is_last: bool) Error!void {
    if (bytes.len > max_block_size) return error.BlockTooLarge;

    const header_value: u32 = (@as(u32, @intCast(bytes.len)) << 3) | @as(u32, @intFromBool(is_last));
    var header: [3]u8 = .{
        @truncate(header_value),
        @truncate(header_value >> 8),
        @truncate(header_value >> 16),
    };
    try writer.writeAll(&header);
    try writer.writeAll(bytes);
}

pub fn writeRawFrameForSlice(writer: *std.Io.Writer, bytes: []const u8, payload: ?[skippable_payload_len]u8) Error!void {
    if (payload) |p| try writeSkippableFrame(writer, p);
    try writeFrameHeader(writer, bytes.len);

    if (bytes.len == 0) {
        try writeRawBlock(writer, &.{}, true);
        return;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const chunk_len = @min(remaining, max_block_size);
        const is_last = offset + chunk_len == bytes.len;
        try writeRawBlock(writer, bytes[offset .. offset + chunk_len], is_last);
        offset += chunk_len;
    }
}

fn readU16Le(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32Le(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readU64Le(bytes: []const u8) u64 {
    std.debug.assert(bytes.len >= 8);
    return @as(u64, bytes[0]) | (@as(u64, bytes[1]) << 8) | (@as(u64, bytes[2]) << 16) | (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) | (@as(u64, bytes[5]) << 40) | (@as(u64, bytes[6]) << 48) | (@as(u64, bytes[7]) << 56);
}

pub const Decoded = struct {
    payload: ?[skippable_payload_len]u8,
    bytes: []u8,
};

pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!Decoded {
    var offset: usize = 0;
    var payload: ?[skippable_payload_len]u8 = null;

    if (encoded.len >= 8) {
        const maybe_magic = readU32Le(encoded[0..4]);
        if (maybe_magic >= skippable_magic and maybe_magic <= skippable_magic + 0xF) {
            const frame_size = readU32Le(encoded[4..8]);
            if (frame_size != skippable_payload_len) return error.BadSkippableFrame;
            if (encoded.len < 8 + frame_size) return error.Truncated;
            var tmp: [skippable_payload_len]u8 = undefined;
            @memcpy(&tmp, encoded[8 .. 8 + frame_size]);
            payload = tmp;
            offset = 8 + frame_size;
        }
    }

    if (encoded.len < offset + frameHeaderSize()) return error.Truncated;
    if (readU32Le(encoded[offset .. offset + 4]) != zstd_magic) return error.BadMagic;
    offset += 4;

    const descriptor = encoded[offset];
    offset += 1;
    if ((descriptor & 0x08) != 0) return error.ReservedBitSet;
    if ((descriptor & 0x10) != 0) return error.UnsupportedFrame;
    if ((descriptor & 0x04) != 0) return error.UnsupportedChecksum;
    if ((descriptor & 0x03) != 0) return error.UnsupportedDictionary;
    if ((descriptor & 0x20) == 0) return error.UnsupportedFrame;

    const fcs_flag: u2 = @truncate(descriptor >> 6);
    const fcs_size: usize = switch (fcs_flag) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
    };
    if (encoded.len < offset + fcs_size) return error.Truncated;

    const content_size: u64 = switch (fcs_size) {
        1 => encoded[offset],
        2 => @as(u64, readU16Le(encoded[offset .. offset + 2])) + 256,
        4 => readU32Le(encoded[offset .. offset + 4]),
        8 => readU64Le(encoded[offset .. offset + 8]),
        else => unreachable,
    };
    offset += fcs_size;

    const out = try allocator.alloc(u8, content_size);
    errdefer allocator.free(out);

    var out_offset: usize = 0;
    while (true) {
        if (encoded.len < offset + 3) return error.Truncated;
        const header_value = @as(u32, encoded[offset]) |
            (@as(u32, encoded[offset + 1]) << 8) |
            (@as(u32, encoded[offset + 2]) << 16);
        offset += 3;

        const is_last = (header_value & 1) != 0;
        const block_type = (header_value >> 1) & 0x3;
        const block_size = header_value >> 3;
        if (block_size > max_block_size) return error.BlockTooLarge;
        if (block_type != 0) return error.UnsupportedBlockType;
        if (encoded.len < offset + block_size) return error.Truncated;
        if (out.len < out_offset + block_size) return error.SizeMismatch;

        @memcpy(out[out_offset .. out_offset + block_size], encoded[offset .. offset + block_size]);
        offset += block_size;
        out_offset += block_size;

        if (is_last) break;
    }

    if (out_offset != out.len) return error.SizeMismatch;
    if (offset != encoded.len) return error.TrailingBytes;

    return .{ .payload = payload, .bytes = out };
}

test "raw-frame encoder round-trips via minimal decoder" {
    const input = "hello zstd raw blocks" ** 4096;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const payload: [skippable_payload_len]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try writeRawFrameForSlice(&out.writer, input[0..], payload);
    try std.testing.expectEqual(encodedSize(input.len, true), out.written().len);

    const decoded = try decodeAlloc(std.testing.allocator, out.written());
    defer std.testing.allocator.free(decoded.bytes);

    try std.testing.expectEqual(payload, decoded.payload.?);
    try std.testing.expectEqualSlices(u8, input[0..], decoded.bytes);
}

test "large input is split into multiple raw blocks" {
    var input: [max_block_size + 17]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate(i);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeRawFrameForSlice(&out.writer, input[0..], null);

    const decoded = try decodeAlloc(std.testing.allocator, out.written());
    defer std.testing.allocator.free(decoded.bytes);

    try std.testing.expect(decoded.payload == null);
    try std.testing.expectEqualSlices(u8, input[0..], decoded.bytes);
}

test "empty input emits a valid empty frame" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeRawFrameForSlice(&out.writer, "", null);
    try std.testing.expectEqual(encodedSize(0, false), out.written().len);

    const decoded = try decodeAlloc(std.testing.allocator, out.written());
    defer std.testing.allocator.free(decoded.bytes);
    try std.testing.expectEqual(@as(usize, 0), decoded.bytes.len);
}
