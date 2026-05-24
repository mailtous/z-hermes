const std = @import("std");
const loader = @import("loader.zig");

pub const SkillManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    skill_loader: *loader.SkillLoader,
    skills_dir: []const u8,

    pub fn dummyHandler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
        _ = alloc;
        _ = io_arg;
        _ = args;
        return "not dispatched via registry";
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, skill_loader: *loader.SkillLoader, skills_dir: []const u8) SkillManager {
        return .{
            .allocator = allocator,
            .io = io,
            .skill_loader = skill_loader,
            .skills_dir = skills_dir,
        };
    }

    fn copyDirRecursive(self: *SkillManager, src_dir: []const u8, dest_dir: []const u8) !usize {
        var file_count: usize = 0;
        const cwd = std.Io.Dir.cwd();

        var src = cwd.openDir(self.io, src_dir, .{ .iterate = true }) catch return 0;
        defer src.close(self.io);

        var walker = src.walk(self.allocator) catch return 0;
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind == .file) {
                const src_path = try std.fs.path.join(self.allocator, &.{ src_dir, entry.path });
                defer self.allocator.free(src_path);

                const dest_path = try std.fs.path.join(self.allocator, &.{ dest_dir, entry.path });
                defer self.allocator.free(dest_path);

                const content = cwd.readFileAlloc(self.io, src_path, self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch continue;
                defer self.allocator.free(content);

                const parent = std.fs.path.dirname(dest_path);
                if (parent) |p| {
                    cwd.createDirPath(self.io, p) catch {};
                }

                const file = try cwd.createFile(self.io, dest_path, .{});
                defer file.close(self.io);
                try file.writeStreamingAll(self.io, content);

                file_count += 1;
            }
        }

        return file_count;
    }

    pub fn skillsList(self: *SkillManager, args: std.json.Value) ![]const u8 {
        const all_skills = self.skill_loader.loadAll() catch return "Error: failed to load skills";
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

        const filtered_skills: []const loader.Skill = all_skills;
        var category_filter: ?[]const u8 = null;
        if (args.object.get("category")) |cat| {
            category_filter = cat.string;
        }

        var result: std.ArrayList(u8) = .empty;
        var count: usize = 0;

        for (filtered_skills) |s| {
            if (category_filter) |cf| {
                if (std.mem.indexOf(u8, s.path, cf) == null) continue;
            }
            const desc = if (s.description.len > 200) s.description[0..200] else s.description;
            try result.print(self.allocator, "  {s}: {s} (v{s})\n", .{ s.name, desc, s.version });
            count += 1;
        }

        if (count == 0) return "No skills found.";
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn skillView(self: *SkillManager, args: std.json.Value) ![]const u8 {
        const name = if (args.object.get("name")) |n| n.string else return "Error: name is required";

        const skill = try self.skill_loader.findSkill(name) orelse
            return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});

        if (args.object.get("file_path")) |fp| {
            const target_path = try std.fs.path.join(self.allocator, &.{ skill.path, fp.string });
            defer self.allocator.free(target_path);

            const cwd = std.Io.Dir.cwd();
            return cwd.readFileAlloc(self.io, target_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch
                try std.fmt.allocPrint(self.allocator, "Error: file '{s}' not found in skill '{s}'", .{ fp.string, name });
        }

        return try self.skill_loader.viewSkillFile(skill);
    }

    pub fn skillManage(self: *SkillManager, args: std.json.Value) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        const action_val = args.object.get("action") orelse return "Error: action is required";
        const action = action_val.string;
        const name = if (args.object.get("name")) |n| n.string else return "Error: name is required";

        if (std.mem.eql(u8, action, "create")) {
            const content = if (args.object.get("content")) |c| c.string else return "Error: content is required for create";
            if (!std.mem.startsWith(u8, content, "---")) return "Error: SKILL.md must start with YAML frontmatter (---)";

            var skill_dir_buf: std.ArrayList(u8) = .empty;
            if (args.object.get("category")) |cat| {
                try skill_dir_buf.print(self.allocator, "{s}/{s}/{s}", .{ self.skills_dir, cat.string, name });
            } else {
                try skill_dir_buf.print(self.allocator, "{s}/{s}", .{ self.skills_dir, name });
            }

            const skill_md_path = try std.fs.path.join(self.allocator, &.{ skill_dir_buf.items, "SKILL.md" });
            const existing = cwd.readFileAlloc(self.io, skill_md_path, self.allocator, std.Io.Limit.limited(1)) catch null;
            if (existing) |_| {
                self.allocator.free(skill_md_path);
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' already exists. Use 'patch' or 'edit'.", .{name});
            }

            cwd.createDirPath(self.io, skill_dir_buf.items) catch {};

            const file = try cwd.createFile(self.io, skill_md_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, content);

            return try std.fmt.allocPrint(self.allocator, "Skill '{s}' created at {s}", .{ name, skill_dir_buf.items });
        }

        if (std.mem.eql(u8, action, "patch")) {
            const old_string = if (args.object.get("old_string")) |o| o.string else return "Error: old_string is required for patch";
            const new_string_val = args.object.get("new_string") orelse return "Error: new_string is required for patch";
            const new_string = new_string_val.string;
            const replace_all = if (args.object.get("replace_all")) |ra| ra.bool else false;

            const skill = try self.skill_loader.findSkill(name) orelse
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});

            var target_path: []const u8 = undefined;
            if (args.object.get("file_path")) |fp| {
                target_path = try std.fs.path.join(self.allocator, &.{ skill.path, fp.string });
            } else {
                target_path = try std.fs.path.join(self.allocator, &.{ skill.path, "SKILL.md" });
            }
            defer self.allocator.free(target_path);

            const current = cwd.readFileAlloc(self.io, target_path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch
                return "Error: failed to read skill file";
            defer self.allocator.free(current);

            const count = std.mem.count(u8, current, old_string);
            if (count == 0) return "Error: old_string not found";
            if (count > 1 and !replace_all)
                return try std.fmt.allocPrint(self.allocator, "Error: old_string found {d} times. Use replace_all=true or add more context.", .{count});

            var new_content: std.ArrayList(u8) = .empty;
            if (replace_all) {
                var parts = std.mem.splitSequence(u8, current, old_string);
                var first = true;
                while (parts.next()) |part| {
                    if (!first) try new_content.appendSlice(self.allocator, new_string);
                    try new_content.appendSlice(self.allocator, part);
                    first = false;
                }
            } else {
                if (std.mem.indexOf(u8, current, old_string)) |idx| {
                    try new_content.appendSlice(self.allocator, current[0..idx]);
                    try new_content.appendSlice(self.allocator, new_string);
                    try new_content.appendSlice(self.allocator, current[idx + old_string.len ..]);
                }
            }

            const file = try cwd.createFile(self.io, target_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, new_content.items);

            return try std.fmt.allocPrint(self.allocator, "Patched '{s}': {d} replacement(s)", .{ name, count });
        }

        if (std.mem.eql(u8, action, "edit")) {
            const content = if (args.object.get("content")) |c| c.string else return "Error: content is required for edit";
            const skill = try self.skill_loader.findSkill(name) orelse
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});
            const skill_md_path = try std.fs.path.join(self.allocator, &.{ skill.path, "SKILL.md" });
            defer self.allocator.free(skill_md_path);
            const file = try cwd.createFile(self.io, skill_md_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, content);
            return try std.fmt.allocPrint(self.allocator, "Skill '{s}' fully rewritten", .{name});
        }

        if (std.mem.eql(u8, action, "delete")) {
            const skill = try self.skill_loader.findSkill(name) orelse
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});
            cwd.deleteTree(self.io, skill.path) catch return "Error: failed to delete skill";
            return try std.fmt.allocPrint(self.allocator, "Skill '{s}' deleted", .{name});
        }

        if (std.mem.eql(u8, action, "write_file")) {
            const file_path = if (args.object.get("file_path")) |fp| fp.string else return "Error: file_path is required for write_file";
            const file_content = if (args.object.get("file_content")) |fc| fc.string else return "Error: file_content is required for write_file";

            const allowed_dirs = [_][]const u8{ "references", "templates", "scripts", "assets" };
            var first_dir: []const u8 = "";
            if (std.mem.indexOf(u8, file_path, "/")) |slash_pos| {
                first_dir = file_path[0..slash_pos];
            } else {
                first_dir = file_path;
            }
            var is_allowed = false;
            for (allowed_dirs) |ad| {
                if (std.mem.eql(u8, first_dir, ad)) {
                    is_allowed = true;
                    break;
                }
            }
            if (!is_allowed)
                return "Error: file must be under one of: references, templates, scripts, assets";

            const skill = try self.skill_loader.findSkill(name) orelse
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});

            const target_path = try std.fs.path.join(self.allocator, &.{ skill.path, file_path });
            defer self.allocator.free(target_path);

            const parent_dir = std.fs.path.dirname(target_path) orelse target_path;
            cwd.createDirPath(self.io, parent_dir) catch {};

            const file = try cwd.createFile(self.io, target_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, file_content);

            return try std.fmt.allocPrint(self.allocator, "Written {s} in skill '{s}'", .{ file_path, name });
        }

        if (std.mem.eql(u8, action, "remove_file")) {
            const file_path = if (args.object.get("file_path")) |fp| fp.string else return "Error: file_path is required for remove_file";

            const skill = try self.skill_loader.findSkill(name) orelse
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' not found", .{name});

            const target_path = try std.fs.path.join(self.allocator, &.{ skill.path, file_path });
            defer self.allocator.free(target_path);

            cwd.deleteFile(self.io, target_path) catch
                return try std.fmt.allocPrint(self.allocator, "Error: file '{s}' not found", .{file_path});

            return try std.fmt.allocPrint(self.allocator, "Removed {s} from skill '{s}'", .{ file_path, name });
        }

        if (std.mem.eql(u8, action, "install")) {
            const source_dir = if (args.object.get("source_dir")) |sd| sd.string else return "Error: source_dir is required for install";

            const src_base = "src/skills";
            var src_path_buf: std.ArrayList(u8) = .empty;
            try src_path_buf.print(self.allocator, "{s}/{s}", .{ src_base, source_dir });
            defer src_path_buf.deinit(self.allocator);

            const src_exists = cwd.openDir(self.io, src_path_buf.items, .{}) catch null;
            if (src_exists == null) {
                return try std.fmt.allocPrint(self.allocator, "Error: source directory '{s}/{s}' not found", .{ src_base, source_dir });
            } else {
                src_exists.?.close(self.io);
            }

            var dest_path_buf: std.ArrayList(u8) = .empty;
            try dest_path_buf.print(self.allocator, "{s}/{s}", .{ self.skills_dir, name });
            defer dest_path_buf.deinit(self.allocator);

            const existing = cwd.openDir(self.io, dest_path_buf.items, .{}) catch null;
            if (existing != null) {
                existing.?.close(self.io);
                return try std.fmt.allocPrint(self.allocator, "Error: skill '{s}' already installed. Use 'patch' or 'edit' to modify.", .{name});
            }

            cwd.createDirPath(self.io, dest_path_buf.items) catch {};

            const copied = try self.copyDirRecursive(src_path_buf.items, dest_path_buf.items);
            if (copied > 0) {
                return try std.fmt.allocPrint(self.allocator, "Skill '{s}' installed from '{s}' ({d} files copied)", .{ name, source_dir, copied });
            } else {
                cwd.deleteTree(self.io, dest_path_buf.items) catch {};
                return try std.fmt.allocPrint(self.allocator, "Error: no files found in source directory '{s}'", .{source_dir});
            }
        }

        return try std.fmt.allocPrint(self.allocator, "Error: unknown action '{s}'. Use: create, patch, edit, delete, write_file, remove_file, install", .{action});
    }
};
