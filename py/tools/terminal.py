"""
Terminal tool (Chapter 4)

Execute shell commands with timeout and output truncation.
"""

import subprocess
from py.tool_registry import registry


def run_terminal(command: str, timeout: int = 30) -> str:
    """Execute a shell command and return stdout + stderr."""
    try:
        result = subprocess.run(
            command, shell=True, capture_output=True,
            text=True, timeout=timeout,
            cwd=None,  # uses current working directory
        )
        output = result.stdout + result.stderr
        return output.strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return f"Error: command timed out after {timeout}s"
    except Exception as e:
        return f"Error: {e}"


registry.register(
    name="terminal",
    description=(
        "Run a shell command. Use for file operations, git, builds, "
        "system inspection, etc. Returns stdout and stderr combined."
    ),
    parameters={
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "Shell command to execute",
            },
            "timeout": {
                "type": "integer",
                "description": "Timeout in seconds (default: 30)",
                "default": 30,
            },
        },
        "required": ["command"],
    },
    handler=run_terminal,
    category="execution",
)
