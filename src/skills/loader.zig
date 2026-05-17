const std = @import("std");

/// 技能结构体
/// 描述一个可复用的技能，包含名称、描述、内容、路径和版本信息
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
    path: []const u8,
    version: []const u8,
};

/// 技能加载器
/// 从磁盘目录中加载技能文件（SKILL.md），解析YAML前置元数据
pub const SkillLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    skills_dir: []const u8,

    /// 初始化技能加载器
    /// 创建技能目录（如果不存在）
    /// 参数：
    ///   allocator - 内存分配器
    ///   io - I/O实例
    ///   skills_dir - 技能文件目录路径
    pub fn init(allocator: std.mem.Allocator, io: std.Io, skills_dir: []const u8) !SkillLoader {
        std.Io.Dir.cwd().createDirPath(io, skills_dir) catch {};

        return .{
            .allocator = allocator,
            .io = io,
            .skills_dir = try allocator.dupe(u8, skills_dir),
        };
    }

    /// 释放技能加载器占用的资源
    pub fn deinit(self: *SkillLoader) void {
        self.allocator.free(self.skills_dir);
    }

    /// 加载所有技能
    /// 递归遍历技能目录，查找所有SKILL.md文件并解析
    /// 返回：技能数组
    pub fn loadAll(self: *SkillLoader) ![]Skill {
        var skills: std.ArrayList(Skill) = .empty;

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, self.skills_dir, .{ .iterate = true }) catch return try skills.toOwnedSlice(self.allocator);
        defer dir.close(self.io);

        var walker = dir.walk(self.allocator) catch return try skills.toOwnedSlice(self.allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            // 查找SKILL.md文件
            if (entry.kind == .file and std.mem.eql(u8, entry.basename, "SKILL.md")) {
                const file_path = try std.fs.path.join(self.allocator, &.{ self.skills_dir, entry.path });
                const content = cwd.readFileAlloc(self.io, file_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch {
                    self.allocator.free(file_path);
                    continue;
                };
                defer self.allocator.free(content);

                // 解析前置元数据
                if (parseFrontmatter(content)) |result| {
                    if (result.name.len > 0) {
                        const skill_dir = std.fs.path.dirname(entry.path) orelse "";
                        const full_path = try std.fs.path.join(self.allocator, &.{ self.skills_dir, skill_dir });
                        try skills.append(self.allocator, .{
                            .name = try self.allocator.dupe(u8, result.name),
                            .description = try self.allocator.dupe(u8, result.description),
                            .body = try self.allocator.dupe(u8, result.body),
                            .path = full_path,
                            .version = try self.allocator.dupe(u8, result.version),
                        });
                    }
                }
                self.allocator.free(file_path);
            }
        }

        return try skills.toOwnedSlice(self.allocator);
    }

    /// 构建技能索引文本
    /// 生成技能名称和描述的简要列表，用于系统提示词
    pub fn buildSkillsIndex(self: *SkillLoader) ![]const u8 {
        const all_skills = try self.loadAll();
        defer {
            for (all_skills) |s| {
                self.allocator.free(s.name);
                self.allocator.free(s.description);
                self.allocator.free(s.body);
                self.allocator.free(s.path);
                self.allocator.free(s.version);
            }
            self.allocator.free(all_skills);
        }

        if (all_skills.len == 0) return "";

        var index: std.ArrayList(u8) = .empty;
        try index.print(self.allocator, "{s}", .{"Available skills (use skill_view to load full content):\n"});

        for (all_skills) |s| {
            const desc = if (s.description.len > 200) s.description[0..200] else s.description;
            try index.print(self.allocator, "- **{s}**: {s}\n", .{ s.name, desc });
        }

        return try index.toOwnedSlice(self.allocator);
    }

    /// 根据名称查找技能
    /// 参数：
    ///   name - 技能名称
    /// 返回：找到的技能，未找到返回null
    pub fn findSkill(self: *SkillLoader, name: []const u8) !?Skill {
        const all_skills = try self.loadAll();
        defer {
            for (all_skills) |s| {
                self.allocator.free(s.name);
                self.allocator.free(s.description);
                self.allocator.free(s.body);
                self.allocator.free(s.path);
                self.allocator.free(s.version);
            }
            self.allocator.free(all_skills);
        }

        for (all_skills) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return Skill{
                    .name = try self.allocator.dupe(u8, s.name),
                    .description = try self.allocator.dupe(u8, s.description),
                    .body = try self.allocator.dupe(u8, s.body),
                    .path = try self.allocator.dupe(u8, s.path),
                    .version = try self.allocator.dupe(u8, s.version),
                };
            }
        }
        return null;
    }

    /// 查看技能文件的完整内容
    /// 参数：
    ///   skill - 技能结构体
    /// 返回：技能文件的完整文本内容
    pub fn viewSkillFile(self: *SkillLoader, skill: Skill) ![]const u8 {
        const skill_md_path = try std.fs.path.join(self.allocator, &.{ skill.path, "SKILL.md" });
        defer self.allocator.free(skill_md_path);

        const cwd = std.Io.Dir.cwd();
        return cwd.readFileAlloc(self.io, skill_md_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch
            @as([]const u8, "Error: failed to read skill file");
    }

    /// 前置元数据解析结果
    const FrontmatterResult = struct {
        name: []const u8 = "",
        description: []const u8 = "",
        body: []const u8 = "",
        version: []const u8 = "1.0.0",
    };

    /// 解析SKILL.md文件的YAML前置元数据
    /// 格式：---\nname: xxx\ndescription: xxx\n---\n正文内容
    fn parseFrontmatter(text: []const u8) ?FrontmatterResult {
        if (!std.mem.startsWith(u8, text, "---")) return null;

        var parts = std.mem.splitSequence(u8, text, "---");
        _ = parts.next(); // 跳过第一个空段
        const frontmatter = parts.next() orelse return null;
        const body = parts.next() orelse return null;

        var result = FrontmatterResult{
            .body = std.mem.trim(u8, body, " \t\n\r"),
        };

        // 逐行解析前置元数据
        var lines = std.mem.splitSequence(u8, frontmatter, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const val = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

                if (std.mem.eql(u8, key, "name")) {
                    result.name = val;
                } else if (std.mem.eql(u8, key, "description")) {
                    result.description = val;
                } else if (std.mem.eql(u8, key, "version")) {
                    result.version = val;
                }
            }
        }

        return result;
    }
};
