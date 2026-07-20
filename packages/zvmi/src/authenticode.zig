//! Native Authenticode signing support for unsigned PE/UEFI images.
//!
//! The PE parsing and range-hashing portions are adapted from ghr's
//! `src/authenticode.zig` (MIT, Copyright (c) 2026 Cameron Taggart).
//! This module deliberately contains no private-key operation: callers send
//! `PreparedRsaSha256.signing_digest` to their signing provider and supply
//! the resulting PKCS#1 v1.5 RSA signature to `finishRsaSha256Alloc`.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

const oid_spc_indirect_data = "\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x02\x01\x04";
const oid_spc_pe_image_data = "\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x02\x01\x0f";
const oid_sha256 = "\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01";
const oid_rsa_encryption = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01";
const oid_signed_data = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02";
const oid_content_type = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x03";
const oid_message_digest = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x04";

const Error = error{
    InvalidPe,
    AlreadySigned,
    FileTooLarge,
    InvalidDer,
    InvalidCertificate,
    InvalidSignatureLength,
};

const Pe = struct {
    checksum_offset: usize,
    security_directory_offset: usize,
};

/// Values passed between the external signing operation and CMS construction.
pub const PreparedRsaSha256 = struct {
    aligned_pe: []u8,
    spc_indirect_data: []u8,
    signed_attributes: []u8,
    signing_digest: [32]u8,

    pub fn deinit(self: *PreparedRsaSha256, allocator: std.mem.Allocator) void {
        allocator.free(self.aligned_pe);
        allocator.free(self.spc_indirect_data);
        allocator.free(self.signed_attributes);
        self.* = undefined;
    }
};

/// Prepares an unsigned PE image for external RSA/SHA-256 signing.
pub fn prepareRsaSha256Alloc(
    allocator: std.mem.Allocator,
    unsigned_pe: []const u8,
) !PreparedRsaSha256 {
    try requireU32Size(unsigned_pe.len);
    const aligned_len = try align8(unsigned_pe.len);
    try requireU32Size(aligned_len);

    var aligned_pe = try allocator.alloc(u8, aligned_len);
    errdefer allocator.free(aligned_pe);
    @memcpy(aligned_pe[0..unsigned_pe.len], unsigned_pe);
    @memset(aligned_pe[unsigned_pe.len..], 0);

    const pe = try parseUnsignedPe(aligned_pe);
    var pe_digest: [Sha256.digest_length]u8 = undefined;
    hashPe(aligned_pe, pe, &pe_digest);

    const spc_indirect_data = try makeSpcIndirectData(allocator, pe_digest);
    errdefer allocator.free(spc_indirect_data);

    const signed_attributes = try makeSignedAttributes(allocator, spc_indirect_data);
    errdefer allocator.free(signed_attributes);

    var signing_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(signed_attributes, &signing_digest, .{});
    return .{
        .aligned_pe = aligned_pe,
        .spc_indirect_data = spc_indirect_data,
        .signed_attributes = signed_attributes,
        .signing_digest = signing_digest,
    };
}

