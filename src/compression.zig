const std = @import("std");
const llm = @import("llm_client.zig");

/// 上下文压缩器
/// 当对话历史过长时，自动压缩中间部分的消息为摘要，
/// 保留头部消息和尾部近期消息，以控制token使用量
pub const ContextCompressor = struct {
    allocator: std.mem.Allocator,
    client: *llm.LlmClient,
    model: []const u8,
    max_context_tokens: usize,
    max_tokens: u32,

    /// 压缩阈值：当估算token数超过最大上下文token数的50%时触发压缩
    pub const THRESHOLD: f64 = 0.5;
    /// 尾部保留的token数
    pub const TAIL_TOKENS: usize = 20000;
    /// 头部保留的消息条数（系统提示等关键消息）
    pub const HEAD_MESSAGES: usize = 3;
    /// 估算比率：每token约3.5个字符
    pub const CHARS_PER_TOKEN: f64 = 3.5;

    /// 初始化上下文压缩器
    /// 参数：
    ///   allocator - 内存分配器
    ///   client - LLM客户端，用于生成摘要
    ///   model - 模型名称
    ///   max_context_tokens - 最大上下文token数
    ///   max_tokens - 摘要生成的最大token数
    pub fn init(allocator: std.mem.Allocator, client: *llm.LlmClient, model: []const u8, max_context_tokens: usize, max_tokens: u32) ContextCompressor {
        return .{
            .allocator = allocator,
            .client = client,
            .model = model,
            .max_context_tokens = max_context_tokens,
            .max_tokens = max_tokens,
        };
    }

    /// 尝试压缩消息列表
    /// 如果消息总token数未超过阈值，直接返回原消息
    /// 否则保留头部消息+摘要+尾部消息
    pub fn maybeCompress(self: *ContextCompressor, messages: []llm.Message) ![]llm.Message {
        const estimated = self.estimateTokens(messages);
        if (@as(f64, @floatFromInt(estimated)) < @as(f64, @floatFromInt(self.max_context_tokens)) * THRESHOLD) {
            return messages;
        }

        // 消息太少则不压缩
        if (messages.len <= HEAD_MESSAGES) return messages;

        // 从尾部向前收集消息，直到达到TAIL_TOKENS限制
        var tail: std.ArrayList(llm.Message) = .empty;
        var total: usize = 0;

        var i: usize = messages.len;
        while (i > HEAD_MESSAGES) : (i -= 1) {
            const chars = if (messages[i - 1].content) |c| c.len else 0;
            const tokens = @as(usize, @intFromFloat(@as(f64, @floatFromInt(chars)) / CHARS_PER_TOKEN));
            if (total + tokens > TAIL_TOKENS) break;
            try tail.insert(self.allocator, 0, messages[i - 1]);
            total += tokens;
        }

        // 提取中间部分用于生成摘要
        const middle_end = messages.len - tail.items.len;
        const middle = messages[HEAD_MESSAGES..middle_end];
        if (middle.len == 0) return messages;

        // 使用LLM生成中间部分的摘要
        const summary = try self.summarizeMiddle(middle);

        // 组合结果：头部消息 + 摘要 + 尾部消息
        var result: std.ArrayList(llm.Message) = .empty;
        for (messages[0..HEAD_MESSAGES]) |msg| {
            try result.append(self.allocator, msg);
        }

        try result.append(self.allocator, .{
            .role = .system,
            .content = try std.fmt.allocPrint(self.allocator, "[Compressed context summary]\n{s}", .{summary}),
        });

        for (tail.items) |msg| {
            try result.append(self.allocator, msg);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// 估算消息列表的总token数
    /// 基于字符数和CHARS_PER_TOKEN比率进行粗略估算
    pub fn estimateTokens(self: *ContextCompressor, messages: []llm.Message) usize {
        _ = self;
        var total_chars: usize = 0;
        for (messages) |msg| {
            if (msg.content) |c| {
                total_chars += c.len;
            }
        }
        return @intFromFloat(@as(f64, @floatFromInt(total_chars)) / CHARS_PER_TOKEN);
    }

    /// 使用LLM生成中间消息的摘要
    /// 将消息截断为200字符后拼接，请求LLM生成500词以内的摘要
    fn summarizeMiddle(self: *ContextCompressor, messages: []llm.Message) ![]const u8 {
        // 构建对话记录
        var transcript: std.ArrayList(u8) = .empty;
        for (messages) |msg| {
            const content = msg.content orelse "[tool call]";
            const truncated = if (content.len > 200) content[0..200] else content;
            try transcript.print(self.allocator, "{s}: {s}\n", .{ msg.role.toString(), truncated });
        }

        // 构建摘要请求消息
        const system_msg = llm.Message{
            .role = .system,
            .content = "Summarize this conversation segment. Include:\n- Questions that were resolved\n- Decisions that were made\n- Pending work items\n- Key facts discovered\nBe concise. Under 500 words.",
        };
        const user_msg = llm.Message{
            .role = .user,
            .content = transcript.items,
        };

        const msgs = [_]llm.Message{ system_msg, user_msg };
        const response = self.client.chatCompletion(self.model, &msgs, self.max_tokens, null) catch {
            return "(compression failed)";
        };

        if (response.choices.len > 0) {
            if (response.choices[0].message.content) |c| {
                return try self.allocator.dupe(u8, c);
            }
        }

        return "(compression failed)";
    }
};
