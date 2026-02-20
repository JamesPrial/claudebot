#!/usr/bin/env python3
"""Claudebot lifecycle orchestrator.

Runs the MCP server as a persistent Docker daemon (HTTP transport) so the
Discord gateway stays open and the bot appears always-online. Uses repeated
`claude -p --resume` calls to maintain a persistent session across poll cycles.
"""

import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_DIR = SCRIPT_DIR.parent

# Import the logging library from the same directory
sys.path.insert(0, str(SCRIPT_DIR))
from log_lib import get_logger


# ---------------------------------------------------------------------------
# .env loader
# ---------------------------------------------------------------------------

def load_dotenv(path: Path) -> None:
    """Parse a .env file into os.environ (handles comments, quotes, blank lines)."""
    if not path.is_file():
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
            if not m:
                continue
            key = m.group(1)
            val = m.group(2).strip()
            # Strip surrounding quotes
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            os.environ[key] = val


# ---------------------------------------------------------------------------
# Lifecycle manager
# ---------------------------------------------------------------------------

class BotLifecycle:
    def __init__(self, container_name: str, session_file: Path, log: "log_lib.Logger"):
        self.container_name = container_name
        self.session_file = session_file
        self.log = log
        self.shutting_down = False
        self.log_streamer: subprocess.Popen | None = None
        self.children: list[subprocess.Popen] = []

    def register_signals(self) -> None:
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)
        atexit.register(self.cleanup)

    def _handle_signal(self, signum: int, _frame) -> None:
        self.cleanup()
        sys.exit(128 + signum)

    def cleanup(self) -> None:
        if self.shutting_down:
            return
        self.shutting_down = True

        self.log.info("Shutting down — killing child processes")

        # Kill MCP log streamer first to avoid broken-pipe noise
        if self.log_streamer and self.log_streamer.poll() is None:
            self.log_streamer.terminate()
            try:
                self.log_streamer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.log_streamer.kill()

        # Terminate tracked child processes
        for child in self.children:
            if child.poll() is None:
                child.terminate()
        for child in self.children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()

        self.log.info("Stopping MCP daemon container")
        subprocess.run(
            ["docker", "stop", "-t", "10", self.container_name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["docker", "rm", "-f", self.container_name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        if self.session_file.is_file():
            self.log.info("Session ID preserved for restart recovery", f"file={self.session_file}")
        self.log.info("Shutdown complete")


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

def preflight_checks(log) -> None:
    for var in ("CLAUDEBOT_DISCORD_TOKEN", "CLAUDEBOT_DISCORD_GUILD_ID"):
        if not os.environ.get(var):
            log.error("Required env var is not set", f"var={var}")
            sys.exit(1)

    if not shutil.which("claude"):
        log.error("claude CLI is not installed")
        sys.exit(1)

    if not shutil.which("docker"):
        log.error("docker is not installed")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

def pull_docker_images(log) -> None:
    log.info("Pre-pulling go-scream image")
    result = subprocess.run(
        ["docker", "pull", "--platform", "linux/arm64", "ghcr.io/jamesprial/go-scream:latest"],
        capture_output=True,
    )
    if result.returncode != 0:
        log.warn("Failed to pull go-scream image (voice screams may not work)")

    log.info("Pre-pulling MCP Docker image")
    result = subprocess.run(
        ["docker", "pull", "--platform", "linux/arm64", "ghcr.io/jamesprial/claudebot-mcp:latest"],
        capture_output=True,
    )
    if result.returncode != 0:
        log.error("Failed to pull MCP Docker image")
        sys.exit(1)
    # Print last line of output to stderr like bash version
    lines = result.stdout.decode().strip().splitlines()
    if lines:
        print(lines[-1], file=sys.stderr)


def start_mcp_daemon(mcp_port: int, container_name: str, log) -> None:
    log.info("Starting MCP daemon", f"port={mcp_port}")
    subprocess.run(
        ["docker", "rm", "-f", container_name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "docker", "run", "-d", "--name", container_name,
            "--platform", "linux/arm64",
            "-p", f"{mcp_port}:8080",
            "-e", "CLAUDEBOT_DISCORD_TOKEN",
            "-e", "CLAUDEBOT_DISCORD_GUILD_ID",
            "ghcr.io/jamesprial/claudebot-mcp:latest",
        ],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=True,
    )

    # Wait for container to be running
    log.info("Waiting for MCP container to start")
    for i in range(1, 31):
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", container_name],
            capture_output=True, text=True,
        )
        if "true" in result.stdout:
            break
        if i == 30:
            log.error("MCP container failed to start within 30s")
            result = subprocess.run(
                ["docker", "logs", container_name],
                capture_output=True, text=True,
            )
            for line in result.stdout.splitlines()[-20:]:
                print(line, file=sys.stderr)
            for line in result.stderr.splitlines()[-20:]:
                print(line, file=sys.stderr)
            sys.exit(1)
        time.sleep(1)

    # Wait for Discord connection
    log.info("Waiting for Discord connection")
    for i in range(1, 31):
        result = subprocess.run(
            ["docker", "logs", container_name],
            capture_output=True, text=True,
        )
        combined = result.stdout + result.stderr
        if "discord: connected as" in combined:
            log.info("MCP daemon connected to Discord")
            break

        # Check container is still running
        inspect = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", container_name],
            capture_output=True, text=True,
        )
        if "true" not in inspect.stdout:
            log.error("MCP container exited unexpectedly")
            for line in combined.splitlines()[-20:]:
                print(line, file=sys.stderr)
            sys.exit(1)

        if i == 30:
            log.warn("Timed out waiting for Discord connection, proceeding anyway")
        time.sleep(1)


def start_log_streamer(container_name: str, mcp_log_file: Path, lifecycle: BotLifecycle, log) -> None:
    log.info("Starting MCP daemon log stream")
    f = open(mcp_log_file, "a")
    proc = subprocess.Popen(
        ["docker", "logs", "-f", "--timestamps", container_name],
        stdout=f, stderr=subprocess.STDOUT,
    )
    lifecycle.log_streamer = proc
    log.debug("MCP log streamer started", f"pid={proc.pid}")


def is_container_running(container_name: str) -> bool:
    result = subprocess.run(
        ["docker", "inspect", "-f", "{{.State.Running}}", container_name],
        capture_output=True, text=True,
    )
    return "true" in result.stdout


# ---------------------------------------------------------------------------
# MCP config
# ---------------------------------------------------------------------------

def generate_mcp_config(mcp_port: int, log) -> Path:
    config_path = PLUGIN_DIR / ".mcp.runtime.json"
    config = {
        "mcpServers": {
            "discord": {
                "type": "http",
                "url": f"http://localhost:{mcp_port}/mcp",
            }
        }
    }
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    log.info("Generated runtime MCP config", f"path={config_path}")
    return config_path


# ---------------------------------------------------------------------------
# Claude CLI
# ---------------------------------------------------------------------------

def run_claude(claude_flags: list[str], prompt: str, timeout_secs: int, log_file: Path) -> bool:
    """Execute claude CLI with common flags. Returns True on success."""
    cmd = ["claude"] + claude_flags + [prompt]
    try:
        with open(log_file, "a") as f:
            subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=f, stderr=subprocess.STDOUT,
                timeout=timeout_secs,
            )
        return True
    except subprocess.TimeoutExpired:
        return False
    except subprocess.CalledProcessError:
        return False


