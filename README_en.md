# Z-Hermes

An AI Agent project built with Zig 0.16, derived from the hermes project.
Features persistent memory, self-improving skills, tool calling, and context compression.

## Project Structure

```
z-hermes/
├── build.zig                  # Build configuration (links SQLite3)
├── build.zig.zon              # Package management configuration
├── config.ymal                # Runtime configuration file
├── src/
│   ├── main.zig               # Program entry point, interactive REPL main loop
│   ├── config.zig             # Configuration file loading and parsing
│   ├── agent.zig              # AI agent core logic (message loop, tool calling)
│   ├── llm_client.zig         # LLM API client (HTTP communication, JSON serialization)
│   ├── tool_calling.zig       # Tool calling strategy (structured/text parsing)
│   ├── tool_registry.zig      # Tool registry
│   ├── prompt_builder.zig     # System prompt builder
│   ├── prompt_caching.zig     # Prompt cache (reserved interface)
│   ├── compression.zig        # Context compressor (middle-out algorithm)
│   ├── memory/
│   │   ├── persistent.zig     # Persistent memory (MEMORY.md + USER.md)
│   │   ├── session_db.zig     # SQLite + FTS5 session database
│   │   └── recall.zig         # Cross-session search and LLM summarization
│   ├── skills/
│   │   ├── loader.zig         # Skill file loader (parses SKILL.md)
│   │   └── manager.zig        # Skill management (create/modify/delete)
│   └── tools/
│       ├── terminal.zig       # Shell command execution tool
│       ├── file_tools.zig     # File read/write tools
│       └── memory_tool.zig    # Memory operation tools
|
├── data/                      # Runtime data directory (auto-created)
│   ├── state.db               # SQLite session database
│   ├── MEMORY.md              # AI observation records
│   ├── USER.md                # User profile
│   └── skills/                # Skill file directory
└── zig-out/bin/z-hermes       # Compiled output
```

## Core Features

### 1. AI Agent
- Manages conversation message history, calls LLM for responses
- Supports multi-turn tool calling loop (max iterations configurable)
- Automatically persists messages to SQLite database
- Configurable memory nudge and skill nudge intervals

### 2. Persistent Memory
- Saves AI observation records to `MEMORY.md` file
- Saves user profile to `USER.md` file
- Automatically evicts oldest records when limits are exceeded
- Maintains memory continuity across sessions

### 3. Session Database (Session DB)
- Uses SQLite to store session metadata and message records
- Supports FTS5 full-text search for quick history lookup
- Automatically builds search indexes for user and assistant messages

### 4. Session Recall
- Finds relevant historical sessions via full-text search
- Uses LLM to generate summaries related to current topics
- Enables AI to "recall" past conversation content

### 5. Tool Calling
- **Structured Strategy**: Suitable for models supporting OpenAI-style function calling (qwen, mistral, hermes, etc.)
- **Text Parsing Strategy**: Suitable for models not supporting structured calling, parses tool calls from text
- Automatically selects appropriate strategy based on model name

### 6. Built-in Tools
- `terminal`: Execute shell commands
- `read_file`: Read file contents
- `write_file`: Write to file (auto-creates parent directories)
- `memory`: Memory operations (save/read/search)
- `skills_list`: List all skills
- `skill_view`: View skill details
- `skill_manage`: Manage skills (create/modify/delete)

### 7. Skills System
- Skills stored as SKILL.md files, supporting YAML frontmatter
- Supports creating, viewing, partial modification (patch), full rewrite (edit), and deletion
- Skill content automatically injected into system prompt

### 8. Context Compression
- Automatically triggers compression when conversation history exceeds limits
- Preserves head critical messages + LLM-generated intermediate summary + tail recent messages
- Configurable threshold (default 50% context window)

## Configuration

Edit `config.json` file:

