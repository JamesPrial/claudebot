# Claudebot - Discord Bot Brain Plugin

## Overview

Claudebot turns a Claude Code session into a Discord bot brain. An external Discord bot pipes messages in as prompts. This plugin provides the decision-making framework, personality system, and persistent memory that make the bot intelligent and evolving.

## Architecture

Messages flow through a pipeline:
1. **Incoming message** arrives as a user prompt from the external Discord bot
2. **Triage agent** (haiku) evaluates: ignore, respond, or act
3. **Responder agent** (sonnet) crafts personality-driven replies OR **researcher/executor agents** (sonnet) handle tool-based actions
4. **PreCompact hook** fires before context compression, triggering memory-manager (opus) to save the context graph, then personality-evolver (haiku) to absorb a chat participant's trait

## Key Components

- **Skill**: `discord-bot` - Core behavior guide loaded for every session
- **Agents**: triage, responder, researcher, executor, memory-manager, personality-evolver
- **Hook**: PreCompact prompt-based hook for memory preservation
- **Command**: `/bot-setup` for configuration
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

## Conventions

- Memory files are updated ONLY during PreCompact (not on every message)
- Personality evolves gradually - small trait additions, never full rewrites
- The triage agent runs for EVERY incoming message
- Responses should be Discord-appropriate (markdown, reasonable length)
- Channel tool permissions MUST be respected by executor agent