def initialize_session(claude_flags: list[str], init_prompt: str, session_file: Path, log_file: Path, log) -> str:
    """Try to resume from saved session, fall back to new UUID session."""
    session_id = ""

    if session_file.is_file():
        existing = session_file.read_text().strip()
        log.info("Found existing session, attempting resume", f"session={existing}")

        flags = claude_flags + ["--resume", existing]
        if run_claude(flags, init_prompt, 180, log_file):
            session_id = existing
            log.info("Resumed session", f"session={session_id}")
        else:
            log.warn("Failed to resume, starting fresh session")
            session_file.unlink(missing_ok=True)

    if not session_id:
        session_id = str(uuid.uuid4())
        log.info("Creating new session", f"session={session_id}")

        flags = claude_flags + ["--session-id", session_id]
        if not run_claude(flags, init_prompt, 180, log_file):
            log.error("Failed to initialize session")
            sys.exit(1)

        log.info("Session initialized successfully")

    # Persist for crash recovery
    session_file.write_text(session_id + "\n")
    log.debug("Session ID saved", f"file={session_file}")
    return session_id


# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------

def poll_loop(session_id: str, claude_flags: list[str], poll_timeout: int,
              max_failures: int, container_name: str, mcp_log_file: Path,
              log_file: Path, lifecycle: BotLifecycle, log) -> None:
    log.info("Starting message poll loop", f"interval={poll_timeout}s")

    consecutive_failures = 0

    while not lifecycle.shutting_down:
        # Health check: daemon still running?
        if not is_container_running(container_name):
            log.error("MCP daemon container died, exiting")
            sys.exit(1)

        # Health check: log streamer still alive?
        if lifecycle.log_streamer and lifecycle.log_streamer.poll() is not None:
            log.warn("MCP log streamer died, restarting")
            start_log_streamer(container_name, mcp_log_file, lifecycle, log)

        poll_prompt = (
            f"Poll for new Discord messages using discord_poll_messages "
            f"with timeout_seconds={poll_timeout} and limit=10. Process any messages received."
        )

        flags = claude_flags + ["--resume", session_id]
        if run_claude(flags, poll_prompt, 120, log_file):
            consecutive_failures = 0
        else:
            consecutive_failures += 1
            log.warn("Poll failed", f"consecutive={consecutive_failures}/{max_failures}")

            if consecutive_failures >= max_failures:
                log.error("Too many consecutive failures, exiting")
                sys.exit(1)

            # Exponential backoff capped at poll_timeout
            backoff = min(consecutive_failures * 5, poll_timeout)
            log.info("Backing off", f"seconds={backoff}")
            time.sleep(backoff)
            continue

        # Brief pause between polls
        time.sleep(2)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    # Load .env
    load_dotenv(PLUGIN_DIR / ".env")

    # Set up logging env
    os.environ.setdefault("CLAUDEBOT_LOG_LEVEL", "INFO")
    os.environ["CLAUDEBOT_PLUGIN_DIR"] = str(PLUGIN_DIR)
    log = get_logger("run-bot")

    # Config from env
    poll_timeout = int(os.environ.get("CLAUDEBOT_POLL_TIMEOUT", "30"))
    max_failures = int(os.environ.get("CLAUDEBOT_MAX_FAILURES", "5"))
    mcp_port = int(os.environ.get("CLAUDEBOT_MCP_PORT", "8080"))
    container_name = "claudebot-mcp-daemon"
    log_dir = PLUGIN_DIR / "logs"
    today = datetime.now().strftime("%Y%m%d")
    log_file = log_dir / f"bot-{today}.log"
    mcp_log_file = log_dir / f"mcp-{today}.log"
    session_file = PLUGIN_DIR / ".bot-session-id"

    # Preflight
    preflight_checks(log)
    log_dir.mkdir(exist_ok=True)

    # Lifecycle
    lifecycle = BotLifecycle(container_name, session_file, log)
    lifecycle.register_signals()

    # Docker
    pull_docker_images(log)
    start_mcp_daemon(mcp_port, container_name, log)
    start_log_streamer(container_name, mcp_log_file, lifecycle, log)

    # MCP config
    runtime_config = generate_mcp_config(mcp_port, log)

    # Claude flags
    claude_flags = [
        "-p",
        "--plugin-dir", str(PLUGIN_DIR),
        "--mcp-config", str(runtime_config),
        "--dangerously-skip-permissions",
        "--output-format", "json",
    ]
    log.debug("Claude flags configured", f"plugin_dir={PLUGIN_DIR}", f"mcp_config={runtime_config}")

    # Session
    init_prompt = (
        "Session starting. Load the discord-bot skill and initialize. "
        "Read .claude/claudebot.local.md for channel config and .claude/memory/personality.md "
        "for current personality. Verify MCP connectivity by calling discord_get_guild."
    )
    session_id = initialize_session(claude_flags, init_prompt, session_file, log_file, log)

    # Poll
    poll_loop(session_id, claude_flags, poll_timeout, max_failures,
              container_name, mcp_log_file, log_file, lifecycle, log)


if __name__ == "__main__":
    main()
