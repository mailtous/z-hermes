"""
Memory tool (Chapter 8)

Exposes persistent memory to the agent as a callable tool.
"""

from py.tool_registry import registry

# Will be set by cli.py at startup
_persistent_memory = None
_session_recall = None


def set_memory(persistent_memory, session_recall=None):
    global _persistent_memory, _session_recall
    _persistent_memory = persistent_memory
    _session_recall = session_recall


def memory(action: str, text: str = "") -> str:
    """Unified memory tool: save, read, search."""
    if _persistent_memory is None:
        return "Error: memory not initialized"

    if action == "save":
        if not text:
            return "Error: text is required for save"
        return _persistent_memory.save_observation(text)
    elif action == "save_user":
        if not text:
            return "Error: text is required for save_user"
        return _persistent_memory.update_user_profile(text)
    elif action == "read":
        mem = _persistent_memory.read_memory()
        user = _persistent_memory.read_user()
        return f"## Memory\n{mem}\n\n## User Profile\n{user}"
    elif action == "search":
        if not text:
            return "Error: text (query) is required for search"
        if _session_recall is None:
            return "Error: session recall not available"
        result = _session_recall.recall(text)
        return result if result else "No relevant past sessions found."
    else:
        return f"Error: unknown action '{action}'. Use: save, save_user, read, search"


registry.register(
    name="memory",
    description=(
        "Manage persistent memory across sessions. Actions:\n"
        "- save: Save an observation about the user or project\n"
        "- save_user: Update the user profile\n"
        "- read: Read current memory and user profile\n"
        "- search: Search past conversations for relevant context"
    ),
    parameters={
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["save", "save_user", "read", "search"],
                "description": "Action to perform",
            },
            "text": {
                "type": "string",
                "description": "Text to save, or query to search for",
            },
        },
        "required": ["action"],
    },
    handler=memory,
    category="memory",
)
