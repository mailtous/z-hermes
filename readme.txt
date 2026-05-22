Mini-Hermes 项目结构
=====================

根目录文件
----------
agent.py                 # 核心 Agent 循环（消息 -> 工具 -> 响应）
cli.py                  # REPL 交互界面，负责串联所有模块
compression.py           # 上下文压缩（middle-out 算法）
prompt_builder.py        # 构建冻结的系统提示词
prompt_caching.py        # Anthropic 风格的缓存断点
tool_calling.py          # 工具调用策略模式
tool_registry.py         # 全局工具注册表
requirements.txt         # Python 依赖
setup.sh                 # 安装脚本
hermes.sh                # 启动脚本
README.md                # 项目说明文档
.gitignore              # Git 忽略配置

memory/                  # 记忆模块
----------
memory/__init__.py
memory/persistent.py     # 持久化记忆（MEMORY.md + USER.md）
memory/recall.py          # 跨会话搜索与 LLM 摘要
memory/session_db.py      # SQLite + FTS5 情景记忆

skills/                   # 技能模块
----------
skills/__init__.py
skills/loader.py          # 发现和解析 SKILL.md 文件
skills/manager.py         # 运行时创建、编辑、删除技能

tools/                    # 工具模块
----------
tools/__init__.py
tools/terminal.py          # Shell 命令执行
tools/file_tools.py       # 文件读写
tools/memory_tool.py       # 记忆工具（保存观察、更新用户画像）

graphify-out/             # 图谱输出目录（graphify 生成）
----------
graphify-out/cache/       # 提取缓存
graphify-out/graph.html   # 交互式图谱
graphify-out/graph.json   # 图谱数据
graphify-out/GRAPH_REPORT.md  # 审计报告
