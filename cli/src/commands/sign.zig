//! `zvmi sign` implements the external UKI signer protocol used by the
//! Azure Linux release builder. The private key remains in Azure Key Vault
//! or Managed HSM; this command exchanges GitHub OIDC for a short-lived token
//! and submits only the Authenticode signed-attributes digest.

const std = @import("std");
const zvmi = @import("zvmi");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const Io = std.Io;

const max_unsigned_bytes = 512 * 1024 * 1024;
const max_certificate_bytes = 1024 * 1024;
const max_response_bytes = 1024 * 1024;
const key_vault_api_version = "2025-07-01";
const github_oidc_prefix = "https://vstoken.actions.githubusercontent.com/";
const oidc_audience = "api%3A%2F%2FAzureADTokenExchange";

const OidcResponse = struct {
    value: []const u8,
};

const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
};

const SignResponse = struct {
    kid: []const u8,
    value: []const u8,
};

pub fn run(
    allocator: Allocator,
    io: Io,
    environ: Environ,
    args: []const []const u8,
) u8 {
    if (args.len != 0) {
        std.debug.print("usage: zvmi sign\n", .{});
        return 1;
    }
    runFallible(allocator, io, environ) catch |err| {
        std.debug.print("zvmi sign: failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runFallible(allocator: Allocator, io: Io, environ: Environ) !void {
    const unsigned_path = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_UNSIGNED",
    );
    defer allocator.free(unsigned_path);
    const signed_path = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_SIGNED",
    );
    defer allocator.free(signed_path);
    const certificate_path = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_CERTIFICATE",
    );
    defer allocator.free(certificate_path);
    const expected_unsigned_text = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_UNSIGNED_SHA256",
    );
    defer allocator.free(expected_unsigned_text);
    const expected_certificate_text = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_CERTIFICATE_SHA256",
    );
    defer allocator.free(expected_certificate_text);
    const tenant_id = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_AZURE_TENANT_ID",
    );
    defer allocator.free(tenant_id);
    const client_id = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_AZURE_CLIENT_ID",
    );
    defer allocator.free(client_id);
    const key_id = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_AZURE_KEY_ID",
    );
    defer allocator.free(key_id);
    const key_version = try requiredEnvAlloc(
        allocator,
        environ,
        "ZVMI_UKI_SIGNING_KEY_VERSION",
    );
    defer allocator.free(key_version);
    const oidc_request_url = try requiredEnvAlloc(
        allocator,
        environ,
        "ACTIONS_ID_TOKEN_REQUEST_URL",
    );
    defer allocator.free(oidc_request_url);
    const oidc_request_token = try requiredEnvAlloc(
        allocator,
        environ,
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    );
    defer allocator.free(oidc_request_token);

    if (!isUuid(tenant_id) or !isUuid(client_id)) return error.InvalidAzureIdentity;
    try validateKeyId(key_id, key_version);
    try validateOidcRequestUrl(oidc_request_url);

    const unsigned = try Dir.cwd().readFileAlloc(
        io,
        unsigned_path,
        allocator,
        .limited(max_unsigned_bytes),
    );
    defer allocator.free(unsigned);
    const expected_unsigned = try zvmi.artifact_pipeline.parseSha256(
        expected_unsigned_text,
    );
    const actual_unsigned = zvmi.artifact_pipeline.sha256Bytes(unsigned);
    if (!std.mem.eql(u8, &actual_unsigned, &expected_unsigned))
        return error.UnsignedUkiDigestMismatch;

    const certificate_pem = try Dir.cwd().readFileAlloc(
        io,
        certificate_path,
        allocator,
        .limited(max_certificate_bytes),
    );
    defer allocator.free(certificate_pem);
    const certificate_der = try decodePemCertificateAlloc(
        allocator,
        certificate_pem,
    );
    defer allocator.free(certificate_der);
    const expected_certificate = try zvmi.artifact_pipeline.parseSha256(
        expected_certificate_text,
    );
    const actual_certificate = zvmi.artifact_pipeline.sha256Bytes(
        certificate_der,
    );
    if (!std.mem.eql(u8, &actual_certificate, &expected_certificate))
        return error.SigningCertificateFingerprintMismatch;

    var prepared = try zvmi.authenticode.prepareRsaSha256Alloc(
        allocator,
        unsigned,
    );
    defer prepared.deinit(allocator);

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();
    const signature = try signDigestWithAzureKeyVaultAlloc(
        allocator,
        &http_client,
        oidc_request_url,
        oidc_request_token,
        tenant_id,
        client_id,
        key_id,
        prepared.signing_digest,
    );
    defer allocator.free(signature);

    const signed = try zvmi.authenticode.finishRsaSha256Alloc(
        allocator,
        prepared,
        certificate_der,
        signature,
    );
    defer allocator.free(signed);
    try writeAtomic(io, allocator, signed_path, signed);
}

