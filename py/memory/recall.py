"""
Cross-Session Recall (Chapter 9)

FTS5 search -> group by session -> summarize via LLM.
"""

from openai import OpenAI
from py.memory.session_db import SessionDB


class SessionRecall:
    def __init__(self, session_db: SessionDB, client: OpenAI, model: str,
                 max_tokens: int = 300):
        self.db = session_db
        self.client = client
        self.model = model
        self.max_tokens = max_tokens

    def recall(self, query: str, max_sessions: int = 3) -> str:
        """Search past sessions and return summarized context."""
        # Step 1: FTS5 search
        results = self.db.search(query, limit=30)
        if not results:
            return ""

        # Step 2: Group by session, take top N unique
        seen = {}
        for r in results:
            sid = r["session_id"]
            if sid not in seen:
                seen[sid] = r
            if len(seen) >= max_sessions:
                break

        # Step 3: For each session, load + summarize
        summaries = []
        for sid, meta in seen.items():
            messages = self.db.get_session_messages(sid, limit=30)
            if not messages:
                continue
            transcript = self._format_transcript(messages)
            summary = self._summarize(query, transcript, meta["date"])
            if summary:
                summaries.append(f"[{meta['date']}] {summary}")

        return "\n\n---\n\n".join(summaries)

    def _format_transcript(self, messages: list[dict]) -> str:
        lines = []
        for m in messages:
            content = m.get("content", "")[:300]
            if content:
                lines.append(f"{m['role']}: {content}")
        return "\n".join(lines)[:5000]

    def _summarize(self, topic: str, transcript: str,
                   date: str) -> str:
        try:
            resp = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content":
                     "Summarize this past conversation, focusing on "
                     "information relevant to the given topic. Be concise. "
                     "Under 150 words."},
                    {"role": "user", "content":
                     f"Topic: {topic}\nDate: {date}\n\nTRANSCRIPT:\n{transcript}"}
                ],
                max_tokens=self.max_tokens,
            )
            content = resp.choices[0].message.content
            return content.strip() if content else ""
        except Exception as e:
            return f"(recall error: {e})"
