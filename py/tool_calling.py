"""
Tool-Calling Strategies (Chapter 3b)

Two strategies for tool calling depending on model capabilities:
- StructuredStrategy: for models with native function-calling (Qwen, Mistral, etc.)
- TextStrategy: for models that emit tool calls as text (Gemma, LLaMA, etc.)

The agent delegates three decisions to the strategy:
  1. How to present tools to the model (API param vs. system prompt text)
  2. How to parse tool calls from the response
  3. How to feed tool results back into the conversation
"""

import json
import re
import uuid
import logging

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Parsed tool call — uniform type both strategies produce
# ---------------------------------------------------------------------------

class ParsedToolCall:
    """A tool call extracted from a model response, regardless of format."""
    __slots__ = ("id", "name", "arguments")

    def __init__(self, name: str, arguments: dict, call_id: str = None):
        self.id = call_id or f"call_{uuid.uuid4().hex[:8]}"
        self.name = name
        self.arguments = arguments


# ---------------------------------------------------------------------------
# Base
# ---------------------------------------------------------------------------

class ToolCallingStrategy:
    """Interface that the Agent delegates to."""

    def prepare_kwargs(self, kwargs: dict, tools: list[dict]) -> dict:
        """Modify the chat-completion kwargs before the API call."""
        raise NotImplementedError

    def parse_response(self, msg) -> tuple[str, list[ParsedToolCall]]:
        """Return (text_content, [parsed_tool_calls])."""
        raise NotImplementedError

    def build_assistant_msg(self, content: str,
                            tool_calls: list[ParsedToolCall]) -> dict:
        """Build the assistant message to append to history."""
        raise NotImplementedError

    def build_tool_result_msg(self, call: ParsedToolCall,
                              result: str) -> dict:
        """Build the message that carries a tool result back to the model."""
        raise NotImplementedError


# ---------------------------------------------------------------------------
# Strategy 1: Structured (OpenAI-compatible function calling)
# ---------------------------------------------------------------------------

class StructuredStrategy(ToolCallingStrategy):
    """For models that support the `tools` API parameter."""

    def prepare_kwargs(self, kwargs, tools):
        if tools:
            kwargs["tools"] = tools
            kwargs["tool_choice"] = "auto"
        return kwargs

    def parse_response(self, msg):
        content = msg.content or ""
        raw_calls = getattr(msg, "tool_calls", None)
        if not raw_calls:
            return content, []
        parsed = [
            ParsedToolCall(
                name=tc.function.name,
                arguments=json.loads(tc.function.arguments)
                if tc.function.arguments else {},
                call_id=tc.id,
            )
            for tc in raw_calls
        ]
        return content, parsed

    def build_assistant_msg(self, content, tool_calls):
        msg = {"role": "assistant", "content": content}
        if tool_calls:
            msg["tool_calls"] = [
                {"id": tc.id, "type": "function",
                 "function": {"name": tc.name,
                              "arguments": json.dumps(tc.arguments)}}
                for tc in tool_calls
            ]
        return msg

    def build_tool_result_msg(self, call, result):
        return {
            "role": "tool",
            "tool_call_id": call.id,
            "content": result,
        }


# ---------------------------------------------------------------------------
# Strategy 2: Text-based (parse tool calls from model output)
# ---------------------------------------------------------------------------

# Patterns we try, in order.  Covers Gemma, LLaMA, ChatML, and generic JSON.
_TOOL_CALL_PATTERNS = [
    # <tool_call>{"name": "...", "arguments": {...}}</tool_call>  (and variants)
    re.compile(
        r"<\|?tool_call\|?>(.+?)<\|?/?tool_call\|?>",
        re.DOTALL,
    ),
    # ```tool_call\n{...}\n```
    re.compile(
        r"```(?:tool_call|json)?\s*\n?({.+?})\s*\n?```",
        re.DOTALL,
    ),
    # Bare JSON object with "name" key on its own line
    re.compile(
        r'(\{[^{}]*"name"\s*:.+?\})',
        re.DOTALL,
    ),
]

# For the call:name{json} format some models use
_CALL_COLON_PATTERN = re.compile(
    r"call:(\w+)\{(.+?)\}", re.DOTALL
)