fn requiredEnvAlloc(
    allocator: Allocator,
    environ: Environ,
    name: []const u8,
) ![]u8 {
    const value = try environ.getAlloc(allocator, name);
    errdefer allocator.free(value);
    if (value.len == 0) return error.EmptyEnvironmentVariable;
    return value;
}

fn signDigestWithAzureKeyVaultAlloc(
    allocator: Allocator,
    client: *std.http.Client,
    oidc_request_url: []const u8,
    oidc_request_token: []const u8,
    tenant_id: []const u8,
    client_id: []const u8,
    key_id: []const u8,
    digest: [32]u8,
) ![]u8 {
    const audience_url = try appendOidcAudienceAlloc(
        allocator,
        oidc_request_url,
    );
    defer allocator.free(audience_url);
    const oidc_authorization = try std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{oidc_request_token},
    );
    defer allocator.free(oidc_authorization);
    const oidc_body = try fetchBoundedAlloc(
        allocator,
        client,
        .GET,
        audience_url,
        null,
        &.{.{ .name = "Accept", .value = "application/json" }},
        &.{.{ .name = "Authorization", .value = oidc_authorization }},
    );
    defer allocator.free(oidc_body);
    const oidc = try std.json.parseFromSlice(
        OidcResponse,
        allocator,
        oidc_body,
        .{ .ignore_unknown_fields = true },
    );
    defer oidc.deinit();
    if (oidc.value.value.len == 0) return error.EmptyGithubOidcToken;

    const token_url = try std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{tenant_id},
    );
    defer allocator.free(token_url);
    const token_form = try formEncodeAlloc(allocator, &.{
        .{ "client_id", client_id },
        .{ "scope", azureTokenScope(key_id) },
        .{
            "client_assertion_type",
            "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        },
        .{ "client_assertion", oidc.value.value },
        .{ "grant_type", "client_credentials" },
    });
    defer allocator.free(token_form);
    const token_body = try fetchBoundedAlloc(
        allocator,
        client,
        .POST,
        token_url,
        token_form,
        &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        &.{},
    );
    defer allocator.free(token_body);
    const token = try std.json.parseFromSlice(
        TokenResponse,
        allocator,
        token_body,
        .{ .ignore_unknown_fields = true },
    );
    defer token.deinit();
    if (!std.ascii.eqlIgnoreCase(token.value.token_type, "Bearer") or
        token.value.access_token.len == 0)
    {
        return error.InvalidAzureAccessToken;
    }

    var digest_text_buf: [
        std.base64.url_safe_no_pad.Encoder.calcSize(
            digest.len,
        )
    ]u8 = undefined;
    const digest_text = std.base64.url_safe_no_pad.Encoder.encode(
        &digest_text_buf,
        &digest,
    );
    const request_body = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .alg = "RS256", .value = digest_text },
        .{},
    );
    defer allocator.free(request_body);
    const sign_url = try std.fmt.allocPrint(
        allocator,
        "{s}/sign?api-version={s}",
        .{ key_id, key_vault_api_version },
    );
    defer allocator.free(sign_url);
    const key_authorization = try std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{token.value.access_token},
    );
    defer allocator.free(key_authorization);
    const sign_body = try fetchBoundedAlloc(
        allocator,
        client,
        .POST,
        sign_url,
        request_body,
        &.{.{ .name = "Content-Type", .value = "application/json" }},
        &.{.{ .name = "Authorization", .value = key_authorization }},
    );
    defer allocator.free(sign_body);
    const response = try std.json.parseFromSlice(
        SignResponse,
        allocator,
        sign_body,
        .{ .ignore_unknown_fields = true },
    );
    defer response.deinit();
    if (!std.mem.eql(u8, response.value.kid, key_id))
        return error.AzureKeyIdMismatch;

    const signature_size = try std.base64.url_safe_no_pad.Decoder
        .calcSizeForSlice(response.value.value);
    if (signature_size != 128 and signature_size != 256 and
        signature_size != 384 and signature_size != 512)
    {
        return error.InvalidRsaSignatureSize;
    }
    const signature = try allocator.alloc(u8, signature_size);
    errdefer allocator.free(signature);
    try std.base64.url_safe_no_pad.Decoder.decode(
        signature,
        response.value.value,
    );
    return signature;
}

