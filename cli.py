#!/usr/bin/env python3
"""
Mini-Hermes CLI (Chapter 15)

Terminal interface that wires all components together:
- Frozen system prompt built once at session start
- SQLite + FTS5 session persistence
- Persistent memory (MEMORY.md / USER.md)
- Skill system with progressive disclosure
- Learning loop with nudge counters
"""

import sys
import yaml
import logging
from pathlib import Path
from openai import OpenAI

sys.path.insert(0, str(Path(__file__).parent))

from py.tool_calling import strategy_for_model
from py.tool_registry import registry
from py.agent import Agent
from py.prompt_builder import PromptBuilder
from py.memory.session_db import SessionDB
from py.memory.persistent import PersistentMemory
from py.memory.recall import SessionRecall
from py.skills.loader import SkillLoader
from py.compression import ContextCompressor

import py.tools.terminal
import py.tools.file_tools
import py.tools.memory_tool
import py.skills.manager

import io
logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger("mini-hermes")

_stdin_wrapper = None

def safe_input(prompt=""):
    global _stdin_wrapper
    old_stdin = sys.stdin
    if _stdin_wrapper is None:
        _stdin_wrapper = io.TextIOWrapper(
            sys.stdin.buffer,
            encoding=sys.stdin.encoding or 'utf-8',
            errors='replace'
        )
    try:
        sys.stdin = _stdin_wrapper
        return input(prompt)
    finally:
        sys.stdin = old_stdin


def main():
    config_path = Path(__file__).parent / "config.yaml"
    if not config_path.exists():
        print(f"Error: {config_path} not found")
        sys.exit(1)
    config = yaml.safe_load(config_path.read_text())

    client = OpenAI(
        api_key=config["model"]["api_key"],
        base_url=config["model"]["base_url"],
    )
    model = config["model"]["model"]
    max_tokens = config["model"].get("max_tokens", 400)

    data_dir = Path(__file__).parent / "data"
    data_dir.mkdir(exist_ok=True)
    skills_dir = data_dir / "skills"
    skills_dir.mkdir(exist_ok=True)

    session_db = SessionDB(data_dir / "state.db")
    persistent = PersistentMemory(data_dir)
    skill_loader = SkillLoader(skills_dir)
    recall = SessionRecall(
        session_db, client, model,
        max_tokens=config.get("aux_model", {}).get("max_tokens", 300),
    )

    py.tools.memory_tool.set_memory(persistent, recall)
    py.skills.manager.set_skill_loader(skill_loader, skills_dir)

    builder = PromptBuilder()
    system_prompt = builder.build(
        memory_block=persistent.load(),
        skills_index=skill_loader.build_skills_index(),
    )

    session_id = session_db.create_session(
        source="cli", system_prompt=system_prompt,
    )

    agent = Agent(
        client=client,
        model=model,
        system_prompt=system_prompt,
        tools=registry.get_schemas(),
        max_iterations=config.get("agent", {}).get("max_iterations", 15),
        max_tokens=max_tokens,
    )
    agent.set_handlers(registry.get_handlers())
    agent.session_db = session_db
    agent.session_id = session_id

    learning = config.get("learning", {})
    agent.configure_learning(
        memory_nudge=learning.get("memory_nudge_interval", 5),
        skill_nudge=learning.get("skill_nudge_interval", 8),
    )

    compressor = ContextCompressor(
        client=client, model=model,
        max_context_tokens=32000,
        max_tokens=max_tokens,
    )
    agent.set_compressor(compressor)

    print("╔══════════════════════════════════════╗")
    print("║       Mini-Hermes Agent v0.1         ║")
    print("║  /mem /skills /model /sessions       ║")
    print("║  exit to quit                        ║")
    print("╚══════════════════════════════════════╝")
    print(f"  Model: {model}")
    print(f"  Session: {session_id[:8]}...")
    mem_status = "loaded" if persistent.load() else "empty"
    skill_count = len(skill_loader.load_all())
    print(f"  Memory: {mem_status} | Skills: {skill_count}")
    print()

    while True:
        try:
            user_input = safe_input("\033[1;32myou >\033[0m ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            break

        if not user_input:
            continue

        if user_input.lower() in ("exit", "quit", "/exit", "/quit"):
            print("Goodbye!")
            break

        if user_input == "/mem":
            print("\n\033[1;33m── Memory ──\033[0m")
            print(persistent.read_memory())
            print("\n\033[1;33m── User Profile ──\033[0m")
            print(persistent.read_user())
            print()
            continue

        if user_input == "/skills":
            all_skills = skill_loader.load_all()
            if not all_skills:
                print("No skills yet.\n")
            else:
                print(f"\n\033[1;33m── {len(all_skills)} Skills ──\033[0m")
                for s in all_skills:
                    print(f"  {s['name']}: {s['description'][:60]}")
                print()
            continue

        if user_input == "/model":
            print("\033[2m  fetching models...\033[0m", end="", flush=True)
            try:
                from pick import pick
                models = client.models.list()
                model_ids = [m.id for m in models.data]
            except Exception as e:
                print(f"\r  Error listing models: {e}\n")
                continue
            print("\r" + " " * 40 + "\r", end="")
            options = [f"{mid}  ← active" if mid == agent.model else mid
                       for mid in model_ids]
            try:
                default = model_ids.index(agent.model)
            except ValueError:
                default = 0
            try:
                _, idx = pick(options, "Select model (↑↓ to move, Enter to select, q to cancel):",
                              default_index=default)
                new_model = model_ids[idx]
                agent.model = new_model
                agent._strategy = strategy_for_model(new_model)
                strategy_name = type(agent._strategy).__name__
                print(f"  Switched to \033[1m{new_model}\033[0m ({strategy_name})\n")
            except (KeyboardInterrupt, EOFError):
                print("  Cancelled.\n")
            continue

        if user_input == "/sessions":
            query = safe_input("Search query: ").strip()
            if query:
                result = recall.recall(query)
                print(result if result else "No results.\n")
            continue

        print("\033[2m  thinking...\033[0m", end="", flush=True)
        response = agent.run(user_input)
        print("\r" + " " * 40 + "\r", end="")

        print(f"\033[1;36mhermes >\033[0m {response}\n")

    session_db.end_session(session_id)
    print(f"Session {session_id[:8]} saved.")


if __name__ == "__main__":
    main()
