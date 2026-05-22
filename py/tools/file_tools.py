"""
File tools (Chapter 4)

Read and write files.
"""

from pathlib import Path
from py.tool_registry import registry


def read_file(path: str) -> str:
    """Read a file and return its contents."""
    p = Path(path).expanduser()
    if not p.exists():
        return f"Error: file not found: {path}"
    if not p.is_file():
        return f"Error: not a file: {path}"
    try:
        content = p.read_text()
        if len(content) > 50000:
            content = content[:50000] + "\n... [truncated]"
        return content
    except Exception as e:
        return f"Error reading {path}: {e}"


def write_file(path: str, content: str) -> str:
    """Write content to a file, creating directories as needed."""
    p = Path(path).expanduser()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return f"Written {len(content)} chars to {path}"
    except Exception as e:
        return f"Error writing {path}: {e}"


registry.register(
    name="read_file",
    description="Read the contents of a file given its path.",
    parameters={
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File path to read"},
        },
        "required": ["path"],
    },
    handler=read_file,
    category="file",
)

registry.register(
    name="write_file",
    description="Write content to a file. Creates parent directories if needed.",
    parameters={
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File path to write"},
            "content": {"type": "string", "description": "Content to write"},
        },
        "required": ["path", "content"],
    },
    handler=write_file,
    category="file",
)
