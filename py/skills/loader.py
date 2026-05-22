"""
Skill Loader (Chapter 10)

Discover SKILL.md files in folders, parse frontmatter,
build progressive-disclosure index.
"""

import yaml
from pathlib import Path


class SkillLoader:
    def __init__(self, skills_dir: Path):
        self.skills_dir = skills_dir
        self.skills_dir.mkdir(parents=True, exist_ok=True)

    def load_all(self) -> list[dict]:
        """Load all skill folders, return name + description + body + path."""
        result = []
        for skill_md in self.skills_dir.rglob("SKILL.md"):
            text = skill_md.read_text()
            meta, body = self._parse_frontmatter(text)
            if meta and meta.get("name"):
                result.append({
                    "name": meta["name"],
                    "description": meta.get("description", ""),
                    "body": body,
                    "path": skill_md.parent,
                    "version": meta.get("version", "1.0.0"),
                })
        return result

    def build_skills_index(self) -> str:
        """Build summary index for system prompt (tier 1: metadata only)."""
        all_skills = self.load_all()
        if not all_skills:
            return ""
        lines = ["Available skills (use skill_view to load full content):"]
        for s in all_skills:
            desc = s["description"][:200]
            lines.append(f"- **{s['name']}**: {desc}")
        return "\n".join(lines)

    def find_skill(self, name: str) -> dict | None:
        """Find a skill by name."""
        for s in self.load_all():
            if s["name"] == name:
                return s
        return None

    def _parse_frontmatter(self, text: str) -> tuple[dict, str]:
        """Split YAML frontmatter from markdown body."""
        if not text.startswith("---"):
            return {}, text
        parts = text.split("---", 2)
        if len(parts) < 3:
            return {}, text
        try:
            meta = yaml.safe_load(parts[1])
            if not isinstance(meta, dict):
                return {}, text
            return meta, parts[2].strip()
        except yaml.YAMLError:
            return {}, text
