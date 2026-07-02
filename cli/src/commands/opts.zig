//! Shared `-o key=value,...` option parsing helpers for the CLI commands.

const std = @import("std");
const zvmi = @import("zvmi");

/// Parses a qemu-img-style `-o` option string (currently only
/// `subformat=fixed|dynamic` is recognized, matching qemu-img's `-f vpc -o
/// subformat=...`). Returns `null` and prints a diagnostic on the first
/// unrecognized key or value.
pub fn parseVhdCreateOptions(opt_string: []const u8) ?zvmi.CreateOptions {
    var options = zvmi.CreateOptions{};
    var it = std.mem.splitScalar(u8, opt_string, ',');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            std.debug.print("create: malformed -o option '{s}' (expected key=value)\n", .{pair});
            return null;
        };
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "subformat")) {
            if (std.mem.eql(u8, value, "fixed")) {
                options.vhd_subformat = .fixed;
            } else if (std.mem.eql(u8, value, "dynamic")) {
                options.vhd_subformat = .dynamic;
            } else {
                std.debug.print("create: unknown subformat '{s}' (expected fixed or dynamic)\n", .{value});
                return null;
            }
        } else {
            std.debug.print("create: unknown -o option '{s}'\n", .{key});
            return null;
        }
    }
    return options;
}