/// Embeds a provider-produced PKCS#1 v1.5 RSA/SHA-256 signature in a CMS
/// Authenticode certificate table. Ownership of `prepared` stays with caller.
pub fn finishRsaSha256Alloc(
    allocator: std.mem.Allocator,
    prepared: PreparedRsaSha256,
    certificate_der: []const u8,
    rsa_signature: []const u8,
) ![]u8 {
    if (!validRsaSignatureLength(rsa_signature.len)) return error.InvalidSignatureLength;
    const pe = try parseUnsignedPe(prepared.aligned_pe);
    const issuer_and_serial = try extractIssuerAndSerial(certificate_der);
    const cms = try makeCms(
        allocator,
        prepared.spc_indirect_data,
        prepared.signed_attributes,
        certificate_der,
        issuer_and_serial,
        rsa_signature,
    );
    defer allocator.free(cms);

    const certificate_length = try std.math.add(usize, 8, cms.len);
    try requireU32Size(certificate_length);
    const certificate_table_size = try align8(certificate_length);
    try requireU32Size(certificate_table_size);
    const output_len = try std.math.add(usize, prepared.aligned_pe.len, certificate_table_size);
    try requireU32Size(output_len);

    var output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);
    @memcpy(output[0..prepared.aligned_pe.len], prepared.aligned_pe);
    @memset(output[prepared.aligned_pe.len..], 0);

    writeU32Le(output[pe.security_directory_offset..][0..4], try asU32(prepared.aligned_pe.len));
    writeU32Le(output[pe.security_directory_offset + 4 ..][0..4], try asU32(certificate_table_size));
    const certificate_offset = prepared.aligned_pe.len;
    writeU32Le(output[certificate_offset..][0..4], try asU32(certificate_length));
    writeU16Le(output[certificate_offset + 4 ..][0..2], 0x0200);
    writeU16Le(output[certificate_offset + 6 ..][0..2], 0x0002);
    @memcpy(output[certificate_offset + 8 .. certificate_offset + certificate_length], cms);
    return output;
}

fn parseUnsignedPe(bytes: []const u8) Error!Pe {
    try requireU32Size(bytes.len);
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.InvalidPe;
    const nt_offset = @as(usize, readU32Le(bytes[0x3c..][0..4]));
    if (nt_offset < 0x40) return error.InvalidPe;
    const nt_end = std.math.add(usize, nt_offset, 4) catch return error.InvalidPe;
    if (nt_end > bytes.len or !std.mem.eql(u8, bytes[nt_offset..nt_end], "PE\x00\x00"))
        return error.InvalidPe;

    const file_header_offset = nt_end;
    const file_header_end = std.math.add(usize, file_header_offset, 20) catch return error.InvalidPe;
    if (file_header_end > bytes.len) return error.InvalidPe;
    const optional_size = @as(usize, readU16Le(bytes[file_header_offset + 16 ..][0..2]));
    const optional_offset = file_header_end;
    const optional_end = std.math.add(usize, optional_offset, optional_size) catch return error.InvalidPe;
    if (optional_end > bytes.len) return error.InvalidPe;

    const magic_end = std.math.add(usize, optional_offset, 2) catch return error.InvalidPe;
    if (magic_end > optional_end) return error.InvalidPe;
    const magic = readU16Le(bytes[optional_offset..][0..2]);
    const data_directory_relative_offset: usize = switch (magic) {
        0x10b => 96,
        0x20b => 112,
        else => return error.InvalidPe,
    };
    const checksum_offset = std.math.add(usize, optional_offset, 64) catch return error.InvalidPe;
    const checksum_end = std.math.add(usize, checksum_offset, 4) catch return error.InvalidPe;
    if (checksum_end > optional_end) return error.InvalidPe;

    const count_offset = std.math.add(usize, optional_offset, data_directory_relative_offset - 4) catch return error.InvalidPe;
    const count_end = std.math.add(usize, count_offset, 4) catch return error.InvalidPe;
    if (count_end > optional_end) return error.InvalidPe;
    if (readU32Le(bytes[count_offset..][0..4]) < 5) return error.InvalidPe;

    const security_directory_offset = std.math.add(
        usize,
        optional_offset,
        data_directory_relative_offset + 4 * 8,
    ) catch return error.InvalidPe;
    const security_directory_end = std.math.add(usize, security_directory_offset, 8) catch return error.InvalidPe;
    if (security_directory_end > optional_end) return error.InvalidPe;
    const certificate_offset = readU32Le(bytes[security_directory_offset..][0..4]);
    const certificate_size = readU32Le(bytes[security_directory_offset + 4 ..][0..4]);
    if (certificate_offset != 0 or certificate_size != 0) return error.AlreadySigned;
    return .{
        .checksum_offset = checksum_offset,
        .security_directory_offset = security_directory_offset,
    };
}

