# Z-Hermes

基于 Zig 0.16 的 AI Agent 项目，从mini-hermes项目(python)迁移而来。
具备持久化记忆、自我改进技能、工具调用和上下文压缩等功能。

## 项目结构

```
z-hermes/
├── build.zig                  # 构建配置（链接SQLite3）
├── build.zig.zon              # 包管理配置
├── config.ymal                # 运行时配置文件
├── src/
│   ├── main.zig               # 程序入口，交互式REPL主循环
│   ├── config.zig             # 配置文件加载与解析
│   ├── agent.zig              # AI代理核心逻辑（消息循环、工具调用）
│   ├── llm_client.zig         # LLM API客户端（HTTP通信、JSON序列化）
│   ├── tool_calling.zig       # 工具调用策略（结构化/文本解析）
│   ├── tool_registry.zig      # 工具注册表
│   ├── prompt_builder.zig     # 系统提示词构建器
│   ├── prompt_caching.zig     # 提示词缓存（预留接口）
│   ├── compression.zig        # 上下文压缩器（middle-out算法）
│   ├── memory/
│   │   ├── persistent.zig     # 持久化记忆（MEMORY.md + USER.md）
│   │   ├── session_db.zig     # SQLite + FTS5 会话数据库
│   │   └── recall.zig         # 跨会话搜索与LLM摘要
│   ├── skills/
│   │   ├── loader.zig         # 技能文件加载器（解析SKILL.md）
│   │   └── manager.zig        # 技能管理（创建/修改/删除）
│   └── tools/
│       ├── terminal.zig       # Shell命令执行工具
│       ├── file_tools.zig     # 文件读写工具
│       └── memory_tool.zig    # 记忆操作工具
|
├── data/                      # 运行时数据目录（自动创建）
│   ├── state.db               # SQLite会话数据库
│   ├── MEMORY.md              # AI观察记录
│   ├── USER.md                # 用户画像
│   └── skills/                # 技能文件目录
└── zig-out/bin/z-hermes       # 编译输出
```

## 核心功能

### 1. AI代理 (Agent)
- 管理对话消息历史，调用LLM获取回复
- 支持多轮工具调用循环（最大迭代次数可配置）
- 自动持久化消息到SQLite数据库
- 可配置的记忆提醒和技能提醒间隔

### 2. 持久化记忆 (Persistent Memory)
- 将AI的观察记录保存到 `MEMORY.md` 文件
- 将用户画像保存到 `USER.md` 文件
- 超出限制时自动淘汰最早的记录
- 跨会话保持记忆连续性

### 3. 会话数据库 (Session DB)
- 使用SQLite存储会话元数据和消息记录
- 支持FTS5全文搜索，快速查找历史对话
- 自动为用户和助手消息建立搜索索引

### 4. 会话回忆 (Session Recall)
- 通过全文搜索找到相关的历史会话
- 使用LLM生成与当前话题相关的摘要
- 让AI能够"回忆"过去的对话内容

### 5. 工具调用 (Tool Calling)
- **结构化策略**：适用于支持OpenAI风格函数调用的模型（qwen、mistral、hermes等）
- **文本解析策略**：适用于不支持结构化调用的模型，从文本中解析工具调用
- 根据模型名称自动选择合适的策略

### 6. 内置工具
- `terminal`：执行Shell命令
- `read_file`：读取文件内容
- `write_file`：写入文件（自动创建父目录）
- `memory`：记忆操作（保存/读取/搜索）
- `skills_list`：列出所有技能
- `skill_view`：查看技能详情
- `skill_manage`：管理技能（创建/修改/删除）

### 7. 技能系统 (Skills)
- 技能以SKILL.md文件存储，支持YAML前置元数据
- 支持创建、查看、局部修改(patch)、完全重写(edit)和删除
- 技能内容自动注入系统提示词

### 8. 上下文压缩 (Compression)
- 当对话历史过长时自动触发压缩
- 保留头部关键消息 + LLM生成的中间摘要 + 尾部近期消息
- 阈值可配置（默认50%上下文窗口）

## 配置说明

编辑 `config.json` 文件：

```yaml
# Z-Hermes 配置文件
# 修改后重启程序生效

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

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `model.api_key` | LLM API密钥 | `sk-no-key-required` |
| `model.base_url` | LLM API基础URL | `http://localhost:1234/v1` |
| `model.model` | 模型名称 | `qwen2.5-7b-instruct` |
| `model.max_tokens` | 最大生成token数 | 400 |
| `agent.max_iterations` | 代理最大迭代次数 | 15 |
| `learning.memory_nudge_interval` | 记忆提醒间隔（轮次） | 5 |
| `learning.skill_nudge_interval` | 技能提醒间隔（轮次） | 8 |
| `aux_model.max_tokens` | 辅助模型最大token数 | 300 |

## 构建与运行

### 前置依赖
- Zig 0.16
- SQLite3

### 构建

```bash
zig build
```

### 运行

```bash
zig build run
# 或直接运行编译产物
./zig-out/bin/z-hermes
```

### 交互命令

| 命令 | 说明 |
|------|------|
| 直接输入文本 | 与AI对话 |
| `/mem` | 查看持久化记忆和用户画像 |
| `/skills` | 列出所有已加载的技能 |
| `/sessions` | 搜索历史会话 |
| `exit` / `quit` | 退出程序 |

## LLM服务配置

本项目兼容任何OpenAI API格式的LLM服务，推荐使用：

- **LM Studio**：本地运行模型，默认端口1234
- **Ollama**：本地运行模型，需设置OpenAI兼容端点
- **OpenAI API**：设置 `base_url` 为 `https://api.openai.com/v1`

启动本地LLM服务后，修改 `config.json` 中的 `base_url` 和 `model` 即可使用。

## 技术架构

```
用户输入 → Agent.run()
              ├── 添加用户消息到历史
              ├── 调用LLM (LlmClient.chatCompletion)
              │     └── 如需压缩 → ContextCompressor.maybeCompress()
              ├── 解析回复 (ToolCallingStrategy.parseResponse)
              ├── 如有工具调用 → 执行工具 → 添加结果到历史 → 继续循环
              └── 返回最终文本回复
```
