"""
Persistent Memory (Chapter 8)

MEMORY.md and USER.md files -- frozen snapshot loaded at session start.
Writes go to disk but don't update the running system prompt.
"""

from pathlib import Path


class PersistentMemory:
    MEMORY_LIMIT = 2200   # Hermes default for observations
    USER_LIMIT = 1375     # Hermes default for user profile

    def __init__(self, data_dir: Path):
        self.memory_path = data_dir / "MEMORY.md"
        self.user_path = data_dir / "USER.md"
        self.memory_path.touch(exist_ok=True)
        self.user_path.touch(exist_ok=True)

    def load(self) -> str:
        """Load both files as a combined context block (frozen snapshot)."""
        parts = []
        user = self.user_path.read_text().strip()
        memory = self.memory_path.read_text().strip()
        if user:
            parts.append(f"### User Profile\n{user}")
        if memory:
            parts.append(f"### Observations\n{memory}")
        return "\n\n".join(parts)

    def save_observation(self, text: str) -> str:
        """Append an observation to MEMORY.md (writes to disk only)."""
        current = self.memory_path.read_text()
        new_entry = f"\n- {text}"
        if len(current) + len(new_entry) > self.MEMORY_LIMIT:
            lines = current.strip().split("\n")
            while lines and len("\n".join(lines)) + len(new_entry) > self.MEMORY_LIMIT:
                lines.pop(0)
            current = "\n".join(lines)
        self.memory_path.write_text(current + new_entry)
        return f"Saved to memory: {text[:80]}"

    def update_user_profile(self, text: str) -> str:
        """Replace the user profile (writes to disk only)."""
        self.user_path.write_text(text[:self.USER_LIMIT])
        return f"User profile updated ({len(text)} chars)"

    def read_memory(self) -> str:
        """Read current memory contents."""
        return self.memory_path.read_text().strip() or "(empty)"

    def read_user(self) -> str:
        """Read current user profile."""
        return self.user_path.read_text().strip() or "(empty)"
