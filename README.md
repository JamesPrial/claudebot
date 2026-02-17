# Claudebot

A Claude Code plugin that turns a Claude Code session into a Discord bot brain with intelligent message triage, tool-based actions, persistent memory, and an organically evolving personality.

## How It Works

An external Discord bot pipes chat messages into a long-running Claude Code session. This plugin provides:

- **Intelligent triage** - Decides whether to respond, act, or ignore each message
- **Personality system** - Starts blank, evolves by absorbing traits from chat participants
- **Persistent memory** - Full context graph (users, topics, relationships) survives context compaction
- **Per-channel configuration** - Different channels get different tool permissions and response thresholds

## Setup

1. Install the plugin:
   ```bash
   claude plugins add /path/to/claudebot
   ```

2. Run the setup command in your project:
   ```
   /claudebot:bot-setup
   ```

3. Configure your external Discord bot to pipe messages into a Claude Code session.

## Configuration

Settings are stored in `.claude/claudebot.local.md` in your project. See `templates/claudebot.local.md` for the full template.

### Channel Configuration

```yaml
channels:
  general:
    tools: [WebSearch]
    respond_threshold: medium
  dev:
    tools: [WebSearch, Read, Bash, Glob, Grep]
    respond_threshold: high
```

## Memory Files

Memory is stored in `.claude/memory/` and persists across context compactions:

| File | Contents |
|------|----------|
| `personality.md` | Evolving bot personality and absorbed traits |
| `users.md` | Known user profiles and communication styles |
| `topics.md` | Discussion topics and summaries |
| `relationships.md` | User-user, user-topic, topic-topic graph |
| `action-items.md` | Open and completed action items |

## Components

- **Skill**: `discord-bot` - Core behavior guide
- **Agents**: triage (haiku), responder (sonnet), researcher (sonnet), executor (sonnet), memory-manager (opus), personality-evolver (haiku)
- **Hook**: PreCompact - Saves memory before context compression
- **Command**: `/bot-setup` - Interactive configuration

## License

MIT
