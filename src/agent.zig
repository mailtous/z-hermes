const std = @import("std");
const llm = @import("llm_client.zig");
const tool_calling = @import("tool_calling.zig");
const tool_registry = @import("tool_registry.zig");
const compression = @import("compression.zig");
const session_db = @import("memory/session_db.zig");

/// AI代理核心结构体
/// 负责管理对话消息、调用LLM、执行工具、持久化消息等核心逻辑
pub const Agent = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *llm.LlmClient,
    model: []const u8,
    system_prompt: []const u8,
    tools: []llm.ToolSchema,
    max_iterations: u32,
    max_tokens: u32,
    messages: std.ArrayList(llm.Message),
    strategy: tool_calling.ToolCallingStrategy,
    session_db: ?*session_db.SessionDB,
    session_id: ?[]const u8,
    memory_nudge_interval: u32,
    skill_nudge_interval: u32,
    turns_since_memory: u32,
    iters_since_skill: u32,
    user_turn_count: u32,
    compressor: ?*compression.ContextCompressor,
    tool_handlers: std.StringHashMap(tool_registry.ToolHandler),

    /// 初始化代理实例
    /// 参数：
    ///   allocator - 内存分配器
    ///   io - I/O实例
    ///   client - LLM客户端指针
    ///   model - 模型名称
    ///   system_prompt - 系统提示词
    ///   tools - 工具Schema数组
    ///   max_iterations - 最大迭代次数（防止无限循环）
    ///   max_tokens - 最大生成token数
    ///   strategy - 工具调用策略（结构化或文本解析）
    /// 返回：初始化后的Agent实例
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *llm.LlmClient,
        model: []const u8,
        system_prompt: []const u8,
        tools: []llm.ToolSchema,
        max_iterations: u32,
        max_tokens: u32,
        strategy: tool_calling.ToolCallingStrategy,
    ) Agent {
        // 初始化消息列表，添加系统提示词作为第一条消息
        var messages: std.ArrayList(llm.Message) = .empty;
        messages.append(allocator, .{
            .role = .system,
            .content = allocator.dupe(u8, system_prompt) catch "",
        }) catch {};

        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .model = model,
            .system_prompt = system_prompt,
            .tools = tools,
            .max_iterations = max_iterations,
            .max_tokens = max_tokens,
            .messages = messages,
            .strategy = strategy,
            .session_db = null,
            .session_id = null,
            .memory_nudge_interval = 5,
            .skill_nudge_interval = 8,
            .turns_since_memory = 0,
            .iters_since_skill = 0,
            .user_turn_count = 0,
            .compressor = null,
            .tool_handlers = std.StringHashMap(tool_registry.ToolHandler).init(allocator),
        };
    }

    /// 释放代理占用的所有资源，包括消息内容和工具处理器映射
    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |msg| {
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.type);
                    self.allocator.free(tc.function.name);
                    self.allocator.free(tc.function.arguments);
                }
                self.allocator.free(tcs);
            }
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_name) |n| self.allocator.free(n);
        }
        self.messages.deinit(self.allocator);
        self.tool_handlers.deinit();
    }

    /// 注册工具处理器
    /// 参数：
    ///   name - 工具名称
    ///   handler - 工具处理函数
    pub fn setHandler(self: *Agent, name: []const u8, handler: tool_registry.ToolHandler) void {
        self.tool_handlers.put(name, handler) catch {};
    }

    /// 配置学习间隔参数
    /// 参数：
    ///   memory_nudge - 每隔多少轮对话提醒AI回顾记忆
    ///   skill_nudge - 每隔多少轮对话提醒AI使用技能
    pub fn configureLearning(self: *Agent, memory_nudge: u32, skill_nudge: u32) void {
        self.memory_nudge_interval = memory_nudge;
        self.skill_nudge_interval = skill_nudge;
    }

    /// 设置上下文压缩器，当对话过长时自动压缩历史消息
    pub fn setCompressor(self: *Agent, comp: *compression.ContextCompressor) void {
        self.compressor = comp;
    }

    /// 代理主运行循环
    /// 处理用户输入，调用LLM获取回复，执行工具调用，返回最终文本回复
    /// 参数：
    ///   user_input - 用户输入的文本
    /// 返回：AI的最终文本回复
    pub fn run(self: *Agent, user_input: []const u8) ![]const u8 {
        self.user_turn_count += 1;
        self.turns_since_memory += 1;

        // 检查是否需要提醒AI回顾记忆
        const should_review_memory = self.memory_nudge_interval > 0 and
            self.turns_since_memory >= self.memory_nudge_interval;
        if (should_review_memory) {
            self.turns_since_memory = 0;
        }

        // 将用户消息添加到对话历史
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, user_input),
        });
        self.persistMessage("user", user_input, null, null);

        var content: []const u8 = "";
        // 迭代循环：调用LLM，处理工具调用，直到获得最终文本回复或达到最大迭代次数
        for (0..self.max_iterations) |_| {
            const response = self.callLlm() catch |err| {
                var buf: std.ArrayList(u8) = .empty;
                buf.print(self.allocator, "[LLM Error: {} - 请检查config.yaml中的base_url是否正确，以及LLM服务是否已启动]", .{err}) catch {};
                return try buf.toOwnedSlice(self.allocator);
            };

            if (response.choices.len == 0) {
                return "[Error: empty response]";
            }

            const choice = response.choices[0];
            const msg_content = choice.message.content orelse "";
            const raw_calls = choice.message.tool_calls;

            // 使用策略解析LLM的回复，提取文本内容和工具调用
            const parsed = try self.strategy.parseResponse(
                self.allocator,
                msg_content,
                raw_calls,
            );

            // 构建助手消息并添加到对话历史
            const assistant_msg = try self.strategy.buildAssistantMsg(
                self.allocator,
                parsed.content,
                parsed.tool_calls,
            );
            try self.messages.append(self.allocator, assistant_msg);

            // 如果没有工具调用，返回文本内容作为最终回复
            if (parsed.tool_calls.len == 0) {
                content = parsed.content;
                self.persistMessage("assistant", content, null, null);
                break;
            }

            self.iters_since_skill += 1;

            // 依次执行每个工具调用
            for (parsed.tool_calls) |tc| {
                // 更新记忆和技能的计时器
                if (std.mem.eql(u8, tc.name, "memory")) {
                    self.turns_since_memory = 0;
                } else if (std.mem.eql(u8, tc.name, "skill_manage")) {
                    self.iters_since_skill = 0;
                }

                // 执行工具并获取结果
                const result = self.executeTool(tc.name, tc.arguments);
                defer self.allocator.free(result);

                // 将工具结果添加到对话历史
                const result_msg = try self.strategy.buildToolResultMsg(
                    self.allocator,
                    tc,
                    result,
                );
                try self.messages.append(self.allocator, result_msg);
                self.persistMessage("tool", result, tc.name, tc.id);
            }

            content = parsed.content;
        } else {
            // 达到最大迭代次数仍未获得最终回复
            content = "[Max iterations reached]";
        }

        // 检查是否需要提醒AI使用技能
        const should_review_skills = self.skill_nudge_interval > 0 and
            self.iters_since_skill >= self.skill_nudge_interval;
        if (should_review_skills) {
            self.iters_since_skill = 0;
        }

        return try self.allocator.dupe(u8, content);
    }

    /// 调用LLM API获取回复
    /// 如果配置了压缩器且对话过长，会先压缩历史消息
    fn callLlm(self: *Agent) !llm.ChatCompletionResponse {
        // 检查是否需要压缩上下文
        if (self.compressor) |comp| {
            const est = comp.estimateTokens(self.messages.items);
            if (est >= @as(usize, @intFromFloat(@as(f64, @floatFromInt(comp.max_context_tokens)) * compression.ContextCompressor.THRESHOLD))) {
                const compressed = try comp.maybeCompress(self.messages.items);
                if (compressed.len < self.messages.items.len) {
                    self.messages.clearRetainingCapacity();
                    for (compressed) |msg| {
                        try self.messages.append(self.allocator, msg);
                    }
                }
            }
        }

        return try self.client.chatCompletion(
            self.model,
            self.messages.items,
            self.max_tokens,
            self.tools,
        );
    }

    /// 执行指定名称的工具
    /// 参数：
    ///   name - 工具名称
    ///   args - 工具参数（JSON值）
    /// 返回：工具执行结果字符串（超过50000字符会被截断）
    fn executeTool(self: *Agent, name: []const u8, args: std.json.Value) []const u8 {
        // 查找工具处理器
        const handler = self.tool_handlers.get(name) orelse {
            var buf: std.ArrayList(u8) = .empty;
            buf.print(self.allocator, "Error: unknown tool '{s}'", .{name}) catch {};
            return buf.items;
        };

        // 执行工具处理器
        const result = handler(self.allocator, self.io, args) catch |err| {
            var buf: std.ArrayList(u8) = .empty;
            buf.print(self.allocator, "Error executing {s}: {}", .{ name, err }) catch {};
            return buf.items;
        };

        // 截断过长的结果
        if (result.len > 50000) {
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(self.allocator, result[0..50000]) catch {};
            buf.appendSlice(self.allocator, "\n... [truncated]") catch {};
            return buf.items;
        }

        return result;
    }

    /// 将消息持久化到会话数据库
    /// 参数：
    ///   role - 消息角色（user/assistant/tool）
    ///   content - 消息内容
    ///   tool_name - 工具名称（仅tool角色有值）
    ///   tool_call_id - 工具调用ID（仅tool角色有值）
    fn persistMessage(self: *Agent, role: []const u8, content: []const u8, tool_name: ?[]const u8, tool_call_id: ?[]const u8) void {
        if (self.session_db) |db| {
            if (self.session_id) |sid| {
                db.appendMessage(sid, role, content, tool_name, tool_call_id) catch {};
            }
        }
    }
};