fn fetchBoundedAlloc(
    allocator: Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    privileged_headers: []const std.http.Header,
) ![]u8 {
    const storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &writer,
        .redirect_behavior = .not_allowed,
        .extra_headers = headers,
        .privileged_headers = privileged_headers,
    });
    if (result.status != .ok) return error.UnexpectedHttpStatus;
    return allocator.dupe(u8, writer.buffered());
}

fn appendOidcAudienceAlloc(
    allocator: Allocator,
    request_url: []const u8,
) ![]u8 {
    if (std.mem.indexOf(u8, request_url, "audience=") != null)
        return error.UnexpectedOidcAudience;
    const separator: u8 = if (std.mem.indexOfScalar(u8, request_url, '?') == null)
        '?'
    else
        '&';
    return std.fmt.allocPrint(
        allocator,
        "{s}{c}audience={s}",
        .{ request_url, separator, oidc_audience },
    );
}

fn formEncodeAlloc(
    allocator: Allocator,
    fields: []const struct { []const u8, []const u8 },
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (fields, 0..) |field, index| {
        if (index != 0) try output.writer.writeByte('&');
        try writeFormComponent(&output.writer, field[0]);
        try output.writer.writeByte('=');
        try writeFormComponent(&output.writer, field[1]);
    }
    return output.toOwnedSlice();
}

fn writeFormComponent(writer: *std.Io.Writer, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~')
        {
            continue;
        }
        try writer.print("{s}%{X:0>2}", .{ value[start..index], byte });
        start = index + 1;
    }
    try writer.writeAll(value[start..]);
}

fn decodePemCertificateAlloc(
    allocator: Allocator,
    pem: []const u8,
) ![]u8 {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const begin = std.mem.indexOf(u8, pem, begin_marker) orelse
        return error.InvalidCertificatePem;
    if (std.mem.trim(u8, pem[0..begin], " \t\r\n").len != 0)
        return error.InvalidCertificatePem;
    const body_start = begin + begin_marker.len;
    const relative_end = std.mem.indexOf(u8, pem[body_start..], end_marker) orelse
        return error.InvalidCertificatePem;
    const body_end = body_start + relative_end;
    const suffix = pem[body_end + end_marker.len ..];
    if (std.mem.trim(u8, suffix, " \t\r\n").len != 0)
        return error.InvalidCertificatePem;

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    for (pem[body_start..body_end]) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        try encoded.writer.writeByte(byte);
    }
    const encoded_slice = encoded.written();
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(
        encoded_slice,
    );
    if (decoded_size == 0 or decoded_size > max_certificate_bytes)
        return error.InvalidCertificatePem;
    const certificate = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(certificate);
    try std.base64.standard.Decoder.decode(certificate, encoded_slice);
    return certificate;
}

fn validateOidcRequestUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, github_oidc_prefix) or
        std.mem.indexOfScalar(u8, url, '#') != null or
        std.mem.indexOfAny(u8, url, " \t\r\n") != null)
    {
        return error.InvalidGithubOidcUrl;
    }
}

fn validateKeyId(key_id: []const u8, expected_version: []const u8) !void {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, key_id, prefix) or
        std.mem.indexOfAny(u8, key_id, "?#% \t\r\n") != null)
    {
        return error.InvalidAzureKeyId;
    }
    const remainder = key_id[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse
        return error.InvalidAzureKeyId;
    const host = remainder[0..slash];
    if ((!std.mem.endsWith(u8, host, ".vault.azure.net") and
        !std.mem.endsWith(u8, host, ".managedhsm.azure.net")) or
        host.len == 0)
    {
        return error.InvalidAzureKeyId;
    }
    for (host) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            byte == '-' or byte == '.'))
        {
            return error.InvalidAzureKeyId;
        }
    }

    var segments = std.mem.splitScalar(u8, remainder[slash + 1 ..], '/');
    if (!std.mem.eql(u8, segments.next() orelse "", "keys"))
        return error.InvalidAzureKeyId;
    const key_name = segments.next() orelse return error.InvalidAzureKeyId;
    const key_version = segments.next() orelse return error.InvalidAzureKeyId;
    if (segments.next() != null or key_name.len == 0 or key_version.len == 0 or
        !std.mem.eql(u8, key_version, expected_version))
    {
        return error.InvalidAzureKeyId;
    }
    for (key_name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-'))
            return error.InvalidAzureKeyId;
    }
    for (key_version) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidAzureKeyId;
    }
}

