const std = @import("std");

/// 终端命令执行工具
/// 通过shell执行命令并返回输出结果
/// 参数：
///   allocator - 内存分配器
///   io - I/O实例
///   args - JSON参数，需包含command字段，可选timeout字段（默认30秒）
/// 返回：命令执行结果（标准输出或标准错误）
pub fn runTerminal(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror![]const u8 {
    const command = if (args.object.get("command")) |c| c.string else return "Error: command is required";

    // 解析超时参数（当前未使用，保留接口）
    _ = if (args.object.get("timeout")) |t| blk: {
        switch (t) {
            .integer => |i| break :blk @as(u32, @intCast(i)),
            else => break :blk @as(u32, 30),
        }
    } else @as(u32, 30);

    // 使用sh -c执行命令
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sh", "-c", command },
    }) catch {
        return "Error: failed to execute command";
    };

    var output: std.ArrayList(u8) = .empty;

    // 处理退出码
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                try output.print(allocator, "Exit code: {d}\n", .{code});
            }
        },
        else => try output.appendSlice(allocator, "Process terminated abnormally"),
    }

    // 优先输出stdout，其次stderr
    if (result.stdout.len > 0) {
        try output.appendSlice(allocator, result.stdout);
    } else if (result.stderr.len > 0) {
        try output.appendSlice(allocator, result.stderr);
    } else if (output.items.len == 0) {
        try output.appendSlice(allocator, "(no output)");
    }

    // 截断过长的输出
    if (output.items.len > 50000) {
        output.shrinkRetainingCapacity(50000);
        try output.appendSlice(allocator, "\n... [truncated]");
    }

    return try output.toOwnedSlice(allocator);
}
