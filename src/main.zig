const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;

fn putVarint32(dst: *ArrayList(u8), v: u32) !void {
    const B: u32 = 128;
    if (v < (1 << 7)) {
        try dst.append(@truncate(u8, v));
    } else if (v < (1 << 14)) {
        try dst.append(@truncate(u8, v | B));
        try dst.append(@truncate(u8, v >> 7));
    } else if (v < (1 << 21)) {
        try dst.append(@truncate(u8, v | B));
        try dst.append(@truncate(u8, (v >> 7) | B));
        try dst.append(@truncate(u8, v >> 14));
    } else if (v < (1 << 28)) {
        try dst.append(@truncate(u8, v | B));
        try dst.append(@truncate(u8, (v >> 7) | B));
        try dst.append(@truncate(u8, (v >> 14) | B));
        try dst.append(@truncate(u8, v >> 21));
    } else {
        try dst.append(@truncate(u8, v | B));
        try dst.append(@truncate(u8, (v >> 7) | B));
        try dst.append(@truncate(u8, (v >> 14) | B));
        try dst.append(@truncate(u8, (v >> 21) | B));
        try dst.append(@truncate(u8, v >> 28));
    }
}

fn putFixed32(dst: *ArrayList(u8), v: u32) !void {
    var buf: [@sizeOf(u32)]u8 = undefined;
    buf[0] = @truncate(u8, v);
    buf[1] = @truncate(u8, v >> 8);
    buf[2] = @truncate(u8, v >> 16);
    buf[3] = @truncate(u8, v >> 24);
    try dst.appendSlice(&buf);
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
            return BlockBuilderType{
                .block = ArrayList(u8).init(allocator),
                .restarts = ArrayList(u32).init(allocator),
                .restart_count = 0,
                .finished = false,
                .last_key = ArrayList(u8).init(allocator),
            };
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
            try putVarint32(&self.block, shared);
            try putVarint32(&self.block, non_shared);
            try putVarint32(&self.block, @intCast(u32, value.len));

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
                try putFixed32(&self.block, offset);
            }
            try putFixed32(&self.block, @intCast(u32, self.restarts.items.len));
            self.finished = true;
            return self.block.toOwnedSlice(); // Caller owns the slice
        }
    };
}

test "block builder" {
    const allocator = std.testing.allocator;

    var builder = try NewBlockBuilder(16).init(allocator);
    defer builder.deinit();

    // make sure to add newline to the end of the string
    try builder.add("a", "val1");
    try builder.add("ab", "val2");
    try builder.add("abc", "val3");
    try builder.add("bcd", "val4");

    const block = try builder.finish(); // we're responsible for freeing the block
    // print block
    std.debug.print("block: {s}\n", .{std.fmt.fmtSliceHexLower(block)});
    defer allocator.free(block);
}