fn hashPe(bytes: []const u8, pe: Pe, digest: *[Sha256.digest_length]u8) void {
    var hash = Sha256.init(.{});
    hash.update(bytes[0..pe.checksum_offset]);
    hash.update(bytes[pe.checksum_offset + 4 .. pe.security_directory_offset]);
    hash.update(bytes[pe.security_directory_offset + 8 ..]);
    hash.final(digest);
}

fn makeSpcIndirectData(allocator: std.mem.Allocator, pe_digest: [32]u8) ![]u8 {
    var data = std.array_list.Managed(u8).init(allocator);
    defer data.deinit();
    try data.appendSlice("\x30\x33");
    try data.appendSlice(oid_spc_pe_image_data);
    try data.appendSlice("\x30\x25\x03\x01\x00\xa0\x20\xa2\x1e\x80\x1c");
    try data.appendSlice(
        "\x00\x3c\x00\x3c\x00\x3c\x00\x4f\x00\x62\x00\x73\x00\x6f\x00\x6c" ++
            "\x00\x65\x00\x74\x00\x65\x00\x3e\x00\x3e\x00\x3e",
    );

    const digest_algorithm = try algorithmIdentifier(allocator, oid_sha256);
    defer allocator.free(digest_algorithm);
    var digest_info = std.array_list.Managed(u8).init(allocator);
    defer digest_info.deinit();
    try digest_info.appendSlice(digest_algorithm);
    try appendDer(&digest_info, 0x04, &pe_digest);

    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    try body.appendSlice(data.items);
    try appendDer(&body, 0x30, digest_info.items);
    return wrapDer(allocator, 0x30, body.items);
}

fn makeSignedAttributes(allocator: std.mem.Allocator, spc: []const u8) ![]u8 {
    if (spc.len < 2 or spc[0] != 0x30) return error.InvalidDer;
    const spc_element = try parseDerElement(spc, 0);
    if (spc_element.end != spc.len) return error.InvalidDer;
    var content_type_value = std.array_list.Managed(u8).init(allocator);
    defer content_type_value.deinit();
    try content_type_value.appendSlice(oid_spc_indirect_data);
    const content_type_set = try wrapDer(allocator, 0x31, content_type_value.items);
    defer allocator.free(content_type_set);
    const content_type_attribute = try makeAttribute(allocator, oid_content_type, content_type_set);
    defer allocator.free(content_type_attribute);

    var message_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(spc[spc_element.content_start..spc_element.end], &message_digest, .{});
    const digest_value = try wrapDer(allocator, 0x04, &message_digest);
    defer allocator.free(digest_value);
    const digest_set = try wrapDer(allocator, 0x31, digest_value);
    defer allocator.free(digest_set);
    const digest_attribute = try makeAttribute(allocator, oid_message_digest, digest_set);
    defer allocator.free(digest_attribute);

    var set_body = std.array_list.Managed(u8).init(allocator);
    defer set_body.deinit();
    if (std.mem.order(u8, content_type_attribute, digest_attribute) == .gt) {
        try set_body.appendSlice(digest_attribute);
        try set_body.appendSlice(content_type_attribute);
    } else {
        try set_body.appendSlice(content_type_attribute);
        try set_body.appendSlice(digest_attribute);
    }
    return wrapDer(allocator, 0x31, set_body.items);
}

fn makeAttribute(allocator: std.mem.Allocator, oid: []const u8, value_set: []const u8) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    try body.appendSlice(oid);
    try body.appendSlice(value_set);
    return wrapDer(allocator, 0x30, body.items);
}

const IssuerAndSerial = struct {
    issuer: []const u8,
    serial: []const u8,
};

