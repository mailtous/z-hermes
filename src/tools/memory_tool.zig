const std = @import("std");
const persistent = @import("../memory/persistent.zig");
const recall = @import("../memory/recall.zig");

/// 内存工具
/// 提供记忆的保存、读取、搜索和用户画像更新功能
/// 作为AI代理的工具接口，通过action参数区分不同操作
pub const MemoryTool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    persistent_memory: ?*persistent.PersistentMemory = null,
    session_recall: ?*recall.SessionRecall = null,

    pub fn dummyHandler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
        _ = alloc;
        _ = io_arg;
        _ = args;
        return "not dispatched via registry";
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemoryTool {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    /// 设置持久化内存和会话回忆的引用
    pub fn setMemory(self: *MemoryTool, pm: *persistent.PersistentMemory, sr: ?*recall.SessionRecall) void {
        self.persistent_memory = pm;
        self.session_recall = sr;
    }

    /// 执行内存操作
    /// 支持的action：
    ///   save - 保存观察记录到记忆文件
    ///   save_user - 更新用户画像
    ///   read - 读取所有记忆和用户画像
    ///   search - 搜索历史会话中的相关内容
    /// 参数：
    ///   args - JSON参数，需包含action字段
    /// 返回：操作结果文本
    pub fn execute(self: *MemoryTool, args: std.json.Value) anyerror![]const u8 {
        const action_val = args.object.get("action") orelse return "Error: action is required";
        const action = action_val.string;

        const pm = self.persistent_memory orelse return "Error: memory not initialized";

        // 保存观察记录
        if (std.mem.eql(u8, action, "save")) {
            const text = if (args.object.get("text")) |t| t.string else return "Error: text is required for save";
            return try pm.saveObservation(text);
        }

        // 更新用户画像
        if (std.mem.eql(u8, action, "save_user")) {
            const text = if (args.object.get("text")) |t| t.string else return "Error: text is required for save_user";
            return try pm.updateUserProfile(text);
        }

        // 读取所有记忆
        if (std.mem.eql(u8, action, "read")) {
            const mem = pm.readMemory();
            const user = pm.readUser();
            defer self.allocator.free(mem);
            defer self.allocator.free(user);

            var result: std.ArrayList(u8) = .empty;
            try result.print(self.allocator, "## Memory\n{s}\n\n## User Profile\n{s}", .{ mem, user });
            return try result.toOwnedSlice(self.allocator);
        }

        // 搜索历史会话
        if (std.mem.eql(u8, action, "search")) {
            const text = if (args.object.get("text")) |t| t.string else return "Error: text (query) is required for search";
            const sr = self.session_recall orelse return "Error: session recall not available";
            const result = try sr.recall(text, 3);
            if (result.len == 0) return "No relevant past sessions found.";
            return result;
        }

        return try std.fmt.allocPrint(self.allocator, "Error: unknown action '{s}'. Use: save, save_user, read, search", .{action});
    }
};
