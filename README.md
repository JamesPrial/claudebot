# Claudebot

A Claude Code plugin that turns a Claude Code session into a Discord bot brain with intelligent message triage, tool-based actions, persistent memory, and an organically evolving personality.

## How It Works

A runner script (`scripts/run-bot.sh`) orchestrates the full bot lifecycle: starts the `claudebot-mcp` Go server for Discord connectivity, starts a Claude Code session with this plugin, and polls for incoming Discord messages. Agents interact with Discord directly via MCP tools — sending messages, adding reactions, showing typing indicators, and reading channel history.

- **Intelligent triage** - Decides whether to respond, react, act, or ignore each message
- **Direct Discord I/O** - Agents send messages, add reactions, and show typing indicators via MCP tools
- **Personality system** - Starts blank, evolves by absorbing traits from chat participants
- **Persistent memory** - Full context graph (users, topics, relationships) survives context compaction
- **Per-channel configuration** - Different channels get different tool permissions and response thresholds

## Setup

1. Install the plugin:
   ```bash
   claude plugins add /path/to/claudebot
   ```

2. Set up the [claudebot-mcp](https://github.com/jamesprial/claudebot-mcp) Go server (provides Discord connectivity via MCP tools).

3. Set required environment variables:
   ```bash
   export CLAUDEBOT_DISCORD_TOKEN="Bot your-token-here"
   export CLAUDEBOT_DISCORD_GUILD_ID="your-guild-id"
   export CLAUDEBOT_AUTH_TOKEN="your-auth-token"  # optional, for MCP auth
   ```

4. Run the setup command in your project:
   ```
   /claudebot:bot-setup
   ```

5. Start the bot:
   ```bash
   ./scripts/run-bot.sh
   ```

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
- **MCP Server**: `claudebot-mcp` - Go HTTP server for Discord I/O (13 tools)
- **Runner**: `scripts/run-bot.sh` - Orchestrates MCP server + Claude session + message polling
- **Hook**: PreCompact - Saves memory before context compression
- **Command**: `/bot-setup` - Interactive configuration

## License

MIT