fn extractIssuerAndSerial(certificate: []const u8) Error!IssuerAndSerial {
    try requireU32Size(certificate.len);
    const outer = try parseCertificateElement(certificate, 0);
    if (outer.tag != 0x30 or outer.end != certificate.len) return error.InvalidCertificate;
    try validateCertificateDer(certificate, outer);
    const tbs = try parseCertificateElement(certificate, outer.content_start);
    if (tbs.tag != 0x30 or tbs.end > outer.end) return error.InvalidCertificate;
    var index = tbs.content_start;
    var field = try parseCertificateElement(certificate, index);
    if (field.tag == 0xa0) {
        const version = try parseCertificateElement(certificate, field.content_start);
        if (version.tag != 0x02 or version.end != field.end) return error.InvalidCertificate;
        index = field.end;
        field = try parseCertificateElement(certificate, index);
    }
    if (field.tag != 0x02 or field.content_start == field.end) return error.InvalidCertificate;
    const serial = certificate[field.start..field.end];
    index = field.end;
    const signature_algorithm = try parseCertificateElement(certificate, index);
    if (signature_algorithm.tag != 0x30) return error.InvalidCertificate;
    index = signature_algorithm.end;
    const issuer_field = try parseCertificateElement(certificate, index);
    if (issuer_field.tag != 0x30) return error.InvalidCertificate;
    const issuer = certificate[issuer_field.start..issuer_field.end];

    index = issuer_field.end;
    while (index < tbs.end) index = (try parseCertificateElement(certificate, index)).end;
    if (index != tbs.end) return error.InvalidCertificate;
    index = tbs.end;
    const outer_signature = try parseCertificateElement(certificate, index);
    if (outer_signature.tag != 0x30) return error.InvalidCertificate;
    const signature_value = try parseCertificateElement(certificate, outer_signature.end);
    if (signature_value.tag != 0x03 or signature_value.end != outer.end) return error.InvalidCertificate;
    return .{ .issuer = issuer, .serial = serial };
}

fn makeCms(
    allocator: std.mem.Allocator,
    spc: []const u8,
    signed_attributes: []const u8,
    certificate: []const u8,
    issuer_and_serial: IssuerAndSerial,
    rsa_signature: []const u8,
) ![]u8 {
    const sha256_algorithm = try algorithmIdentifier(allocator, oid_sha256);
    defer allocator.free(sha256_algorithm);
    const rsa_algorithm = try algorithmIdentifier(allocator, oid_rsa_encryption);
    defer allocator.free(rsa_algorithm);

    var digest_algorithms = std.array_list.Managed(u8).init(allocator);
    defer digest_algorithms.deinit();
    try digest_algorithms.appendSlice(sha256_algorithm);
    const digest_algorithm_set = try wrapDer(allocator, 0x31, digest_algorithms.items);
    defer allocator.free(digest_algorithm_set);

    var encap_body = std.array_list.Managed(u8).init(allocator);
    defer encap_body.deinit();
    try encap_body.appendSlice(oid_spc_indirect_data);
    const explicit_spc = try wrapDer(allocator, 0xa0, spc);
    defer allocator.free(explicit_spc);
    try encap_body.appendSlice(explicit_spc);
    const encap = try wrapDer(allocator, 0x30, encap_body.items);
    defer allocator.free(encap);

    const issuer_and_serial_sequence = blk: {
        var body = std.array_list.Managed(u8).init(allocator);
        defer body.deinit();
        try body.appendSlice(issuer_and_serial.issuer);
        try body.appendSlice(issuer_and_serial.serial);
        break :blk try wrapDer(allocator, 0x30, body.items);
    };
    defer allocator.free(issuer_and_serial_sequence);
    var signer_body = std.array_list.Managed(u8).init(allocator);
    defer signer_body.deinit();
    try signer_body.appendSlice("\x02\x01\x01");
    try signer_body.appendSlice(issuer_and_serial_sequence);
    try signer_body.appendSlice(sha256_algorithm);
    if (signed_attributes.len < 2 or signed_attributes[0] != 0x31) return error.InvalidDer;
    const signed_attributes_element = try parseDerElement(signed_attributes, 0);
    if (signed_attributes_element.end != signed_attributes.len) return error.InvalidDer;
    try signer_body.append(0xa0);
    try appendDerLength(&signer_body, signed_attributes.len - signed_attributes_element.content_start);
    try signer_body.appendSlice(signed_attributes[signed_attributes_element.content_start..]);
    try signer_body.appendSlice(rsa_algorithm);
    try appendDer(&signer_body, 0x04, rsa_signature);
    const signer_info = try wrapDer(allocator, 0x30, signer_body.items);
    defer allocator.free(signer_info);
    const signer_infos = try wrapDer(allocator, 0x31, signer_info);
    defer allocator.free(signer_infos);

    var signed_data_body = std.array_list.Managed(u8).init(allocator);
    defer signed_data_body.deinit();
    try signed_data_body.appendSlice("\x02\x01\x01");
    try signed_data_body.appendSlice(digest_algorithm_set);
    try signed_data_body.appendSlice(encap);
    try signed_data_body.append(0xa0);
    try appendDerLength(&signed_data_body, certificate.len);
    try signed_data_body.appendSlice(certificate);
    try signed_data_body.appendSlice(signer_infos);
    const signed_data = try wrapDer(allocator, 0x30, signed_data_body.items);
    defer allocator.free(signed_data);

    var content_info = std.array_list.Managed(u8).init(allocator);
    defer content_info.deinit();
    try content_info.appendSlice(oid_signed_data);
    const explicit_signed_data = try wrapDer(allocator, 0xa0, signed_data);
    defer allocator.free(explicit_signed_data);
    try content_info.appendSlice(explicit_signed_data);
    return wrapDer(allocator, 0x30, content_info.items);
}

