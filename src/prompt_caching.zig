const std = @import("std");
const llm = @import("llm_client.zig");

/// 应用提示词缓存（预留接口）
/// 目前直接复制消息数组，未来可扩展为缓存系统提示词以减少重复计算
pub fn applyPromptCaching(allocator: std.mem.Allocator, messages: []llm.Message) ![]llm.Message {
    var result = try allocator.alloc(llm.Message, messages.len);
    for (messages, 0..) |msg, i| {
        result[i] = msg;
    }
    return result;
}
