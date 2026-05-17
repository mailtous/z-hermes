const std = @import("std");
const yaml = @import("yaml.zig");

/// 模型配置：定义LLM API的连接参数
pub const ModelConfig = struct {
    api_key: []const u8 = "sk-no-key-required",
    base_url: []const u8 = "http://localhost:1234/v1",
    model: []const u8 = "qwen2.5-7b-instruct",
    max_tokens: u32 = 400,
};

/// 代理配置：定义代理的最大迭代次数
pub const AgentConfig = struct {
    max_iterations: u32 = 15,
};

/// 学习配置：定义记忆提醒和技能提醒的间隔轮次
pub const LearningConfig = struct {
    memory_nudge_interval: u32 = 5,
    skill_nudge_interval: u32 = 8,
};

/// 辅助模型配置：定义辅助模型的最大token数
pub const AuxModelConfig = struct {
    max_tokens: u32 = 300,
};

/// 项目总配置结构体，包含模型、代理、学习和辅助模型四个子配置
pub const Config = struct {
    model: ModelConfig = .{},
    agent: AgentConfig = .{},
    learning: LearningConfig = .{},
    aux_model: AuxModelConfig = .{},

    /// 从YAML文件加载配置
    /// 参数：
    ///   allocator - 内存分配器
    ///   io - I/O实例，用于文件读取
    ///   path - 配置文件路径
    /// 返回：解析后的Config结构体
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const dir = std.Io.Dir.cwd();
        const contents = try dir.readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(contents);

        var root = try yaml.YamlParser.parse(allocator, contents);
        defer root.deinit(allocator);

        var result = Config{};

        // 解析model配置段
        if (root.getMap("model")) |model_map| {
            result.model = .{
                .api_key = try allocator.dupe(u8, yamlGetString(model_map, "api_key", result.model.api_key)),
                .base_url = try allocator.dupe(u8, yamlGetString(model_map, "base_url", result.model.base_url)),
                .model = try allocator.dupe(u8, yamlGetString(model_map, "model", result.model.model)),
                .max_tokens = @intCast(yamlGetInt(model_map, "max_tokens", result.model.max_tokens)),
            };
        }

        // 解析agent配置段
        if (root.getMap("agent")) |agent_map| {
            result.agent = .{
                .max_iterations = @intCast(yamlGetInt(agent_map, "max_iterations", result.agent.max_iterations)),
            };
        }

        // 解析learning配置段
        if (root.getMap("learning")) |learning_map| {
            result.learning = .{
                .memory_nudge_interval = @intCast(yamlGetInt(learning_map, "memory_nudge_interval", result.learning.memory_nudge_interval)),
                .skill_nudge_interval = @intCast(yamlGetInt(learning_map, "skill_nudge_interval", result.learning.skill_nudge_interval)),
            };
        }

        // 解析aux_model配置段
        if (root.getMap("aux_model")) |aux_map| {
            result.aux_model = .{
                .max_tokens = @intCast(yamlGetInt(aux_map, "max_tokens", result.aux_model.max_tokens)),
            };
        }

        return result;
    }
};

/// 从YamlValue的map中获取字符串值
fn yamlGetString(map: std.StringHashMap(yaml.YamlValue), key: []const u8, default: []const u8) []const u8 {
    if (map.get(key)) |val| {
        switch (val) {
            .string => |s| return s,
            else => {},
        }
    }
    return default;
}

/// 从YamlValue的map中获取整数值
fn yamlGetInt(map: std.StringHashMap(yaml.YamlValue), key: []const u8, default: u32) i64 {
    if (map.get(key)) |val| {
        switch (val) {
            .integer => |i| return i,
            else => {},
        }
    }
    return @intCast(default);
}