fn algorithmIdentifier(allocator: std.mem.Allocator, oid: []const u8) ![]u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    try body.appendSlice(oid);
    try body.appendSlice("\x05\x00");
    return wrapDer(allocator, 0x30, body.items);
}

fn wrapDer(allocator: std.mem.Allocator, tag: u8, content: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try appendDer(&result, tag, content);
    return result.toOwnedSlice();
}

fn appendDer(list: *std.array_list.Managed(u8), tag: u8, content: []const u8) !void {
    try list.append(tag);
    try appendDerLength(list, content.len);
    try list.appendSlice(content);
}

fn appendDerLength(list: *std.array_list.Managed(u8), length: usize) !void {
    if (length < 128) {
        try list.append(@intCast(length));
        return;
    }
    var bytes: [@sizeOf(usize)]u8 = undefined;
    var value = length;
    var count: usize = 0;
    while (value != 0) : (value >>= 8) {
        bytes[bytes.len - 1 - count] = @truncate(value);
        count += 1;
    }
    try list.append(@intCast(0x80 | count));
    try list.appendSlice(bytes[bytes.len - count ..]);
}

const DerElement = struct {
    tag: u8,
    start: usize,
    content_start: usize,
    end: usize,
};

fn parseDerElement(bytes: []const u8, start: usize) Error!DerElement {
    const minimum = std.math.add(usize, start, 2) catch return error.InvalidDer;
    if (minimum > bytes.len) return error.InvalidDer;
    const tag = bytes[start];
    if ((tag & 0x1f) == 0x1f) return error.InvalidDer;
    const length_byte = bytes[start + 1];
    var content_start = minimum;
    var length: usize = 0;
    if (length_byte < 0x80) {
        length = length_byte;
    } else {
        const count: usize = length_byte & 0x7f;
        if (count == 0 or count > @sizeOf(u32)) return error.InvalidDer;
        const length_end = std.math.add(usize, content_start, count) catch return error.InvalidDer;
        if (length_end > bytes.len or bytes[content_start] == 0) return error.InvalidDer;
        var i = content_start;
        while (i < length_end) : (i += 1) {
            length = std.math.mul(usize, length, 256) catch return error.InvalidDer;
            length = std.math.add(usize, length, bytes[i]) catch return error.InvalidDer;
        }
        if (length < 128) return error.InvalidDer;
        content_start = length_end;
    }
    const end = std.math.add(usize, content_start, length) catch return error.InvalidDer;
    if (end > bytes.len) return error.InvalidDer;
    return .{ .tag = tag, .start = start, .content_start = content_start, .end = end };
}

