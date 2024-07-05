const std = @import("std");
const Buffer = @import("Buffer");

const ArrayList = std.ArrayList;
const a = std.testing.allocator;

fn metrics() Buffer.Metrix {
    return .{
        .ctx = undefined,
        .egc_length = struct {
            fn f(_: *const anyopaque, _: []const u8, colcount: *c_int, _: usize) usize {
                colcount.* = 1;
                return 1;
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(_: *const anyopaque, chunk_: []const u8, _: usize) usize {
                return chunk_.len;
            }
        }.f,
    };
}

fn get_big_doc() !*Buffer {
    const BigDocGen = struct {
        line_num: usize = 0,
        lines: usize = 10000,

        buf: [128]u8 = undefined,
        line_buf: []u8 = "",
        read_count: usize = 0,

        const Self = @This();
        const Reader = std.io.Reader(*Self, Err, read);
        const Err = error{NoSpaceLeft};

        fn gen_line(self: *Self) Err!void {
            var stream = std.io.fixedBufferStream(&self.buf);
            const writer = stream.writer();
            try writer.print("this is line {d}\n", .{self.line_num});
            self.line_buf = stream.getWritten();
            self.read_count = 0;
            self.line_num += 1;
        }

        fn read(self: *Self, buffer: []u8) Err!usize {
            if (self.line_num > self.lines)
                return 0;
            if (self.line_buf.len == 0 or self.line_buf.len - self.read_count == 0)
                try self.gen_line();
            const read_count = self.read_count;
            const bytes_to_read = @min(self.line_buf.len - read_count, buffer.len);
            @memcpy(buffer[0..bytes_to_read], self.line_buf[read_count .. read_count + bytes_to_read]);
            self.read_count += bytes_to_read;
            return bytes_to_read;
        }

        fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
    var gen: BigDocGen = .{};
    var doc = ArrayList(u8).init(a);
    defer doc.deinit();
    try gen.reader().readAllArrayList(&doc, std.math.maxInt(usize));
    var buf = try Buffer.create(a);
    var fis = std.io.fixedBufferStream(doc.items);
    buf.update(try buf.load(fis.reader(), doc.items.len));
    return buf;
}

test "buffer" {
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    const root = try buffer.load_from_string(doc);

    try std.testing.expect(root.is_balanced());
    buffer.update(root);

    const result: []const u8 = try buffer.store_to_string(a);
    defer a.free(result);
    try std.testing.expectEqualDeep(result, doc);
    try std.testing.expectEqual(doc.len, result.len);
    try std.testing.expectEqual(doc.len, buffer.root.length());
}

fn get_line(buf: *const Buffer, line: usize) ![]const u8 {
    var result = ArrayList(u8).init(a);
    try buf.root.get_line(line, &result, metrics());
    return result.toOwnedSlice();
}

test "walk_from_line" {
    const buffer = try get_big_doc();
    defer buffer.deinit();

    const lines = buffer.root.lines();
    try std.testing.expectEqual(lines, 10002);

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "this is line 0"));

    const line1 = try get_line(buffer, 1);
    defer a.free(line1);
    try std.testing.expect(std.mem.eql(u8, line1, "this is line 1"));

    const line100 = try get_line(buffer, 100);
    defer a.free(line100);
    try std.testing.expect(std.mem.eql(u8, line100, "this is line 100"));

    const line9999 = try get_line(buffer, 9999);
    defer a.free(line9999);
    try std.testing.expect(std.mem.eql(u8, line9999, "this is line 9999"));
}

test "line_len" {
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc));

    try std.testing.expectEqual(try buffer.root.line_width(0, metrics()), 8);
    try std.testing.expectEqual(try buffer.root.line_width(1, metrics()), 5);
}

