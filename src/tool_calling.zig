const std = @import("std");
const llm = @import("llm_client.zig");

/// 解析后的工具调用：包含调用ID、工具名称和参数
pub const ParsedToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
};

/// 解析结果：包含文本内容和工具调用列表
pub const ParseResult = struct {
    content: []const u8,
    tool_calls: []ParsedToolCall,
};

/// 工具调用策略：使用虚函数表实现多态
/// 不同的LLM模型可能使用不同的工具调用格式（结构化JSON或文本解析）
pub const ToolCallingStrategy = struct {
    vtable: *const VTable,

    /// 虚函数表：定义工具调用策略的四个核心方法
    pub const VTable = struct {
        prepareKwargs: *const fn (*ToolCallingStrategy, std.mem.Allocator, *std.ArrayList(u8), []llm.ToolSchema) anyerror!void,
        parseResponse: *const fn (*ToolCallingStrategy, std.mem.Allocator, []const u8, ?[]llm.ToolCallData) anyerror!ParseResult,
        buildAssistantMsg: *const fn (*ToolCallingStrategy, std.mem.Allocator, []const u8, []ParsedToolCall) anyerror!llm.Message,
        buildToolResultMsg: *const fn (*ToolCallingStrategy, std.mem.Allocator, ParsedToolCall, []const u8) anyerror!llm.Message,
    };

    /// 准备工具调用的额外请求参数
    pub fn prepareKwargs(self: *ToolCallingStrategy, allocator: std.mem.Allocator, body: *std.ArrayList(u8), tools: []llm.ToolSchema) !void {
        try self.vtable.prepareKwargs(self, allocator, body, tools);
    }

    /// 解析LLM回复，提取文本内容和工具调用
    pub fn parseResponse(self: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, raw_calls: ?[]llm.ToolCallData) !ParseResult {
        return try self.vtable.parseResponse(self, allocator, content, raw_calls);
    }

    /// 构建助手消息（包含文本和工具调用信息）
    pub fn buildAssistantMsg(self: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, tool_calls: []ParsedToolCall) !llm.Message {
        return try self.vtable.buildAssistantMsg(self, allocator, content, tool_calls);
    }

    /// 构建工具结果消息
    pub fn buildToolResultMsg(self: *ToolCallingStrategy, allocator: std.mem.Allocator, call: ParsedToolCall, result: []const u8) !llm.Message {
        return try self.vtable.buildToolResultMsg(self, allocator, call, result);
    }
};

