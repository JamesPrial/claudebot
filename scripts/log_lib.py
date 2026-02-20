#!/usr/bin/env python3
"""Structured logging library for claudebot.

Produces identical output format to log-lib.sh:
    2026-02-20T14:30:00 level=INFO component=run-bot msg="Starting poll loop" interval=30s

Environment:
    CLAUDEBOT_LOG_LEVEL  - Minimum level to emit (DEBUG|INFO|WARN|ERROR, default INFO)
    CLAUDEBOT_PLUGIN_DIR - If set and logs/ exists, also appends to daily log file
"""

import os
import sys
from datetime import datetime, timezone
from enum import IntEnum
from pathlib import Path


class Level(IntEnum):
    DEBUG = 0
    INFO = 1
    WARN = 2
    ERROR = 3


_LEVEL_NAMES = {name: member for name, member in Level.__members__.items()}


def _parse_level(s: str) -> Level:
    return _LEVEL_NAMES.get(s.upper(), Level.INFO)


class Logger:
    __slots__ = ("component", "threshold")

    def __init__(self, component: str, threshold: Level | None = None):
        self.component = component
        if threshold is None:
            threshold = _parse_level(os.environ.get("CLAUDEBOT_LOG_LEVEL", "INFO"))
        self.threshold = threshold

    def _emit(self, level: Level, msg: str, *extras: str) -> None:
        if level < self.threshold:
            return

        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
        line = f'{ts} level={level.name} component={self.component} msg="{msg}"'

        for kv in extras:
            line += f" {kv}"

        print(line, file=sys.stderr)

        plugin_dir = os.environ.get("CLAUDEBOT_PLUGIN_DIR", "")
        if plugin_dir:
            log_dir = Path(plugin_dir) / "logs"
            if log_dir.is_dir():
                log_file = log_dir / f"bot-{datetime.now().strftime('%Y%m%d')}.log"
                with open(log_file, "a") as f:
                    f.write(line + "\n")

    def debug(self, msg: str, *extras: str) -> None:
        self._emit(Level.DEBUG, msg, *extras)

    def info(self, msg: str, *extras: str) -> None:
        self._emit(Level.INFO, msg, *extras)

    def warn(self, msg: str, *extras: str) -> None:
        self._emit(Level.WARN, msg, *extras)

    def error(self, msg: str, *extras: str) -> None:
        self._emit(Level.ERROR, msg, *extras)


def get_logger(component: str) -> Logger:
    return Logger(component)


if __name__ == "__main__":
    # CLI: python3 log_lib.py <component> <level> <msg> [key=val ...]
    if len(sys.argv) < 4:
        print(
            "Usage: python3 log_lib.py <component> <level> <msg> [key=val ...]",
            file=sys.stderr,
        )
        sys.exit(1)

    component = sys.argv[1]
    level_str = sys.argv[2].upper()
    msg = sys.argv[3]
    extras = sys.argv[4:]

    logger = get_logger(component)
    level = _parse_level(level_str)
    logger._emit(level, msg, *extras)
