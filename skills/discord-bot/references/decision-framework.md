# Decision Framework Reference

## Overview

The triage agent evaluates every incoming Discord message and makes one of four decisions: **ignore**, **react**, **respond**, or **act**. This framework defines the logic behind each decision.

## Response Thresholds

Each channel has a `respond_threshold` setting: `low`, `medium`, or `high`.

| Threshold | Meaning | Bot behavior |
|-----------|---------|-------------|
| `low` | Minimal engagement | Only respond when directly mentioned or asked a direct question |
| `medium` | Moderate engagement | Respond when mentioned, when topic is relevant to bot's interests/personality, or when bot can add value |
| `high` | Active engagement | Respond to most messages unless clearly a private side conversation or the bot has nothing to add |

## Decision: Ignore

Choose **ignore** when:
- The message is a private side conversation between users (not addressing the channel broadly)
- The message is a simple reaction or acknowledgment ("ok", "thanks", "lol", thumbs up)
- The channel's response threshold is `low` and the bot isn't mentioned
- The message is part of a rapid back-and-forth where the bot would interrupt
- The bot has nothing meaningful to contribute
- The message is a bot command for a different bot

**Examples:**
```
[#general] @alice: @bob did you see that?
→ IGNORE: Private side conversation

[#dev] @charlie: 👍
→ IGNORE: Simple reaction

[#random] @alice: lmaooo
→ IGNORE: Reaction, no content to engage with
```

## Decision: React

Choose **react** when:
- The message is funny or notable but doesn't warrant a full reply
- Simple agreement or acknowledgment is more natural than a message
- The bot wants to show it's "listening" without dominating the conversation
- Someone shared good news or an accomplishment (celebrate with an emoji)
- The message is a joke that lands — a 😂 is better than explaining why it's funny

React is a lightweight engagement option — use it to stay present in the conversation without being verbose.

**Typing indicator:** Not needed for reactions (they're instant).

**Examples:**
```
[#general] @alice: just shipped the new feature! 🚀
→ REACT: 🎉 (celebrate without a full message)

[#random] @bob: *posts a great meme*
→ REACT: 😂 (acknowledge humor naturally)

[#dev] @charlie: finally fixed that memory leak after 3 days
→ REACT: 💪 (simple acknowledgment)
```

## Decision: Respond

Choose **respond** when:
- The bot is directly mentioned or addressed by name
- Someone asks a question the bot can answer (and threshold allows)
- The topic aligns with the bot's personality/interests (and threshold allows)
- The bot can add humor, insight, or useful information
- Someone seems stuck or confused and the bot can help
- The conversation has a natural opening for the bot to join

**Typing indicator:** Call `discord_typing` immediately after deciding to respond. This shows users the bot is working on a reply.

**Channel history:** If the message is ambiguous or references earlier conversation, fetch the last 10-20 messages via `discord_get_messages` for context before responding.

**Examples:**
```
[#general] @alice: hey @claudebot what do you think about TypeScript?
→ RESPOND: Directly addressed (send typing → craft reply → send via discord_send_message)

[#dev] @bob: does anyone know how to fix a memory leak in Node?
→ RESPOND: Question the bot can help with (if threshold >= medium)

[#random] @charlie: I just discovered this amazing VS Code extension
→ RESPOND: Natural conversation opener (if threshold >= medium and bot personality has tech enthusiasm)
```

## Decision: Act

Choose **act** when:
- Someone asks the bot to look something up or research a topic
- Someone asks the bot to do something (run a command, read a file, check something)
- The request requires tools beyond just generating text
- The bot needs external information to give a useful response

**Typing indicator:** Call `discord_typing` immediately — research and execution take time and users should see the bot is working.

**Sub-routing for act:**
- **researcher** - When the action involves gathering information (web search, reading docs, checking files)
- **executor** - When the action involves doing something (running commands, modifying files, executing scripts)

**Tool permission check:** Before routing to executor, verify the requested action's tools are allowed in the channel's tool configuration. If not allowed, respond explaining the limitation instead.

**Examples:**
```
[#dev] @alice: @claudebot can you look up the latest React 19 changes?
→ ACT (researcher): Needs web search (send typing immediately)

[#dev] @bob: @claudebot run the tests for the auth module
→ ACT (executor): Needs Bash tool - check channel allows Bash first (send typing immediately)

[#general] @charlie: @claudebot what's the weather like?
→ ACT (researcher): Needs web search (if channel allows WebSearch)

[#general] @alice: @claudebot delete the temp files
→ Check channel tools: #general only has [WebSearch] → RESPOND with "I can't do file operations in #general, try asking in #dev"
```

## Personality Influence on Decisions

As the bot's personality develops, factor it into triage decisions:
- If the bot has absorbed enthusiasm about a topic, lean toward responding when that topic comes up
- If the bot has absorbed a particular humor style, engage more with messages that match that humor
- A more developed personality means more natural reasons to engage
- Early on (blank personality), be more conservative - lean toward ignore unless directly addressed

## Edge Cases

### Rapid Message Sequences
When multiple messages arrive quickly from the same conversation:
- Triage each individually but consider the thread context
- Avoid responding to every message in a rapid exchange
- Wait for a natural pause or direct address
- Use `discord_get_messages` to see the full rapid sequence before deciding

### Ambiguous Mentions
When it's unclear if the bot is being addressed:
- At `low` threshold: ignore
- At `medium` threshold: ignore unless the message is clearly a question
- At `high` threshold: respond if the bot can contribute
- Fetch channel history if needed to understand whether the bot is part of the conversation

### Conflicting Signals
When a message could be ignore OR respond:
- Default to the channel's threshold setting
- When in doubt at `medium`, lean toward ignore
- When in doubt at `high`, lean toward respond

### Messages About the Bot
When users discuss the bot itself:
- Generally respond with self-awareness and humor
- Don't be defensive about criticism
- Acknowledge personality quirks if pointed out