/// 结构化工具调用策略
/// 适用于支持OpenAI风格函数调用的模型（如qwen、mistral、hermes等）
/// 直接使用API返回的tool_calls字段
pub const StructuredStrategy = struct {
    strategy: ToolCallingStrategy,

    /// 初始化结构化策略实例
    pub fn init() StructuredStrategy {
        return .{
            .strategy = .{
                .vtable = &.{
                    .prepareKwargs = StructuredStrategy.prepareKwargs,
                    .parseResponse = StructuredStrategy.parseResponse,
                    .buildAssistantMsg = StructuredStrategy.buildAssistantMsg,
                    .buildToolResultMsg = StructuredStrategy.buildToolResultMsg,
                },
            },
        };
    }

    /// 准备请求参数：将工具Schema序列化到请求体中
    fn prepareKwargs(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, body: *std.ArrayList(u8), tools: []llm.ToolSchema) anyerror!void {
        _ = strategy;
        if (tools.len > 0) {
            try body.appendSlice(allocator, ",\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try body.appendSlice(allocator, ",");
                try body.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
                try writeJsonString(body, allocator, tool.function.name);
                try body.appendSlice(allocator, ",\"description\":");
                try writeJsonString(body, allocator, tool.function.description);
                try body.appendSlice(allocator, ",\"parameters\":");
                const params_json = try std.json.Stringify.valueAlloc(allocator, tool.function.parameters, .{});
                try body.appendSlice(allocator, params_json);
                try body.appendSlice(allocator, "}}");
            }
            try body.appendSlice(allocator, "],\"tool_choice\":\"auto\"");
        }
    }

    /// 解析LLM回复：从API返回的tool_calls字段提取工具调用
    fn parseResponse(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, raw_calls: ?[]llm.ToolCallData) anyerror!ParseResult {
        _ = strategy;
        var calls: std.ArrayList(ParsedToolCall) = .empty;

        if (raw_calls) |tcs| {
            for (tcs) |tc| {
                // 尝试解析工具参数为JSON值
                const args_parsed = if (tc.function.arguments.len > 0)
                    std.json.parseFromSlice(std.json.Value, allocator, tc.function.arguments, .{}) catch null
                else
                    null;

                try calls.append(allocator, .{
                    .id = try allocator.dupe(u8, tc.id),
                    .name = try allocator.dupe(u8, tc.function.name),
                    .arguments = if (args_parsed) |p| p.value else .null,
                });
            }
        }

        return .{
            .content = try allocator.dupe(u8, if (content.len > 0) content else ""),
            .tool_calls = try calls.toOwnedSlice(allocator),
        };
    }

    /// 构建助手消息：包含文本内容和结构化的工具调用数据
    fn buildAssistantMsg(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, tool_calls: []ParsedToolCall) anyerror!llm.Message {
        _ = strategy;
        var msg = llm.Message{
            .role = .assistant,
            .content = try allocator.dupe(u8, content),
        };

        if (tool_calls.len > 0) {
            var tcs = try allocator.alloc(llm.ToolCallData, tool_calls.len);
            for (tool_calls, 0..) |tc, i| {
                const args_json = try std.json.Stringify.valueAlloc(allocator, tc.arguments, .{});
                tcs[i] = .{
                    .id = try allocator.dupe(u8, tc.id),
                    .function = .{
                        .name = try allocator.dupe(u8, tc.name),
                        .arguments = args_json,
                    },
                };
            }
            msg.tool_calls = tcs;
        }

        return msg;
    }

    /// 构建工具结果消息：以tool角色返回工具执行结果
    fn buildToolResultMsg(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, call: ParsedToolCall, result: []const u8) anyerror!llm.Message {
        _ = strategy;
        return llm.Message{
            .role = .tool,
            .content = try allocator.dupe(u8, result),
            .tool_call_id = try allocator.dupe(u8, call.id),
        };
    }
};

/// 文本解析工具调用策略
/// 适用于不支持结构化函数调用的模型
/// 从文本中解析.tool_call标记后的JSON工具调用
pub const TextStrategy = struct {
    strategy: ToolCallingStrategy,
    tools_text: ?[]const u8 = null,

    /// 初始化文本解析策略实例
    pub fn init() TextStrategy {
        return .{
            .strategy = .{
                .vtable = &.{
                    .prepareKwargs = TextStrategy.prepareKwargs,
                    .parseResponse = TextStrategy.parseResponse,
                    .buildAssistantMsg = TextStrategy.buildAssistantMsg,
                    .buildToolResultMsg = TextStrategy.buildToolResultMsg,
                },
            },
        };
    }

    /// 文本策略不需要额外的请求参数
    fn prepareKwargs(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, body: *std.ArrayList(u8), tools: []llm.ToolSchema) anyerror!void {
        _ = strategy;
        _ = allocator;
        _ = body;
        _ = tools;
    }

    /// 解析LLM回复：从文本中提取工具调用
    fn parseResponse(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, raw_calls: ?[]llm.ToolCallData) anyerror!ParseResult {
        _ = strategy;
        _ = raw_calls;
        var calls: std.ArrayList(ParsedToolCall) = .empty;

        // 尝试从文本中解析工具调用
        if (try parseToolCallsFromText(allocator, content)) |parsed| {
            calls = parsed.list;
            return .{
                .content = try allocator.dupe(u8, parsed.clean_content),
                .tool_calls = try calls.toOwnedSlice(allocator),
            };
        }

        return .{
            .content = try allocator.dupe(u8, content),
            .tool_calls = try calls.toOwnedSlice(allocator),
        };
    }

    /// 构建助手消息：仅包含文本内容（文本策略不使用结构化工具调用）
    fn buildAssistantMsg(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, content: []const u8, tool_calls: []ParsedToolCall) anyerror!llm.Message {
        _ = strategy;
        _ = tool_calls;
        return llm.Message{
            .role = .assistant,
            .content = try allocator.dupe(u8, content),
        };
    }

    /// 构建工具结果消息：以user角色返回工具结果（因为文本策略不使用tool角色）
    fn buildToolResultMsg(strategy: *ToolCallingStrategy, allocator: std.mem.Allocator, call: ParsedToolCall, result: []const u8) anyerror!llm.Message {
        _ = strategy;
        var buf: std.ArrayList(u8) = .empty;
        try buf.print(allocator, "[Tool Result: {s}]\n{s}", .{ call.name, result });
        return llm.Message{
            .role = .user,
            .content = buf.items,
        };
    }
};

