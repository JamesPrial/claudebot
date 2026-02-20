#!/usr/bin/env bash
# run-bot.sh - Claudebot lifecycle orchestrator
# Uses repeated `claude -p --resume` calls to maintain a persistent session
# that polls Discord for messages via MCP tools.
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
MAX_CONSECUTIVE_FAILURES="${CLAUDEBOT_MAX_FAILURES:-5}"
LOG_DIR="${PLUGIN_DIR}/logs"
LOG_FILE="${LOG_DIR}/bot-$(date '+%Y%m%d').log"
SESSION_FILE="${PLUGIN_DIR}/.bot-session-id"

log() { echo "[run-bot] $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }

SHUTTING_DOWN=false

cleanup() {
  # Guard against re-entry from EXIT after INT/TERM
  $SHUTTING_DOWN && return
  SHUTTING_DOWN=true

  log "Shutting down — killing child processes..."
  # Kill all processes in this process group (claude, docker, sleep)
  kill -- -$$ 2>/dev/null || true
  # Wait briefly for children to exit
  wait 2>/dev/null || true

  if [[ -f "$SESSION_FILE" ]]; then
    log "Session ID preserved in ${SESSION_FILE} for restart recovery"
  fi
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

if ! command -v claude &>/dev/null; then
  log "ERROR: claude CLI is not installed"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  log "ERROR: docker is not installed"
  exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# --- Pre-pull Docker images ---
log "Pre-pulling go-scream image..."
docker pull --platform linux/arm64 ghcr.io/jamesprial/go-scream:latest || log "WARNING: Failed to pull go-scream image (voice screams may not work)"

# Pre-pull the MCP Docker image to avoid pull delay on each invocation
log "Pre-pulling MCP Docker image..."
docker pull --platform linux/arm64 ghcr.io/jamesprial/claudebot-mcp:latest 2>&1 | tail -1 | tee -a "$LOG_FILE"

# --- Common claude flags ---
CLAUDE_FLAGS=(
  -p
  --plugin-dir "$PLUGIN_DIR"
  --mcp-config "$PLUGIN_DIR/.mcp.json"
  --dangerously-skip-permissions
  --output-format json
)

# --- Initialize or resume session ---
INIT_PROMPT="Session starting. Load the discord-bot skill and initialize. \
Read .claude/claudebot.local.md for channel config and .claude/memory/personality.md \
for current personality. Verify MCP connectivity by calling discord_get_guild."

SESSION_ID=""

# Check for existing session to resume
if [[ -f "$SESSION_FILE" ]]; then
  EXISTING_SESSION="$(cat "$SESSION_FILE")"
  log "Found existing session: ${EXISTING_SESSION}, attempting resume..."

  if claude "${CLAUDE_FLAGS[@]}" --resume "$EXISTING_SESSION" \
    "$INIT_PROMPT" >>"$LOG_FILE" 2>&1; then
    SESSION_ID="$EXISTING_SESSION"
    log "Resumed session: ${SESSION_ID}"
  else
    log "Failed to resume, starting fresh session"
    rm -f "$SESSION_FILE"
  fi
fi

if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  log "Creating new session: ${SESSION_ID}"

  if ! claude "${CLAUDE_FLAGS[@]}" --session-id "$SESSION_ID" \
    "$INIT_PROMPT" >>"$LOG_FILE" 2>&1; then
    log "ERROR: Failed to initialize session"
    exit 1
  fi

  log "Session initialized successfully"
fi

# Persist session ID for crash recovery
echo "$SESSION_ID" > "$SESSION_FILE"
log "Session ID saved to ${SESSION_FILE}"

# --- Poll loop ---
log "Starting message poll loop (interval: ${POLL_TIMEOUT}s)..."

consecutive_failures=0

while true; do
  POLL_PROMPT="Poll for new Discord messages using discord_poll_messages \
with timeout_seconds=${POLL_TIMEOUT} and limit=10. Process any messages received."

  if claude "${CLAUDE_FLAGS[@]}" --resume "$SESSION_ID" \
    "$POLL_PROMPT" >>"$LOG_FILE" 2>&1; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    log "WARNING: Poll failed (consecutive: ${consecutive_failures}/${MAX_CONSECUTIVE_FAILURES})"

    if [[ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]]; then
      log "ERROR: Too many consecutive failures, exiting"
      exit 1
    fi

    # Backoff: sleep for (failures * 5) seconds, capped at POLL_TIMEOUT
    backoff=$((consecutive_failures * 5))
    [[ $backoff -gt $POLL_TIMEOUT ]] && backoff=$POLL_TIMEOUT
    log "Backing off for ${backoff}s..."
    sleep "$backoff"
    continue
  fi

  # Brief pause between polls
  sleep 2
done
