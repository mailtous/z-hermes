"""
Skill Manager (Chapter 10-12)

skill_manage tool: create, patch, edit, delete.
skills_list and skill_view tools.
"""

import json
import yaml
from pathlib import Path
from py.tool_registry import registry

# Set by cli.py
_skill_loader = None
_skills_dir = None


def set_skill_loader(loader, skills_dir):
    global _skill_loader, _skills_dir
    _skill_loader = loader
    _skills_dir = skills_dir


def skills_list(category: str = None) -> str:
    """List all skills with metadata (progressive disclosure tier 1)."""
    if _skill_loader is None:
        return "Error: skills not initialized"
    all_skills = _skill_loader.load_all()
    if category:
        all_skills = [s for s in all_skills if category in str(s["path"])]
    result = []
    for s in all_skills:
        result.append({
            "name": s["name"],
            "description": s["description"][:200],
            "version": s.get("version", "1.0.0"),
        })
    return json.dumps(result, indent=2) if result else "No skills found."


def skill_view(name: str, file_path: str = None) -> str:
    """Load full skill content (progressive disclosure tier 2-3)."""
    if _skill_loader is None:
        return "Error: skills not initialized"
    skill = _skill_loader.find_skill(name)
    if not skill:
        return f"Error: skill '{name}' not found"
    if file_path:
        target = skill["path"] / file_path
        if not target.exists():
            return f"Error: file '{file_path}' not found in skill '{name}'"
        return target.read_text()
    return (skill["path"] / "SKILL.md").read_text()


def skill_manage(action: str, name: str, content: str = None,
                 category: str = None, old_string: str = None,
                 new_string: str = None, replace_all: bool = False,
                 file_path: str = None, file_content: str = None) -> str:
    """Manage skills: create, edit, patch, delete, write_file, remove_file."""
    if _skills_dir is None:
        return "Error: skills not initialized"

    if action == "create":
        if not content:
            return "Error: content is required for create (full SKILL.md text)"
        # Validate frontmatter
        if not content.startswith("---"):
            return "Error: SKILL.md must start with YAML frontmatter (---)"
        # Build path
        if category:
            skill_dir = _skills_dir / category / name
        else:
            skill_dir = _skills_dir / name
        if (skill_dir / "SKILL.md").exists():
            return f"Error: skill '{name}' already exists. Use 'patch' or 'edit'."
        skill_dir.mkdir(parents=True, exist_ok=True)
        (skill_dir / "SKILL.md").write_text(content)
        return json.dumps({"success": True, "message": f"Skill '{name}' created at {skill_dir}"})

    elif action == "patch":
        if not old_string:
            return "Error: old_string is required for patch"
        if new_string is None:
            return "Error: new_string is required for patch"
        skill = _skill_loader.find_skill(name)
        if not skill:
            return f"Error: skill '{name}' not found"
        target = skill["path"] / (file_path or "SKILL.md")
        if not target.exists():
            return f"Error: file not found: {target}"
        current = target.read_text()
        count = current.count(old_string)
        if count == 0:
            return f"Error: old_string not found in {target.name}"
        if count > 1 and not replace_all:
            return f"Error: old_string found {count} times. Use replace_all=true or add more context."
        new_content = current.replace(old_string, new_string, -1 if replace_all else 1)
        target.write_text(new_content)
        return json.dumps({"success": True, "message": f"Patched '{name}': {count} replacement(s)"})

    elif action == "edit":
        if not content:
            return "Error: content is required for edit (full SKILL.md text)"
        skill = _skill_loader.find_skill(name)
        if not skill:
            return f"Error: skill '{name}' not found"
        (skill["path"] / "SKILL.md").write_text(content)
        return json.dumps({"success": True, "message": f"Skill '{name}' fully rewritten"})

    elif action == "delete":
        skill = _skill_loader.find_skill(name)
        if not skill:
            return f"Error: skill '{name}' not found"
        import shutil
        shutil.rmtree(skill["path"])
        return json.dumps({"success": True, "message": f"Skill '{name}' deleted"})

    elif action == "write_file":
        if not file_path or not file_content:
            return "Error: file_path and file_content required for write_file"
        skill = _skill_loader.find_skill(name)
        if not skill:
            return f"Error: skill '{name}' not found"
        allowed = {"references", "templates", "scripts", "assets"}
        first_dir = Path(file_path).parts[0] if Path(file_path).parts else ""
        if first_dir not in allowed:
            return f"Error: file must be under one of: {', '.join(sorted(allowed))}"
        target = skill["path"] / file_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(file_content)
        return json.dumps({"success": True, "message": f"Written {file_path} in skill '{name}'"})

    elif action == "remove_file":
        if not file_path:
            return "Error: file_path required for remove_file"
        skill = _skill_loader.find_skill(name)
        if not skill:
            return f"Error: skill '{name}' not found"
        target = skill["path"] / file_path
        if not target.exists():
            return f"Error: file not found: {file_path}"
        target.unlink()
        return json.dumps({"success": True, "message": f"Removed {file_path} from skill '{name}'"})

    else:
        return f"Error: unknown action '{action}'"


# Register tools
registry.register(
    name="skills_list",
    description="List all available skills with name and description (metadata only).",
    parameters={
        "type": "object",
        "properties": {
            "category": {"type": "string", "description": "Optional category filter"},
        },
    },
    handler=skills_list,
    category="skills",
)

registry.register(
    name="skill_view",
    description="View the full content of a skill or a specific supporting file within it.",
    parameters={
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "Skill name"},
            "file_path": {"type": "string", "description": "Optional: path to a supporting file (e.g. references/api.md)"},
        },
        "required": ["name"],
    },
    handler=skill_view,
    category="skills",
)

registry.register(
    name="skill_manage",
    description=(
        "Manage skills (create, update, delete). Skills are procedural memory.\n"
        "Actions: create (full SKILL.md), patch (old_string/new_string), "
        "edit (full rewrite), delete, write_file, remove_file.\n"
        "After difficult tasks, offer to save as a skill. Confirm before creating/deleting."
    ),
    parameters={
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["create", "patch", "edit", "delete", "write_file", "remove_file"],
            },
            "name": {"type": "string", "description": "Skill name (lowercase, hyphens)"},
            "content": {"type": "string", "description": "Full SKILL.md for create/edit"},
            "category": {"type": "string", "description": "Category subdirectory for create"},
            "old_string": {"type": "string", "description": "Text to find (patch)"},
            "new_string": {"type": "string", "description": "Replacement text (patch)"},
            "replace_all": {"type": "boolean", "description": "Replace all occurrences (patch)"},
            "file_path": {"type": "string", "description": "Supporting file path"},
            "file_content": {"type": "string", "description": "Content for write_file"},
        },
        "required": ["action", "name"],
    },
    handler=skill_manage,
    category="skills",
)
