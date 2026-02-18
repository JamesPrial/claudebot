#!/usr/bin/env bash
# run-bot.sh - Full claudebot lifecycle orchestrator
# Starts MCP server, starts Claude Code session, polls for Discord messages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [[ -f "${PLUGIN_DIR}/.env" ]]; then
  set -a
  source "${PLUGIN_DIR}/.env"
  set +a
fi

CLAUDEBOT_MCP_SOURCE="${CLAUDEBOT_MCP_SOURCE:-$HOME/code/claudebot-mcp}"
CLAUDEBOT_MCP_URL="${CLAUDEBOT_MCP_URL:-http://localhost:8080}"
CLAUDEBOT_MCP_PORT="${CLAUDEBOT_MCP_PORT:-8080}"
POLL_TIMEOUT="${CLAUDEBOT_POLL_TIMEOUT:-30}"

export CLAUDEBOT_MCP_URL

MCP_PID=""
CLAUDE_PID=""

log() { echo "[run-bot] $(date '+%H:%M:%S') $*" >&2; }

cleanup() {
  log "Shutting down..."
  [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null && wait "$CLAUDE_PID" 2>/dev/null
  [[ -n "$MCP_PID" ]]   && kill "$MCP_PID"   2>/dev/null && wait "$MCP_PID"   2>/dev/null
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

# --- Build & start MCP server ---
log "Building and starting MCP server..."
"$SCRIPT_DIR/start-mcp.sh" --build-only

BINARY_PATH="${CLAUDEBOT_MCP_SOURCE}/claudebot-mcp"
"$BINARY_PATH" &
MCP_PID=$!
log "MCP server started (PID: ${MCP_PID})"

# Wait for server to be ready
log "Waiting for MCP server to be ready..."
for i in $(seq 1 30); do
  if curl -sf "${CLAUDEBOT_MCP_URL}" -o /dev/null 2>/dev/null; then
    log "MCP server is ready."
    break
  fi
  if ! kill -0 "$MCP_PID" 2>/dev/null; then
    log "ERROR: MCP server exited unexpectedly"
    exit 1
  fi
  sleep 1
done

if ! curl -sf "${CLAUDEBOT_MCP_URL}" -o /dev/null 2>/dev/null; then
  log "ERROR: MCP server did not become ready in 30 seconds"
  exit 1
fi

# --- Start Claude Code session ---
log "Starting Claude Code session..."

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

# --- Poll loop ---
log "Starting message poll loop..."
AUTH_HEADER=""
if [[ -n "${CLAUDEBOT_AUTH_TOKEN:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer ${CLAUDEBOT_AUTH_TOKEN}"
fi

build_poll_request() {
  cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"discord_poll_messages","arguments":{"timeout_seconds":${POLL_TIMEOUT},"limit":10}}}
EOF
}

while kill -0 "$CLAUDE_PID" 2>/dev/null && kill -0 "$MCP_PID" 2>/dev/null; do
  # Poll MCP server for new messages
  POLL_RESULT=$(
    if [[ -n "$AUTH_HEADER" ]]; then
      curl -sf -X POST "${CLAUDEBOT_MCP_URL}" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "$(build_poll_request)" \
        --max-time $((POLL_TIMEOUT + 5)) 2>/dev/null
    else
      curl -sf -X POST "${CLAUDEBOT_MCP_URL}" \
        -H "Content-Type: application/json" \
        -d "$(build_poll_request)" \
        --max-time $((POLL_TIMEOUT + 5)) 2>/dev/null
    fi
  ) || continue

  # Check if we got messages (not "No new messages")
  if echo "$POLL_RESULT" | grep -q '"No new messages"'; then
    continue
  fi

  # Extract the content text from the MCP response
  MESSAGES=$(echo "$POLL_RESULT" | python3 -c "
import sys, json
try:
    resp = json.load(sys.stdin)
    content = resp.get('result', {}).get('content', [])
    for item in content:
        if item.get('type') == 'text':
            msgs = json.loads(item['text'])
            if isinstance(msgs, list):
                for msg in msgs:
                    print(json.dumps(msg))
except:
    pass
" 2>/dev/null) || continue

  # Pipe each message as a user prompt to Claude
  while IFS= read -r msg; do
    [[ -z "$msg" ]] && continue
    log "Received message: $(echo "$msg" | python3 -c "import sys,json; m=json.load(sys.stdin); print(f'[#{m.get(\"channel_name\",\"?\")}] @{m.get(\"author_username\",\"?\")}:  {m.get(\"content\",\"\")[:80]}')" 2>/dev/null || echo "$msg" | head -c 100)"
    echo "$msg" >&3
  done <<< "$MESSAGES"
done

log "Process exited. Claude PID running: $(kill -0 "$CLAUDE_PID" 2>/dev/null && echo yes || echo no), MCP PID running: $(kill -0 "$MCP_PID" 2>/dev/null && echo yes || echo no)"
