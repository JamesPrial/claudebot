# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Claudebot is a Claude Code **plugin** that turns a Claude Code session into a Discord bot brain. There is no build/lint/test — the codebase is markdown agent definitions, shell scripts, and JSON config consumed by Claude Code's plugin system.

## Running the Bot

```bash
# Full lifecycle (starts Claude Code session with Docker MCP server, polls Discord)
./scripts/run-bot.sh
```

**Prerequisites:** Docker installed and running.

Required env vars (set in `.env` or export): `CLAUDEBOT_DISCORD_TOKEN`, `CLAUDEBOT_DISCORD_GUILD_ID`. See `.env.example` for all options.

The MCP server (`claudebot-mcp`) runs as a Docker container pulled from `ghcr.io/jamesprial/claudebot-mcp:latest` via `.mcp.json` (stdio transport). The runner pre-pulls the image at startup, then uses repeated `claude -p --resume` calls to maintain a persistent session across poll cycles.

## Setup & Config

```
/claudebot:bot-setup              # Interactive setup wizard
/claudebot:bot-setup show-status  # Check MCP connectivity
/claudebot:bot-setup show-config  # Show current channel config
```

Per-project settings live in `.claude/claudebot.local.md` (YAML frontmatter for channel tools/thresholds, markdown body for personality seed and instructions). Template at `templates/claudebot.local.md`.

## Architecture

Messages flow through a pipeline:
1. **Runner** (`scripts/run-bot.sh`) sends periodic poll prompts via `claude -p --resume`, maintaining a persistent session; Claude Code polls Discord via MCP tools
2. **Triage agent** (haiku) evaluates every message: ignore, react, respond, or act — sends typing indicator when engaging
3. **Downstream agent** handles the routed action:
   - `responder` (sonnet) — personality-driven replies
   - `researcher` (sonnet) — web search, file lookups
   - `executor` (sonnet) — tool-based actions (Bash, file ops)
   - `screamer` (sonnet) — voice channel screams via Docker
4. **PreCompact hook** fires before context compression, dispatching `memory-manager` (opus) then `personality-evolver` (haiku)

All agents send responses **directly to Discord via MCP tools** — they don't return text to be relayed.

## Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata |
| Skill | `skills/discord-bot/SKILL.md` | Core behavior guide loaded every session |
| Agents | `agents/*.md` | triage, responder, researcher, executor, screamer, memory-manager, personality-evolver |
| Hook | `hooks/hooks.json` | PreCompact prompt-based hook for memory preservation |
| Command | `commands/bot-setup.md` | `/bot-setup` configuration wizard |
| MCP config | `.mcp.json` | Docker stdio connection to claudebot-mcp |
| Settings template | `templates/claudebot.local.md` | Per-project config template |
| Memory templates | `templates/memory/*.md` | Initial blank memory files |
| Reference docs | `skills/discord-bot/references/` | Memory schema and decision framework |

## Memory System

Memory files live in `.claude/memory/` in the project being botted (not this plugin repo):
- `personality.md` — Evolving bot personality (starts blank, grows by absorbing user traits)
- `users.md`, `topics.md`, `relationships.md`, `action-items.md` — Full context graph

**Critical rule:** Memory files are updated ONLY during PreCompact (by memory-manager and personality-evolver agents), never during normal message processing. Agents READ memory for context but do NOT write to it mid-conversation.

## Voice (go-scream)

The bot can play synthetic screams in Discord voice channels via the `screamer` agent. go-scream runs as a Docker container (`ghcr.io/jamesprial/go-scream:latest`) invoked with `docker run --network host`. The bot token (`CLAUDEBOT_DISCORD_TOKEN`) is passed as `DISCORD_TOKEN` to the container. The guild ID comes from `CLAUDEBOT_DISCORD_GUILD_ID`. Voice channel IDs are resolved at runtime via `discord_get_channels`.

Available presets: classic, whisper, death-metal, glitch, banshee, robot.

`Scream` must be listed in the channel's tools configuration in `.claude/claudebot.local.md` for the triage agent to route scream requests.

## MCP Tools

All tools prefixed with `mcp__plugin_claudebot_discord__`. Key tools: `discord_poll_messages` (primary message intake), `discord_send_message` (with `reply_to` for threading), `discord_get_messages`, `discord_typing`, `discord_add_reaction`, `discord_edit_message`, `discord_get_channels`, `discord_get_guild`.

## Conventions

- Agents send responses directly to Discord via MCP tools (not by returning text)
- Personality evolves gradually — small trait additions per PreCompact cycle, never full rewrites
- The triage agent runs for EVERY incoming message, even obvious ignores
- Channel tool permissions from `.claude/claudebot.local.md` MUST be respected by executor
- Voice screams are played via Docker (go-scream image), not by directly executing a binary
- The screamer agent uses `--network host` for Docker to support Discord voice UDP
- Responses should be Discord-appropriate (markdown, under 2000 chars)
- The runner uses repeated `claude -p --resume` calls; each poll is a separate invocation that resumes the same session
