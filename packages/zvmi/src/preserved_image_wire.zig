const std = @import("std");
const customization_wire = @import("customization_wire.zig");

pub const api_version: u32 = 2;

pub const Backend = enum {
    native_edit,
    rebuild,
};

pub const PartitionSelector = union(enum) {
    gpt_index: u32,
    mbr_index: u8,
};

pub const OverwriteFile = struct {
    path: []const u8,
    source_index: usize,
};

pub const Operation = union(enum) {
    overwrite_file: OverwriteFile,
    remove_file: []const u8,
    remove_tree: []const u8,
};

pub const Configuration = struct {
    api_version: u32 = api_version,
    backend: Backend = .native_edit,
    root_partition: PartitionSelector,
    operations: []const Operation = &.{},
    customization: customization_wire.Configuration = .{},
};

pub const ValidationError = error{
    UnsupportedApiVersion,
    InvalidPartitionSelector,
    MissingSourceArgument,
    ExtraSourceArgument,
    SourceIndexOutOfBounds,
    DuplicateSourceIndex,
};

pub fn validate(configuration: Configuration, source_count: usize) ValidationError!void {
    if (configuration.api_version != api_version) return error.UnsupportedApiVersion;
    switch (configuration.root_partition) {
        .gpt_index => |index| if (index == 0) return error.InvalidPartitionSelector,
        .mbr_index => |index| if (index == 0 or index > 4) return error.InvalidPartitionSelector,
    }

    var expected_sources: usize = 0;
    for (configuration.operations) |operation| {
        if (operation == .overwrite_file) expected_sources += 1;
    }
    for (configuration.customization.os.filesystem) |operation| {
        if (operation == .put_file) expected_sources += 1;
    }
    if (source_count < expected_sources) return error.MissingSourceArgument;
    if (source_count > expected_sources) return error.ExtraSourceArgument;

    for (configuration.operations, 0..) |operation, operation_index| {
        const source_index = switch (operation) {
            .overwrite_file => |overwrite| overwrite.source_index,
            .remove_file, .remove_tree => continue,
        };
        if (source_index >= source_count) return error.SourceIndexOutOfBounds;
        for (configuration.operations[0..operation_index]) |previous| {
            const previous_source_index = switch (previous) {
                .overwrite_file => |overwrite| overwrite.source_index,
                .remove_file, .remove_tree => continue,
            };
            if (source_index == previous_source_index) return error.DuplicateSourceIndex;
        }
    }
    for (configuration.customization.os.filesystem, 0..) |operation, operation_index| {
        const source_index = switch (operation) {
            .put_file => |file| file.source_index,
            .put_directory, .put_symlink, .remove, .set_metadata => continue,
        };
        if (source_index >= source_count) return error.SourceIndexOutOfBounds;
        for (configuration.operations) |previous| {
            const previous_source_index = switch (previous) {
                .overwrite_file => |overwrite| overwrite.source_index,
                .remove_file, .remove_tree => continue,
            };
            if (source_index == previous_source_index) return error.DuplicateSourceIndex;
        }
        for (configuration.customization.os.filesystem[0..operation_index]) |previous| {
            const previous_source_index = switch (previous) {
                .put_file => |file| file.source_index,
                .put_directory, .put_symlink, .remove, .set_metadata => continue,
            };
            if (source_index == previous_source_index) return error.DuplicateSourceIndex;
        }
    }
}

test "source arguments form an exact indexed closure" {
    const operations = [_]Operation{
        .{ .overwrite_file = .{ .path = "/etc/first", .source_index = 1 } },
        .{ .remove_file = "/etc/old" },
        .{ .overwrite_file = .{ .path = "/etc/second", .source_index = 0 } },
    };
    var customization_operations = [_]customization_wire.FilesystemOperation{
        .{ .put_file = .{ .path = "/etc/third", .source_index = 2 } },
    };
    const configuration = Configuration{
        .backend = .rebuild,
        .root_partition = .{ .gpt_index = 2 },
        .operations = &operations,
        .customization = .{ .os = .{ .filesystem = &customization_operations } },
    };

    try validate(configuration, 3);
    try std.testing.expectError(error.MissingSourceArgument, validate(configuration, 2));
    try std.testing.expectError(error.ExtraSourceArgument, validate(configuration, 4));

    var out_of_bounds = operations;
    out_of_bounds[0].overwrite_file.source_index = 3;
    try std.testing.expectError(error.SourceIndexOutOfBounds, validate(.{
        .root_partition = .{ .gpt_index = 2 },
        .operations = &out_of_bounds,
        .customization = configuration.customization,
    }, 3));

    var duplicate = operations;
    duplicate[0].overwrite_file.source_index = 0;
    try std.testing.expectError(error.DuplicateSourceIndex, validate(.{
        .root_partition = .{ .mbr_index = 1 },
        .operations = &duplicate,
        .customization = configuration.customization,
    }, 3));

    customization_operations[0].put_file.source_index = 0;
    try std.testing.expectError(
        error.DuplicateSourceIndex,
        validate(configuration, 3),
    );
}

test "configuration version and one-based partition are validated" {
    try std.testing.expectError(error.UnsupportedApiVersion, validate(.{
        .api_version = api_version + 1,
        .root_partition = .{ .gpt_index = 1 },
    }, 0));
    try std.testing.expectError(error.InvalidPartitionSelector, validate(.{
        .root_partition = .{ .mbr_index = 0 },
    }, 0));
    try std.testing.expectError(error.InvalidPartitionSelector, validate(.{
        .root_partition = .{ .mbr_index = 5 },
    }, 0));
}
