const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;

fn encodeVarint32(buf: []u8, val: u32) usize {
    const B: u32 = 128;
    if (val < (1 << 7)) {
        buf[0] = @truncate(u8, val);
        return 1;
    } else if (val < (1 << 14)) {
        buf[0] = @truncate(u8, val | B);
        buf[1] = @truncate(u8, val >> 7);
        return 2;
    } else if (val < (1 << 21)) {
        buf[0] = @truncate(u8, val | B);
        buf[1] = @truncate(u8, (val >> 7) | B);
        buf[2] = @truncate(u8, val >> 14);
        return 3;
    } else if (val < (1 << 28)) {
        buf[0] = @truncate(u8, val | B);
        buf[1] = @truncate(u8, (val >> 7) | B);
        buf[2] = @truncate(u8, (val >> 14) | B);
        buf[3] = @truncate(u8, val >> 21);
        return 4;
    } else {
        buf[0] = @truncate(u8, val | B);
        buf[1] = @truncate(u8, (val >> 7) | B);
        buf[2] = @truncate(u8, (val >> 14) | B);
        buf[3] = @truncate(u8, (val >> 21) | B);
        buf[4] = @truncate(u8, val >> 28);
        return 5;
    }
}

fn encodeFixed32(buf: []u8, val: u32) void {
    buf[0] = @truncate(u8, val);
    buf[1] = @truncate(u8, val >> 8);
    buf[2] = @truncate(u8, val >> 16);
    buf[3] = @truncate(u8, val >> 24);
}

const varint32 = struct {
    val: u32,
    bytesRead: usize,
};

fn decodeVarint32(buf: []const u8) !varint32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const b = buf[i];
        result |= @truncate(u32, std.math.shl(u32, b & 0x7f, shift));
        if (b < 0x80) {
            return varint32{ .val = result, .bytesRead = i + 1 };
        }
        shift += 7;
    }
    return error.InvalidVarint32;
}

fn NewBlockBuilder(
    comptime restart_interval: u32,
) type {
    return struct {
        const BlockBuilderType = @This();

        block: ArrayList(u8),
        restarts: ArrayList(u32),
        restart_count: u32,
        finished: bool,
        last_key: ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) !BlockBuilderType {
            var restarts = ArrayList(u32).init(allocator);
            try restarts.append(0); // first restart point is at offset 0
            return BlockBuilderType{
                .block = ArrayList(u8).init(allocator),
                .restarts = restarts,
                .restart_count = 0,
                .finished = false,
                .last_key = ArrayList(u8).init(allocator),
            };
        }

        pub fn reset(self: *BlockBuilderType) !void {
            self.block.clearRetainingCapacity();
            self.restarts.clearRetainingCapacity();
            try self.restarts.append(0); // first restart point is at offset 0
            self.restart_count = 0;
            self.finished = false;
            self.last_key.clearRetainingCapacity();
        }

        pub fn deinit(self: *BlockBuilderType) void {
            self.restarts.deinit();
            self.last_key.deinit();
            if (!self.finished) {
                self.block.deinit();
            }
        }

        pub fn add(self: *BlockBuilderType, key: []const u8, value: []const u8) !void {
            std.debug.assert(!self.finished);
            std.debug.assert(self.restart_count <= restart_interval);

            // We expect keys to be added in order, i.e. we have zero items or the last key is less than the current key.
            std.debug.assert(self.block.items.len == 0 or std.mem.order(u8, self.last_key.items, key) == .lt);

            // Compute shared prefix.
            var shared: u32 = 0;
            if (self.restart_count < restart_interval) {
                const min_length = @min(self.last_key.items.len, key.len);
                std.debug.print("min_length: {}\n", .{min_length});
                while (shared < min_length and self.last_key.items[shared] == key[shared]) {
                    shared += 1;
                }
            } else {
                try self.restarts.append(@intCast(u32, self.block.items.len));
                self.restart_count = 0;
            }
            const non_shared = @intCast(u32, key.len) - shared;

            // <shared><non_shared><value_size>
            try self.emitVarint32(shared);
            try self.emitVarint32(non_shared);
            try self.emitVarint32(@intCast(u32, value.len));

            // string delta of key + value
            try self.block.appendSlice(key[shared..]);
            try self.block.appendSlice(value);

            // update state
            try self.last_key.resize(key.len);
            self.last_key.clearRetainingCapacity();
            try self.last_key.appendSlice(key);
            self.restart_count += 1;
        }

        pub fn currentSizeEstimate(self: *const BlockBuilderType) usize {
            return self.block.items.len + (self.restarts.items.len * @sizeOf(u32)) + @sizeOf(u32);
        }

        pub fn finish(self: *BlockBuilderType) ![]const u8 {
            // Write restart array offsets
            for (self.restarts.items) |offset| {
                try self.emitFixed32(offset);
            }
            try self.emitFixed32(@intCast(u32, self.restarts.items.len));
            self.finished = true;
            return self.block.toOwnedSlice(); // Caller owns the slice
        }

        fn emitVarint32(self: *BlockBuilderType, val: u32) !void {
            var buf: [5]u8 = undefined;
            const used = encodeVarint32(&buf, val);
            try self.block.appendSlice(buf[0..used]);
        }

        fn emitFixed32(self: *BlockBuilderType, val: u32) !void {
            var buf: [4]u8 = undefined;
            encodeFixed32(&buf, val);
            try self.block.appendSlice(&buf);
        }
    };
}

test "block builder" {
    const allocator = std.testing.allocator;

    var builder = try NewBlockBuilder(16).init(allocator);
    defer builder.deinit();

    try builder.add("a", "val1");
    try builder.add("ab", "val2");
    try builder.add("abc", "val3");
    try builder.add("bcd", "val4");

    const block = try builder.finish(); // once finished, we own the slice
    defer allocator.free(block);

    std.debug.print("block: {s}\n", .{std.fmt.fmtSliceHexLower(block)});
}
