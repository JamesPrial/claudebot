# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Claudebot is a Claude Code **plugin** that turns a Claude Code session into a Discord bot brain. There is no build/lint/test — the codebase is markdown agent definitions, shell scripts, and JSON config consumed by Claude Code's plugin system.

## Running the Bot

```bash
# Local foreground (default instance)
python3 ./scripts/run_bot.py

# Named instance (for multi-instance setups)
python3 ./scripts/run_bot.py --instance main

# With explicit env file
python3 ./scripts/run_bot.py --instance main --env-file /etc/claudebot/main.env
```

**Prerequisites:** Docker installed and running.

Required env vars (set in `.env` or export): `CLAUDEBOT_DISCORD_TOKEN` (raw token — do NOT include `Bot ` prefix, the MCP server adds it automatically), `CLAUDEBOT_DISCORD_GUILD_ID`. Optional: `CLAUDEBOT_MCP_PORT` (default 8080, must be unique per instance), `CLAUDEBOT_DOCKER_PLATFORM` (omit for auto-detect). See `.env.example` for all options.

The MCP server (`claudebot-mcp`) runs as a **persistent Docker daemon** pulled from `ghcr.io/jamesprial/claudebot-mcp:latest` with HTTP transport on port 8080. The daemon maintains the Discord gateway connection continuously, keeping the bot always-online. The runner starts the daemon before the poll loop, then uses repeated `claude -p --resume` calls to maintain a persistent session across poll cycles.

**Operational files** (gitignored, `{instance}` defaults to `default`):
- `logs/{instance}/bot-YYYYMMDD.log` — Daily log files from the runner
- `logs/{instance}/mcp-YYYYMMDD.log` — MCP daemon container output (streamed continuously)
- `logs/{instance}/scream-YYYYMMDD.log` — go-scream invocation output (appended per scream)
- `.bot-session-{instance}.id` — Persisted session ID for crash recovery across restarts
- `.mcp.runtime-{instance}.json` — Generated at startup with the daemon's HTTP URL
- `.claudebot-{instance}.pid` — PID file for status checking

## Setup & Config

```
/claudebot:bot-setup                   # Interactive setup wizard
/claudebot:bot-setup show-status       # Check MCP connectivity
/claudebot:bot-setup show-config       # Show current channel config
/claudebot:bot-setup show-personality  # View personality state
/claudebot:bot-setup reset-personality # Reset to blank personality
```

Per-project settings live in `.claude/claudebot.local.md` (YAML frontmatter for channel tools/thresholds, markdown body for personality seed and instructions). Template at `templates/claudebot.local.md`.

## Architecture

Messages flow through a pipeline:
1. **Runner** (`scripts/run_bot.py`) starts the MCP daemon container, then sends periodic poll prompts via `claude -p --resume`, maintaining a persistent session; Claude Code polls Discord via MCP tools over HTTP
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
| MCP config | `.mcp.json` | HTTP connection to claudebot-mcp daemon |
| Settings template | `templates/claudebot.local.md` | Per-project config template |
| Memory templates | `templates/memory/*.md` | Initial blank memory files |
| Reference docs | `skills/discord-bot/references/` | Memory schema and decision framework |
| Systemd unit | `systemd/claudebot@.service` | Template unit for daemon deployment |
| Instance env template | `configs/example.env` | Per-instance env file template |
| Management CLI | `scripts/claudebot-ctl` | systemctl wrapper for instance management |

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

## Logging

Structured key=value logging with level filtering across all components.

**Format:** `2026-02-20T14:30:00 level=INFO component=run-bot msg="Starting poll loop" interval=30s`

**Levels:** `DEBUG` < `INFO` < `WARN` < `ERROR` (default: `INFO`)

**Configuration:**
- Global: `CLAUDEBOT_LOG_LEVEL` env var (set in `.env` or export)
- Per-component: `logging` key in `.claude/claudebot.local.md` YAML (e.g., `logging: { triage: DEBUG }`)
- Per-component overrides take precedence over the global level

**Two logging mechanisms:**
- **Direct** (Bash-capable agents: executor, screamer): Source `scripts/log-lib.sh`, call `log_info`/`log_error`/`log_debug`/`log_warn`
- **Relay** (non-Bash agents: triage, responder, researcher, memory-manager, personality-evolver): Include `LOG:` section in agent output; the orchestrating session relays qualifying entries to the log file via Bash

**Libraries:**
- `scripts/log-lib.sh` — sourceable bash library for agents (~45 lines). Set `LOG_COMPONENT` before sourcing. Writes to stderr and appends to `logs/bot-YYYYMMDD.log` if `CLAUDEBOT_PLUGIN_DIR` is set.
- `scripts/log_lib.py` — Python logging library used by `run_bot.py`. Same output format. Use `get_logger(component)` or CLI: `python3 log_lib.py <component> <level> <msg> [key=val ...]`

## Daemon Deployment (systemd)

For persistent Linux server deployment with auto-restart and boot persistence.

**Initial setup:**
```bash
sudo claudebot-ctl install            # Install unit file, create /etc/claudebot/ and /var/log/claudebot/
sudo claudebot-ctl add-instance main  # Create /etc/claudebot/main.env from template
sudo vim /etc/claudebot/main.env      # Set token, guild ID, port
sudo claudebot-ctl start main         # Start the instance
sudo claudebot-ctl enable main        # Enable boot persistence
```

**Multi-instance:** Each instance gets its own env file (`/etc/claudebot/<name>.env`), Docker container (`claudebot-mcp-<name>`), and log subdirectory. Instances share the same plugin dir and project dir but use different tokens/guilds/ports.

**Management commands:** `claudebot-ctl start|stop|restart|status|logs|enable|disable|list`

**Log locations:**
- systemd output: `/var/log/claudebot/<instance>.log`
- Bot/MCP logs: `logs/<instance>/bot-YYYYMMDD.log`, `logs/<instance>/mcp-YYYYMMDD.log`

**Troubleshooting:**
- `claudebot-ctl status main` — Check if running, see recent output
- `claudebot-ctl logs main -f` — Tail all log files for an instance
- `journalctl -u claudebot@main` — Full systemd journal (if journald is also enabled)

**Note:** `claudebot-ctl install` rewrites paths in the unit file to match the actual install location. The template at `systemd/claudebot@.service` uses placeholder paths (`/opt/claudebot`, `/usr/bin/python3`).

## Conventions

- Agents send responses directly to Discord via MCP tools (not by returning text)
- Personality evolves gradually — small trait additions per PreCompact cycle, never full rewrites
- The triage agent runs for EVERY incoming message, even obvious ignores
- Channel tool permissions from `.claude/claudebot.local.md` MUST be respected by executor
- Voice screams are played via Docker (go-scream image), not by directly executing a binary
- The screamer agent uses `--network host` for Docker to support Discord voice UDP
- Responses should be Discord-appropriate (markdown, under 2000 chars)
- The runner uses repeated `claude -p --resume` calls; each poll is a separate invocation that resumes the same session
- The MCP daemon container runs persistently to maintain Discord presence; the runner starts it on boot and stops it on exit
- Env vars (`CLAUDEBOT_DISCORD_TOKEN`, `CLAUDEBOT_DISCORD_GUILD_ID`) are passed to the MCP daemon container via Docker's `-e` flag in `run_bot.py` — they must be exported in the shell environment, not just in `.env`
- `CLAUDEBOT_PLUGIN_DIR` is exported by `run_bot.py` — agents' Bash commands can use it to locate the plugin directory (e.g., for writing scream logs)
