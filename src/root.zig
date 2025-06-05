pub const Column = struct {
    fmt: []const u8,
    header: []const u8,
    alignment: union(enum) {
        left,
        middle,
        right,
        separator: u8,
    },
};

pub const Options = struct {
    column_padding: usize = 4,
    header_underline: ?[]const u8 = "─",
    left_margin: usize = 1,
    title: ?[]const u8 = null,
};

pub fn format(
    writer: anytype,
    comptime spec: []const Column,
    options: Options,
    data: anytype,
) @TypeOf(writer).Error!void {
    const type_info = @typeInfo(@TypeOf(data));
    if (type_info != .array and (type_info != .pointer or type_info.pointer.size != .slice)) {
        @compileError("expected slice or array of data rows, got " ++ @typeName(@TypeOf(data)));
    }

    const ArgsType = @TypeOf(data[0]);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const col_widths = measureColumns(spec, data);

    const margin = (options.column_padding + 1) / 2;

    const row_width: usize = row_width: {
        var row_width = 2 * margin + switch (spec[0].alignment) {
            .left, .middle, .right => col_widths[0].total,
            .separator => col_widths[0].split[0] + col_widths[0].split[1],
        };
        for (col_widths[1..], 1..) |measure, i| {
            row_width += options.column_padding + switch (spec[i].alignment) {
                .left, .middle, .right => measure.total,
                .separator => measure.split[0] + measure.split[1],
            };
        }
        break :row_width row_width;
    };

    if (options.title) |title| {
        try writer.writeByteNTimes(' ', options.left_margin);
        try formatTitle(writer, row_width, title);
        if (options.header_underline) |b| {
            try writer.writeByteNTimes(' ', options.left_margin);
            try writer.writeBytesNTimes(b, row_width);
            try writer.writeByte('\n');
        } else {
            try writer.writeByte('\n');
        }
    }

    try writer.writeByteNTimes(' ', margin + options.left_margin);
    try formatHeader(writer, spec, col_widths, options.column_padding);
    if (options.header_underline) |b| {
        try writer.writeByteNTimes(' ', options.left_margin);
        try writer.writeBytesNTimes(b, row_width);
        try writer.writeByte('\n');
    } else {
        try writer.writeByte('\n');
    }
    for (data) |d| {
        try writer.writeByteNTimes(' ', margin + options.left_margin);
        try formatRow(writer, spec, col_widths, options.column_padding, d);
    }
}

pub fn formatTitle(
    writer: anytype,
    width: usize,
    title: []const u8,
) @TypeOf(writer).Error!void {
    const padding = (1 + width - title.len) / 2;
    try writer.writeByteNTimes(' ', padding);
    try writer.writeAll(title);
    try writer.writeByte('\n');
}

pub fn formatHeader(
    writer: anytype,
    comptime spec: []const Column,
    width: [spec.len]ColumnSize,
    column_padding: usize,
) @TypeOf(writer).Error!void {
    for (spec, 0..) |column, i| {
        const padding = switch (column.alignment) {
            .left, .middle, .right => width[i].total,
            .separator => width[i].split[0] + width[i].split[1],
        } - column.header.len;

        const left_pad = padding / 2;
        const right_pad = (padding + 1) / 2;

        try writer.writeByteNTimes(' ', left_pad + if (i == 0) 0 else column_padding);
        try writer.writeAll(column.header);
        try writer.writeByteNTimes(' ', right_pad);
    }
    try writer.writeByte('\n');
}

pub fn formatRow(
    writer: anytype,
    comptime spec: []const Column,
    width: [spec.len]ColumnSize,
    column_padding: usize,
    args: anytype,
) @TypeOf(writer).Error!void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const fields_info = args_type_info.@"struct".fields;

    comptime var arg_index = 0;

    inline for (spec, 0..) |column, i| {
        const placeholder = comptime std.fmt.Placeholder.parse(extractPlaceholder(column.fmt)[0..].*);
        const arg_pos = switch (placeholder.arg) {
            .none => blk: {
                defer arg_index += 1;
                break :blk arg_index;
            },
            .number => |pos| pos,
            .named => |arg_name| std.meta.fieldIndex(ArgsType, arg_name) orelse
                @compileError("no argument with name '" ++ arg_name ++ "'"),
        };

        const arg_value = @field(args, fields_info[arg_pos].name);
        const padding = switch (column.alignment) {
            .left, .middle, .right => width[i].total - std.fmt.count(column.fmt, .{arg_value}),
            .separator => undefined,
        };

        const left_pad, const right_pad = switch (column.alignment) {
            .left => .{ 0, padding },
            .right => .{ padding, 0 },
            .middle => .{ padding / 2, (padding + 1) / 2 },
            .separator => |sep| blk: {
                var index_writer = indexOfWriter(std.io.null_writer, sep);
                index_writer.writer().print(column.fmt, .{arg_value}) catch unreachable;
                if (index_writer.first_index) |index| {
                    break :blk .{
                        width[i].split[0] - index,
                        width[i].split[1] - (index_writer.bytes_written - index),
                    };
                } else {
                    const total = width[i].split[0] + width[i].split[1] + 1;
                    const pad = total - index_writer.bytes_written;
                    break :blk .{ (pad + 1) / 2, pad / 2 };
                }
            },
        };

        try writer.writeByteNTimes(' ', left_pad + if (i == 0) 0 else column_padding);
        try std.fmt.format(
            writer,
            column.fmt,
            .{arg_value},
        );
        try writer.writeByteNTimes(' ', right_pad);
    }
    try writer.writeByte('\n');
}

