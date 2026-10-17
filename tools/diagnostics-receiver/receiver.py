#!/usr/bin/env python3
"""A small, private receiver for Muesli's opt-in diagnostics. Python 3.9+, standard library only.

    DIAG_API_KEY=$(openssl rand -hex 24) python3 receiver.py

The full guide is docs/diagnostics-receiver.md. In short:

- Binds to 127.0.0.1. Put Tailscale Serve (or another private HTTPS proxy) in front of it.
- Refuses to start without an API key of at least 16 characters (DIAG_API_KEY or --key-file).
- POST /v1/diagnostics takes the app's batch. An event the app's allowlist does not know is dropped and
  counted, a bad envelope rejects the batch, and a repeated batch_id is acknowledged and stored once.
- GET /v1/diagnostics/recent and /v1/diagnostics/devices read it back. Every route needs the key.
- Logs ids and counts, never event values, query strings or the key.
"""
import argparse
import hmac
import ipaddress
import json
import logging
import os
import re
import socket
import sqlite3
import stat
import sys
import threading
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8750
MIN_KEY_LENGTH = 16
MAX_BODY_BYTES = 256 * 1024
MAX_EVENTS = 500  # per batch. The app sends at most 100.
MAX_ATTRS = 64
MAX_LIMIT = 2000
DEFAULT_LIMIT = 200
RATE_WINDOW_S = 60.0
TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"

log = logging.getLogger("diagnostics_receiver")

# ---------------------------------------------------------------------------------------------------------
# The app's closed vocabulary. Copied from Shared/DiagnosticsShipping/DiagnosticsVocabulary.swift;
# test_receiver.py fails when the two drift apart.
# ---------------------------------------------------------------------------------------------------------

EVENTS = frozenset("""
ack.retry ack.timedOut handoff.observed insert.performed insert.skipped
intent.start intent.stop intent.captureEntered intent.captureExited
keyboard.appeared keyboard.disappeared keyboard.autoOff keyboard.persistencePreferenceChanged
level.freshness model.select rewrite.skipped
live_typing.unsupported live_typing.detached live_typing.yielded live_typing.final_withheld
audioSession.activated audioSession.activateRequested audioSession.configureRequested
audioSession.deactivated audioSession.deactivateRequested audioSession.deactivationFailed
audioSession.failed audioSession.inputConfigured audioSession.interruption
audioSession.interruptionHandling audioSession.mediaServicesReset audioSession.routeChanged
audioSession.routeHandling
keyboardMic.activityFailed keyboardMic.ioConfiguration keyboardMic.retryWithOutput
keyboardMic.started keyboardMic.startFailed keyboardMic.startStep
recorder.engineStarted recorder.ioConfiguration recorder.prepareCompleted
recorder.prepareRequested recorder_start_failed
recording.audioEstablished recording.engineAttempt recording.inputReady
recording.interruptedStop recording.recovery recording.recoveryRejected recording.started
recording.startFailed recording.startRequested recording.startRetry
dictation.delivery dictation.finalText preview.persistFailed
startup.exited startup.permissionRequested startup.permissionResolved
liveActivity.failed liveActivity.skipped liveActivity.started livePreview.memoryWarning
model.prewarm.backingOff whisper.loaded
scene.active scene.inactive scene.background
handoff.saved stop.received stop.ignored recording.stopped transcription.started
transcription.finished transcription.failed result.persisted delivery.outcome
dictation.cancelled dictation.exit backgroundTask app.memoryWarning app.thermalState
transcribe.trimmed transcribe.tail_dropped transcribe.skipped_silent
""".split())

THERMAL = ("nominal", "fair", "serious", "critical")


def _keys(kind, allowed, *names):
    return {name: (kind, frozenset(allowed) if allowed else None) for name in names}


