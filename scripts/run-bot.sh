#!/usr/bin/env bash
# run-bot.sh - Full claudebot lifecycle orchestrator
# Starts Claude Code session (MCP server auto-starts via .mcp.json Docker stdio),
# then polls for Discord messages by sending prompts to Claude Code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [[ -f "${PLUGIN_DIR}/.env" ]]; then
  set -a
  source "${PLUGIN_DIR}/.env"
  set +a
fi

POLL_TIMEOUT="${CLAUDEBOT_POLL_TIMEOUT:-30}"

CLAUDE_PID=""

log() { echo "[run-bot] $(date '+%H:%M:%S') $*" >&2; }

cleanup() {
  log "Shutting down..."
  exec 3>&- 2>/dev/null
  [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null && wait "$CLAUDE_PID" 2>/dev/null
  [[ -n "${FIFO:-}" ]] && rm -f "$FIFO"
  log "Shutdown complete."
}
trap cleanup EXIT INT TERM

# --- Preflight checks ---
for var in CLAUDEBOT_DISCORD_TOKEN CLAUDEBOT_DISCORD_GUILD_ID; do
  if [[ -z "${!var:-}" ]]; then
    log "ERROR: ${var} is not set"
    exit 1
  fi
done

if ! command -v docker &>/dev/null; then
  log "ERROR: docker is not installed"
  exit 1
fi

# --- Start Claude Code session ---
# The MCP server starts automatically via .mcp.json (Docker stdio transport)
log "Starting Claude Code session (MCP server will auto-start via Docker)..."

# Create a FIFO for piping messages into Claude
FIFO=$(mktemp -u /tmp/claudebot-fifo-XXXXXX)
mkfifo "$FIFO"

# Start Claude Code in headless mode reading from the FIFO
claude --plugin-dir "$PLUGIN_DIR" --headless < "$FIFO" &
CLAUDE_PID=$!
log "Claude Code session started (PID: ${CLAUDE_PID})"

# Open the FIFO for writing (keep it open so Claude doesn't see EOF)
exec 3>"$FIFO"

# Send initial prompt to load the skill and initialize
echo '{"type":"system","content":"Session starting. Load the discord-bot skill and initialize."}' >&3

# Give Claude Code time to start and initialize MCP connection
sleep 5

# --- Poll loop ---
log "Starting message poll loop (interval: ${POLL_TIMEOUT}s)..."

while kill -0 "$CLAUDE_PID" 2>/dev/null; do
  echo '{"type":"poll","content":"Poll for new Discord messages using discord_poll_messages with timeout_seconds='"${POLL_TIMEOUT}"' and limit=10. Process any messages received."}' >&3
  sleep "$POLL_TIMEOUT"
done

log "Claude Code session exited."