pub const ColumnSize = union {
    total: usize,
    split: struct { u32, u32 },
};

pub fn measureColumns(comptime spec: []const Column, data: anytype) [spec.len]ColumnSize {
    const ArgsType = @TypeOf(data[0]);
    const args_type_info = @typeInfo(ArgsType);
    const fields_info = args_type_info.@"struct".fields;

    var sizes: [spec.len]ColumnSize = undefined;
    comptime var arg_index = 0;
    inline for (&sizes, spec) |*size, column| {
        const placeholder = comptime std.fmt.Placeholder.parse(extractPlaceholder(column.fmt)[0..].*);
        const arg_pos = switch (placeholder.arg) {
            .none => blk: {
                defer arg_index += 1;
                break :blk arg_index;
            },
            .number => |pos| pos,
            .named => |arg_name| std.meta.fieldIndex(ArgsType, arg_name) orelse
                @compileError("no argument with name '" ++ arg_name ++ "'"),
        };

        size.* = switch (column.alignment) {
            .left, .middle, .right => .{ .total = column.header.len },
            .separator => .{ .split = .{ 0, 0 } },
        };

        for (data) |d| {
            const arg_value = @field(d, fields_info[arg_pos].name);
            const len: usize = @truncate(std.fmt.count(column.fmt, .{arg_value}));
            switch (column.alignment) {
                .left, .middle, .right => {
                    size.total = @max(size.total, len);
                },
                .separator => |sep| {
                    var index_writer = indexOfWriter(std.io.null_writer, sep);
                    index_writer.writer().print(column.fmt, .{arg_value}) catch unreachable;

                    if (index_writer.first_index) |index| {
                        size.split[0] = @max(size.split[0], @as(u32, @truncate(index)));
                        const right: u32 = @truncate(index_writer.bytes_written - index);
                        size.split[1] = @max(size.split[1], right);
                    }
                },
            }
        }

        switch (column.alignment) {
            .separator => if (size.split[0] + size.split[1] < column.header.len) {
                size.split = .{ (column.header.len + 1) / 2, column.header.len / 2 };
            },
            .left, .middle, .right => {},
        }
    }

    return sizes;
}

fn extractPlaceholder(comptime fmt: []const u8) []const u8 {
    const errors = struct {
        const missing = "column format string '" ++ fmt ++ "' does not contain a placeholder";
        const unclosed = "placeholder in column format string '" ++ fmt ++ "'" ++ "is missing closing '}'";
    };

    var start = std.mem.indexOfScalar(u8, fmt, '{') orelse
        @compileError(errors.missing);

    while (fmt.len > start + 1 and fmt[start + 1] == '{') {
        start = std.mem.indexOfScalarPos(u8, fmt, start + 2, '{') orelse
            @compileError(errors.missing);
    }

    var end = std.mem.indexOfScalarPos(u8, fmt, start + 1, '}') orelse {
        @compileError(errors.unclosed);
    };

    while (fmt.len > end + 1 and fmt[end + 1] == '}') {
        end = std.mem.indexOfScalarPos(u8, fmt, end + 2, '}') orelse {
            @compileError(errors.unclosed);
        };
    }

    return fmt[start + 1 .. end];
}

fn IndexOfWriter(comptime WriterType: type) type {
    return struct {
        scalar: u8,
        first_index: ?usize = null,
        bytes_written: usize,
        child_stream: WriterType,

        pub const Error = WriterType.Error;
        pub const Writer = std.io.Writer(*Self, Error, write);

        const Self = @This();

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (self.first_index == null) {
                if (std.mem.indexOfScalar(u8, bytes, self.scalar)) |index| {
                    self.first_index = self.bytes_written + index;
                }
            }
            const amt = try self.child_stream.write(bytes);
            self.bytes_written += amt;
            return amt;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

fn indexOfWriter(child_stream: anytype, scalar: u8) IndexOfWriter(@TypeOf(child_stream)) {
    return .{ .scalar = scalar, .bytes_written = 0, .child_stream = child_stream };
}

const std = @import("std");