/// 从文本解析出的工具调用结果
const ParsedTextCalls = struct {
    clean_content: []const u8,
    list: std.ArrayList(ParsedToolCall),
};

/// 从文本中解析工具调用
/// 查找.tool_call标记后的JSON对象，提取name和arguments字段
fn parseToolCallsFromText(allocator: std.mem.Allocator, content: []const u8) !?ParsedTextCalls {
    var calls: std.ArrayList(ParsedToolCall) = .empty;

    // 检查是否包含工具调用标记
    if (std.mem.indexOf(u8, content, ".tool_call")) |_| {
        var start: usize = 0;
        // 查找所有JSON格式的工具调用
        while (std.mem.indexOfPos(u8, content, start, "{\"name\"")) |pos| {
            // 通过括号深度匹配找到完整的JSON对象
            var depth: usize = 0;
            var end: usize = pos;
            for (content[pos..], 0..) |c, offset| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        end = pos + offset + 1;
                        break;
                    }
                }
            }
            if (end > pos) {
                const json_str = content[pos..end];
                // 尝试解析JSON
                const parsed = std.json.parseFromSlice(struct { name: []const u8, arguments: ?std.json.Value = null }, allocator, json_str, .{}) catch continue;
                defer parsed.deinit();
                try calls.append(allocator, .{
                    .id = try std.fmt.allocPrint(allocator, "call_{d}", .{calls.items.len}),
                    .name = try allocator.dupe(u8, parsed.value.name),
                    .arguments = parsed.value.arguments orelse .null,
                });
                start = end;
            } else {
                break;
            }
        }
    }

    if (calls.items.len == 0) return null;

    return .{
        .clean_content = try allocator.dupe(u8, content),
        .list = calls,
    };
}

/// 根据模型名称选择合适的工具调用策略
/// 支持结构化函数调用的模型使用StructuredStrategy，其他使用TextStrategy
pub fn strategyForModel(allocator: std.mem.Allocator, model_name: []const u8) !ToolCallingStrategy {
    // 支持结构化函数调用的模型关键词列表
    const structured_keywords = [_][]const u8{ "qwen", "mistral", "hermes", "functionary", "firefunction", "gorilla", "command-r" };

    const lower = try std.ascii.allocLowerString(allocator, model_name);
    defer allocator.free(lower);

    // 检查模型名称是否包含结构化调用关键词
    for (structured_keywords) |keyword| {
        if (std.mem.indexOf(u8, lower, keyword) != null) {
            const ss = try allocator.create(StructuredStrategy);
            ss.* = StructuredStrategy.init();
            return ss.strategy;
        }
    }

    // 默认使用文本解析策略
    const ts = try allocator.create(TextStrategy);
    ts.* = TextStrategy.init();
    return ts.strategy;
}

/// 将字符串转义并写入为JSON字符串格式
fn writeJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(allocator, "\"");
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    try list.appendSlice(allocator, "\"");
}
