---
description: Configure the Discord bot - set up channels, personality, initialize memory files, and verify MCP connectivity
argument-hint: [reset-personality | show-personality | show-config | show-status]
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash(mkdir:*)
  - AskUserQuestion
  - mcp__plugin_claudebot_discord__discord_get_guild
  - mcp__plugin_claudebot_discord__discord_get_channels
---

# Bot Setup

Configure the claudebot Discord bot for this project.

## Context

Check current state:
- Does `.claude/claudebot.local.md` exist?
- Does `.claude/memory/` directory exist?
- If memory exists, what's the current personality state?

## Your Task

Based on the argument provided (or lack thereof), perform the appropriate action:

### No argument: Full setup wizard

Run the interactive setup:

1. **Verify MCP connectivity**: Call `discord_get_guild` to confirm the MCP server is running and accessible. If it fails, warn the user that the MCP server needs to be running for full functionality, but continue with manual setup.

2. **Discover channels**: If MCP is available, call `discord_get_channels` to get the list of available Discord channels. Present these to the user for selection instead of requiring manual entry.

3. **Create memory directory**: If `.claude/memory/` doesn't exist, create it and copy all template files from the plugin's `templates/memory/` directory.

4. **Configure channels**: Ask the user which Discord channels the bot will operate in (pre-populated from discovery if available). For each channel, ask:
   - What tools should be available? (Options: WebSearch, Read, Bash, Glob, Grep, Write, Edit)
   - What response threshold? (low/medium/high)

5. **Set bot name**: Ask the user for a bot name (default: "claudebot")

6. **Personality seed**: Ask if they want to provide an initial personality seed, or start completely blank for organic growth.

7. **Write settings**: Create `.claude/claudebot.local.md` with YAML frontmatter containing the channel configurations and any personality seed.

8. **Confirm**: Show a summary of the configuration including discovered channels.

### `reset-personality` argument

1. Confirm with the user that they want to reset the bot's personality (this is irreversible).
2. If confirmed, replace `.claude/memory/personality.md` with the blank template from the plugin's `templates/memory/personality.md`.
3. Report that personality has been reset.

### `show-personality` argument

1. Read `.claude/memory/personality.md`
2. Display the current personality state including:
   - Number of core traits
   - List of absorbed traits with sources
   - Current voice notes

### `show-config` argument

1. Read `.claude/claudebot.local.md`
2. Display the current configuration:
   - Configured channels with their tools and thresholds
   - Bot name
   - Personality seed (if any)
   - Additional instructions (if any)

### `show-status` argument

1. Call `discord_get_guild` to check MCP server connectivity
2. If successful, display:
   - Guild name and member count
   - Available channels (call `discord_get_channels`)
   - Configured channels vs available channels comparison
3. If MCP is unreachable, report the connection error and suggest checking that the MCP server is running

## Tips

- If settings file already exists, ask if the user wants to update or replace it
- If memory files already exist, don't overwrite them (they contain accumulated bot memory)
- Always confirm destructive actions (reset-personality, replacing existing config)
- Channel discovery via MCP is preferred over manual entry — it prevents typos and shows category info