KEY_RULES = {
    **_keys("uuid", None, "capture_request", "intent_invocation", "history_id"),
    **_keys("request_id", None, "request"),
    **_keys("optional_id", None, "active", "active_request", "session", "mic_generation"),
    **_keys("int", None, "type", "attempt", "elapsed_ms", "duration_ms", "samples", "bytes", "characters", "code",
            "options", "options_before", "channels", "app_state", "audio_ms", "heartbeat_age_ms",
            "bg_remaining_ms", "leading_ms", "trailing_ms", "phrase_len"),
    **_keys("code_or_int", None, "reason"),
    **_keys("flag", None, "should_resume", "enabled", "startup", "recording", "protected_data", "persistent",
            "loaded", "input_enabled", "output_enabled", "input_available", "other_audio", "file_written", "empty",
            "fresh", "inserted", "matchesActive", "canUseRuntimeStart"),
    **_keys("decimal", None, "sample_rate", "input_sample_rate"),
    **_keys("duration", None, "total_s", "wall_s", "encoder_load_s", "encoder_specialization_s", "decoder_load_s",
            "decoder_specialization_s", "age", "appSeenAt"),
    **_keys("identifier", None, "model", "variant", "source", "trigger", "kind", "error", "stage", "step", "caller",
            "file", "category", "category_before", "mode", "mode_before", "preference", "phase", "localPhase",
            "appPhase"),
    **_keys("identifier_list", None, "input_ports", "output_ports"),
    **_keys("error_domain", None, "domain"),
    **_keys("one_of", ("saved", "failed", "cancelled", "superseded", "abandoned", "missingAudio",
                       "noRecoverableRecording"), "outcome"),
    **_keys("one_of", ("requested", "startup", "recording", "stopping", "finalizingAudio", "transcribing",
                       "persisting", "delivering", "completed"), "last_stage", "cancel_stage"),
    **_keys("one_of", ("keyboardCommand", "appUser", "taskCancelled", "unknown"), "cancel_by"),
    **_keys("one_of", ("conflictingCommand", "notRecording", "lifecycleRejected", "noActiveRequest",
                       "recoveredFromStorage"), "ignored_reason"),
    **_keys("one_of", ("onDevice", "remote", "streaming"), "text_source"),
    **_keys("one_of", ("timeout", "interrupted", "engineFailure", "audioUnavailable", "checkpointFailure",
                       "unknown"), "failure"),
    **_keys("one_of", ("insertDirect", "copied", "copyRequired"), "route"),
    **_keys("one_of", ("ok", "noExtensionStatus", "noOpenAccess", "notVisible", "heartbeatStale"), "route_reason"),
    **_keys("one_of", ("begin", "denied", "end", "expired"), "bg_state"),
    **_keys("one_of", THERMAL, "thermal"),
    **_keys("one_of", ("clipboard", "foregroundCopyRequired"), "destination"),
}

# ---------------------------------------------------------------------------------------------------------
# Validation. Every pattern is applied with fullmatch: `$` would accept a trailing newline.
# ---------------------------------------------------------------------------------------------------------

NAME_RE = re.compile(r"[A-Za-z0-9_.-]{1,64}")
VALUE_RE = re.compile(r"[A-Za-z0-9_.:=/+\- ]{0,128}")
META_RE = re.compile(r"[A-Za-z0-9_.:=/+, \-]{1,64}")  # "iPhone18,4" has a comma
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
SHORT_ID_RE = re.compile(r"[0-9a-f]{8}")
INT_RE = re.compile(r"-?[0-9]{1,12}")
DECIMAL_RE = re.compile(r"-?[0-9]{1,10}(\.[0-9]{1,6})?")
IDENTIFIER_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.:\-]*")
TIME_RE = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,9}))?)?"
    r"(Z|[+-][0-9]{2}:?[0-9]{2})?")
INT_LIMIT = 2 ** 53


class BadEnvelope(Exception):
    """The batch is rejected. The message is a fixed string that names our own field, never a request value."""


def normalize_time(text):
    """A UTC `YYYY-MM-DDTHH:MM:SS.ffffffZ` string, so string order is time order, or None."""
    if not isinstance(text, str) or len(text) > 40:
        return None
    match = TIME_RE.fullmatch(text)
    if not match:
        return None
    year, month, day, hour, minute, second, fraction, zone = match.groups()
    try:
        moment = datetime(int(year), int(month), int(day), int(hour), int(minute), int(second or 0),
                          int((fraction or "0").ljust(6, "0")[:6]), tzinfo=timezone.utc)
        if zone and zone != "Z":
            digits = zone[1:].replace(":", "")
            offset = timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
            moment -= offset if zone[0] == "+" else -offset
    except (ValueError, OverflowError):
        return None
    return moment.strftime(TIME_FORMAT)


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and abs(value) <= 999_999_999_999


