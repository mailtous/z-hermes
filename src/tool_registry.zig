const std = @import("std");

/// 工具处理器函数类型
/// 参数：分配器、I/O实例、JSON参数值
/// 返回：工具执行结果字符串
pub const ToolHandler = *const fn (std.mem.Allocator, std.Io, std.json.Value) anyerror![]const u8;

/// 工具条目：包含工具的元数据和处理器
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    handler: ToolHandler,
    category: []const u8 = "general",
};

/// 工具注册表：管理所有可用工具的注册、查询和Schema生成
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayList(ToolEntry),

    /// 初始化工具注册表
    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.ArrayList(ToolEntry).empty,
        };
    }

    /// 释放注册表占用的资源
    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit(self.allocator);
    }

    /// 注册一个新工具
    /// 参数：
    ///   name - 工具名称
    ///   description - 工具描述
    ///   parameters - 工具参数的JSON Schema
    ///   handler - 工具处理函数
    ///   category - 工具分类（如"execution"、"file"等）
    pub fn register(
        self: *ToolRegistry,
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
        handler: ToolHandler,
        category: []const u8,
    ) void {
        self.tools.append(self.allocator, .{
            .name = name,
            .description = description,
            .parameters = parameters,
            .handler = handler,
            .category = category,
        }) catch {};
    }

    /// 获取所有工具的LLM Schema描述
    /// 用于将工具信息传递给LLM，让模型知道可以调用哪些工具
    pub fn getSchemas(self: *ToolRegistry, allocator: std.mem.Allocator) ![]llm.ToolSchema {
        var schemas: std.ArrayList(llm.ToolSchema) = .empty;
        for (self.tools.items) |tool| {
            try schemas.append(allocator, .{
                .function = .{
                    .name = tool.name,
                    .description = tool.description,
                    .parameters = tool.parameters,
                },
            });
        }
        return try schemas.toOwnedSlice(allocator);
    }

    /// 根据工具名称查找对应的处理器
    /// 返回null表示未找到该工具
    pub fn getHandler(self: *ToolRegistry, name: []const u8) ?ToolHandler {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) {
                return tool.handler;
            }
        }
        return null;
    }
};

const llm = @import("llm_client.zig");
