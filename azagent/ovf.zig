//! Minimal parser for the `ovf-env.xml` provisioning document Azure mounts
//! on a virtual CD-ROM/DVD for a new Linux VM: just the
//! `LinuxProvisioningConfigurationSet` fields `azagent` needs to provision
//! the VM (hostname, username, SSH public keys). Reuses `wireserver.xml`'s
//! zero-copy element finder/iterator (the tags this module cares about are
//! unprefixed even though sibling elements elsewhere in the document use a
//! `wa:` namespace prefix -- see the fixture in this file's tests, modeled
//! on a real `ovf-env.xml`).
//!
//! Explicitly out of scope (see issue #112): `UserPassword`-based
//! authentication (this project provisions SSH-key-only accounts; hashing
//! a password to match glibc's `crypt(3)` algorithm is real, security-
//! sensitive work that deserves its own follow-up rather than a rushed
//! reimplementation here), `KeyPair` private-key deployment (requires
//! decoding a PKCS7/certificate blob fetched from the WireServer -- out of
//! scope per issue #111), and `CustomData`.
//!
//! Reference: `azurelinuxagent/common/protocol/ovfenv.py` (Microsoft Azure
//! Linux Agent, analyzed at /work/WALinuxAgent during planning).
const std = @import("std");
const xml = @import("wireserver").xml;
const validation = @import("validation.zig");

pub const ParseError = error{ MissingField, InvalidUsername, InvalidPublicKey };

/// A single `<PublicKey>` entry's `<Value>` (raw `ssh-<type> ...` text).
/// The `<Fingerprint>`/certificate-thumbprint path is not supported (see
/// module doc comment); such entries are silently skipped by `parse`.
pub const PublicKey = struct {
    value: []const u8,
};

/// The minimal subset of `LinuxProvisioningConfigurationSet` needed to
/// provision a VM. All fields are borrowed slices into the original
/// document (matching `wireserver.xml`'s zero-copy design).
pub const OvfEnv = struct {
    hostname: []const u8,
    username: []const u8,
    disable_ssh_password_auth: bool,
    /// Up to `max_public_keys` raw-value public keys found in the document
    /// (real ovf-env.xml documents have at most a handful).
    public_keys_buf: [max_public_keys]PublicKey = undefined,
    public_keys_len: usize = 0,

    pub const max_public_keys = 16;

    pub fn publicKeys(self: *const OvfEnv) []const PublicKey {
        return self.public_keys_buf[0..self.public_keys_len];
    }

    pub fn parse(xml_text: []const u8) ParseError!OvfEnv {
        const conf_set = xml.findElement(xml_text, "LinuxProvisioningConfigurationSet") orelse return error.MissingField;

        const hostname = xml.findElement(conf_set, "HostName") orelse return error.MissingField;
        const username = xml.findElement(conf_set, "UserName") orelse return error.MissingField;
        try validation.validateUsername(username);

        const disable_ssh_password_auth = if (xml.findElement(conf_set, "DisableSshPasswordAuthentication")) |v|
            std.ascii.eqlIgnoreCase(v, "true")
        else
            true; // matches upstream's default when the field is absent

        var result: OvfEnv = .{
            .hostname = hostname,
            .username = username,
            .disable_ssh_password_auth = disable_ssh_password_auth,
        };

        var it = xml.ElementIterator.init(conf_set, "PublicKey");
        while (it.next()) |pubkey_block| {
            if (result.public_keys_len >= max_public_keys) break;
            const value = xml.findElement(pubkey_block, "Value") orelse continue;
            try validation.validatePublicKey(value);
            result.public_keys_buf[result.public_keys_len] = .{ .value = value };
            result.public_keys_len += 1;
        }

        return result;
    }
};

const sample_ovf_env =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:oe="http://schemas.dmtf.org/ovf/environment/1" xmlns:wa="http://schemas.microsoft.com/windowsazure" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    \\    <wa:ProvisioningSection>
    \\      <wa:Version>1.0</wa:Version>
    \\      <LinuxProvisioningConfigurationSet xmlns="http://schemas.microsoft.com/windowsazure" xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
    \\        <ConfigurationSetType>LinuxProvisioningConfiguration</ConfigurationSetType>
    \\        <HostName>my-host</HostName>
    \\        <UserName>azureuser</UserName>
    \\        <DisableSshPasswordAuthentication>true</DisableSshPasswordAuthentication>
    \\        <SSH>
    \\          <PublicKeys>
    \\            <PublicKey>
    \\              <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
    \\              <Path>$HOME/azureuser/.ssh/authorized_keys</Path>
    \\              <Value>ssh-rsa AAAANOTAREALKEY== foo@bar.local</Value>
    \\            </PublicKey>
    \\          </PublicKeys>
    \\          <KeyPairs>
    \\            <KeyPair>
    \\              <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
    \\              <Path>$HOME/azureuser/.ssh/id_rsa</Path>
    \\            </KeyPair>
    \\          </KeyPairs>
    \\        </SSH>
    \\        <CustomData>c29tZSBjdXN0b20gZGF0YQ==</CustomData>
    \\      </LinuxProvisioningConfigurationSet>
    \\    </wa:ProvisioningSection>
    \\    <wa:PlatformSettingsSection>
    \\        <wa:Version>1.0</wa:Version>
    \\        <wa:PlatformSettings>
    \\            <wa:ProvisionGuestAgent>false</wa:ProvisionGuestAgent>
    \\        </wa:PlatformSettings>
    \\    </wa:PlatformSettingsSection>
    \\ </Environment>