def _is_identifier(value, longest=48):
    """A letter, then letters, digits and `_ . : -`; short; not ending in a dot (a cut-off value)."""
    return (isinstance(value, str) and len(value) <= longest and IDENTIFIER_RE.fullmatch(value) is not None
            and not value.endswith("."))


def _is_identifier_list(value):
    if not isinstance(value, str) or len(value) > 160:
        return False
    if value == "":
        return True
    items = value.split("+")
    return len(items) <= 8 and all(_is_identifier(item) for item in items)


def _is_duration(value):
    if not isinstance(value, str):
        return False
    if value in ("none", "never", "unlimited"):
        return True
    return len(value) <= 14 and DECIMAL_RE.fullmatch(value[:-1] if value.endswith("s") else value) is not None


def _is_error_domain(value):
    return _is_identifier(value, 64) and ("." in value or value.endswith("Domain"))


_SHAPES = {
    "uuid": lambda v, _: isinstance(v, str) and UUID_RE.fullmatch(v) is not None,
    "request_id": lambda v, _: isinstance(v, str) and (UUID_RE.fullmatch(v) or SHORT_ID_RE.fullmatch(v)) is not None,
    "optional_id": lambda v, _: isinstance(v, str) and (
        v == "none" or UUID_RE.fullmatch(v) is not None or SHORT_ID_RE.fullmatch(v) is not None),
    "int": lambda v, _: _is_int(v),
    # The app sends `reason` as text even when it holds digits (only `int` keys go out as JSON numbers).
    "code_or_int": lambda v, _: _is_int(v) or (isinstance(v, str) and INT_RE.fullmatch(v) is not None) or _is_identifier(v),
    "flag": lambda v, _: isinstance(v, bool) or v in ("true", "false", "yes", "no"),
    "decimal": lambda v, _: isinstance(v, str) and DECIMAL_RE.fullmatch(v) is not None,
    "duration": lambda v, _: _is_duration(v),
    "identifier": lambda v, _: _is_identifier(v),
    "identifier_list": lambda v, _: _is_identifier_list(v),
    "error_domain": lambda v, _: _is_error_domain(v),
    "one_of": lambda v, allowed: isinstance(v, str) and v in allowed,
}


def value_ok(key, value):
    """True when `value` has the shape the app's vocabulary allows for `key`. Floats never do."""
    rule = KEY_RULES.get(key)
    return rule is not None and _SHAPES[rule[0]](value, rule[1])


def _uuid(value, field):
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        raise BadEnvelope(f"invalid {field}")
    return value.lower()


