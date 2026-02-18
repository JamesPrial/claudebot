#!/usr/bin/env bash
# start-mcp.sh - Build and start the claudebot-mcp server
# Usage: ./scripts/start-mcp.sh [--build-only]
set -euo pipefail

CLAUDEBOT_MCP_SOURCE="${CLAUDEBOT_MCP_SOURCE:-$HOME/code/claudebot-mcp}"
CLAUDEBOT_MCP_PORT="${CLAUDEBOT_MCP_PORT:-8080}"
BINARY_PATH="${CLAUDEBOT_MCP_SOURCE}/claudebot-mcp"

log() { echo "[start-mcp] $*" >&2; }

# --- Build ---
if [[ ! -f "$BINARY_PATH" ]] || [[ "${1:-}" == --build* ]]; then
  log "Building claudebot-mcp from ${CLAUDEBOT_MCP_SOURCE}..."
  (cd "$CLAUDEBOT_MCP_SOURCE" && go build -o ./claudebot-mcp ./cmd/claudebot-mcp)
  log "Build complete: ${BINARY_PATH}"
fi

if [[ "${1:-}" == "--build-only" ]]; then
  log "Build-only mode, exiting."
  exit 0
fi

# --- Preflight checks ---
for var in CLAUDEBOT_DISCORD_TOKEN CLAUDEBOT_DISCORD_GUILD_ID; do
  if [[ -z "${!var:-}" ]]; then
    log "ERROR: ${var} is not set"
    exit 1
  fi
done

# --- Start server ---
log "Starting MCP server on port ${CLAUDEBOT_MCP_PORT}..."
exec "$BINARY_PATH"
