const std = @import("std");
const config_mod = @import("config.zig");
const llm = @import("llm_client.zig");
const agent_mod = @import("agent.zig");
const tool_calling = @import("tool_calling.zig");
const tool_registry = @import("tool_registry.zig");
const prompt_builder = @import("prompt_builder.zig");
const compression = @import("compression.zig");
const persistent = @import("memory/persistent.zig");
const session_db_mod = @import("memory/session_db.zig");
const recall_mod = @import("memory/recall.zig");
const skill_loader = @import("skills/loader.zig");
const skill_manager = @import("skills/manager.zig");
const terminal_tool = @import("tools/terminal.zig");
const file_tools_mod = @import("tools/file_tools.zig");
const memory_tool = @import("tools/memory_tool.zig");
const cp = @import("color_printer.zig");

/// 程序主入口函数
/// 初始化所有组件（配置、LLM客户端、数据库、内存、技能系统、工具注册等），
/// 然后进入交互式命令循环，处理用户输入
pub fn main() !void {
    // 初始化Arena分配器，用于统一管理内存，退出时一次性释放
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 初始化线程化I/O，用于处理输入输出操作
    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // 初始化带缓冲的标准输出写入器
    var stdout_buf: [512]u8 = undefined;
    var stdout_file_writer = std.Io.File.writer(std.Io.File.stdout(), io, &stdout_buf);

    // 初始化彩色打印器
    var printer = cp.ColorPrinter.init(allocator, &stdout_file_writer);

    // 加载配置文件，失败则退出
    const config_path = "config.yaml";
    const cfg = config_mod.Config.load(allocator, io, config_path) catch {
        printer.errorMsg("配置文件 {s} 加载失败！请确保文件存在且格式正确", .{config_path});
        printer.flush();
        std.process.exit(1);
    };

    // 打印配置信息，方便调试
    printer.color(cp.Color.bright_white, "  配置: base_url={s}, model={s}\n", .{ cfg.model.base_url, cfg.model.model });
    printer.flush();

    // 初始化LLM客户端，用于与语言模型API通信
    var client = llm.LlmClient.init(allocator, io, cfg.model.api_key, cfg.model.base_url);

    // 创建数据目录和技能子目录
    const data_dir = "data";
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    const skills_dir = try std.fs.path.join(allocator, &.{ data_dir, "skills" });
    std.Io.Dir.cwd().createDirPath(io, skills_dir) catch {};

    // 初始化SQLite会话数据库，用于持久化存储对话历史
    var sdb = session_db_mod.SessionDB.init(allocator, try std.fs.path.join(allocator, &.{ data_dir, "state.db" })) catch {
        printer.errorMsg("会话数据库初始化失败", .{});
        printer.flush();
        std.process.exit(1);
    };
    defer sdb.deinit();

    // 初始化持久化内存，用于保存AI的观察和用户画像
    var pm = persistent.PersistentMemory.init(allocator, io, data_dir) catch {
        printer.errorMsg("持久化内存初始化失败", .{});
        printer.flush();
        std.process.exit(1);
    };
    defer pm.deinit();

    // 初始化技能加载器，用于从磁盘加载技能文件
    var sloader = skill_loader.SkillLoader.init(allocator, io, skills_dir) catch {
        printer.errorMsg("技能加载器初始化失败", .{});
        printer.flush();
        std.process.exit(1);
    };
    defer sloader.deinit();

    // 初始化会话回忆系统，用于搜索和总结历史对话
    var srecall = recall_mod.SessionRecall.init(allocator, &sdb, &client, cfg.model.model, cfg.aux_model.max_tokens);

    // 初始化内存工具，并关联持久化内存和会话回忆
    var mem_tool = memory_tool.MemoryTool.init(allocator, io);
    mem_tool.setMemory(&pm, &srecall);

    // 初始化技能管理器，用于创建、查看、修改技能
    var smanager = skill_manager.SkillManager.init(allocator, io, &sloader, skills_dir);

    // 加载持久化内存内容
    const memory_block = pm.load() catch "";
    // 构建技能索引
    const skills_index = sloader.buildSkillsIndex() catch "";

    // 构建系统提示词，包含身份、记忆和技能信息
    const system_prompt = prompt_builder.PromptBuilder.build(allocator, memory_block, skills_index, "") catch "You are a helpful AI assistant.";

    // 创建新的会话并获取会话ID
    const session_id = sdb.createSession("cli", system_prompt) catch "unknown";

    // 根据模型名称选择工具调用策略（结构化或文本解析）
    const strategy = tool_calling.strategyForModel(allocator, cfg.model.model) catch {
        printer.errorMsg("工具调用策略创建失败", .{});
        printer.flush();
        std.process.exit(1);
    };

    // 初始化工具注册表，注册所有可用工具
    var registry = tool_registry.ToolRegistry.init(allocator);
    defer registry.deinit();

    // 注册终端命令执行工具
    registry.register(
        "terminal",
        "Run a shell command. Use for file operations, git, builds, system inspection, etc.",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds","default":30}},"required":["command"]}
        , .{}) catch .null,
        terminal_tool.runTerminal,
        "execution",
    );

    // 注册文件读取工具
    registry.register(
        "read_file",
        "Read the contents of a file given its path.",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"File path to read"}},"required":["path"]}
        , .{}) catch .null,
        file_tools_mod.readFile,
        "file",
    );

    // 注册文件写入工具
    registry.register(
        "write_file",
        "Write content to a file. Creates parent directories if needed.",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}
        , .{}) catch .null,
        file_tools_mod.writeFile,
        "file",
    );

    // 注册内存工具
    registry.register(
        "memory",
        "Manage persistent memory and session recall. Actions: save (observation), save_user (profile), read (all), search (history).",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"action":{"type":"string","enum":["save","save_user","read","search"],"description":"Action to perform"},"text":{"type":"string","description":"Text for save/save_user/search"}},"required":["action"]}
        , .{}) catch .null,
        memory_tool.MemoryTool.dummyHandler,
        "memory",
    );

    // 注册技能列表工具
    registry.register(
        "skills_list",
        "List all available skills with name, description and version (metadata only).",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"category":{"type":"string","description":"Optional category filter"}}}
        , .{}) catch .null,
        skill_manager.SkillManager.dummyHandler,
        "skills",
    );

    // 注册技能详情查看工具
    registry.register(
        "skill_view",
        "View the full content of a skill or a specific supporting file within it.",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name"},"file_path":{"type":"string","description":"Optional: path to a supporting file (e.g. references/api.md)"}},"required":["name"]}
        , .{}) catch .null,
        skill_manager.SkillManager.dummyHandler,
        "skills",
    );

    // 注册技能管理工具
    registry.register(
        "skill_manage",
        "Manage skills (create, update, delete, install). Skills are procedural memory. Actions: create (full SKILL.md), patch (old_string/new_string), edit (full rewrite), delete, write_file, remove_file, install (from src/skills/). After difficult tasks, offer to save as a skill. Confirm before creating/deleting.",
        std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"action":{"type":"string","enum":["create","patch","edit","delete","write_file","remove_file","install"],"description":"Action to perform"},"name":{"type":"string","description":"Skill name (lowercase, hyphens)"},"content":{"type":"string","description":"Full SKILL.md for create/edit"},"category":{"type":"string","description":"Category subdirectory for create"},"old_string":{"type":"string","description":"Text to find (patch)"},"new_string":{"type":"string","description":"Replacement text (patch)"},"replace_all":{"type":"boolean","description":"Replace all occurrences (patch)"},"file_path":{"type":"string","description":"Supporting file path"},"file_content":{"type":"string","description":"Content for write_file"},"source_dir":{"type":"string","description":"Source directory under src/skills/ for install action"}},"required":["action","name"]}
        , .{}) catch .null,
        skill_manager.SkillManager.dummyHandler,
        "skills",
    );

    // 获取所有工具的JSON Schema描述
    const schemas = try registry.getSchemas(allocator);

    // 初始化AI代理，配置模型、系统提示、工具和策略
    var agent = agent_mod.Agent.init(
        allocator,
        io,
        &client,
        cfg.model.model,
        system_prompt,
        schemas,
        cfg.agent.max_iterations,
        cfg.model.max_tokens,
        strategy,
    );

    // 关联会话数据库到代理
    agent.session_db = &sdb;
    agent.session_id = session_id;
    // 配置学习间隔（记忆提醒和技能提醒）
    agent.configureLearning(cfg.learning.memory_nudge_interval, cfg.learning.skill_nudge_interval);

    // 注册各工具的处理器到代理
    agent.setHandler("terminal", terminal_tool.runTerminal);
    agent.setHandler("read_file", file_tools_mod.readFile);
    agent.setHandler("write_file", file_tools_mod.writeFile);

    // 注册内存工具处理器（使用静态变量传递实例引用）
    const memoryHandler = struct {
        var mt: *memory_tool.MemoryTool = undefined;
        fn handler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
            _ = alloc;
            _ = io_arg;
            return try mt.execute(args);
        }
    };
    memoryHandler.mt = &mem_tool;
    agent.setHandler("memory", memoryHandler.handler);

    // 注册技能列表查看处理器
    const skillListHandler = struct {
        var sm: *skill_manager.SkillManager = undefined;
        fn handler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
            _ = alloc;
            _ = io_arg;
            return try sm.skillsList(args);
        }
    };
    skillListHandler.sm = &smanager;
    agent.setHandler("skills_list", skillListHandler.handler);

    // 注册技能详情查看处理器
    const skillViewHandler = struct {
        var sm2: *skill_manager.SkillManager = undefined;
        fn handler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
            _ = alloc;
            _ = io_arg;
            return try sm2.skillView(args);
        }
    };
    skillViewHandler.sm2 = &smanager;
    agent.setHandler("skill_view", skillViewHandler.handler);

    // 注册技能管理处理器（创建/修改/删除技能）
    const skillManageHandler = struct {
        var sm3: *skill_manager.SkillManager = undefined;
        fn handler(alloc: std.mem.Allocator, io_arg: std.Io, args: std.json.Value) anyerror![]const u8 {
            _ = alloc;
            _ = io_arg;
            return try sm3.skillManage(args);
        }
    };
    skillManageHandler.sm3 = &smanager;
    agent.setHandler("skill_manage", skillManageHandler.handler);

    // 初始化上下文压缩器，当对话过长时自动压缩历史消息
    var compressor = compression.ContextCompressor.init(allocator, &client, cfg.model.model, 32000, cfg.model.max_tokens);
    agent.setCompressor(&compressor);

    // 打印欢迎横幅
    printer.banner("v0.1");
    printer.color(cp.Color.bright_white, "  /mem /skills /sessions | exit to quit", .{});
    printer.print("\n", .{});
    printer.status("Model: {s}", .{cfg.model.model});
    printer.status("Session: {s}...", .{if (session_id.len > 8) session_id[0..8] else session_id});
    printer.flush();

    // 显示内存和技能状态
    const mem_status = if (memory_block.len > 0) "loaded" else "empty";
    const all_skills = sloader.loadAll() catch &[_]skill_loader.Skill{};
    printer.color(cp.Color.white, "  Memory: ", .{});
    if (memory_block.len > 0) {
        printer.color(cp.Color.bright_green, "{s}", .{mem_status});
    } else {
        printer.color(cp.Color.bright_yellow, "{s}", .{mem_status});
    }
    printer.color(cp.Color.white, " | Skills: {d}", .{all_skills.len});
    printer.print("\n\n", .{});
    printer.flush();

    // 主交互循环：读取用户输入并处理
    var input_buf: [4096]u8 = undefined;
    var input_pos: usize = 0;

    while (true) {
        // 显示用户提示符（绿色粗体）
        printer.userPrompt();
        printer.flush();

        // 从标准输入读取用户输入
        input_pos = 0;
        while (true) {
            const n = std.posix.read(std.posix.STDIN_FILENO, input_buf[input_pos..]) catch 0;
            if (n == 0) {
                // stdin已关闭，退出程序
                printer.color(cp.Color.bright_magenta, "Goodbye!", .{});
                printer.print("\n", .{});
                printer.flush();
                sdb.endSession(session_id);
                agent.deinit();
                return;
            }
            input_pos += n;
            if (input_pos > 0 and input_buf[input_pos - 1] == '\n') break;
        }

        // 去除首尾空白字符
        const user_input = std.mem.trim(u8, input_buf[0..input_pos], " \t\r\n");
        if (user_input.len == 0) continue;

        // 处理退出命令
        if (std.mem.eql(u8, user_input, "exit") or std.mem.eql(u8, user_input, "quit") or
            std.mem.eql(u8, user_input, "/exit") or std.mem.eql(u8, user_input, "/quit"))
        {
            printer.color(cp.Color.bright_magenta, "Goodbye!", .{});
            printer.print("\n", .{});
            printer.flush();
            break;
        }

        // 处理 /mem 命令：显示持久化记忆和用户画像
        if (std.mem.eql(u8, user_input, "/mem")) {
            printer.separator("Memory");
            const mem_content = pm.readMemory();
            defer allocator.free(mem_content);
            printer.print("{s}\n", .{mem_content});

            printer.separator("User Profile");
            const user_content = pm.readUser();
            defer allocator.free(user_content);
            printer.print("{s}\n\n", .{user_content});
            printer.flush();
            continue;
        }

        // 处理 /skills 命令：列出所有已加载的技能
        if (std.mem.eql(u8, user_input, "/skills")) {
            const skills = sloader.loadAll() catch &[_]skill_loader.Skill{};
            if (skills.len == 0) {
                printer.color(cp.Color.bright_yellow, "No skills yet.\n\n", .{});
            } else {
                printer.color(cp.Color.bright_yellow, "{d} Skills", .{skills.len});
                printer.print("\n", .{});
                for (skills) |s| {
                    const desc = if (s.description.len > 60) s.description[0..60] else s.description;
                    printer.color(cp.Color.bright_cyan, "  {s}", .{s.name});
                    printer.color(cp.Color.white, ": {s}", .{desc});
                    printer.print("\n", .{});
                }
                printer.print("\n", .{});
            }
            printer.flush();
            continue;
        }

        // 处理 /sessions 命令：搜索历史会话
        if (std.mem.eql(u8, user_input, "/sessions")) {
            printer.color(cp.Color.bright_white, "Search query: ", .{});
            printer.flush();
            var query_pos: usize = 0;
            var query_buf: [1024]u8 = undefined;
            while (true) {
                const n = std.posix.read(std.posix.STDIN_FILENO, query_buf[query_pos..]) catch 0;
                if (n == 0) break;
                query_pos += n;
                if (query_pos > 0 and query_buf[query_pos - 1] == '\n') break;
            }
            const query = std.mem.trim(u8, query_buf[0..query_pos], " \t\r\n");
            if (query.len > 0) {
                const result = srecall.recall(query, 3) catch "";
                if (result.len > 0) {
                    printer.print("{s}\n", .{result});
                } else {
                    printer.color(cp.Color.bright_yellow, "No results.\n\n", .{});
                }
            }
            printer.flush();
            continue;
        }

        // 显示思考中提示（暗色）
        printer.dim("  thinking...", .{});
        printer.flush();

        // 调用代理处理用户输入
        const response = agent.run(user_input) catch |err| blk: {
            var err_buf: std.ArrayList(u8) = .empty;
            err_buf.print(allocator, "[Agent Error: {}]", .{err}) catch {};
            break :blk try err_buf.toOwnedSlice(allocator);
        };

        // 清除思考提示，显示AI回复
        printer.print("\r{s}  \r", .{" " ** 40});
        printer.aiPrompt();
        printer.color(cp.Color.bright_white, "{s}", .{response});
        printer.print("\n\n", .{});
        printer.flush();
    }

    // 结束会话，保存到数据库
    sdb.endSession(session_id);
    printer.color(cp.Color.bright_green, "Session {s} saved.", .{if (session_id.len > 8) session_id[0..8] else session_id});
    printer.print("\n", .{});
    printer.flush();

    // 释放代理资源
    agent.deinit();
}
