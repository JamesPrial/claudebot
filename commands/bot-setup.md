---
description: Configure the Discord bot - set up channels, personality, and initialize memory files
argument-hint: [reset-personality | show-personality | show-config]
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash(mkdir:*)
  - AskUserQuestion
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

1. **Create memory directory**: If `.claude/memory/` doesn't exist, create it and copy all template files from the plugin's `templates/memory/` directory.

2. **Configure channels**: Ask the user which Discord channels the bot will operate in. For each channel, ask:
   - What tools should be available? (Options: WebSearch, Read, Bash, Glob, Grep, Write, Edit)
   - What response threshold? (low/medium/high)

3. **Set bot name**: Ask the user for a bot name (default: "claudebot")

4. **Personality seed**: Ask if they want to provide an initial personality seed, or start completely blank for organic growth.

5. **Write settings**: Create `.claude/claudebot.local.md` with YAML frontmatter containing the channel configurations and any personality seed.

6. **Confirm**: Show a summary of the configuration.

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

## Tips

- If settings file already exists, ask if the user wants to update or replace it
- If memory files already exist, don't overwrite them (they contain accumulated bot memory)
- Always confirm destructive actions (reset-personality, replacing existing config)