def _parse_tool_json(raw: str) -> list[ParsedToolCall]:
    """Try to parse one or more tool calls from a raw string."""
    raw = raw.strip()

    # Handle call:name{args} format
    m = _CALL_COLON_PATTERN.search(raw)
    if m:
        name = m.group(1)
        try:
            # Unescape weird model quoting like <|"|>
            args_str = m.group(2).replace('<|"|>', '"')
            args = json.loads(args_str)
        except json.JSONDecodeError:
            args = {"raw": m.group(2)}
        return [ParsedToolCall(name=name, arguments=args)]

    # Try as JSON
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return []

    # Single call: {"name": "...", "arguments": {...}}
    if isinstance(obj, dict) and "name" in obj:
        args = obj.get("arguments", obj.get("args", obj.get("parameters", {})))
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {"raw": args}
        return [ParsedToolCall(name=obj["name"], arguments=args)]

    # Array of calls
    if isinstance(obj, list):
        calls = []
        for item in obj:
            if isinstance(item, dict) and "name" in item:
                args = item.get("arguments", item.get("args", {}))
                calls.append(ParsedToolCall(name=item["name"], arguments=args))
        return calls

    return []


def _format_tools_as_text(tools: list[dict]) -> str:
    """Render tool schemas as plain-text instructions for the system prompt."""
    lines = ["## Available Tools",
             "Call tools by responding with a JSON block inside <tool_call> tags:",
             '<tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}</tool_call>',
             "",
             "You may call multiple tools by using multiple <tool_call> blocks.",
             "After each tool call, you will receive the result and can continue.",
             "",
             "Tools:"]
    for t in tools:
        fn = t.get("function", t)
        name = fn["name"]
        desc = fn.get("description", "")
        params = fn.get("parameters", {})
        props = params.get("properties", {})
        required = params.get("required", [])

        param_parts = []
        for pname, pdef in props.items():
            req = " (required)" if pname in required else ""
            ptype = pdef.get("type", "string")
            pdesc = pdef.get("description", "")
            param_parts.append(f"    - {pname} ({ptype}{req}): {pdesc}")

        lines.append(f"\n### {name}")
        lines.append(f"{desc}")
        if param_parts:
            lines.append("  Parameters:")
            lines.extend(param_parts)

    return "\n".join(lines)


class TextStrategy(ToolCallingStrategy):
    """For models that emit tool calls as text (Gemma, LLaMA, etc.)."""

    def __init__(self):
        self._tools_text: str = ""

    def prepare_kwargs(self, kwargs, tools):
        # Don't pass tools param — model doesn't support it.
        # Instead, inject tool descriptions into the system message.
        if tools and not self._tools_text:
            self._tools_text = _format_tools_as_text(tools)
        if self._tools_text:
            msgs = kwargs.get("messages", [])
            if msgs and msgs[0]["role"] == "system":
                msgs = list(msgs)  # don't mutate original
                msgs[0] = dict(msgs[0])
                msgs[0]["content"] = msgs[0]["content"] + "\n\n" + self._tools_text
                kwargs["messages"] = msgs
        return kwargs

    def parse_response(self, msg):
        content = msg.content or ""

        # Try each regex pattern
        for pattern in _TOOL_CALL_PATTERNS:
            matches = pattern.findall(content)
            if matches:
                calls = []
                for match in matches:
                    calls.extend(_parse_tool_json(match))
                if calls:
                    # Strip tool-call markup from the visible content
                    clean = pattern.sub("", content).strip()
                    return clean, calls

        return content, []

    def build_assistant_msg(self, content, tool_calls):
        # Store full content including tool-call text so the model
        # sees its own output format in conversation history
        return {"role": "assistant", "content": content}

    def build_tool_result_msg(self, call, result):
        # Text-based models don't understand role="tool", so we use
        # a user message with clear formatting
        return {
            "role": "user",
            "content": f"[Tool Result: {call.name}]\n{result}",
        }


# ---------------------------------------------------------------------------
# Factory: pick strategy based on model name
# ---------------------------------------------------------------------------

# Models known to support structured function calling
_STRUCTURED_MODELS = {
    "qwen", "mistral", "hermes", "functionary", "firefunction",
    "gorilla", "nexusraven", "command-r",
}


def strategy_for_model(model_name: str) -> ToolCallingStrategy:
    """Return the right strategy based on model name heuristics."""
    name_lower = model_name.lower()
    for keyword in _STRUCTURED_MODELS:
        if keyword in name_lower:
            return StructuredStrategy()
    # Default: text-based (safer — works with any model)
    return TextStrategy()
