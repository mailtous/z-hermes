const std = @import("std");

/// ANSI颜色代码枚举
pub const Color = enum {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    /// 获取ANSI转义序列
    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }
};

/// 文本样式枚举
pub const Style = enum {
    bold,
    dim,
    italic,
    underline,

    /// 获取ANSI转义序列
    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
            .underline => "\x1b[4m",
        };
    }

    /// 获取重置序列
    pub fn resetCode(self: Style) []const u8 {
        return switch (self) {
            .bold => "\x1b[22m",
            .dim => "\x1b[22m",
            .italic => "\x1b[23m",
            .underline => "\x1b[24m",
        };
    }
};

/// 彩色打印器
/// 封装标准输出文件写入器，提供带颜色和样式的打印功能
/// 注意：必须存储指向File.Writer的指针，因为Writer的vtable方法
/// 依赖完整的File.Writer上下文
pub const ColorPrinter = struct {
    file_writer: *std.Io.File.Writer,
    allocator: std.mem.Allocator,

    /// 初始化彩色打印器
    /// 参数：
    ///   allocator - 内存分配器
    ///   file_writer - 标准输出文件写入器指针
    pub fn init(allocator: std.mem.Allocator, file_writer: *std.Io.File.Writer) ColorPrinter {
        return .{
            .allocator = allocator,
            .file_writer = file_writer,
        };
    }

    /// 获取底层Io.Writer接口
    fn writer(self: *ColorPrinter) std.Io.Writer {
        return self.file_writer.interface;
    }

    /// 刷新输出缓冲区
    pub fn flush(self: *ColorPrinter) void {
        self.file_writer.flush() catch {};
    }

    /// 打印普通文本（无颜色）
    pub fn print(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print(fmt, args) catch {};
    }

    /// 打印带颜色的文本
    /// 参数：
    ///   color - 文本颜色
    ///   fmt - 格式字符串
    ///   args - 格式参数
    pub fn color(self: *ColorPrinter, c: Color, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print("{s}", .{c.code()}) catch {};
        self.file_writer.interface.print(fmt, args) catch {};
        self.file_writer.interface.print("{s}", .{Color.reset.code()}) catch {};
    }

    /// 打印带样式的文本
    pub fn style(self: *ColorPrinter, s: Style, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print("{s}", .{s.code()}) catch {};
        self.file_writer.interface.print(fmt, args) catch {};
        self.file_writer.interface.print("{s}", .{s.resetCode()}) catch {};
    }

    /// 打印带颜色和样式的文本
    pub fn colorStyle(self: *ColorPrinter, c: Color, s: Style, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print("{s}{s}", .{ s.code(), c.code() }) catch {};
        self.file_writer.interface.print(fmt, args) catch {};
        self.file_writer.interface.print("{s}", .{Color.reset.code()}) catch {};
    }

    /// 打印红色错误信息
    pub fn errorMsg(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.colorStyle(.bright_red, .bold, fmt, args);
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印黄色警告信息
    pub fn warn(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.color(.bright_yellow, fmt, args);
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印绿色成功信息
    pub fn success(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.color(.bright_green, fmt, args);
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印青色信息（用于AI回复）
    pub fn info(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.color(.bright_cyan, fmt, args);
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印暗色文本（用于提示信息）
    pub fn dim(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.style(.dim, fmt, args);
    }

    /// 打印粗体文本
    pub fn bold(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.style(.bold, fmt, args);
    }

    /// 打印用户提示符（绿色粗体）
    pub fn userPrompt(self: *ColorPrinter) void {
        self.colorStyle(.bright_green, .bold, "you > ", .{});
    }

    /// 打印AI回复提示符（青色粗体）
    pub fn aiPrompt(self: *ColorPrinter) void {
        self.colorStyle(.bright_cyan, .bold, "hermes > ", .{});
    }

    /// 打印分隔线
    pub fn separator(self: *ColorPrinter, title: []const u8) void {
        self.color(.bright_yellow, "── {s} ──", .{title});
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印横幅（项目标题）
    pub fn banner(self: *ColorPrinter, version: []const u8) void {
        self.file_writer.interface.print("\n", .{}) catch {};
        self.colorStyle(.bright_cyan, .bold,
            \\╔══════════════════════════════════════╗
            \\║       Z-Hermes Agent {s}            ║
            \\╚══════════════════════════════════════╝
        , .{version});
        self.file_writer.interface.print("\n", .{}) catch {};
    }

    /// 打印状态信息（模型、会话等）
    pub fn status(self: *ColorPrinter, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print("{s}", .{Color.bright_white.code()}) catch {};
        self.file_writer.interface.print("  ", .{}) catch {};
        self.file_writer.interface.print("{s}", .{Color.reset.code()}) catch {};
        self.file_writer.interface.print(fmt, args) catch {};
        self.file_writer.interface.print("\n", .{}) catch {};
    }
};
