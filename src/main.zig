const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const lib = @import("qmk_oled_compress");

const zigimg = @import("zigimg");

pub fn encode_frames_to_c(gpa: std.mem.Allocator, paths: []const []const u8) !void {
    const stdout = std.fs.File.stdout();

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buff);
    var writer = &stdout_writer.interface;

    const sizes = try gpa.alloc(usize, paths.len);
    defer gpa.free(sizes);

    var height: usize = undefined;
    var width: usize = undefined;

    var files = try gpa.alloc([]u8, paths.len);
    var loaded_files: usize = 0;
    defer {
        for (files[0..loaded_files]) |file| {
            gpa.free(file);
        }
        gpa.free(files);
    }
    for (paths, 0..) |path, i| {
        var _buff: [128 * 32]u8 = undefined;
        var img = try zigimg.Image.fromFilePath(gpa, path, &_buff);
        defer img.deinit(gpa);
        assert(img.width % 8 == 0);

        if (i == 0) {
            height = img.height;
            width = img.width;
        } else {
            assert(height == img.height);
            assert(width == img.width);
        }

        // print("{}\n", .{img.pixelFormat()});
        try img.convert(gpa, .grayscale1);
        const pixels = img.pixels.grayscale1;

        // const buff = try gpa.alloc(u8, pixels.len / 8);

        const buff = try gpa.alloc(u8, pixels.len / 8);
        var idx: usize = 0;
        for (0..height / 8) |y| {
            for (0..width) |x| {
                var v: u8 = 0;
                for (0..8) |b| {
                    const p = @as(u8, pixels[x + width * (y * 8 + b)].value);
                    v |= p << @intCast(b);
                }
                buff[idx] = v;
                idx += 1;
            }
        }
        files[i] = buff;
        loaded_files += 1;
    }

    try writer.print("static const char PROGMEM frames[] = {{\n", .{});
    var diff_frames: std.ArrayList(u8) = try .initCapacity(gpa, files.len);
    defer diff_frames.deinit(gpa);
    for (files, 0..) |file, i| {
        const buff = try gpa.dupe(u8, file);
        defer gpa.free(buff);
        if (i != 0) {
            for (files[i - 1], 0..) |a, idx| {
                buff[idx] ^= a;
            }
        }

        const encoded_raw = try lib.encode(gpa, file);
        defer gpa.free(encoded_raw);

        const encoded_diff = try lib.encode(gpa, buff);
        defer gpa.free(encoded_diff);

        var encoded: []u8 = undefined;
        encoded = encoded_raw;
        if (encoded_diff.len < encoded_raw.len) {
            encoded = encoded_diff;
            try diff_frames.appendBounded(@intCast(i));
        } else {
            encoded = encoded_raw;
        }

        sizes[i] = encoded.len;

        try writer.print("// Frame: {}\n", .{i});
        for (encoded) |item| {
            try writer.print("{},", .{item});
        }
        try writer.print("\n", .{});
    }

    try writer.print("}};\n", .{});

    try writer.print("static const char frame_sizes[] = {{\n", .{});
    for (sizes) |size| {
        assert(size <= 255);
        try writer.print("{},", .{size});
    }
    try writer.print("\n}};\n", .{});

    try writer.print("static const char diff_frames[] = {{\n", .{});
    for (diff_frames.items) |item| {
        try writer.print("{},", .{item});
    }
    try writer.print("\n}};\n", .{});

    try writer.print("static const size_t height = {};\n", .{height});
    try writer.print("static const size_t width = {};\n", .{width});
    try writer.flush();
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{};
    defer if (builtin.mode == .Debug) {
        assert(debug_allocator.deinit() == .ok);
    };
    const gpa = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len <= 1) {
        const stderr = std.fs.File.stderr();
        var stderr_buff: [256]u8 = undefined;
        var writer = stderr.writer(&stderr_buff);
        try writer.interface.print("usage: {s} <frame1.png> [frame2.png ...]\n", .{args[0]});
        try writer.interface.flush();
        return error.InvalidUsage;
    }

    try encode_frames_to_c(gpa, args[1..]);
}
