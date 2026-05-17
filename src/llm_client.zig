const std = @import("std");

/// 消息角色枚举：system(系统)、user(用户)、assistant(助手)、tool(工具)
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    /// 将角色枚举转换为字符串表示
    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    /// 从字符串解析角色枚举，无法识别则返回null
    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }
};

/// 工具调用函数信息：包含函数名和参数
pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

/// 工具调用数据：包含调用ID、类型和函数信息
pub const ToolCallData = struct {
    id: []const u8 = "",
    type: []const u8 = "function",
    function: ToolCallFunction,
};

/// 对话消息结构体
/// 包含角色、内容、工具调用信息和工具结果标识
pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCallData = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
};

/// 工具参数属性定义
pub const ToolParameterProperty = struct {
    type: []const u8 = "string",
    description: []const u8 = "",
};

/// 工具函数Schema：描述工具的名称、描述和参数格式
pub const ToolFunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value = .null,
};

/// 工具Schema：包含类型和函数描述
pub const ToolSchema = struct {
    type: []const u8 = "function",
    function: ToolFunctionSchema,
};

/// 聊天完成选项：包含LLM返回的消息
pub const ChatCompletionChoice = struct {
    message: struct {
        role: ?[]const u8 = null,
        content: ?[]const u8 = null,
        tool_calls: ?[]ToolCallData = null,
    },
};

/// 聊天完成响应：包含LLM返回的所有选项
pub const ChatCompletionResponse = struct {
    choices: []ChatCompletionChoice = &.{},
};

/// 模型信息：包含模型ID
pub const ModelInfo = struct {
    id: []const u8,
};

/// 模型列表响应：包含可用模型数组
pub const ModelsResponse = struct {
    data: []ModelInfo = &.{},
};

