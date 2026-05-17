const std = @import("std");

/// 持久化内存管理器
/// 将AI的观察记录和用户画像保存到磁盘文件中，实现跨会话的记忆持久化
/// 使用MEMORY.md存储观察记录，USER.md存储用户画像
pub const PersistentMemory = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    memory_path: []const u8,
    user_path: []const u8,
    memory_limit: usize = 2200,
    user_limit: usize = 1375,

    /// 初始化持久化内存
    /// 创建数据目录和记忆文件（如果不存在）
    /// 参数：
    ///   allocator - 内存分配器
    ///   io - I/O实例
    ///   data_dir - 数据目录路径
    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !PersistentMemory {
        const memory_path = try std.fs.path.join(allocator, &.{ data_dir, "MEMORY.md" });
        const user_path = try std.fs.path.join(allocator, &.{ data_dir, "USER.md" });

        // 确保数据目录存在
        const dir = std.Io.Dir.cwd();
        dir.createDirPath(io, data_dir) catch {};

        // 创建记忆文件（如果不存在）
        {
            const f = dir.createFile(io, memory_path, .{}) catch |err| switch (err) {
                else => return err,
            };
            f.close(io);
        }

        // 创建用户画像文件（如果不存在）
        {
            const f = dir.createFile(io, user_path, .{}) catch |err| switch (err) {
                else => return err,
            };
            f.close(io);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .memory_path = memory_path,
            .user_path = user_path,
        };
    }

    /// 释放持久化内存占用的资源
    pub fn deinit(self: *PersistentMemory) void {
        self.allocator.free(self.memory_path);
        self.allocator.free(self.user_path);
    }

    /// 加载所有记忆内容
    /// 将用户画像和观察记录合并为一个字符串
    pub fn load(self: *PersistentMemory) ![]const u8 {
        var parts: std.ArrayList(u8) = .empty;

        const user = self.readUser();
        const memory = self.readMemory();

        if (user.len > 0) {
            try parts.appendSlice(self.allocator, "### User Profile\n");
            try parts.appendSlice(self.allocator, user);
        }

        if (memory.len > 0) {
            if (parts.items.len > 0) try parts.appendSlice(self.allocator, "\n\n");
            try parts.appendSlice(self.allocator, "### Observations\n");
            try parts.appendSlice(self.allocator, memory);
        }

        return try parts.toOwnedSlice(self.allocator);
    }

    /// 保存一条观察记录到记忆文件
    /// 当总内容超过memory_limit时，从最早的记录开始删除
    /// 参数：
    ///   text - 要保存的观察文本
    /// 返回：保存确认消息
    pub fn saveObservation(self: *PersistentMemory, text: []const u8) ![]const u8 {
        const current = self.readMemory();
        defer self.allocator.free(current);

        // 构建新条目
        var new_entry: std.ArrayList(u8) = .empty;
        try new_entry.appendSlice(self.allocator, "\n- ");
        try new_entry.appendSlice(self.allocator, text);

        // 如果超出限制，从最早的记录开始删除
        var combined: std.ArrayList(u8) = .empty;
        if (current.len + new_entry.items.len > self.memory_limit) {
            var lines: std.ArrayList([]const u8) = .empty;
            var iter = std.mem.splitSequence(u8, current, "\n");
            while (iter.next()) |line| {
                try lines.append(self.allocator, line);
            }
            // 逐行删除直到总长度在限制内
            while (lines.items.len > 0 and
                (try std.mem.join(self.allocator, "\n", lines.items)).len + new_entry.items.len > self.memory_limit)
            {
                _ = lines.orderedRemove(0);
            }
            const joined = try std.mem.join(self.allocator, "\n", lines.items);
            try combined.appendSlice(self.allocator, joined);
            self.allocator.free(joined);
            lines.deinit(self.allocator);
        } else {
            try combined.appendSlice(self.allocator, current);
        }

        try combined.appendSlice(self.allocator, new_entry.items);
        new_entry.deinit(self.allocator);

        // 写入文件
        const dir = std.Io.Dir.cwd();
        const file = try dir.createFile(self.io, self.memory_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, combined.items);
        combined.deinit(self.allocator);

        var result: std.ArrayList(u8) = .empty;
        if (text.len > 80) {
            try result.print(self.allocator, "Saved to memory: {s}...", .{text[0..80]});
        } else {
            try result.print(self.allocator, "Saved to memory: {s}", .{text});
        }
        return try result.toOwnedSlice(self.allocator);
    }

    /// 更新用户画像
    /// 直接覆盖写入，超过user_limit的部分会被截断
    /// 参数：
    ///   text - 新的用户画像文本
    /// 返回：更新确认消息
    pub fn updateUserProfile(self: *PersistentMemory, text: []const u8) ![]const u8 {
        const truncated = if (text.len > self.user_limit) text[0..self.user_limit] else text;

        const dir = std.Io.Dir.cwd();
        const file = try dir.createFile(self.io, self.user_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, truncated);

        var result: std.ArrayList(u8) = .empty;
        try result.print(self.allocator, "User profile updated ({d} chars)", .{text.len});
        return try result.toOwnedSlice(self.allocator);
    }

    /// 读取记忆文件内容
    /// 返回去除首尾空白后的记忆文本
    pub fn readMemory(self: *PersistentMemory) []const u8 {
        const dir = std.Io.Dir.cwd();
        const content = dir.readFileAlloc(self.io, self.memory_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return "";
        defer self.allocator.free(content);
        return std.mem.trim(u8, content, " \t\n\r");
    }

    /// 读取用户画像文件内容
    /// 返回去除首尾空白后的用户画像文本
    pub fn readUser(self: *PersistentMemory) []const u8 {
        const dir = std.Io.Dir.cwd();
        const content = dir.readFileAlloc(self.io, self.user_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return "";
        defer self.allocator.free(content);
        return std.mem.trim(u8, content, " \t\n\r");
    }
};