;

test "OvfEnv.parse extracts hostname, username, ssh auth flag, and public keys" {
    const env = try OvfEnv.parse(sample_ovf_env);
    try std.testing.expectEqualStrings("my-host", env.hostname);
    try std.testing.expectEqualStrings("azureuser", env.username);
    try std.testing.expect(env.disable_ssh_password_auth);
    try std.testing.expectEqual(@as(usize, 1), env.publicKeys().len);
    try std.testing.expectEqualStrings("ssh-rsa AAAANOTAREALKEY== foo@bar.local", env.publicKeys()[0].value);
}

test "OvfEnv.parse defaults DisableSshPasswordAuthentication to true when absent" {
    const doc =
        \\<LinuxProvisioningConfigurationSet>
        \\  <HostName>h</HostName>
        \\  <UserName>u</UserName>
        \\</LinuxProvisioningConfigurationSet>
    ;
    const env = try OvfEnv.parse(doc);
    try std.testing.expect(env.disable_ssh_password_auth);
    try std.testing.expectEqual(@as(usize, 0), env.publicKeys().len);
}

test "OvfEnv.parse respects an explicit false DisableSshPasswordAuthentication" {
    const doc =
        \\<LinuxProvisioningConfigurationSet>
        \\  <HostName>h</HostName>
        \\  <UserName>u</UserName>
        \\  <DisableSshPasswordAuthentication>false</DisableSshPasswordAuthentication>
        \\</LinuxProvisioningConfigurationSet>
    ;
    const env = try OvfEnv.parse(doc);
    try std.testing.expect(!env.disable_ssh_password_auth);
}

test "OvfEnv.parse skips PublicKey entries with no Value (certificate-thumbprint path)" {
    const doc =
        \\<LinuxProvisioningConfigurationSet>
        \\  <HostName>h</HostName>
        \\  <UserName>u</UserName>
        \\  <SSH><PublicKeys>
        \\    <PublicKey><Fingerprint>ABC123</Fingerprint><Path>p</Path></PublicKey>
        \\    <PublicKey><Fingerprint>DEF456</Fingerprint><Path>p2</Path><Value>ssh-ed25519 AAAA== a@b</Value></PublicKey>
        \\  </PublicKeys></SSH>
        \\</LinuxProvisioningConfigurationSet>
    ;
    const env = try OvfEnv.parse(doc);
    try std.testing.expectEqual(@as(usize, 1), env.publicKeys().len);
    try std.testing.expectEqualStrings("ssh-ed25519 AAAA== a@b", env.publicKeys()[0].value);
}

test "OvfEnv.parse fails when a required field is missing" {
    try std.testing.expectError(error.MissingField, OvfEnv.parse("<LinuxProvisioningConfigurationSet></LinuxProvisioningConfigurationSet>"));
    try std.testing.expectError(error.MissingField, OvfEnv.parse("<Nope></Nope>"));
}

test "OvfEnv.parse validates usernames and every supplied public key" {
    const unsafe_user =
        \\<LinuxProvisioningConfigurationSet>
        \\  <HostName>h</HostName><UserName>../root</UserName>
        \\</LinuxProvisioningConfigurationSet>
    ;
    try std.testing.expectError(error.InvalidUsername, OvfEnv.parse(unsafe_user));

    const injected_key =
        \\<LinuxProvisioningConfigurationSet>
        \\  <HostName>h</HostName><UserName>azureuser</UserName>
        \\  <SSH><PublicKeys><PublicKey><Value>ssh-ed25519 AAAA
        \\command="id"</Value></PublicKey></PublicKeys></SSH>
        \\</LinuxProvisioningConfigurationSet>
    ;
    try std.testing.expectError(error.InvalidPublicKey, OvfEnv.parse(injected_key));
}
