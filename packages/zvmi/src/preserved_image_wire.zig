const std = @import("std");
const customization_wire = @import("customization_wire.zig");

pub const previous_api_version: u32 = 2;
pub const api_version: u32 = 3;

pub const Backend = enum {
    native_edit,
    rebuild,
    unsafe_chroot,
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

pub const PackageAction = union(enum) {
    install: []const []const u8,
    remove: []const []const u8,
    update_all,
    update_selected: []const []const u8,
};

pub const TrustSource = struct {
    source_index: usize,
};

pub const PackageRepository = struct {
    id: []const u8,
    urls: []const []const u8,
    trust: []const TrustSource = &.{},
};

pub const PackageCachePolicy = enum {
    online,
    cache_only,
};

pub const PackageVersionLock = struct {
    name: []const u8,
    version: []const u8,
    repository_id: []const u8,
};

pub const PackageLockPolicy = union(enum) {
    unlocked,
    snapshot: []const u8,
    exact: []const PackageVersionLock,
};

pub const PackagePolicy = struct {
    actions: []const PackageAction = &.{},
    repositories: []const PackageRepository = &.{},
    cache: PackageCachePolicy = .online,
    lock: PackageLockPolicy = .unlocked,
};

pub const InitramfsPolicy = union(enum) {
    unchanged,
    regenerate: struct {
        generator: ?[]const u8 = null,
        kernels: []const []const u8 = &.{},
    },
};

pub const GuestExecutionPolicy = enum {
    same_architecture,
};

pub const ConfigurationV2 = struct {
    api_version: u32 = previous_api_version,
    backend: enum { native_edit, rebuild } = .native_edit,
    root_partition: PartitionSelector,
    operations: []const Operation = &.{},
    customization: customization_wire.Configuration = .{},
};

pub const Configuration = struct {
    api_version: u32 = api_version,
    backend: Backend = .native_edit,
    root_partition: PartitionSelector,
    operations: []const Operation = &.{},
    customization: customization_wire.Configuration = .{},
    acknowledge_unsafe: bool = false,
    packages: PackagePolicy = .{},
    initramfs: InitramfsPolicy = .unchanged,
    guest_execution: GuestExecutionPolicy = .same_architecture,
};

pub const ValidationError = error{
    UnsupportedApiVersion,
    InvalidPartitionSelector,
    MissingSourceArgument,
    ExtraSourceArgument,
    SourceIndexOutOfBounds,
    DuplicateSourceIndex,
};

pub fn validateV2(configuration: ConfigurationV2, source_count: usize) ValidationError!void {
    if (configuration.api_version != previous_api_version) {
        return error.UnsupportedApiVersion;
    }
    try validatePartition(configuration.root_partition);
    try validateExistingSourceClosure(
        configuration.operations,
        configuration.customization,
        source_count,
    );
}

pub fn validate(configuration: Configuration, source_count: usize) ValidationError!void {
    if (configuration.api_version != api_version) return error.UnsupportedApiVersion;
    try validatePartition(configuration.root_partition);

    var expected_sources: usize = 0;
    for (configuration.operations) |operation| {
        if (operation == .overwrite_file) expected_sources += 1;
    }
    for (configuration.customization.os.filesystem) |operation| {
        if (operation == .put_file) expected_sources += 1;
    }
    for (configuration.packages.repositories) |repository| {
        expected_sources += repository.trust.len;
    }
    if (source_count < expected_sources) return error.MissingSourceArgument;
    if (source_count > expected_sources) return error.ExtraSourceArgument;

    var iterator = SourceIndexIterator.init(configuration);
    var ordinal: usize = 0;
    while (iterator.next()) |source_index| : (ordinal += 1) {
        if (source_index >= source_count) return error.SourceIndexOutOfBounds;
        var previous = SourceIndexIterator.init(configuration);
        var previous_ordinal: usize = 0;
        while (previous_ordinal < ordinal) : (previous_ordinal += 1) {
            if (source_index == previous.next().?) return error.DuplicateSourceIndex;
        }
    }
}

fn validatePartition(partition: PartitionSelector) ValidationError!void {
    switch (partition) {
        .gpt_index => |index| if (index == 0) return error.InvalidPartitionSelector,
        .mbr_index => |index| if (index == 0 or index > 4) {
            return error.InvalidPartitionSelector;
        },
    }
}

fn validateExistingSourceClosure(
    operations: []const Operation,
    customization: customization_wire.Configuration,
    source_count: usize,
) ValidationError!void {
    const configuration = Configuration{
        .root_partition = .{ .gpt_index = 1 },
        .operations = operations,
        .customization = customization,
    };
    try validate(configuration, source_count);
}

const SourceIndexIterator = struct {
    configuration: Configuration,
    operation_index: usize = 0,
    filesystem_index: usize = 0,
    repository_index: usize = 0,
    trust_index: usize = 0,

    fn init(configuration: Configuration) SourceIndexIterator {
        return .{ .configuration = configuration };
    }

    fn next(self: *SourceIndexIterator) ?usize {
        while (self.operation_index < self.configuration.operations.len) {
            const operation = self.configuration.operations[self.operation_index];
            self.operation_index += 1;
            switch (operation) {
                .overwrite_file => |overwrite| return overwrite.source_index,
                .remove_file, .remove_tree => {},
            }
        }
        while (self.filesystem_index < self.configuration.customization.os.filesystem.len) {
            const operation = self.configuration.customization.os.filesystem[self.filesystem_index];
            self.filesystem_index += 1;
            switch (operation) {
                .put_file => |file| return file.source_index,
                .put_directory, .put_symlink, .remove, .set_metadata => {},
            }
        }
        while (self.repository_index < self.configuration.packages.repositories.len) {
            const repository = self.configuration.packages.repositories[self.repository_index];
            if (self.trust_index < repository.trust.len) {
                const source_index = repository.trust[self.trust_index].source_index;
                self.trust_index += 1;
                return source_index;
            }
            self.repository_index += 1;
            self.trust_index = 0;
        }
        return null;
    }
};

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
        .backend = .unsafe_chroot,
        .root_partition = .{ .gpt_index = 2 },
        .operations = &operations,
        .customization = .{ .os = .{ .filesystem = &customization_operations } },
        .acknowledge_unsafe = true,
        .packages = .{ .repositories = &.{.{
            .id = "base",
            .urls = &.{"https://packages.example.invalid"},
            .trust = &.{.{ .source_index = 3 }},
        }} },
    };

    try validate(configuration, 4);
    try std.testing.expectError(error.MissingSourceArgument, validate(configuration, 3));
    try std.testing.expectError(error.ExtraSourceArgument, validate(configuration, 5));

    var out_of_bounds = operations;
    out_of_bounds[0].overwrite_file.source_index = 4;
    try std.testing.expectError(error.SourceIndexOutOfBounds, validate(.{
        .root_partition = .{ .gpt_index = 2 },
        .operations = &out_of_bounds,
        .customization = configuration.customization,
        .packages = configuration.packages,
    }, 4));

    var duplicate = operations;
    duplicate[0].overwrite_file.source_index = 0;
    try std.testing.expectError(error.DuplicateSourceIndex, validate(.{
        .root_partition = .{ .mbr_index = 1 },
        .operations = &duplicate,
        .customization = configuration.customization,
        .packages = configuration.packages,
    }, 4));

    customization_operations[0].put_file.source_index = 0;
    try std.testing.expectError(
        error.DuplicateSourceIndex,
        validate(configuration, 4),
    );
}

