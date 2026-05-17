const std = @import("std");

/// 简易YAML值类型
pub const YamlValue = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    list: []YamlValue,
    map: std.StringHashMap(YamlValue),

    /// 释放YamlValue及其所有子值占用的内存
    pub fn deinit(self: *YamlValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .null, .boolean, .integer, .float => {},
            .string => |s| allocator.free(s),
            .list => |items| {
                for (items) |*item| {
                    var mut = item;
                    mut.deinit(allocator);
                }
                allocator.free(items);
            },
            .map => |*m| {
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                m.deinit();
            },
        }
    }

    /// 从map中获取字符串值，键不存在或类型不匹配返回default
    pub fn getString(self: YamlValue, key: []const u8, default: []const u8) []const u8 {
        switch (self) {
            .map => |m| {
                if (m.get(key)) |val| {
                    switch (val) {
                        .string => |s| return s,
                        else => return default,
                    }
                }
            },
            else => {},
        }
        return default;
    }

    /// 从map中获取整数值，键不存在或类型不匹配返回default
    pub fn getInt(self: YamlValue, key: []const u8, default: i64) i64 {
        switch (self) {
            .map => |m| {
                if (m.get(key)) |val| {
                    switch (val) {
                        .integer => |i| return i,
                        else => return default,
                    }
                }
            },
            else => {},
        }
        return default;
    }

    /// 从map中获取子map值，键不存在或类型不匹配返回null
    pub fn getMap(self: YamlValue, key: []const u8) ?std.StringHashMap(YamlValue) {
        switch (self) {
            .map => |m| {
                if (m.get(key)) |val| {
                    switch (val) {
                        .map => |sub| return sub,
                        else => return null,
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

/// 简易YAML解析器
/// 支持嵌套map、字符串值、整数值、布尔值和列表
/// 不支持：锚点、引用、多文档、流式风格、块标量等高级特性
pub const YamlParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize,

    /// 从YAML文本解析为YamlValue
    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !YamlValue {
        var parser = YamlParser{
            .allocator = allocator,
            .source = source,
            .pos = 0,
        };
        return try parser.parseRoot();
    }

    /// 解析根级节点
    fn parseRoot(self: *YamlParser) anyerror!YamlValue {
        var map = std.StringHashMap(YamlValue).init(self.allocator);
        errdefer {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var val = entry.value_ptr.*;
                val.deinit(self.allocator);
            }
            map.deinit();
        }

        while (self.pos < self.source.len) {
            self.skipEmptyLines();
            if (self.pos >= self.source.len) break;

            // 检查是否是列表项（根级列表）
            if (self.source[self.pos] == '-') {
                // 解析为列表
                var items: std.ArrayList(YamlValue) = .empty;
                while (self.pos < self.source.len) {
                    self.skipEmptyLines();
                    if (self.pos >= self.source.len) break;
                    if (self.source[self.pos] != '-') break;
                    self.pos += 1;
                    // 跳过'-'后的空格
                    while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}
                    const val = try self.parseValue(0);
                    try items.append(self.allocator, val);
                    self.skipToNextLine();
                }
                return .{ .list = try items.toOwnedSlice(self.allocator) };
            }

            const indent = self.countIndent();
            if (indent > 0) {
                // 非零缩进的行不应该出现在根级，跳过
                self.skipToNextLine();
                continue;
            }

            // 解析键值对
            const key = try self.parseKey();
            if (key.len == 0) {
                self.skipToNextLine();
                continue;
            }

            // 跳过冒号后的空格
            while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}

            // 检查是否有内联值
            if (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r' and self.source[self.pos] != '#') {
                const val = try self.parseValue(indent + 2);
                try map.put(try self.allocator.dupe(u8, key), val);
            } else {
                // 值在下一行（嵌套map或列表）
                self.skipToNextLine();
                const val = try self.parseBlock(indent + 2);
                try map.put(try self.allocator.dupe(u8, key), val);
            }
        }

        return .{ .map = map };
    }

    /// 解析块级节点（嵌套map或列表）
    fn parseBlock(self: *YamlParser, min_indent: usize) anyerror!YamlValue {
        // 检查下一个非空行的缩进
        const saved_pos = self.pos;
        self.skipEmptyLines();

        if (self.pos >= self.source.len) {
            return .{ .map = std.StringHashMap(YamlValue).init(self.allocator) };
        }

        const actual_indent = self.countIndent();

        // 缩进不够，回退位置
        if (actual_indent < min_indent) {
            self.pos = saved_pos;
            return .{ .map = std.StringHashMap(YamlValue).init(self.allocator) };
        }

        // 判断是列表还是map
        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            return try self.parseListBlock(actual_indent);
        } else {
            self.pos = saved_pos;
            return try self.parseMapBlock(actual_indent);
        }
    }

    /// 解析map块
    fn parseMapBlock(self: *YamlParser, block_indent: usize) anyerror!YamlValue {
        var map = std.StringHashMap(YamlValue).init(self.allocator);
        errdefer {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var val = entry.value_ptr.*;
                val.deinit(self.allocator);
            }
            map.deinit();
        }

        while (self.pos < self.source.len) {
            self.skipEmptyLines();
            if (self.pos >= self.source.len) break;

            const indent = self.countIndent();
            if (indent != block_indent) break;

            const key = try self.parseKey();
            if (key.len == 0) {
                self.skipToNextLine();
                continue;
            }

            // 跳过冒号后的空格
            while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}

            if (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r' and self.source[self.pos] != '#') {
                const val = try self.parseValue(block_indent + 2);
                try map.put(try self.allocator.dupe(u8, key), val);
            } else {
                self.skipToNextLine();
                const val = try self.parseBlock(block_indent + 2);
                try map.put(try self.allocator.dupe(u8, key), val);
            }
        }

        return .{ .map = map };
    }

    /// 解析列表块
    fn parseListBlock(self: *YamlParser, block_indent: usize) anyerror!YamlValue {
        var items: std.ArrayList(YamlValue) = .empty;

        while (self.pos < self.source.len) {
            self.skipEmptyLines();
            if (self.pos >= self.source.len) break;

            const indent = self.countIndent();
            if (indent != block_indent) break;
            if (self.source[self.pos] != '-') break;

            self.pos += 1;
            // 跳过'-'后的空格
            while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}

            const val = try self.parseValue(block_indent + 2);
            try items.append(self.allocator, val);
            self.skipToNextLine();
        }

        return .{ .list = try items.toOwnedSlice(self.allocator) };
    }

    /// 解析内联值
    fn parseValue(self: *YamlParser, _: usize) anyerror!YamlValue {
        self.skipSpaces();

        if (self.pos >= self.source.len or self.source[self.pos] == '\n' or self.source[self.pos] == '\r') {
            return .null;
        }

        // 注释
        if (self.source[self.pos] == '#') {
            return .null;
        }

        // 引号字符串
        if (self.source[self.pos] == '"' or self.source[self.pos] == '\'') {
            const quote = self.source[self.pos];
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != quote) : (self.pos += 1) {}
            const str = self.source[start..self.pos];
            if (self.pos < self.source.len) self.pos += 1; // 跳过结束引号
            return .{ .string = try self.allocator.dupe(u8, str) };
        }

        // 列表开始（内联）
        if (self.source[self.pos] == '[') {
            return try self.parseInlineList();
        }

        // map开始（内联）
        if (self.source[self.pos] == '{') {
            return try self.parseInlineMap();
        }

        // 裸值（到行尾或注释）
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r' and self.source[self.pos] != '#') : (self.pos += 1) {}
        const raw = std.mem.trim(u8, self.source[start..self.pos], " \t");

        // 布尔值
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "on")) {
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "off")) {
            return .{ .boolean = false };
        }
        // null
        if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~") or raw.len == 0) {
            return .null;
        }

        // 整数
        if (std.fmt.parseInt(i64, raw, 10)) |i| {
            return .{ .integer = i };
        } else |_| {}

        // 浮点数
        if (std.fmt.parseFloat(f64, raw)) |f| {
            return .{ .float = f };
        } else |_| {}

        // 默认为字符串
        return .{ .string = try self.allocator.dupe(u8, raw) };
    }

    /// 解析内联列表 [a, b, c]
    fn parseInlineList(self: *YamlParser) anyerror!YamlValue {
        self.pos += 1; // 跳过 [
        var items: std.ArrayList(YamlValue) = .empty;

        while (self.pos < self.source.len) {
            self.skipSpaces();
            if (self.source[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            if (self.source[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            const val = try self.parseValue(0);
            try items.append(self.allocator, val);
        }

        return .{ .list = try items.toOwnedSlice(self.allocator) };
    }

    /// 解析内联map {a: 1, b: 2}
    fn parseInlineMap(self: *YamlParser) anyerror!YamlValue {
        self.pos += 1; // 跳过 {
        var map = std.StringHashMap(YamlValue).init(self.allocator);

        while (self.pos < self.source.len) {
            self.skipSpaces();
            if (self.source[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            if (self.source[self.pos] == ',') {
                self.pos += 1;
                continue;
            }

            const key = try self.parseKey();
            self.skipSpaces();
            const val = try self.parseValue(0);
            try map.put(try self.allocator.dupe(u8, key), val);
        }

        return .{ .map = map };
    }

    /// 解析键（到冒号为止）
    fn parseKey(self: *YamlParser) anyerror![]const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != ':' and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') : (self.pos += 1) {}
        const key = std.mem.trim(u8, self.source[start..self.pos], " \t");
        if (self.pos < self.source.len and self.source[self.pos] == ':') self.pos += 1;
        return key;
    }

    /// 计算当前行的缩进空格数
    fn countIndent(self: *YamlParser) usize {
        var count: usize = 0;
        var i = self.pos;
        while (i < self.source.len and self.source[i] == ' ') : (i += 1) {
            count += 1;
        }
        return count;
    }

    /// 跳过空格
    fn skipSpaces(self: *YamlParser) void {
        while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}
    }

    /// 跳过空行和注释行（不消耗非空行的缩进空格）
    fn skipEmptyLines(self: *YamlParser) void {
        while (self.pos < self.source.len) {
            // 保存当前位置
            const line_start = self.pos;
            // 跳过行首空格
            while (self.pos < self.source.len and self.source[self.pos] == ' ') : (self.pos += 1) {}
            // 空行或注释行
            if (self.pos < self.source.len and (self.source[self.pos] == '\n' or self.source[self.pos] == '\r' or self.source[self.pos] == '#')) {
                self.skipToNextLine();
            } else {
                // 不是空行，恢复位置（保留缩进空格）
                self.pos = line_start;
                break;
            }
        }
    }

    /// 跳到下一行开头
    fn skipToNextLine(self: *YamlParser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') : (self.pos += 1) {}
        if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
    }
};
