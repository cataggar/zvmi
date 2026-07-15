const std = @import("std");

pub const api_version: u32 = 1;

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
    root_partition: PartitionSelector,
    operations: []const Operation = &.{},
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
}

test "source arguments form an exact indexed closure" {
    const operations = [_]Operation{
        .{ .overwrite_file = .{ .path = "/etc/first", .source_index = 1 } },
        .{ .remove_file = "/etc/old" },
        .{ .overwrite_file = .{ .path = "/etc/second", .source_index = 0 } },
    };
    const configuration = Configuration{
        .root_partition = .{ .gpt_index = 2 },
        .operations = &operations,
    };

    try validate(configuration, 2);
    try std.testing.expectError(error.MissingSourceArgument, validate(configuration, 1));
    try std.testing.expectError(error.ExtraSourceArgument, validate(configuration, 3));

    var out_of_bounds = operations;
    out_of_bounds[0].overwrite_file.source_index = 2;
    try std.testing.expectError(error.SourceIndexOutOfBounds, validate(.{
        .root_partition = .{ .gpt_index = 2 },
        .operations = &out_of_bounds,
    }, 2));

    var duplicate = operations;
    duplicate[0].overwrite_file.source_index = 0;
    try std.testing.expectError(error.DuplicateSourceIndex, validate(.{
        .root_partition = .{ .mbr_index = 1 },
        .operations = &duplicate,
    }, 2));
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