fn azureTokenScope(key_id: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, key_id, ".managedhsm.azure.net/") != null)
        "https://managedhsm.azure.net/.default"
    else
        "https://vault.azure.net/.default";
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }
    return true;
}

fn writeAtomic(
    io: Io,
    allocator: Allocator,
    destination: []const u8,
    bytes: []const u8,
) !void {
    const temporary = try std.fmt.allocPrint(
        allocator,
        "{s}.zvmi-signing",
        .{destination},
    );
    defer allocator.free(temporary);
    Dir.cwd().deleteFile(io, temporary) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer Dir.cwd().deleteFile(io, temporary) catch {};
    try Dir.cwd().writeFile(io, .{
        .sub_path = temporary,
        .data = bytes,
        .flags = .{
            .truncate = true,
            .permissions = .fromMode(0o600),
        },
    });
    try Dir.cwd().renamePreserve(temporary, Dir.cwd(), destination, io);
}

test "form encoding protects assertion delimiters" {
    const encoded = try formEncodeAlloc(std.testing.allocator, &.{
        .{ "scope", "https://vault.azure.net/.default" },
        .{ "assertion", "a+b/c=d" },
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "scope=https%3A%2F%2Fvault.azure.net%2F.default&assertion=a%2Bb%2Fc%3Dd",
        encoded,
    );
}

test "OIDC audience is appended without replacing protected query data" {
    const with_query = try appendOidcAudienceAlloc(
        std.testing.allocator,
        "https://vstoken.actions.githubusercontent.com/token?api-version=2.0",
    );
    defer std.testing.allocator.free(with_query);
    try std.testing.expectEqualStrings(
        "https://vstoken.actions.githubusercontent.com/token?api-version=2.0&audience=" ++ oidc_audience,
        with_query,
    );
    try std.testing.expectError(
        error.UnexpectedOidcAudience,
        appendOidcAudienceAlloc(
            std.testing.allocator,
            "https://vstoken.actions.githubusercontent.com/token?audience=wrong",
        ),
    );
}

test "Azure key IDs require an immutable matching version" {
    const version = "0123456789abcdef0123456789abcdef";
    try validateKeyId(
        "https://zvmi.vault.azure.net/keys/uki-release/" ++ version,
        version,
    );
    try validateKeyId(
        "https://zvmi.managedhsm.azure.net/keys/uki-release/" ++ version,
        version,
    );
    try std.testing.expectEqualStrings(
        "https://vault.azure.net/.default",
        azureTokenScope(
            "https://zvmi.vault.azure.net/keys/uki-release/" ++ version,
        ),
    );
    try std.testing.expectEqualStrings(
        "https://managedhsm.azure.net/.default",
        azureTokenScope(
            "https://zvmi.managedhsm.azure.net/keys/uki-release/" ++ version,
        ),
    );
    try std.testing.expectError(
        error.InvalidAzureKeyId,
        validateKeyId(
            "https://zvmi.vault.azure.net/keys/uki-release/latest",
            "latest",
        ),
    );
    try std.testing.expectError(
        error.InvalidAzureKeyId,
        validateKeyId(
            "https://evil.example/keys/uki-release/" ++ version,
            version,
        ),
    );
}

test "PEM certificate decoder accepts one canonical certificate block" {
    const der = try decodePemCertificateAlloc(
        std.testing.allocator,
        "-----BEGIN CERTIFICATE-----\nMAMCAQE=\n-----END CERTIFICATE-----\n",
    );
    defer std.testing.allocator.free(der);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x03, 0x02, 0x01, 0x01 }, der);
    try std.testing.expectError(
        error.InvalidCertificatePem,
        decodePemCertificateAlloc(
            std.testing.allocator,
            "prefix\n-----BEGIN CERTIFICATE-----\nMAMCAQE=\n-----END CERTIFICATE-----",
        ),
    );
}
