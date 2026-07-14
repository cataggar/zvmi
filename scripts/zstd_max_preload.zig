//! LD_PRELOAD shared library: intercepts `ZSTD_compressStream2` to force
//! maximum zstd compression level before delegating to the real implementation.
//!
//! Purpose: `qemu-img convert -O qcow2 -o compression_type=zstd` uses zstd
//! but exposes no level knob. Preloading this library makes every call to
//! `ZSTD_compressStream2` set `ZSTD_c_compressionLevel` to `ZSTD_maxCLevel()`
//! and then delegate to the real libzstd symbol found via `dlsym(RTLD_NEXT)`.
//!
//! All zstd functions are resolved at runtime through `dlsym` so this library
//! carries no link-time dependency on libzstd or any versioned symbol.
//! It only links against libdl (for `dlsym`) and libc.
//!
//! Linux-specific: `dlsym(RTLD_NEXT, ...)` and LD_PRELOAD semantics are
//! POSIX/Linux; the generalized-image pipeline is Linux-only anyway.

const builtin = @import("builtin");

// ZSTD opaque context.
const ZSTD_CStream = opaque {};

// ZSTD_EndDirective enum (only the values we reference).
const ZSTD_e_continue: c_int = 0;
const ZSTD_e_flush: c_int = 1;
const ZSTD_e_end: c_int = 2;

// ZSTD cParameter: compression level key.
const ZSTD_c_compressionLevel: c_int = 100;

// Buffer types used by ZSTD_compressStream2.
const ZSTD_inBuffer = extern struct {
    src: ?*const anyopaque,
    size: usize,
    pos: usize,
};
const ZSTD_outBuffer = extern struct {
    dst: ?*anyopaque,
    size: usize,
    pos: usize,
};

// RTLD_NEXT sentinel (defined as (void*)-1 in <dlfcn.h>).
const RTLD_NEXT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// dlsym from libc/libdl (always available on Linux).
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

// Function-pointer types resolved at first call.
const ZSTD_maxCLevel_fn = *const fn () callconv(.c) c_int;
const ZSTD_isError_fn = *const fn (code: usize) callconv(.c) c_uint;
const ZSTD_CCtx_setParameter_fn = *const fn (
    cctx: *ZSTD_CStream,
    param: c_int,
    value: c_int,
) callconv(.c) usize;
const ZSTD_compressStream2_fn = *const fn (
    cctx: *ZSTD_CStream,
    output: *ZSTD_outBuffer,
    input: *ZSTD_inBuffer,
    endOp: c_int,
) callconv(.c) usize;

fn resolveNext(comptime name: [:0]const u8, comptime Fn: type) Fn {
    const ptr = dlsym(RTLD_NEXT, name) orelse
        @panic("zstd_max_preload: dlsym(RTLD_NEXT, \"" ++ name ++ "\") returned null");
    return @ptrCast(@alignCast(ptr));
}

export fn ZSTD_compressStream2(
    cctx: *ZSTD_CStream,
    output: *ZSTD_outBuffer,
    input: *ZSTD_inBuffer,
    endOp: c_int,
) usize {
    const max_clevel = resolveNext("ZSTD_maxCLevel", ZSTD_maxCLevel_fn);
    const is_error = resolveNext("ZSTD_isError", ZSTD_isError_fn);
    const set_parameter = resolveNext("ZSTD_CCtx_setParameter", ZSTD_CCtx_setParameter_fn);
    const compress_stream2 = resolveNext("ZSTD_compressStream2", ZSTD_compressStream2_fn);

    const set_result = set_parameter(cctx, ZSTD_c_compressionLevel, max_clevel());
    if (is_error(set_result) != 0) return set_result;
    return compress_stream2(cctx, output, input, endOp);
}

// Suppress "unused import" for enum constants above.
comptime {
    _ = ZSTD_e_continue;
    _ = ZSTD_e_flush;
    _ = ZSTD_e_end;
}