/// LLM客户端结构体
/// 负责与LLM API通信，发送请求并解析响应
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    base_url: []const u8,

    /// 初始化LLM客户端
    /// 参数：
    ///   allocator - 内存分配器
    ///   io - I/O实例
    ///   api_key - API密钥
    ///   base_url - API基础URL
    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, base_url: []const u8) LlmClient {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .base_url = base_url,
        };
    }

    /// 发送聊天完成请求
    /// 构建JSON请求体，发送HTTP POST请求到LLM API，解析响应
    /// 参数：
    ///   model - 模型名称
    ///   messages - 消息数组
    ///   max_tokens - 最大生成token数
    ///   tools - 可选的工具Schema数组
    /// 返回：聊天完成响应
    pub fn chatCompletion(
        self: *LlmClient,
        model: []const u8,
        messages: []const Message,
        max_tokens: u32,
        tools: ?[]ToolSchema,
    ) !ChatCompletionResponse {
        // 使用Arena分配器管理请求构建期间的临时内存
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // 手动构建JSON请求体
        var request_body: std.ArrayList(u8) = .empty;

        try request_body.appendSlice(aa, "{\"model\":\"");
        try request_body.appendSlice(aa, model);
        try request_body.appendSlice(aa, "\",");

        try request_body.appendSlice(aa, "\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try request_body.appendSlice(aa, ",");
            try self.serializeMessage(&request_body, aa, msg);
        }
        try request_body.appendSlice(aa, "],");

        try request_body.print(aa, "\"max_tokens\":{d}", .{max_tokens});

        // 如果有工具，序列化工具Schema
        if (tools) |t| {
            try request_body.appendSlice(aa, ",\"tools\":[");
            for (t, 0..) |tool, i| {
                if (i > 0) try request_body.appendSlice(aa, ",");
                try self.serializeToolSchema(&request_body, aa, tool);
            }
            try request_body.appendSlice(aa, "],\"tool_choice\":\"auto\"");
        }

        try request_body.appendSlice(aa, "}");

        // 构建请求URL
        var url_buf: std.ArrayList(u8) = .empty;
        try url_buf.print(aa, "{s}/chat/completions", .{self.base_url});
        const url = url_buf.items;

        // 构建认证头
        var auth_buf: std.ArrayList(u8) = .empty;
        try auth_buf.print(aa, "Bearer {s}", .{self.api_key});

        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_buf.items },
        };

        // 创建HTTP客户端并发送请求
        var client = std.http.Client{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(self.allocator);

        const uri = try std.Uri.parse(url);

        var req = try client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        // 发送请求体
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // 接收响应
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // 读取响应体
        var body_reader = response.reader(&.{});
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &response_body);
        _ = try body_reader.streamRemaining(&aw.writer);
        response_body = aw.toArrayList();

        // 解析JSON响应
        const parsed = try std.json.parseFromSlice(ChatCompletionResponse, self.allocator, response_body.items, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // 深拷贝响应数据，确保arena释放后数据仍然有效
        return try deepCopyResponse(self.allocator, parsed.value);
    }

    /// 获取可用模型列表
    /// 发送GET请求到/models端点
    pub fn listModels(self: *LlmClient) !ModelsResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var url_buf: std.ArrayList(u8) = .empty;
        try url_buf.print(aa, "{s}/models", .{self.base_url});

        var auth_buf: std.ArrayList(u8) = .empty;
        try auth_buf.print(aa, "Bearer {s}", .{self.api_key});

        const extra_headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_buf.items },
        };

        var client = std.http.Client{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(self.allocator);

        const uri = try std.Uri.parse(url_buf.items);

        var req = try client.request(.GET, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var body_reader = response.reader(&.{});
        var aw2: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &response_body);
        try body_reader.streamRemaining(&aw2.writer);
        response_body = aw2.toArrayList();

        const parsed = try std.json.parseFromSlice(ModelsResponse, self.allocator, response_body.items, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return try deepCopyModelsResponse(self.allocator, parsed.value);
    }

    /// 将消息序列化为JSON格式
    fn serializeMessage(self: *LlmClient, list: *std.ArrayList(u8), allocator: std.mem.Allocator, msg: Message) !void {
        _ = self;
        try list.appendSlice(allocator, "{\"role\":\"");
        try list.appendSlice(allocator, msg.role.toString());
        try list.appendSlice(allocator, "\"");

        if (msg.content) |c| {
            try list.appendSlice(allocator, ",\"content\":");
            try writeJsonString(list, allocator, c);
        }

        if (msg.tool_calls) |tcs| {
            try list.appendSlice(allocator, ",\"tool_calls\":[");
            for (tcs, 0..) |tc, i| {
                if (i > 0) try list.appendSlice(allocator, ",");
                try list.appendSlice(allocator, "{\"id\":");
                try writeJsonString(list, allocator, tc.id);
                try list.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try writeJsonString(list, allocator, tc.function.name);
                try list.appendSlice(allocator, ",\"arguments\":");
                try writeJsonString(list, allocator, tc.function.arguments);
                try list.appendSlice(allocator, "}}");
            }
            try list.appendSlice(allocator, "]");
        }

        if (msg.tool_call_id) |id| {
            try list.appendSlice(allocator, ",\"tool_call_id\":");
            try writeJsonString(list, allocator, id);
        }

        try list.appendSlice(allocator, "}");
    }

    /// 将工具Schema序列化为JSON格式
    fn serializeToolSchema(self: *LlmClient, list: *std.ArrayList(u8), allocator: std.mem.Allocator, tool: ToolSchema) !void {
        _ = self;
        try list.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try writeJsonString(list, allocator, tool.function.name);
        try list.appendSlice(allocator, ",\"description\":");
        try writeJsonString(list, allocator, tool.function.description);
        try list.appendSlice(allocator, ",\"parameters\":");
        const params_json = try std.json.Stringify.valueAlloc(allocator, tool.function.parameters, .{});
        try list.appendSlice(allocator, params_json);
        try list.appendSlice(allocator, "}}");
    }

    /// 深拷贝聊天完成响应，确保所有字符串数据独立于原始解析缓冲区
    fn deepCopyResponse(allocator: std.mem.Allocator, resp: ChatCompletionResponse) !ChatCompletionResponse {
        var choices = try allocator.alloc(ChatCompletionChoice, resp.choices.len);
        for (resp.choices, 0..) |choice, i| {
            var msg = choice.message;
            if (msg.role) |r| {
                msg.role = try allocator.dupe(u8, r);
            }
            if (msg.content) |c| {
                msg.content = try allocator.dupe(u8, c);
            }
            if (msg.tool_calls) |tcs| {
                var new_tcs = try allocator.alloc(ToolCallData, tcs.len);
                for (tcs, 0..) |tc, j| {
                    new_tcs[j] = .{
                        .id = try allocator.dupe(u8, tc.id),
                        .type = try allocator.dupe(u8, tc.type),
                        .function = .{
                            .name = try allocator.dupe(u8, tc.function.name),
                            .arguments = try allocator.dupe(u8, tc.function.arguments),
                        },
                    };
                }
                msg.tool_calls = new_tcs;
            }
            choices[i] = .{ .message = msg };
        }
        return .{ .choices = choices };
    }

    /// 深拷贝模型列表响应
    fn deepCopyModelsResponse(allocator: std.mem.Allocator, resp: ModelsResponse) !ModelsResponse {
        var data = try allocator.alloc(ModelInfo, resp.data.len);
        for (resp.data, 0..) |m, i| {
            data[i] = .{ .id = try allocator.dupe(u8, m.id) };
        }
        return .{ .data = data };
    }
};

/// 将字符串转义并写入为JSON字符串格式
/// 处理双引号、反斜杠、换行符等特殊字符的转义
fn writeJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(allocator, "\"");
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // 控制字符使用Unicode转义
                    var buf: [8]u8 = undefined;
                    const escaped = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                    try list.appendSlice(allocator, escaped);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.appendSlice(allocator, "\"");
}
