# Claudebot - Discord Bot Brain Plugin

## Overview

Claudebot turns a Claude Code session into a Discord bot brain. A runner script (`scripts/run-bot.sh`) orchestrates the full lifecycle: starts the MCP server, starts a Claude Code session, and polls for Discord messages. Agents interact with Discord directly via MCP tools — sending messages, adding reactions, showing typing indicators, and more.

## Architecture

Messages flow through a pipeline:
1. **Incoming message** arrives via MCP poll (runner pipes Discord messages as JSON user prompts)
2. **Triage agent** (haiku) evaluates: ignore, respond, react, or act — sends typing indicator when engaging
3. **Responder agent** (sonnet) crafts personality-driven replies and sends them directly to Discord via MCP tools, OR **researcher/executor agents** (sonnet) handle tool-based actions and send results directly
4. **PreCompact hook** fires before context compression, triggering memory-manager (opus) to save the context graph, then personality-evolver (haiku) to absorb a chat participant's trait

## Key Components

- **Skill**: `discord-bot` - Core behavior guide loaded for every session
- **Agents**: triage, responder, researcher, executor, memory-manager, personality-evolver
- **MCP Server**: `claudebot-mcp` - Go HTTP server providing Discord I/O tools (separate process, must be running)
- **Hook**: PreCompact prompt-based hook for memory preservation
- **Command**: `/bot-setup` for configuration
- **Runner**: `scripts/run-bot.sh` - Orchestrates MCP server + Claude Code session + message polling
- **Settings**: `.claude/claudebot.local.md` for per-project config

## Memory System

Memory files live in `.claude/memory/` in the project root:
- `personality.md` - Evolving bot personality (starts blank, grows by absorbing user traits)
- `users.md` - Known user profiles and communication styles
- `topics.md` - Discussion topic tracking
- `relationships.md` - User-user, user-topic, topic-topic connections
- `action-items.md` - Open and completed action items

## Channel Configuration

Per-channel tool permissions and response thresholds are configured in `.claude/claudebot.local.md`. The triage agent reads this to determine what tools are available and how eagerly to respond in each channel.

## MCP Tools

Agents interact with Discord via MCP tools provided by the `claudebot-mcp` server. Key tools:
- `discord_send_message` - Send messages (with optional `reply_to` for threading)
- `discord_get_messages` - Read recent channel history for context
- `discord_typing` - Show typing indicator while processing
- `discord_add_reaction` - React to messages (lightweight engagement)
- `discord_edit_message` - Update previously sent messages
- `discord_get_channels` / `discord_get_guild` - Discovery (used by bot-setup)

Full tool prefix: `mcp__plugin_claudebot_discord__<tool_name>`

## Conventions

- Memory files are updated ONLY during PreCompact (not on every message)
- Personality evolves gradually - small trait additions, never full rewrites
- The triage agent runs for EVERY incoming message
- Agents send responses directly to Discord via MCP tools (not by returning text)
- Responses should be Discord-appropriate (markdown, reasonable length)
- Channel tool permissions MUST be respected by executor agent