fn parseCertificateElement(bytes: []const u8, start: usize) Error!DerElement {
    const strict = parseDerElement(bytes, start) catch return error.InvalidCertificate;
    const index = std.math.cast(u32, start) orelse return error.InvalidCertificate;
    const standard = std.crypto.Certificate.der.Element.parse(bytes, index) catch return error.InvalidCertificate;
    if (standard.slice.start != strict.content_start or standard.slice.end != strict.end)
        return error.InvalidCertificate;
    return strict;
}

fn validateCertificateDer(bytes: []const u8, element: DerElement) Error!void {
    if ((element.tag & 0x20) == 0) return;
    var index = element.content_start;
    while (index < element.end) {
        const child = try parseCertificateElement(bytes, index);
        try validateCertificateDer(bytes, child);
        index = child.end;
    }
    if (index != element.end) return error.InvalidCertificate;
}

fn align8(length: usize) Error!usize {
    const with_padding = std.math.add(usize, length, 7) catch return error.FileTooLarge;
    return with_padding & ~@as(usize, 7);
}

fn requireU32Size(value: usize) Error!void {
    _ = try asU32(value);
}

fn asU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.FileTooLarge;
}

fn validRsaSignatureLength(length: usize) bool {
    return length == 128 or length == 256 or length == 384 or length == 512;
}

fn readU16Le(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .little);
}

fn readU32Le(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn writeU16Le(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .little);
}

fn writeU32Le(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

test "prepare aligns and hashes a PE32+ image" {
    const allocator = std.testing.allocator;
    const image = try makeTestPe(allocator, 394);
    defer allocator.free(image);
    var prepared = try prepareRsaSha256Alloc(allocator, image);
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 400), prepared.aligned_pe.len);
    try std.testing.expectEqual(@as(u8, 0x31), prepared.signed_attributes[0]);
    try std.testing.expectEqualSlices(
        u8,
        "\x30\x68\x30\x33\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x02\x01\x0f",
        prepared.spc_indirect_data[0..16],
    );
    try std.testing.expectEqualSlices(
        u8,
        "\x30\x31\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00\x04\x20",
        prepared.spc_indirect_data[55..74],
    );
    try std.testing.expectEqualSlices(
        u8,
        "\x31\x4c\x30\x19\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x03\x31\x0c" ++
            "\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x02\x01\x04\x30\x2f\x06\x09" ++
            "\x2a\x86\x48\x86\xf7\x0d\x01\x09\x04\x31\x22\x04\x20",
        prepared.signed_attributes[0..46],
    );
}

test "PE ranges exclude checksum and security directory" {
    const allocator = std.testing.allocator;
    var image = try makeTestPe(allocator, 512);
    defer allocator.free(image);
    var first = try prepareRsaSha256Alloc(allocator, image);
    defer first.deinit(allocator);
    image[0xd8] ^= 1;
    var second = try prepareRsaSha256Alloc(allocator, image);
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &first.signing_digest, &second.signing_digest);
    const pe = try parseUnsignedPe(image);
    var before: [Sha256.digest_length]u8 = undefined;
    hashPe(image, pe, &before);
    image[0x128] ^= 1;
    var after: [Sha256.digest_length]u8 = undefined;
    hashPe(image, pe, &after);
    try std.testing.expectEqualSlices(u8, &before, &after);
    image[0x128] ^= 1;
    image[0x150] ^= 1;
    var third = try prepareRsaSha256Alloc(allocator, image);
    defer third.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, &first.signing_digest, &third.signing_digest));
}

test "unsigned validation rejects absent directory and signed images" {
    const allocator = std.testing.allocator;
    var image = try makeTestPe(allocator, 512);
    defer allocator.free(image);
    try std.testing.expectError(error.InvalidPe, prepareRsaSha256Alloc(allocator, image[0..0x90]));
    writeU32Le(image[0x104..][0..4], 4);
    try std.testing.expectError(error.InvalidPe, prepareRsaSha256Alloc(allocator, image));
    writeU32Le(image[0x104..][0..4], 5);
    writeU32Le(image[0x128..][0..4], 1);
    try std.testing.expectError(error.AlreadySigned, prepareRsaSha256Alloc(allocator, image));
}