def _uint(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= INT_LIMIT:
        raise BadEnvelope(f"invalid {field}")
    return value


def _meta(value, field):
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= INT_LIMIT:
        value = str(value)
    if not isinstance(value, str) or not META_RE.fullmatch(value):
        raise BadEnvelope(f"invalid {field}")
    return value


def parse_envelope(doc, max_events=MAX_EVENTS):
    """The batch's fields as a dict, or BadEnvelope. Unknown top-level fields (schema, sent_at, trigger) are ignored."""
    if not isinstance(doc, dict):
        raise BadEnvelope("the body must be a JSON object")
    app = doc.get("app")
    if not isinstance(app, dict):
        raise BadEnvelope("invalid app")
    thermal = doc.get("thermal")
    if not isinstance(thermal, str) or thermal not in THERMAL:
        raise BadEnvelope("invalid thermal")
    events = doc.get("events")
    if not isinstance(events, list):
        raise BadEnvelope("invalid events")
    if len(events) > max_events:
        raise BadEnvelope(f"too many events: at most {max_events} per batch")
    return {
        "device_id": _uuid(doc.get("device_id"), "device_id"),
        "batch_id": _uuid(doc.get("batch_id"), "batch_id"),
        "seq": _uint(doc.get("seq"), "seq"),
        "app": {"version": _meta(app.get("version"), "app.version"), "build": _meta(app.get("build"), "app.build")},
        "os": _meta(doc.get("os"), "os"),
        "model": _meta(doc.get("model"), "model"),
        "thermal": thermal,
        "dropped": _uint(doc.get("dropped"), "dropped"),
        "events": events,
    }


def clean_event(raw):
    """The event reduced to t, proc, name and attrs, or None when it is not on the app's allowlist."""
    if not isinstance(raw, dict):
        return None
    t, name, proc, attrs = normalize_time(raw.get("t")), raw.get("name"), raw.get("proc"), raw.get("attrs", {})
    if t is None or name not in EVENTS or not isinstance(proc, str) or not NAME_RE.fullmatch(proc):
        return None
    if not isinstance(attrs, dict) or len(attrs) > MAX_ATTRS:
        return None
    if not all(isinstance(key, str) and value_ok(key, value) for key, value in attrs.items()):
        return None
    return {"t": t, "proc": proc, "name": name, "attrs": dict(attrs)}


# ---------------------------------------------------------------------------------------------------------
# Storage: one SQLite file. Everything runs under one lock; the volume is a few batches a minute.
# ---------------------------------------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, received TEXT NOT NULL, device_id TEXT NOT NULL, batch_id TEXT NOT NULL,
    seq INTEGER NOT NULL, app_version TEXT NOT NULL, app_build TEXT NOT NULL, os TEXT NOT NULL,
    model TEXT NOT NULL, thermal TEXT NOT NULL, client_dropped INTEGER NOT NULL,
    t TEXT NOT NULL, proc TEXT NOT NULL, name TEXT NOT NULL, attrs TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS events_device_t ON events (device_id, t);
CREATE INDEX IF NOT EXISTS events_received ON events (received);
CREATE TABLE IF NOT EXISTS batches (
    device_id TEXT NOT NULL, batch_id TEXT NOT NULL, received TEXT NOT NULL, PRIMARY KEY (device_id, batch_id));
CREATE INDEX IF NOT EXISTS batches_received ON batches (received);
"""


class RateLimited(Exception):
    def __init__(self, retry_after):
        super().__init__("rate limited")
        self.retry_after = retry_after


class Store:
    def __init__(self, path, rate_per_min=60, max_days=14, max_events=1_000_000, monotonic=time.monotonic):
        path = Path(path).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        os.close(os.open(path, os.O_RDWR | os.O_CREAT, 0o600))  # created private; an existing file is kept as is
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()
        self.rate_per_min, self.max_days, self.max_events, self.monotonic = rate_per_min, max_days, max_events, monotonic
        self._rate = {}

    def close(self):
        with self.lock:
            self.db.close()

    def _rate_check(self, device):
        now, window = self.monotonic(), self._rate.setdefault(device, deque())
        while window and now - window[0] >= RATE_WINDOW_S:
            window.popleft()
        if len(window) >= self.rate_per_min:
            raise RateLimited(max(1, int(RATE_WINDOW_S - (now - window[0])) + 1))
        window.append(now)
        if len(self._rate) > 1024:
            self._rate = {d: w for d, w in self._rate.items() if w and now - w[-1] < RATE_WINDOW_S}

    def ingest(self, env, events):
        """Store the cleaned events of one batch. Returns True when the batch id was already seen."""
        with self.lock:
            self._rate_check(env["device_id"])
            if self.db.execute("SELECT 1 FROM batches WHERE device_id=? AND batch_id=?",
                               (env["device_id"], env["batch_id"])).fetchone():
                return True
            received = datetime.now(timezone.utc).strftime(TIME_FORMAT)
            rows = [(received, env["device_id"], env["batch_id"], env["seq"], env["app"]["version"],
                     env["app"]["build"], env["os"], env["model"], env["thermal"], env["dropped"],
                     e["t"], e["proc"], e["name"], json.dumps(e["attrs"], separators=(",", ":"), ensure_ascii=True))
                    for e in events]
            self.db.execute("BEGIN")
            try:
                self.db.executemany("INSERT INTO events (received, device_id, batch_id, seq, app_version, app_build,"
                                    " os, model, thermal, client_dropped, t, proc, name, attrs)"
                                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
                self.db.execute("INSERT INTO batches VALUES (?,?,?)", (env["device_id"], env["batch_id"], received))
                self._retain(received)
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
            return False

    def _retain(self, received):
        cutoff = (datetime.strptime(received, TIME_FORMAT) - timedelta(days=self.max_days)).strftime(TIME_FORMAT)
        self.db.execute("DELETE FROM events WHERE received < ?", (cutoff,))
        self.db.execute("DELETE FROM batches WHERE received < ?", (cutoff,))
        self.db.execute("DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?", (self.max_events,))

    def devices(self):
        with self.lock:
            rows = self.db.execute("SELECT device_id, MAX(received), COUNT(*) FROM events GROUP BY device_id"
                                   " ORDER BY MAX(id) DESC").fetchall()
        return [{"device_id": d, "last_seen": received[:19] + "Z", "events": count} for d, received, count in rows]

    def latest_device(self):
        with self.lock:
            row = self.db.execute("SELECT device_id FROM events ORDER BY id DESC LIMIT 1").fetchone()
        return row[0] if row else None

    def recent(self, device, since, limit, name, request):
        """The `limit` latest events of one device by event time, oldest first."""
        sql, args = "SELECT * FROM events WHERE device_id=?", [device]
        if since:
            sql, args = sql + " AND t >= ?", args + [since]
        if name:
            sql, args = sql + " AND substr(name, 1, ?) = ?", args + [len(name), name]
        if request:
            sql += " AND (json_extract(attrs, '$.request') = ? OR json_extract(attrs, '$.capture_request') = ?)"
            args += [request, request]
        with self.lock:
            cursor = self.db.execute(sql + " ORDER BY t DESC, id DESC LIMIT ?", args + [limit])
            columns = [c[0] for c in cursor.description]
            rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
        return [_public(row) for row in reversed(rows)]


def _public(row):
    return {"received": row["received"], "device_id": row["device_id"], "batch_id": row["batch_id"], "seq": row["seq"],
            "app": {"version": row["app_version"], "build": row["app_build"]}, "os": row["os"], "model": row["model"],
            "thermal": row["thermal"], "client_dropped": row["client_dropped"], "t": row["t"], "proc": row["proc"],
            "name": row["name"], "attrs": json.loads(row["attrs"])}


# ---------------------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------------------

POST_PATH = "/v1/diagnostics"
READ_PATHS = ("/v1/diagnostics/recent", "/v1/diagnostics/devices")
LINGER_BYTES = 1024 * 1024


class BadQuery(Exception):
    pass


def parse_query(query):
    params = {k: v[-1] for k, v in parse_qs(query, keep_blank_values=True).items()}
    device, since, name, request = params.get("device"), params.get("since"), params.get("name"), params.get("request")
    if device is not None and not UUID_RE.fullmatch(device):
        raise BadQuery("invalid device")
    if since is not None and (since := normalize_time(since)) is None:
        raise BadQuery("invalid since: use an ISO 8601 time")
    if name is not None and not NAME_RE.fullmatch(name):
        raise BadQuery("invalid name")
    if request is not None and not (request and VALUE_RE.fullmatch(request)):
        raise BadQuery("invalid request")
    text = params.get("limit")
    if text is None:
        limit = DEFAULT_LIMIT
    elif not (text.isascii() and text.isdigit() and len(text) <= 6) or int(text) < 1:
        raise BadQuery("limit must be a positive integer")
    else:
        limit = min(int(text), MAX_LIMIT)
    return {"device": device.lower() if device else None, "since": since, "limit": limit, "name": name,
            "request": request}


class Handler(BaseHTTPRequestHandler):
    server_version = "muesli-diagnostics-receiver"
    sys_version = ""
    timeout = 15  # a client that stalls mid-request is cut off, not waited for

    # -- plumbing --

    def log_message(self, format, *args):  # noqa: A002 - the stdlib's signature
        pass  # replaced by `_log_request`: the stdlib line would carry the query string

    def _log_request(self, status):
        log.info("%s %s -> %d", self.command, urlsplit(self.path).path, status)

    def _send(self, status, doc, headers=None):
        body = json.dumps(doc, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self._log_request(status)
        if self.command == "POST" and not self._body_read:
            self._linger()

    def _error(self, status, message, kind="invalid_request_error", headers=None):
        self._send(status, {"error": {"message": message, "type": kind}}, headers)

    def _linger(self):
        """Closing with unread request data makes the OS reset the connection, which can destroy the response
        before the client reads it. Say we are done sending, then drain a bounded amount."""
        try:
            self.connection.shutdown(socket.SHUT_WR)
            self.connection.settimeout(2)
            drained = 0
            while drained < LINGER_BYTES:
                chunk = self.connection.recv(65536)
                if not chunk:
                    break
                drained += len(chunk)
        except OSError:
            pass

    def _authorized(self):
        scheme, _, token = self.headers.get("Authorization", "").partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(token.strip().encode(), self.server.api_key)

    def _gate(self):
        """False after sending 401, so the caller stops before any work."""
        if self._authorized():
            return True
        self._error(401, "missing or invalid API key", "authentication_error", {"WWW-Authenticate": "Bearer"})
        return False

    # -- routing --

    def do_POST(self):
        self._body_read = False
        path = urlsplit(self.path).path
        if path in READ_PATHS:
            return self._error(405, "use GET", headers={"Allow": "GET"})
        if path != POST_PATH:
            return self._error(404, "not found")
        if self._gate():
            self._post()

    def do_GET(self):
        self._body_read = True
        parts = urlsplit(self.path)
        if parts.path == POST_PATH:
            return self._error(405, "use POST", headers={"Allow": "POST"})
        if parts.path not in READ_PATHS:
            return self._error(404, "not found")
        if not self._gate():
            return
        try:
            query = parse_query(parts.query)
        except BadQuery as e:
            return self._error(400, str(e))
        if parts.path.endswith("/devices"):
            return self._send(200, {"devices": self.server.store.devices()})
        store = self.server.store
        device = query.pop("device") or store.latest_device()
        events = store.recent(device, **query) if device else []
        self._send(200, {"device": device, "events": events})

    def _method_not_allowed(self):
        self._body_read = False
        self._error(405, "method not allowed")

    do_PUT = do_PATCH = do_DELETE = _method_not_allowed

    # -- POST /v1/diagnostics --

    def _post(self):
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            return self._error(415, "the content type must be application/json")
        try:
            body = _read_body(self)
            self._body_read = True
            env = parse_envelope(_decode(body), self.server.max_batch_events)
        except BodyError as e:
            return self._error(e.status, str(e))
        except BadEnvelope as e:
            return self._error(400, str(e))
        cleaned = [c for c in map(clean_event, env["events"]) if c is not None]
        try:
            duplicate = self.server.store.ingest(env, cleaned)
        except RateLimited as e:
            log.info("diag device=%s rate-limited retry_after=%d", env["device_id"], e.retry_after)
            return self._error(429, "too many batches; retry later", "rate_limit_error",
                               {"Retry-After": str(e.retry_after)})
        except Exception as e:  # noqa: BLE001 - the message can hold a path; only the type is logged
            log.error("storage failed: %s", type(e).__name__)
            return self._error(500, "diagnostics storage failed", "server_error")
        accepted = 0 if duplicate else len(cleaned)
        dropped = 0 if duplicate else len(env["events"]) - len(cleaned)
        log.info("diag device=%s batch=%s accepted=%d dropped=%d duplicate=%s",
                 env["device_id"], env["batch_id"], accepted, dropped, duplicate)
        self._send(200, {"accepted": accepted, "dropped": dropped, "duplicate": duplicate})


class BodyError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def _too_large(limit):
    return BodyError(413, f"the body is larger than {limit // 1024} KB")


def _read_body(handler):
    """The request body, bounded by the server's cap. Both Content-Length and chunked uploads are accepted: a
    proxy may re-chunk, and the app drops a batch the server refuses with a 4xx."""
    limit = handler.server.max_body
    if "chunked" in handler.headers.get("Transfer-Encoding", "").lower():
        return _read_chunked(handler.rfile, limit)
    declared = handler.headers.get("Content-Length", "")
    if not declared:
        raise BodyError(411, "send a Content-Length or a chunked body")
    if not (declared.isascii() and declared.isdigit()):
        raise BodyError(400, "invalid Content-Length")
    if int(declared) > limit:
        raise _too_large(limit)
    body = handler.rfile.read(int(declared))
    if len(body) != int(declared):
        raise BodyError(400, "the body ended early")
    return body


def _read_chunked(rfile, limit):
    body = bytearray()
    while True:
        size_line = rfile.readline(34).split(b";")[0].strip()
        if not re.fullmatch(rb"[0-9a-fA-F]{1,8}", size_line):
            raise BodyError(400, "invalid chunk size")
        size = int(size_line, 16)
        if size == 0:
            for _ in range(16):  # trailers: read to the blank line and ignore them
                if rfile.readline(8192).strip() == b"":
                    return bytes(body)
            raise BodyError(400, "too many trailers")
        if len(body) + size > limit:
            raise _too_large(limit)
        chunk = rfile.read(size)
        if len(chunk) != size or rfile.read(2) != b"\r\n":
            raise BodyError(400, "the body ended early")
        body += chunk


def _reject_constant(name):
    raise ValueError("non-finite number")


def _decode(body):
    try:
        return json.loads(body.decode("utf-8"), parse_constant=_reject_constant)
    except (ValueError, RecursionError):
        raise BadEnvelope("the body is not valid JSON") from None


class Receiver(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, key, store, max_body, max_batch_events):
        super().__init__(address, Handler)
        self.api_key, self.store, self.max_body, self.max_batch_events = key.encode(), store, max_body, max_batch_events

    def server_close(self):
        super().server_close()
        self.store.close()

    def handle_error(self, request, client_address):
        log.info("connection error: %s", type(sys.exc_info()[1]).__name__)  # the stdlib would print a traceback


def make_server(host, port, key, db_path, *, max_body=MAX_BODY_BYTES, rate_per_min=60, max_days=14,
                max_events=1_000_000, max_batch_events=MAX_EVENTS):
    """A ready server, not yet serving: call serve_forever(). `port` 0 picks a free one."""
    check_key(key)
    store = Store(db_path, rate_per_min=rate_per_min, max_days=max_days, max_events=max_events)
    return Receiver((host, port), key, store, max_body, max_batch_events)


# ---------------------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------------------

def check_key(key):
    if len(key) < MIN_KEY_LENGTH:
        raise SystemExit(f"the API key must be at least {MIN_KEY_LENGTH} characters (try: openssl rand -hex 24)")
    if not key.isascii() or not key.isprintable() or " " in key:
        raise SystemExit("the API key must be printable ASCII without spaces")


def load_key(env=None, key_file=None):
    """The key from --key-file (which must not be readable by others) or DIAG_API_KEY. Exits when there is none."""
    env = os.environ if env is None else env
    if key_file:
        mode = stat.S_IMODE(os.stat(key_file).st_mode)
        if mode & 0o077:
            raise SystemExit(f"{key_file} is readable by other users: run chmod 600 on it")
        key = Path(key_file).read_text().strip()
    else:
        key = env.get("DIAG_API_KEY", "").strip()
    if not key:
        raise SystemExit("no API key: set DIAG_API_KEY or pass --key-file (try: openssl rand -hex 24)")
    check_key(key)
    return key


def _is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Receive Muesli's opt-in diagnostics. See docs/diagnostics-receiver.md.")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"address to bind (default {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"port (default {DEFAULT_PORT})")
    parser.add_argument("--db", default=os.environ.get("DIAG_DB", "diagnostics.db"), help="SQLite file (or DIAG_DB)")
    parser.add_argument("--key-file", help="file holding the API key (mode 600); otherwise DIAG_API_KEY")
    parser.add_argument("--max-days", type=int, default=14, help="days of events to keep (default 14)")
    parser.add_argument("--max-events", type=int, default=1_000_000, help="most events to keep (default 1000000)")
    parser.add_argument("--rate-per-min", type=int, default=60, help="batches per device per minute (default 60)")
    parser.add_argument("--allow-remote", action="store_true",
                        help="bind a non-loopback address. This is plain HTTP: only behind a private HTTPS proxy")
    args = parser.parse_args(argv)
    key = load_key(key_file=args.key_file)
    if not _is_loopback(args.host) and not args.allow_remote:
        raise SystemExit(f"{args.host} is not a loopback address: pass --allow-remote if a private proxy fronts this")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stderr)
    server = make_server(args.host, args.port, key, args.db, rate_per_min=args.rate_per_min,
                         max_days=args.max_days, max_events=args.max_events)
    log.info("listening on %s:%d, storing to %s", args.host, server.server_address[1], Path(args.db).expanduser())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
