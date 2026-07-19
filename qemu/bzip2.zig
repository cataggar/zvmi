const std = @import("std");

const c = struct {
    const bz_stream = extern struct {
        next_in: [*c]u8,
        avail_in: c_uint,
        total_in_lo32: c_uint,
        total_in_hi32: c_uint,
        next_out: [*c]u8,
        avail_out: c_uint,
        total_out_lo32: c_uint,
        total_out_hi32: c_uint,
        state: ?*anyopaque,
        bzalloc: ?*const anyopaque,
        bzfree: ?*const anyopaque,
        @"opaque": ?*anyopaque,
    };

    extern fn BZ2_bzDecompressInit(
        stream: *bz_stream,
        verbosity: c_int,
        small: c_int,
    ) c_int;
    extern fn BZ2_bzDecompress(stream: *bz_stream) c_int;
    extern fn BZ2_bzDecompressEnd(stream: *bz_stream) c_int;

    const BZ_OK: c_int = 0;
    const BZ_STREAM_END: c_int = 4;
    const BZ_SEQUENCE_ERROR: c_int = -1;
    const BZ_PARAM_ERROR: c_int = -2;
    const BZ_MEM_ERROR: c_int = -3;
    const BZ_DATA_ERROR: c_int = -4;
    const BZ_DATA_ERROR_MAGIC: c_int = -5;
};

pub const Step = struct {
    consumed: usize,
    produced: usize,
    finished: bool,
};

pub const Decoder = struct {
    stream: c.bz_stream,

    pub fn init(self: *Decoder) !void {
        self.stream = std.mem.zeroes(c.bz_stream);
        try checkInitStatus(c.BZ2_bzDecompressInit(&self.stream, 0, 0));
    }

    pub fn deinit(self: *Decoder) void {
        _ = c.BZ2_bzDecompressEnd(&self.stream);
        self.* = undefined;
    }

    pub fn step(
        self: *Decoder,
        input: []const u8,
        output: []u8,
    ) !Step {
        self.stream.next_in = @ptrCast(@constCast(input.ptr));
        self.stream.avail_in = @intCast(input.len);
        self.stream.next_out = @ptrCast(output.ptr);
        self.stream.avail_out = @intCast(output.len);

        const status = c.BZ2_bzDecompress(&self.stream);
        try checkStepStatus(status);
        return .{
            .consumed = input.len - self.stream.avail_in,
            .produced = output.len - self.stream.avail_out,
            .finished = status == c.BZ_STREAM_END,
        };
    }
};

fn checkInitStatus(status: c_int) !void {
    switch (status) {
        c.BZ_OK => {},
        c.BZ_MEM_ERROR => return error.Bzip2OutOfMemory,
        c.BZ_PARAM_ERROR => return error.Bzip2ParameterError,
        else => return error.Bzip2InitializationFailed,
    }
}

fn checkStepStatus(status: c_int) !void {
    switch (status) {
        c.BZ_OK, c.BZ_STREAM_END => {},
        c.BZ_DATA_ERROR, c.BZ_DATA_ERROR_MAGIC => return error.InvalidBzip2Data,
        c.BZ_MEM_ERROR => return error.Bzip2OutOfMemory,
        c.BZ_PARAM_ERROR => return error.Bzip2ParameterError,
        c.BZ_SEQUENCE_ERROR => return error.Bzip2SequenceError,
        else => return error.Bzip2DecompressionFailed,
    }
}