```yaml
# Z-Hermes Configuration File
# Restart program after changes to take effect

model:
  api_key: "lm-studio"
  base_url: "http://localhost:1234/v1"
  model: "qwen3.5-35b-a3b"
  max_tokens: 400

agent:
  max_iterations: 15

learning:
  memory_nudge_interval: 5
  skill_nudge_interval: 8

aux_model:
  max_tokens: 300
```

| Configuration Item | Description | Default Value |
|--------------------|-------------|---------------|
| `model.api_key` | LLM API Key | `sk-no-key-required` |
| `model.base_url` | LLM API Base URL | `http://localhost:1234/v1` |
| `model.model` | Model Name | `qwen2.5-7b-instruct` |
| `model.max_tokens` | Maximum Generation Tokens | 400 |
| `agent.max_iterations` | Agent Max Iterations | 15 |
| `learning.memory_nudge_interval` | Memory Nudge Interval (rounds) | 5 |
| `learning.skill_nudge_interval` | Skill Nudge Interval (rounds) | 8 |
| `aux_model.max_tokens` | Aux Model Max Tokens | 300 |

## Build & Run

### Install Zig Environment

This project uses the [Zig](https://ziglang.org/) programming language. Before building, ensure Zig 0.16 or higher is installed.

#### Installation Steps

1. **Visit Zig Official Download Page**: [https://ziglang.org/download/](https://ziglang.org/download/)

2. **Download Precompiled Binary for Your OS**:
   - **Linux**: `zig-linux-x86_64-0.16.0.tar.xz`
   - **macOS**: `zig-macos-x86_64-0.16.0.tar.xz` or `zig-macos-aarch64-0.16.0.tar.xz` (Apple Silicon)
   - **Windows**: `zig-windows-x86_64-0.16.0.zip`

3. **Extract and Add to PATH**:

   **Linux/macOS**:
   ```bash
   tar xf zig-linux-x86_64-0.16.0.tar.xz
   sudo mv zig-linux-x86_64-0.16.0 /opt/zig
   export PATH="/opt/zig:$PATH"
   # Recommended to add export command to ~/.bashrc or ~/.zshrc
   ```

   **Windows**:
   - Extract ZIP file to `C:\zig`
   - Add `C:\zig` to system environment variable PATH

4. **Verify Installation**:
   ```bash
   zig version
   # Should output something like: 0.16.0
   ```

#### Alternative Installation Methods

- **Using Package Manager** (Recommended for Linux distributions):
  ```bash
  # Arch Linux
  sudo pacman -S zig

  # Fedora
  sudo dnf install zig

  # macOS (using Homebrew)
  brew install zig
  ```

- **Build from Source**: See [Zig Official Repository](https://github.com/ziglang/zig)

### Prerequisites
- Zig 0.16+
- SQLite3 (development library)

### Build

```bash
zig build
```

### Run

```bash
zig build run
# Or run the compiled binary directly
./zig-out/bin/z-hermes
```

### Interactive Commands

| Command | Description |
|---------|-------------|
| Direct text input | Chat with AI |
| `/mem` | View persistent memory and user profile |
| `/skills` | List all loaded skills |
| `/sessions` | Search historical sessions |
| `exit` / `quit` | Exit program |

## LLM Service Configuration

This project is compatible with any OpenAI API-format LLM service. Recommended options:

- **LM Studio**: Local model serving, default port 1234
- **Ollama**: Local model serving, requires OpenAI-compatible endpoint setup
- **OpenAI API**: Set `base_url` to `https://api.openai.com/v1`

After starting a local LLM service, modify `base_url` and `model` in `config.json` to use.

## Technical Architecture

```
User Input → Agent.run()
              ├── Add user message to history
              ├── Call LLM (LlmClient.chatCompletion)
              │     └── If compression needed → ContextCompressor.maybeCompress()
              ├── Parse response (ToolCallingStrategy.parseResponse)
              ├── If tool call → Execute tool → Add result to history → Continue loop
              └── Return final text response
```