test "finish writes an aligned WIN_CERTIFICATE and security directory" {
    const allocator = std.testing.allocator;
    const image = try makeTestPe(allocator, 393);
    defer allocator.free(image);
    var prepared = try prepareRsaSha256Alloc(allocator, image);
    defer prepared.deinit(allocator);
    const certificate = testCertificate();
    const signature = [_]u8{0} ** 256;
    const signed = try finishRsaSha256Alloc(allocator, prepared, certificate, &signature);
    defer allocator.free(signed);

    const table_offset = prepared.aligned_pe.len;
    const table_size = @as(usize, readU32Le(signed[0x12c..][0..4]));
    try std.testing.expectEqual(@as(u32, @intCast(table_offset)), readU32Le(signed[0x128..][0..4]));
    try std.testing.expectEqual(@as(usize, 0), table_size % 8);
    try std.testing.expectEqual(@as(u16, 0x0200), readU16Le(signed[table_offset + 4 ..][0..2]));
    try std.testing.expectEqual(@as(u16, 0x0002), readU16Le(signed[table_offset + 6 ..][0..2]));
    const entry_size = @as(usize, readU32Le(signed[table_offset..][0..4]));
    try std.testing.expect(entry_size <= table_size);
    try std.testing.expect(std.mem.indexOf(u8, signed[table_offset + 8 ..], "\x30\x00\x02\x02\x00\x01") != null);
}

test "finish rejects malformed certificates and unsupported signatures" {
    const allocator = std.testing.allocator;
    const image = try makeTestPe(allocator, 512);
    defer allocator.free(image);
    var prepared = try prepareRsaSha256Alloc(allocator, image);
    defer prepared.deinit(allocator);
    const short_signature = [_]u8{0} ** 127;
    try std.testing.expectError(
        error.InvalidSignatureLength,
        finishRsaSha256Alloc(allocator, prepared, testCertificate(), &short_signature),
    );
    try std.testing.expectError(
        error.InvalidSignatureLength,
        finishRsaSha256Alloc(allocator, prepared, testCertificate(), ""),
    );
    const signature = [_]u8{0} ** 128;
    try std.testing.expectError(
        error.InvalidCertificate,
        finishRsaSha256Alloc(allocator, prepared, "\x30\x01\x00", &signature),
    );
}

test "alignment padding contributes to PE digest" {
    const allocator = std.testing.allocator;
    const image = try makeTestPe(allocator, 393);
    defer allocator.free(image);
    var prepared = try prepareRsaSha256Alloc(allocator, image);
    defer prepared.deinit(allocator);
    const pe = try parseUnsignedPe(prepared.aligned_pe);
    var original: [Sha256.digest_length]u8 = undefined;
    hashPe(prepared.aligned_pe, pe, &original);
    prepared.aligned_pe[prepared.aligned_pe.len - 1] = 1;
    var changed: [Sha256.digest_length]u8 = undefined;
    hashPe(prepared.aligned_pe, pe, &changed);
    try std.testing.expect(!std.mem.eql(u8, &original, &changed));
}

fn testCertificate() []const u8 {
    return "\x30\x1a" ++
        "\x30\x13\xa0\x03\x02\x01\x02\x02\x02\x00\x01\x30\x00\x30\x00\x30\x00\x30\x00\x30\x00" ++
        "\x30\x00\x03\x01\x00";
}

fn makeTestPe(allocator: std.mem.Allocator, length: usize) ![]u8 {
    var image = try allocator.alloc(u8, length);
    @memset(image, 0);
    image[0] = 'M';
    image[1] = 'Z';
    writeU32Le(image[0x3c..][0..4], 0x80);
    @memcpy(image[0x80..0x84], "PE\x00\x00");
    writeU16Le(image[0x94..][0..2], 0xf0);
    writeU16Le(image[0x98..][0..2], 0x20b);
    writeU32Le(image[0x104..][0..4], 5);
    return image;
}
