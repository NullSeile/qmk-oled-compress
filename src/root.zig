const std = @import("std");
const assert = std.debug.assert;

const zigimg = @import("zigimg");

pub fn encode(gpa: std.mem.Allocator, buff: []const u8) ![]u8 {
    if (buff.len == 0) {
        return &[_]u8{};
    }

    const State = enum {
        black,
        raw,
        rle,
    };

    const Control = packed union {
        black: packed struct {
            count: u7,
            state: u1 = 0b0,
        },
        raw: packed struct {
            count: u6,
            state: u2 = 0b10,
        },
        rle: packed struct {
            count: u6,
            state: u2 = 0b11,
        },
    };

    const Element = packed union {
        control: Control,
        value: u8,
    };

    assert(@sizeOf(Element) == 1);

    var output: std.ArrayList(Element) = .{};
    defer output.deinit(gpa);

    var i: usize = 0;
    // var state: State = .raw;
    var state: State = if (buff[0] == 0) .black else .raw;
    while (i < buff.len) {
        switch (state) {
            .black, .rle => {
                // Get the repeating value
                const val = switch (state) {
                    .black => 0,
                    .rle => buff[i],
                    else => unreachable,
                };
                const max_count: u7 = switch (state) {
                    .black => std.math.maxInt(u7),
                    .rle => std.math.maxInt(u6),
                    else => unreachable,
                };

                // Count the number of repetitions
                const start = i;
                while (i < buff.len and buff[i] == val and (i - start) < max_count) {
                    i += 1;
                }

                // Write the control byte
                if (state == .black) {
                    try output.append(gpa, Element{ .control = .{
                        .black = .{
                            .count = @intCast(i - start),
                        },
                    } });
                } else if (state == .rle) {
                    try output.append(gpa, Element{ .control = .{
                        .rle = .{
                            .count = @intCast(i - start),
                        },
                    } });
                    try output.append(gpa, Element{
                        .value = val,
                    });
                }

                if (i >= buff.len) break;

                const n = 2; // Number of repeating characters for it to be worth
                const check_end = @min(i + n, buff.len);
                state = if (i < buff.len and check_end > i + 1 and std.mem.allEqual(u8, buff[i + 1 .. check_end], buff[i]))
                    switch (buff[i]) {
                        0 => .black,
                        else => .rle,
                    }
                else
                    .raw;
            },
            .raw => {
                const max_repeat = 2;

                const start = i;
                var repeat_count: u4 = 0;
                var repeat_val: u8 = buff[i];
                while (i < buff.len and repeat_count < max_repeat and (i - start) < std.math.maxInt(u6)) {
                    if (buff[i] == repeat_val) {
                        repeat_count += 1;
                    } else {
                        repeat_count = 0;
                        repeat_val = buff[i];
                    }
                    i += 1;
                }

                if (repeat_count == max_repeat) {
                    i -= max_repeat;
                }
                try output.append(gpa, Element{
                    .control = .{
                        .raw = .{
                            .count = @intCast(i - start),
                        },
                    },
                });
                try output.appendSlice(gpa, @ptrCast(buff[start..i]));

                state = if (repeat_count == max_repeat)
                    switch (repeat_val) {
                        0 => .black,
                        else => .rle,
                    }
                else
                    .raw;
            },
        }
    }

    return @ptrCast(try output.toOwnedSlice(gpa));
}

pub fn decode(gpa: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(gpa);

    var i: usize = 0;
    while (i < encoded.len) {
        const ctrl: u8 = encoded[i];
        if (ctrl >> 7 == 0) { // black
            const count: u7 = @intCast(ctrl & 0b01111111);
            i += 1;
            for (0..count) |_| {
                try output.append(gpa, 0);
            }
        } else {
            const val: u6 = @intCast(ctrl & 0b00111111);
            i += 1;
            switch (ctrl >> 6) {
                0b10 => { // raw
                    for (0..val) |_| {
                        const v = encoded[i];
                        i += 1;
                        try output.append(gpa, v);
                    }
                },
                0b11 => { // rle
                    const v = encoded[i];
                    i += 1;
                    for (0..val) |_| {
                        try output.append(gpa, v);
                    }
                },
                else => unreachable,
            }
        }
    }

    return output.toOwnedSlice(gpa);
}

test "fuzz" {
    const gpa = std.testing.allocator;
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;

            const encoded = try encode(gpa, input);
            defer gpa.free(encoded);
            const decoded = try decode(gpa, encoded);
            defer gpa.free(decoded);
            std.testing.expect(std.mem.eql(u8, input, decoded)) catch |e| {
                std.debug.print("Fuzz test failed:\nInput:\n{x}\nOutput:\n{x}\n", .{ input, decoded });
                return e;
            };
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