test "repository trust participates in the shared source closure" {
    var trust = [_]TrustSource{.{ .source_index = 2 }};
    const repositories = [_]PackageRepository{.{
        .id = "base",
        .urls = &.{"https://packages.example.invalid"},
        .trust = &trust,
    }};
    const configuration = Configuration{
        .root_partition = .{ .gpt_index = 1 },
        .operations = &.{.{ .overwrite_file = .{
            .path = "/etc/one",
            .source_index = 0,
        } }},
        .customization = .{
            .os = .{
                .filesystem = &.{.{ .put_file = .{
                    .path = "/etc/two",
                    .source_index = 1,
                } }},
            },
        },
        .packages = .{
            .repositories = &repositories,
        },
    };
    try validate(configuration, 3);
    try std.testing.expectError(
        error.MissingSourceArgument,
        validate(configuration, 2),
    );
    try std.testing.expectError(
        error.ExtraSourceArgument,
        validate(configuration, 4),
    );

    trust[0].source_index = 1;
    try std.testing.expectError(
        error.DuplicateSourceIndex,
        validate(configuration, 3),
    );
    trust[0].source_index = 3;
    try std.testing.expectError(
        error.SourceIndexOutOfBounds,
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

test "v2 configurations remain valid with their original source closure" {
    const configuration = ConfigurationV2{
        .backend = .rebuild,
        .root_partition = .{ .gpt_index = 1 },
        .operations = &.{.{ .overwrite_file = .{
            .path = "/etc/value",
            .source_index = 0,
        } }},
    };
    try validateV2(configuration, 1);
    try std.testing.expectError(
        error.UnsupportedApiVersion,
        validateV2(.{
            .api_version = api_version,
            .root_partition = .{ .gpt_index = 1 },
        }, 0),
    );
}
