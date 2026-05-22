"""
Tool Registry (Chapter 4)

Register tools, expose OpenAI-compatible schemas, dispatch calls.
"""

from dataclasses import dataclass, field
from typing import Callable, Any, Optional


@dataclass
class ToolEntry:
    name: str
    description: str
    parameters: dict
    handler: Callable
    category: str = "general"


class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, ToolEntry] = {}

    def register(self, name: str, description: str, parameters: dict,
                 handler: Callable, category: str = "general"):
        self._tools[name] = ToolEntry(
            name=name,
            description=description,
            parameters=parameters,
            handler=handler,
            category=category,
        )

    def get_schemas(self, categories: Optional[list[str]] = None) -> list[dict]:
        """Return OpenAI-compatible tool schemas."""
        tools = self._tools.values()
        if categories:
            tools = [t for t in tools if t.category in categories]
        return [
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                },
            }
            for t in tools
        ]

    def get_handlers(self) -> dict[str, Callable]:
        return {name: entry.handler for name, entry in self._tools.items()}

    def execute(self, name: str, args: dict) -> str:
        entry = self._tools.get(name)
        if not entry:
            return f"Error: unknown tool '{name}'"
        try:
            result = entry.handler(**args)
            # Truncate large outputs
            result_str = str(result)
            if len(result_str) > 50000:
                result_str = result_str[:50000] + "\n... [truncated]"
            return result_str
        except Exception as e:
            return f"Error executing {name}: {e}"


# Global singleton
registry = ToolRegistry()
