const std = @import("std");
const sqlite = @import("sqlite");

fn getTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
    if (rc != 0) return 0;
    return ts.sec;
}

fn getRandomU32() u32 {
    var prng = std.Random.DefaultPrng.init(@intCast(getTimestamp()));
    return prng.random().int(u32);
}

pub const SessionDB = struct {
    allocator: std.mem.Allocator,
    db: sqlite.Database,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !SessionDB {
        const path_cstr = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_cstr);

        const db = sqlite.Database.open(.{
            .path = path_cstr,
            .mode = .ReadWrite,
            .create = true,
        }) catch {
            return error.DatabaseOpenFailed;
        };

        var self = SessionDB{
            .allocator = allocator,
            .db = db,
        };

        try self.createTables();
        return self;
    }

    pub fn deinit(self: *SessionDB) void {
        self.db.close();
    }

    fn createTables(self: *SessionDB) !void {
        self.db.exec(
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    id TEXT PRIMARY KEY,
            \\    source TEXT DEFAULT 'cli',
            \\    started_at REAL,
            \\    ended_at REAL,
            \\    message_count INTEGER DEFAULT 0,
            \\    system_prompt TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    session_id TEXT REFERENCES sessions(id),
            \\    role TEXT NOT NULL,
            \\    content TEXT,
            \\    tool_name TEXT,
            \\    tool_call_id TEXT,
            \\    tool_calls_json TEXT,
            \\    timestamp REAL
            \\);
        , .{}) catch {
            return error.TableCreationFailed;
        };

        self.db.exec(
            "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content, content_rowid='id');",
            .{},
        ) catch {};
    }

    pub fn createSession(self: *SessionDB, source: []const u8, system_prompt: []const u8) ![]const u8 {
        var uuid_buf: [64]u8 = undefined;
        const timestamp = getTimestamp();
        const uuid = try std.fmt.bufPrint(&uuid_buf, "{d}-{d}", .{ timestamp, getRandomU32() });

        self.db.exec(
            "INSERT INTO sessions (id, source, started_at, system_prompt) VALUES (:id, :source, :started_at, :system_prompt)",
            .{
                .id = sqlite.text(uuid),
                .source = sqlite.text(source),
                .started_at = @as(f64, @floatFromInt(timestamp)),
                .system_prompt = sqlite.text(system_prompt),
            },
        ) catch {
            return error.InsertFailed;
        };

        return try self.allocator.dupe(u8, uuid);
    }

    pub fn appendMessage(self: *SessionDB, session_id: []const u8, role: []const u8, content: []const u8, tool_name: ?[]const u8, tool_call_id: ?[]const u8) !void {
        self.db.exec(
            "INSERT INTO messages (session_id, role, content, tool_name, tool_call_id, timestamp) VALUES (:session_id, :role, :content, :tool_name, :tool_call_id, :timestamp)",
            .{
                .session_id = sqlite.text(session_id),
                .role = sqlite.text(role),
                .content = sqlite.text(content),
                .tool_name = if (tool_name) |tn| sqlite.text(tn) else null,
                .tool_call_id = if (tool_call_id) |tci| sqlite.text(tci) else null,
                .timestamp = @as(f64, @floatFromInt(getTimestamp())),
            },
        ) catch {
            return error.InsertFailed;
        };

        const rowid = sqlite.c.sqlite3_last_insert_rowid(self.db.ptr);

        if (std.mem.eql(u8, role, "user") or std.mem.eql(u8, role, "assistant")) {
            self.db.exec(
                "INSERT INTO messages_fts (rowid, content) VALUES (:rowid, :content)",
                .{
                    .rowid = rowid,
                    .content = sqlite.text(content),
                },
            ) catch {};
        }

        self.db.exec(
            "UPDATE sessions SET message_count = message_count + 1 WHERE id = :id",
            .{ .id = sqlite.text(session_id) },
        ) catch {};
    }

    pub const SearchResult = struct {
        session_id: []const u8,
        role: []const u8,
        snippet: []const u8,
        source: []const u8,
        date: []const u8,
    };

    pub fn search(self: *SessionDB, query: []const u8, limit: u32) ![]SearchResult {
        const sanitized = try self.sanitizeFtsQuery(query);
        defer self.allocator.free(sanitized);
        if (sanitized.len == 0) return &[_]SearchResult{};

        const FtsParams = struct {
            query: sqlite.Text,
            limit: i32,
        };
        const FtsResult = struct {
            session_id: sqlite.Text,
            role: sqlite.Text,
            snippet: sqlite.Text,
            source: sqlite.Text,
            started_at: f64,
        };

        const stmt = self.db.prepare(FtsParams, FtsResult,
            \\SELECT m.session_id, m.role,
            \\       snippet(messages_fts, 0, '>>>', '<<<', '...', 40) as snippet,
            \\       s.source, s.started_at
            \\FROM messages_fts
            \\JOIN messages m ON m.id = messages_fts.rowid
            \\JOIN sessions s ON s.id = m.session_id
            \\WHERE messages_fts MATCH :query
            \\ORDER BY rank
            \\LIMIT :limit
        ) catch return &[_]SearchResult{};
        defer stmt.finalize();

        stmt.bind(.{
            .query = sqlite.text(sanitized),
            .limit = @intCast(limit),
        }) catch return &[_]SearchResult{};
        defer stmt.reset();

        var results: std.ArrayList(SearchResult) = .empty;
        while (stmt.step() catch null) |row| {
            var date_buf: [64]u8 = undefined;
            const date_str = try std.fmt.bufPrint(&date_buf, "{d:.0}", .{row.started_at});

            try results.append(self.allocator, .{
                .session_id = try self.allocator.dupe(u8, row.session_id.data),
                .role = try self.allocator.dupe(u8, row.role.data),
                .snippet = try self.allocator.dupe(u8, row.snippet.data),
                .source = try self.allocator.dupe(u8, row.source.data),
                .date = try self.allocator.dupe(u8, date_str),
            });
        }

        return try results.toOwnedSlice(self.allocator);
    }

    pub const MessageEntry = struct {
        role: []const u8,
        content: []const u8,
    };

    pub fn getSessionMessages(self: *SessionDB, allocator: std.mem.Allocator, session_id: []const u8, limit: u32) ![]MessageEntry {
        const Params = struct {
            session_id: sqlite.Text,
            limit: i32,
        };
        const Result = struct {
            role: sqlite.Text,
            content: sqlite.Text,
        };

        const stmt = self.db.prepare(
            Params,
            Result,
            "SELECT role, content FROM messages WHERE session_id = :session_id ORDER BY timestamp LIMIT :limit",
        ) catch return &[_]MessageEntry{};
        defer stmt.finalize();

        stmt.bind(.{
            .session_id = sqlite.text(session_id),
            .limit = @intCast(limit),
        }) catch return &[_]MessageEntry{};
        defer stmt.reset();

        var messages: std.ArrayList(MessageEntry) = .empty;
        while (stmt.step() catch null) |row| {
            try messages.append(allocator, .{
                .role = try allocator.dupe(u8, row.role.data),
                .content = try allocator.dupe(u8, row.content.data),
            });
        }

        return try messages.toOwnedSlice(allocator);
    }

    pub fn endSession(self: *SessionDB, session_id: []const u8) void {
        self.db.exec(
            "UPDATE sessions SET ended_at = :ended_at WHERE id = :id",
            .{
                .ended_at = @as(f64, @floatFromInt(getTimestamp())),
                .id = sqlite.text(session_id),
            },
        ) catch {};
    }

    fn sanitizeFtsQuery(self: *SessionDB, query: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        const chars_to_remove = "\"*+-():^~";
        for (query) |ch| {
            var found = false;
            for (chars_to_remove) |r| {
                if (ch == r) {
                    found = true;
                    break;
                }
            }
            if (!found and ch != ' ') {
                try result.append(self.allocator, ch);
            } else if (ch == ' ') {
                try result.append(self.allocator, ch);
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }
};
