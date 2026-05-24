const std = @import("std");

/// 提示词构建器
/// 将身份描述、记忆、技能和工具使用指导组合成完整的系统提示词
pub const PromptBuilder = struct {
    /// 构建系统提示词
    /// 参数：
    ///   allocator - 内存分配器
    ///   memory_block - 持久化记忆内容
    ///   skills_index - 技能索引文本
    ///   user_context - 用户项目上下文
    /// 返回：完整的系统提示词字符串
    pub fn build(allocator: std.mem.Allocator, memory_block: []const u8, skills_index: []const u8, user_context: []const u8) ![]const u8 {
        var sections: std.ArrayList(u8) = .empty;

        // 添加AI身份描述
        try sections.appendSlice(allocator, IDENTITY);

        // 添加记忆内容（如果有）
        if (memory_block.len > 0) {
            try sections.appendSlice(allocator, "\n\n## What I Remember\n");
            try sections.appendSlice(allocator, memory_block);
        }

        // 添加技能索引（如果有）
        if (skills_index.len > 0) {
            try sections.appendSlice(allocator, "\n\n## Available Skills\n");
            try sections.appendSlice(allocator, skills_index);
        }

        // 添加项目上下文（如果有）
        if (user_context.len > 0) {
            try sections.appendSlice(allocator, "\n\n## Project Context\n");
            try sections.appendSlice(allocator, user_context);
        }

        // 添加记忆、技能和工具使用的指导说明
        try sections.appendSlice(allocator, "\n\n");
        try sections.appendSlice(allocator, MEMORY_GUIDANCE);
        try sections.appendSlice(allocator, "\n\n");
        try sections.appendSlice(allocator, SKILLS_GUIDANCE);
        try sections.appendSlice(allocator, "\n\n");
        try sections.appendSlice(allocator, TOOL_USE_GUIDANCE);

        return try sections.toOwnedSlice(allocator);
    }

    // AI身份描述
    const IDENTITY = "You are a helpful AI assistant with persistent memory and self-improving skills. You remember past conversations and learn from experience. Use your tools to accomplish tasks. Be concise and direct.";

    // 记忆使用指导：告诉AI何时保存和搜索记忆
    const MEMORY_GUIDANCE =
        \\## Memory Instructions
        \\After completing tasks, actively decide what's worth remembering:
        \\- User preferences and habits
        \\- Project context and architecture decisions
        \\- Solutions to problems that might recur
        \\Use the memory tool (action="save") to persist important observations.
        \\Use memory (action="search") to recall past conversations when relevant.
    ;

    // 技能使用指导：告诉AI如何创建和管理技能
    const SKILLS_GUIDANCE =
        \\## Skill Instructions
        \\After difficult or iterative tasks, offer to save the approach as a skill. Confirm with the user before creating or deleting. Use skill_manage with action="create" for new skills, action="patch" (old_string/new_string) to fix existing ones. Skip for simple one-offs. Use skills_list to see what skills exist, and skill_view to load their full content when relevant.
        \\
        \\## Built-in Skills (available in src/skills/)
        \\These skills are pre-installed in the source code but not yet loaded. Use skill_manage with action="install" and source_dir to install them:
        \\- himalaya: Email management via CLI (source_dir="email/hamalaya")
        \\To install: skill_manage(action="install", name="himalaya", source_dir="email/hamalaya")
    ;

    // 工具使用指导：鼓励AI主动行动而非仅描述
    const TOOL_USE_GUIDANCE =
        \\## Tool Use
        \\Take action. Don't just describe what you would do -- actually do it. If the user asks you to write code, write the file. If they ask you to run something, run it. Prefer action over explanation.
    ;
};
