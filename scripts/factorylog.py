"""
Structured logging for the Python tools (imagefactory.py, the portal scripts).

    from factorylog import get_logger
    log = get_logger("imagefactory")
    log.info("planned image", extra={"fields": {"image": name, "targets": "azure"}})

Same contract as scripts/ci/log.sh:
  - stderr: "<UTC time> <LEVEL> [component] message key=value"
  - $FACTORY_LOG_DIR/events.jsonl: one JSON object per record, with the
    correlation fields (FACTORY_CORRELATION_ID, run id, job, REQUEST_REF)
  - level from FACTORY_LOG_LEVEL (debug when RUNNER_DEBUG=1)
stdout stays free for the tools' real output (JSON, file lists).
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import sys
from pathlib import Path

_LEVELS = {"debug": logging.DEBUG, "info": logging.INFO, "warn": logging.WARNING, "error": logging.ERROR}


def _level() -> int:
    name = os.environ.get("FACTORY_LOG_LEVEL") or ("debug" if os.environ.get("RUNNER_DEBUG") == "1" else "info")
    return _LEVELS.get(name.lower(), logging.INFO)


def correlation_id() -> str:
    if os.environ.get("FACTORY_CORRELATION_ID"):
        return os.environ["FACTORY_CORRELATION_ID"]
    if os.environ.get("GITHUB_RUN_ID"):
        return f"gh-{os.environ['GITHUB_RUN_ID']}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    if os.environ.get("CI_PIPELINE_ID"):
        return f"gl-{os.environ['CI_PIPELINE_ID']}"
    return "local"


def _fields(record: logging.LogRecord) -> dict:
    return dict(getattr(record, "fields", {}) or {})


class _ConsoleFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        ts = dt.datetime.fromtimestamp(record.created, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        kv = "".join(f" {k}={v}" for k, v in _fields(record).items())
        line = f"{ts} {record.levelname:<5} [{record.name}] {record.getMessage()}{kv}"
        if record.exc_info:
            line += "\n" + self.formatException(record.exc_info)
        return line


class _JsonFileHandler(logging.Handler):
    def __init__(self) -> None:
        super().__init__()
        self.path = Path(os.environ.get("FACTORY_LOG_DIR", "build/logs")) / "events.jsonl"

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            doc = {
                "ts": dt.datetime.fromtimestamp(record.created, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "level": {"WARNING": "warn"}.get(record.levelname, record.levelname.lower()),
                "component": record.name,
                "msg": record.getMessage(),
                "correlation_id": correlation_id(),
                "run_id": os.environ.get("GITHUB_RUN_ID") or os.environ.get("CI_PIPELINE_ID", ""),
                "job": os.environ.get("GITHUB_JOB") or os.environ.get("CI_JOB_NAME", ""),
                "request_ref": os.environ.get("REQUEST_REF", ""),
                **{k: str(v) for k, v in _fields(record).items()},
            }
            if record.exc_info:
                doc["exception"] = logging.Formatter().formatException(record.exc_info)
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(doc, separators=(",", ":")) + "\n")
        except OSError:
            pass  # logging must never break the tool


class _GithubAnnotations(logging.Handler):
    """Warnings and errors show up as annotations on the run page."""

    def emit(self, record: logging.LogRecord) -> None:
        if record.levelno >= logging.ERROR:
            print(f"::error title={record.name}::{record.getMessage()}", file=sys.stdout)
        elif record.levelno >= logging.WARNING:
            print(f"::warning title={record.name}::{record.getMessage()}", file=sys.stdout)


def get_logger(component: str) -> logging.Logger:
    log = logging.getLogger(component)
    if log.handlers:
        return log
    log.setLevel(_level())
    log.propagate = False
    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(_ConsoleFormatter())
    log.addHandler(console)
    log.addHandler(_JsonFileHandler())
    if os.environ.get("GITHUB_ACTIONS") == "true":
        log.addHandler(_GithubAnnotations())
    return log


def fields(**kw: object) -> dict:
    """Shorthand: log.info("msg", extra=fields(image=name))."""
    return {"fields": kw}
