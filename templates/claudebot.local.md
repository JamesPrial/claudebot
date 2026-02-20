---
channels:
  general:
    tools: [WebSearch, Scream]
    respond_threshold: medium
  dev:
    tools: [WebSearch, Read, Bash, Glob, Grep]
    respond_threshold: high
  random:
    tools: [WebSearch, Scream]
    respond_threshold: low
default_channel:
  tools: [WebSearch]
  respond_threshold: medium
# log_level: INFO
# logging:
#   triage: DEBUG
#   responder: INFO
#   researcher: INFO
#   executor: INFO
#   screamer: INFO
---
# Claudebot Settings

## Initial Personality Seed

(Optional) Write a brief personality seed here to give the bot initial direction.
Leave empty for pure organic growth from chat participants.

## Bot Name

claudebot

## Additional Instructions

Any extra behavioral guidelines for the bot go here.
