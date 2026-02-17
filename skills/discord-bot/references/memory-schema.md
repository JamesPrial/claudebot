# Memory File Schema Reference

## Overview

All memory files live in `.claude/memory/` relative to the project root. They are markdown files read and updated by the memory-manager agent during PreCompact events. Templates for initial creation are in the plugin's `templates/memory/` directory.

## personality.md

Tracks the bot's evolving personality. Starts blank and grows over time.

### Structure

```markdown
# Bot Personality

## Core Traits
- [trait description - e.g., "Uses dry humor when responding to obvious questions"]
- [trait description - e.g., "Tends to use gaming metaphors"]

## Absorbed Traits
| Source User | Trait | Date Absorbed |
|-------------|-------|---------------|
| @alice | Frequent use of "honestly" as a sentence starter | 2025-01-15 |
| @bob | Enthusiasm about new tech with exclamation marks | 2025-01-16 |

## Voice Notes
[Free-form description of how the bot communicates]
Example: "Casual and slightly nerdy. Drops gaming references. Starts responses
with 'honestly' sometimes. Gets genuinely excited about new tech."
```

### Update Rules
- Only the personality-evolver agent writes to this file
- Each update adds ONE trait from ONE randomly selected active user
- Core Traits grows incrementally - never rewrite existing traits
- Voice Notes gets refined to reflect the overall personality blend
- Keep the Absorbed Traits table as an audit log

## users.md

Profiles of Discord users the bot has interacted with.

### Structure

```markdown
# Known Users

## @username
- **First seen**: 2025-01-10
- **Communication style**: Concise, uses lots of emoji, asks pointed questions
- **Interests**: React, game development, coffee
- **Notable traits**: Always responds with follow-up questions, uses "ngl" frequently
- **Recent interactions**: Asked about React hooks patterns in #dev, shared a meme in #random
```

### Update Rules
- Add new user entries when encountering unknown users
- Update "Recent interactions" to reflect the latest conversation
- Update "Communication style" and "Notable traits" as patterns emerge
- Keep entries concise - 3-5 bullet points per user
- Remove stale "Recent interactions" older than ~10 conversation cycles

## topics.md

Tracks discussion topics across channels.

### Structure

```markdown
# Discussion Topics

## React Server Components Migration
- **Status**: active
- **Channels**: #dev, #general
- **Participants**: @alice, @bob, @charlie
- **Summary**: Team is evaluating migrating from client components to RSC. Main concerns are bundle size and data fetching patterns.
- **Key points**:
  - Decided to start with non-critical pages
  - @alice is leading the spike
  - Blocked on Next.js version upgrade
```

### Update Rules
- Create new topics when substantive discussions emerge (not one-off messages)
- Update status: active → resolved when topic concludes, or mark as recurring
- Merge related topics if they converge
- Archive resolved topics by moving to a "## Resolved" section (don't delete)
- Keep summaries to 2-4 sentences

## relationships.md

Maps connections between users and topics.

### Structure

```markdown
# Relationship Graph

## User-User
- @alice <-> @bob: Pair program frequently, friendly rivalry about framework choices
- @charlie <-> @alice: Charlie mentors Alice on backend patterns

## User-Topic
- @alice -> React: Expert, leads migration effort
- @bob -> Testing: Advocate, pushes for higher coverage
- @charlie -> DevOps: Go-to person for CI/CD questions

## Topic-Topic
- React -> JavaScript: Parent language/ecosystem
- React Server Components -> React: Subtopic, current migration focus
- CI/CD -> Deployment: Related workflow, CI/CD feeds into deployment
```

### Update Rules
- Add relationships as interaction patterns become clear (not after a single message)
- User-User relationships describe interaction quality and frequency
- User-Topic relationships describe expertise level and engagement type
- Topic-Topic relationships describe hierarchy (parent/child) or association
- Remove relationships that become stale or inaccurate

## action-items.md

Tracks commitments and tasks mentioned in chat.

### Structure

```markdown
# Action Items

## Open
- [ ] Spike on React Server Components migration (@alice, from #dev, 2025-01-15)
- [ ] Update CI pipeline for new test runner (@charlie, from #dev, 2025-01-14)
- [ ] Share article about Bun runtime (@bob, from #random, 2025-01-16)

## Completed
- [x] Fix flaky test in auth module (@bob, completed 2025-01-15)
- [x] Review PR #234 (@alice, completed 2025-01-14)
```

### Update Rules
- Track action items when users explicitly commit to doing something
- Include owner, source channel, and date
- Move to Completed when someone reports finishing the task
- Don't track vague mentions ("we should probably...") - only clear commitments
- Prune completed items older than ~20 conversation cycles