test "del_chars" {
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc));

    buffer.update(try buffer.root.del_chars(3, try buffer.root.line_width(3, metrics()) - 1, 1, buffer.a, metrics()));
    const line3 = try get_line(buffer, 3);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "us"));

    buffer.update(try buffer.root.del_chars(3, 0, 7, buffer.a, metrics()));
    const line3_1 = try get_line(buffer, 3);
    defer a.free(line3_1);
    try std.testing.expect(std.mem.eql(u8, line3_1, "your"));

    // try buffer.rebalance();
    // try std.testing.expect(buffer.is_balanced());

    buffer.update(try buffer.root.del_chars(0, try buffer.root.line_width(0, metrics()) - 1, 2, buffer.a, metrics()));
    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "All youropes"));
}

fn check_line(buffer: *const Buffer, line_no: usize, expect: []const u8) !void {
    const line = try get_line(buffer, line_no);
    defer a.free(line);
    try std.testing.expect(std.mem.eql(u8, line, expect));
}

test "del_chars2" {
    const doc: []const u8 =
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
        \\All your
        \\ropes
        \\are belong to
        \\us!
    ;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc));

    buffer.update(try buffer.root.del_chars(2, try buffer.root.line_width(2, metrics()) - 3, 6, buffer.a, metrics()));

    try check_line(buffer, 2, "are belong!");
    try check_line(buffer, 3, "All your");
    try check_line(buffer, 4, "ropes");
}

test "insert_chars" {
    const doc: []const u8 =
        \\B
    ;
    const buffer = try Buffer.create(a);
    defer buffer.deinit();
    buffer.update(try buffer.load_from_string(doc));

    const line0 = try get_line(buffer, 0);
    defer a.free(line0);
    try std.testing.expect(std.mem.eql(u8, line0, "B"));

    _, _, var root = try buffer.root.insert_chars(0, 0, "1", buffer.a, metrics());
    buffer.update(root);

    const line1 = try get_line(buffer, 0);
    defer a.free(line1);
    try std.testing.expect(std.mem.eql(u8, line1, "1B"));

    _, _, root = try root.insert_chars(0, 1, "2", buffer.a, metrics());
    buffer.update(root);

    const line2 = try get_line(buffer, 0);
    defer a.free(line2);
    try std.testing.expect(std.mem.eql(u8, line2, "12B"));

    _, _, root = try root.insert_chars(0, 2, "3", buffer.a, metrics());
    buffer.update(root);

    const line3 = try get_line(buffer, 0);
    defer a.free(line3);
    try std.testing.expect(std.mem.eql(u8, line3, "123B"));

    _, _, root = try root.insert_chars(0, 3, "4", buffer.a, metrics());
    buffer.update(root);

    const line4 = try get_line(buffer, 0);
    defer a.free(line4);
    try std.testing.expect(std.mem.eql(u8, line4, "1234B"));

    _, _, root = try root.insert_chars(0, 4, "5", buffer.a, metrics());
    buffer.update(root);

    const line5 = try get_line(buffer, 0);
    defer a.free(line5);
    try std.testing.expect(std.mem.eql(u8, line5, "12345B"));

    _, _, root = try root.insert_chars(0, 5, "6", buffer.a, metrics());
    buffer.update(root);

    const line6 = try get_line(buffer, 0);
    defer a.free(line6);
    try std.testing.expect(std.mem.eql(u8, line6, "123456B"));

    _, _, root = try root.insert_chars(0, 6, "7", buffer.a, metrics());
    buffer.update(root);

    const line7 = try get_line(buffer, 0);
    defer a.free(line7);
    try std.testing.expect(std.mem.eql(u8, line7, "1234567B"));

    const line, const col, root = try buffer.root.insert_chars(0, 7, "8\n9", buffer.a, metrics());
    buffer.update(root);

    const line8 = try get_line(buffer, 0);
    defer a.free(line8);
    const line9 = try get_line(buffer, 1);
    defer a.free(line9);
    try std.testing.expect(std.mem.eql(u8, line8, "12345678"));
    try std.testing.expect(std.mem.eql(u8, line9, "9B"));
    try std.testing.expectEqual(line, 1);
    try std.testing.expectEqual(col, 1);
}
