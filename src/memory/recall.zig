const std = @import("std");
const session_db = @import("session_db.zig");
const llm = @import("../llm_client.zig");

/// 会话回忆系统
/// 通过全文搜索历史会话，并使用LLM生成相关摘要，
/// 让AI能够回忆起与当前话题相关的历史对话内容
pub const SessionRecall = struct {
    allocator: std.mem.Allocator,
    db: *session_db.SessionDB,
    client: *llm.LlmClient,
    model: []const u8,
    max_tokens: u32,

    /// 初始化会话回忆系统
    /// 参数：
    ///   allocator - 内存分配器
    ///   db - 会话数据库指针
    ///   client - LLM客户端指针
    ///   model - 模型名称
    ///   max_tokens - 摘要生成的最大token数
    pub fn init(allocator: std.mem.Allocator, db: *session_db.SessionDB, client: *llm.LlmClient, model: []const u8, max_tokens: u32) SessionRecall {
        return .{
            .allocator = allocator,
            .db = db,
            .client = client,
            .model = model,
            .max_tokens = max_tokens,
        };
    }

    /// 回忆与查询相关的历史会话
    /// 搜索数据库中的相关消息，获取完整对话记录，然后使用LLM生成摘要
    /// 参数：
    ///   query - 搜索查询字符串
    ///   max_sessions - 最大返回会话数
    /// 返回：格式化的历史会话摘要文本
    pub fn recall(self: *SessionRecall, query: []const u8, max_sessions: u32) ![]const u8 {
        // 全文搜索相关消息
        const results = try self.db.search(query, 30);
        if (results.len == 0) return "";

        // 去重会话ID
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var unique_sessions: std.ArrayList(*const session_db.SessionDB.SearchResult) = .empty;
        for (results) |*r| {
            if (!seen.contains(r.session_id)) {
                try seen.put(r.session_id, {});
                try unique_sessions.append(self.allocator, r);
                if (unique_sessions.items.len >= max_sessions) break;
            }
        }

        // 为每个会话生成摘要
        var summaries: std.ArrayList(u8) = .empty;
        for (unique_sessions.items, 0..) |meta, i| {
            if (i > 0) try summaries.appendSlice(self.allocator, "\n\n---\n\n");

            // 获取会话的消息记录
            const messages = self.db.getSessionMessages(self.allocator, meta.session_id, 30) catch continue;
            defer {
                for (messages) |m| {
                    self.allocator.free(m.role);
                    self.allocator.free(m.content);
                }
                self.allocator.free(messages);
            }

            // 构建对话记录文本
            var transcript: std.ArrayList(u8) = .empty;
            for (messages) |m| {
                const truncated = if (m.content.len > 300) m.content[0..300] else m.content;
                try transcript.print(self.allocator, "{s}: {s}\n", .{ m.role, truncated });
            }
            if (transcript.items.len > 5000) {
                transcript.shrinkRetainingCapacity(5000);
            }

            // 使用LLM生成摘要
            const summary = self.summarize(query, transcript.items, meta.date) catch "(recall error)";
            defer self.allocator.free(summary);

            try summaries.print(self.allocator, "[{s}] {s}", .{ meta.date, summary });
        }

        return try summaries.toOwnedSlice(self.allocator);
    }

    /// 使用LLM对历史对话生成与特定话题相关的摘要
    /// 参数：
    ///   topic - 当前话题
    ///   transcript - 对话记录文本
    ///   date - 对话日期
    /// 返回：摘要文本
    fn summarize(self: *SessionRecall, topic: []const u8, transcript: []const u8, date: []const u8) ![]const u8 {
        const system_msg = llm.Message{ .role = .system, .content = "Summarize this past conversation, focusing on information relevant to the given topic. Be concise. Under 150 words." };
        var user_content: std.ArrayList(u8) = .empty;
        try user_content.print(self.allocator, "Topic: {s}\nDate: {s}\n\nTRANSCRIPT:\n{s}", .{ topic, date, transcript });
        const user_msg = llm.Message{ .role = .user, .content = user_content.items };

        const messages = [_]llm.Message{ system_msg, user_msg };

        const response = self.client.chatCompletion(self.model, &messages, self.max_tokens, null) catch {
            return try std.fmt.allocPrint(self.allocator, "(recall error)", .{});
        };

        if (response.choices.len > 0) {
            if (response.choices[0].message.content) |c| {
                return try self.allocator.dupe(u8, c);
            }
        }

        return try self.allocator.dupe(u8, "");
    }
};
