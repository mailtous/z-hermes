"""
Session Database (Chapter 7)

SQLite + FTS5 for episodic memory. Stores every conversation turn
with full-text search for cross-session recall.
"""

import sqlite3
import uuid
import json
from datetime import datetime
from typing import Optional


class SessionDB:
    def __init__(self, db_path: str):
        self.db_path = str(db_path)
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self._create_tables()

    def _create_tables(self):
        self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                source TEXT DEFAULT 'cli',
                started_at REAL,
                ended_at REAL,
                message_count INTEGER DEFAULT 0,
                system_prompt TEXT
            );

            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT REFERENCES sessions(id),
                role TEXT NOT NULL,
                content TEXT,
                tool_name TEXT,
                tool_call_id TEXT,
                tool_calls_json TEXT,
                timestamp REAL
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
            USING fts5(content, content_rowid='id');
        """)
        self.conn.commit()

    def create_session(self, source: str = "cli",
                       system_prompt: str = "") -> str:
        session_id = str(uuid.uuid4())
        self.conn.execute(
            "INSERT INTO sessions (id, source, started_at, system_prompt) "
            "VALUES (?, ?, ?, ?)",
            (session_id, source, datetime.now().timestamp(), system_prompt)
        )
        self.conn.commit()
        return session_id

    def get_session(self, session_id: str) -> Optional[dict]:
        row = self.conn.execute(
            "SELECT id, source, started_at, system_prompt FROM sessions WHERE id=?",
            (session_id,)
        ).fetchone()
        if not row:
            return None
        return {
            "id": row[0], "source": row[1],
            "started_at": row[2], "system_prompt": row[3],
        }

    def append_message(self, session_id: str, role: str, content: str,
                       tool_name: str = None, tool_call_id: str = None,
                       tool_calls: list = None):
        tool_calls_json = json.dumps(tool_calls) if tool_calls else None
        cursor = self.conn.execute(
            """INSERT INTO messages
               (session_id, role, content, tool_name, tool_call_id,
                tool_calls_json, timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (session_id, role, content, tool_name, tool_call_id,
             tool_calls_json, datetime.now().timestamp())
        )
        # Index in FTS5 (only user and assistant text messages)
        if role in ("user", "assistant") and content:
            try:
                self.conn.execute(
                    "INSERT INTO messages_fts (rowid, content) VALUES (?, ?)",
                    (cursor.lastrowid, content)
                )
            except Exception:
                pass  # FTS insert failure is non-fatal
        self.conn.commit()

        # Update message count
        self.conn.execute(
            "UPDATE sessions SET message_count = message_count + 1 WHERE id = ?",
            (session_id,)
        )
        self.conn.commit()

    def search(self, query: str, limit: int = 20) -> list[dict]:
        """Full-text search across all sessions."""
        sanitized = self._sanitize_fts_query(query)
        if not sanitized:
            return []
        try:
            rows = self.conn.execute("""
                SELECT m.session_id, m.role,
                       snippet(messages_fts, 0, '>>>', '<<<', '...', 40) as snippet,
                       s.source, s.started_at
                FROM messages_fts
                JOIN messages m ON m.id = messages_fts.rowid
                JOIN sessions s ON s.id = m.session_id
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, (sanitized, limit)).fetchall()
        except Exception:
            return []

        return [
            {
                "session_id": r[0], "role": r[1], "snippet": r[2],
                "source": r[3],
                "date": datetime.fromtimestamp(r[4]).strftime("%Y-%m-%d %H:%M"),
            }
            for r in rows
        ]

    def get_session_messages(self, session_id: str,
                             limit: int = 50) -> list[dict]:
        rows = self.conn.execute(
            """SELECT role, content, tool_name, tool_calls_json
               FROM messages WHERE session_id=?
               ORDER BY timestamp LIMIT ?""",
            (session_id, limit)
        ).fetchall()
        return [
            {"role": r[0], "content": r[1] or "",
             "tool_name": r[2], "tool_calls": r[3]}
            for r in rows
        ]

    def end_session(self, session_id: str):
        self.conn.execute(
            "UPDATE sessions SET ended_at=? WHERE id=?",
            (datetime.now().timestamp(), session_id)
        )
        self.conn.commit()

    def _sanitize_fts_query(self, query: str) -> str:
        """Clean user input for FTS5 safety."""
        for char in ['"', '*', '+', '-', '(', ')', ':', '^', '~']:
            query = query.replace(char, ' ')
        words = [w.strip() for w in query.split() if w.strip()]
        return ' '.join(words) if words else ''
