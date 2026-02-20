# Claudebot

A Claude Code plugin that turns a Claude Code session into a Discord bot brain with intelligent message triage, tool-based actions, persistent memory, and an organically evolving personality.

## How It Works

A runner script (`scripts/run-bot.sh`) orchestrates the full bot lifecycle:

1. Pre-pulls the [`claudebot-mcp`](https://github.com/jamesprial/claudebot-mcp) Docker image and initializes a Claude Code session with this plugin loaded
2. Sends periodic poll prompts via `claude -p --resume`, maintaining conversation context across cycles
3. Claude Code polls Discord for messages via MCP tools and processes them

From there, agents take over — triaging each message, crafting personality-driven replies, running web searches, executing commands, and sending everything directly back to Discord via MCP tools.

### Features

- **Intelligent triage** — Haiku agent evaluates every message: ignore, react, respond, or act
- **Direct Discord I/O** — Agents send messages, add reactions, and show typing indicators via MCP tools
- **Personality system** — Starts blank, evolves organically by absorbing traits from chat participants
- **Persistent memory** — Full context graph (users, topics, relationships) survives context compaction
- **Voice screams** — Play synthetic screams in voice channels via go-scream Docker integration (6 presets)
- **Per-channel configuration** — Different channels get different tool permissions and response thresholds

## Setup

### Prerequisites

- [Claude Code](https://claude.ai/code) CLI installed
- [Docker](https://docs.docker.com/get-docker/) installed and running
- A Discord bot token with message content intent enabled

### Install

1. Install the plugin:
   ```bash
   claude plugins add /path/to/claudebot
   ```

2. Create a `.env` file in the plugin directory (see `.env.example`):
   ```bash
   CLAUDEBOT_DISCORD_TOKEN=Bot your-bot-token-here
   CLAUDEBOT_DISCORD_GUILD_ID=123456789012345678
   ```

3. Run the setup command in your project:
   ```
   /claudebot:bot-setup
   ```

4. Start the bot:
   ```bash
   ./scripts/run-bot.sh
   ```

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLAUDEBOT_DISCORD_TOKEN` | Yes | — | Discord bot token (prefix with `Bot `) |
| `CLAUDEBOT_DISCORD_GUILD_ID` | Yes | — | Discord server ID |
| `CLAUDEBOT_POLL_TIMEOUT` | No | `30` | Poll interval in seconds |
| `CLAUDEBOT_MAX_FAILURES` | No | `5` | Max consecutive poll failures before exit |

## Configuration

Settings are stored in `.claude/claudebot.local.md` in your project (not in this plugin repo). See `templates/claudebot.local.md` for the full template.

### Channel Configuration

YAML frontmatter defines per-channel tool permissions and response thresholds:

```yaml
channels:
  general:
    tools: [WebSearch, Scream]
    respond_threshold: medium
  dev:
    tools: [WebSearch, Read, Bash, Glob, Grep]
    respond_threshold: high
default_channel:
  tools: [WebSearch]
  respond_threshold: medium
```

**Thresholds:** `low` (direct mentions only), `medium` (mentions + relevant topics), `high` (most messages)

### Management Commands

```
/claudebot:bot-setup              # Interactive setup wizard
/claudebot:bot-setup show-status  # Check MCP connectivity
/claudebot:bot-setup show-config  # Show current channel config
/claudebot:bot-setup show-personality  # View personality state
/claudebot:bot-setup reset-personality # Reset to blank personality
```

## Architecture

### Message Pipeline

```
Discord → MCP Server (Docker) ←stdio→ Claude Code (-p --resume) ← Runner (poll loop)
                                                    ↓
                                              Triage Agent (haiku)
                                             ↙    ↙     ↘      ↘
                                        ignore  react  respond      act
                                                  ↓       ↓     ↙    |    ↘
                                               emoji  responder researcher executor screamer
                                                         ↓         ↓         ↓        ↓
                                                    discord_send_message (via MCP)  docker run
```

### Agents

| Agent | Model | Role |
|-------|-------|------|
| triage | haiku | Evaluates every message, routes to downstream agent |
| responder | sonnet | Crafts personality-driven replies |
| researcher | sonnet | Web search, file lookups, information gathering |
| executor | sonnet | Tool-based actions (Bash, file ops) with safety checks |
| screamer | sonnet | Voice channel screams via go-scream Docker container |
| memory-manager | opus | Saves context graph during PreCompact |
| personality-evolver | haiku | Absorbs one user trait per compaction cycle |

### Memory System

Memory files live in `.claude/memory/` and persist across context compactions:

| File | Contents |
|------|----------|
| `personality.md` | Evolving bot personality and absorbed traits |
| `users.md` | Known user profiles and communication styles |
| `topics.md` | Discussion topics and summaries |
| `relationships.md` | User-user, user-topic, topic-topic graph |
| `action-items.md` | Open and completed action items |

Memory is updated **only during PreCompact** — the `memory-manager` agent saves the context graph, then the `personality-evolver` absorbs a trait from a random active user. During normal message processing, agents read memory for context but never write to it.

## License

MIT
