const std = @import("std");

/// 读取文件内容工具
/// 根据文件路径读取文件的全部内容，超过50000字符会被截断
/// 参数：
///   allocator - 内存分配器
///   io - I/O实例
///   args - JSON参数，需包含path字段
/// 返回：文件内容字符串
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror![]const u8 {
    const path = if (args.object.get("path")) |p| p.string else return "Error: path is required";

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error reading {s}: {}", .{ path, err });
    };

    // 截断过长的内容
    if (content.len > 50000) {
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(allocator, content[0..50000]);
        try result.appendSlice(allocator, "\n... [truncated]");
        allocator.free(content);
        return try result.toOwnedSlice(allocator);
    }

    return content;
}

/// 写入文件工具
/// 将内容写入指定路径的文件，自动创建父目录
/// 参数：
///   allocator - 内存分配器
///   io - I/O实例
///   args - JSON参数，需包含path和content字段
/// 返回：写入确认消息
pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror![]const u8 {
    const path = if (args.object.get("path")) |p| p.string else return "Error: path is required";
    const content = if (args.object.get("content")) |c| c.string else return "Error: content is required";

    // 自动创建父目录
    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    // 创建并写入文件
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error writing {s}: {}", .{ path, err });
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error writing {s}: {}", .{ path, err });
    };

    return try std.fmt.allocPrint(allocator, "Written {d} chars to {s}", .{ content.len, path });
}
