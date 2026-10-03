#!/usr/local/bin/python3
"""Authenticated control helper for one notebook runner machine on Fly.

Adapted from marimohub's compute-fargate agent. The helper runs as root so it
can keep its token away from notebook code: every command, process, file read
and file write runs as the unprivileged notebook user, whose environment never
holds the token and who cannot read root's /proc entries. The helper only ever
runs root-owned programs by absolute path; the notebook user owns the Python
environment under /opt/marimohub.
"""

from __future__ import annotations

import base64
import binascii
import hmac
import http.server
import json
import os
import pwd
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from typing import Any

PROTOCOL_VERSION = 1
MAX_BODY_BYTES = 40 * 1024 * 1024
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_WRITE_BATCH_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = ((MAX_FILE_BYTES + 2) // 3) * 4
MAX_LOG_BYTES = 64 * 1024
TOKEN_VARIABLE = "MARIMOHUB_AGENT_TOKEN"
NOTEBOOK_USER = "appuser"
SHELL = "/bin/sh"
PYTHON = "/usr/local/bin/python3"

# Run as the notebook user: read one file, refusing anything over the limit.
READ_FILE = """
import sys
path, limit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, 'rb') as stream:
        data = stream.read(limit + 1)
except FileNotFoundError:
    sys.exit(2)
except IsADirectoryError:
    sys.exit(3)
except OSError:
    sys.exit(5)
if len(data) > limit:
    sys.exit(4)
sys.stdout.buffer.write(data)
"""

# Run as the notebook user: write each file atomically, creating parents.
WRITE_FILES = """
import base64, json, os, secrets, sys
for path, encoded in json.load(sys.stdin):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    temporary = f"{path}.marimohub-{secrets.token_hex(6)}.tmp"
    with open(temporary, 'wb') as stream:
        stream.write(base64.b64decode(encoded))
    os.replace(temporary, path)
"""


class HelperError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def _bounded_timeout(value: Any, default: int = 30_000) -> float:
    if value is None:
        return default / 1000
    if isinstance(value, bool):
        raise HelperError(400, "timeoutMs must be an integer")
    try:
        milliseconds = int(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise HelperError(400, "timeoutMs must be an integer") from exc
    if isinstance(value, float) and value != milliseconds:
        raise HelperError(400, "timeoutMs must be an integer")
    if milliseconds < 0:
        raise HelperError(400, "timeoutMs must not be negative")
    return milliseconds / 1000


def _kill_group(process: subprocess.Popen[Any], sig: int = signal.SIGTERM) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        return


def _wait_process(process: subprocess.Popen[Any], timeout: float) -> int:
    try:
        return process.wait(timeout=None if timeout == 0 else timeout)
    except subprocess.TimeoutExpired:
        _kill_group(process, signal.SIGKILL)
        process.wait()
        return 124


class _BoundedCapture:
    def __init__(self, stream: Any, limit: int, keep_tail: bool):
        self._stream = stream
        self._limit = limit
        self._keep_tail = keep_tail
        self._data = bytearray()
        self._truncated = False
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._drain, daemon=True)
        self._thread.start()

    def _drain(self) -> None:
        try:
            while chunk := self._stream.read1(64 * 1024):
                with self._lock:
                    if self._keep_tail:
                        self._data.extend(chunk)
                        excess = len(self._data) - self._limit
                        if excess > 0:
                            self._truncated = True
                            del self._data[:excess]
                    else:
                        remaining = self._limit - len(self._data)
                        if len(chunk) > remaining:
                            self._truncated = True
                        if remaining > 0:
                            self._data.extend(chunk[:remaining])
        finally:
            self._stream.close()

    def wait(self, timeout: float | None = None) -> bool:
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def read(self) -> bytes:
        with self._lock:
            return bytes(self._data)

    def truncated(self) -> bool:
        with self._lock:
            return self._truncated


class ProcessTable:
    def __init__(self, state: "HelperState"):
        self._state = state
        self._items: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def _remove(self, process_id: str, item: dict[str, Any]) -> None:
        with self._lock:
            if self._items.get(process_id) is item:
                del self._items[process_id]

    def capture_finished(self, item: dict[str, Any]) -> None:
        with item["capture_lock"]:
            if item.get("captured"):
                return
            item["stdout_capture"].wait()
            item["stderr_capture"].wait()
            item["stdout_tail"] = item["stdout_capture"].read().decode("utf-8", errors="replace")
            item["stderr_tail"] = item["stderr_capture"].read().decode("utf-8", errors="replace")
            item["captured"] = True

    def _watch(self, item: dict[str, Any]) -> None:
        item["process"].wait()
        self.capture_finished(item)

    def _expire(self, item: dict[str, Any], timeout: float) -> None:
        process = item["process"]
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(process, signal.SIGKILL)
            process.wait()
        self.capture_finished(item)

    def start(self, payload: dict[str, Any]) -> str:
        command = payload.get("command")
        if not isinstance(command, str) or not command:
            raise HelperError(400, "command is required")
        process_id = payload.get("processId")
        if not isinstance(process_id, str) or not process_id or len(process_id) > 128:
            process_id = f"fly-{uuid.uuid4().hex}"
        with self._lock:
            existing = self._items.get(process_id)
        if existing is not None:
            if existing["process"].poll() is None:
                raise HelperError(409, "process id already exists")
            self._remove(process_id, existing)
        cwd = payload.get("cwd", "/workspace")
        if not isinstance(cwd, str):
            raise HelperError(400, "cwd must be a string")
        timeout = _bounded_timeout(payload.get("timeoutMs"), 0)
        process = self._state.spawn(command, cwd, payload.get("env"))
        item = {
            "process": process,
            "stdout_capture": _BoundedCapture(process.stdout, MAX_LOG_BYTES, True),
            "stderr_capture": _BoundedCapture(process.stderr, MAX_LOG_BYTES, True),
            "capture_lock": threading.Lock(),
        }
        conflicting = False
        with self._lock:
            existing = self._items.get(process_id)
            if existing is not None and existing["process"].poll() is None:
                conflicting = True
            else:
                self._items[process_id] = item
        if conflicting:
            _kill_group(process, signal.SIGKILL)
            process.wait()
            self.capture_finished(item)
            raise HelperError(409, "process id already exists")
        if timeout:
            threading.Thread(target=self._expire, args=(item, timeout), daemon=True).start()
        else:
            threading.Thread(target=self._watch, args=(item,), daemon=True).start()
        return process_id

    def get(self, process_id: str) -> dict[str, Any]:
        with self._lock:
            item = self._items.get(process_id)
        if item is None:
            raise HelperError(404, "process not found")
        return item

    def kill(self, process_id: str, sig: int = signal.SIGTERM) -> None:
        item = self.get(process_id)
        _kill_group(item["process"], sig)
        try:
            item["process"].wait(timeout=1)
        except subprocess.TimeoutExpired:
            _kill_group(item["process"], signal.SIGKILL)
            item["process"].wait()
        self.capture_finished(item)
        self._remove(process_id, item)

    def logs(self, process_id: str) -> dict[str, str]:
        item = self.get(process_id)
        try:
            if item["process"].poll() is not None:
                self.capture_finished(item)
            if item.get("captured"):
                return {"stdout": item["stdout_tail"], "stderr": item["stderr_tail"]}
            return {
                "stdout": item["stdout_capture"].read().decode("utf-8", errors="replace"),
                "stderr": item["stderr_capture"].read().decode("utf-8", errors="replace"),
            }
        finally:
            if item["process"].poll() is not None:
                self._remove(process_id, item)


class HelperState:
    def __init__(self, token: str, user: str = NOTEBOOK_USER):
        if len(token.encode("utf-8")) < 32:
            raise ValueError(f"{TOKEN_VARIABLE} must be at least 32 bytes")
        self.token = token
        self.user = pwd.getpwnam(user)
        self.forced: dict[str, str] = {}
        self.defaults: dict[str, str] = {}
        self._environment_lock = threading.Lock()
        self.processes = ProcessTable(self)

    def authenticate(self, supplied: str | None) -> bool:
        if not supplied or not supplied.lower().startswith("bearer "):
            return False
        return hmac.compare_digest(supplied[7:].strip().encode("utf-8"), self.token.encode("utf-8"))

    def environment(self, overrides: Any = None) -> dict[str, str]:
        values = dict(os.environ)
        values.update(
            HOME=self.user.pw_dir,
            USER=self.user.pw_name,
            LOGNAME=self.user.pw_name,
        )
        with self._environment_lock:
            defaults = dict(self.defaults)
            forced = dict(self.forced)
        for key, value in defaults.items():
            values.setdefault(key, value)
        if isinstance(overrides, dict):
            for key, value in overrides.items():
                if isinstance(key, str) and isinstance(value, str):
                    values[key] = value
        values.update(forced)
        values.pop(TOKEN_VARIABLE, None)
        return values

    def update_environment(self, forced: dict[str, str], defaults: dict[str, str]) -> None:
        with self._environment_lock:
            self.forced.update(forced)
            self.defaults.update(defaults)

    def _as_user(self) -> dict[str, Any]:
        return {"user": self.user.pw_uid, "group": self.user.pw_gid, "extra_groups": []}

    def spawn(self, command: str, cwd: str, overrides: Any = None) -> subprocess.Popen[bytes]:
        """Start a login-shell command as the notebook user, in its own process group."""
        try:
            return subprocess.Popen(
                [SHELL, "-lc", command],
                cwd=cwd,
                env=self.environment(overrides),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                **self._as_user(),
            )
        except OSError as exc:
            raise HelperError(400, f"could not start command: {exc.strerror or 'spawn failed'}") from exc

    def execute(self, payload: dict[str, Any]) -> dict[str, Any]:
        command = payload.get("command")
        if not isinstance(command, str) or not command:
            raise HelperError(400, "command is required")
        cwd = payload.get("cwd", "/workspace")
        if not isinstance(cwd, str):
            raise HelperError(400, "cwd must be a string")
        timeout = _bounded_timeout(payload.get("timeoutMs"))
        process = self.spawn(command, cwd, payload.get("env"))
        stdout_capture = _BoundedCapture(process.stdout, MAX_OUTPUT_BYTES, False)
        stderr_capture = _BoundedCapture(process.stderr, MAX_OUTPUT_BYTES, False)
        deadline = time.monotonic() + timeout if timeout else None
        code = _wait_process(process, timeout)
        for capture in (stdout_capture, stderr_capture):
            remaining = max(0, deadline - time.monotonic()) if deadline is not None else None
            if not capture.wait(remaining):
                # Descendants can retain the pipes after the command's shell exits.
                _kill_group(process, signal.SIGKILL)
                code = 124
                capture.wait()
        if stdout_capture.truncated() or stderr_capture.truncated():
            return {
                "success": False,
                "exitCode": code,
                "stdout": "",
                "stderr": "command output exceeds the helper limit",
            }
        return {
            "success": code == 0,
            "exitCode": code,
            "stdout": stdout_capture.read().decode("utf-8", errors="replace"),
            "stderr": stderr_capture.read().decode("utf-8", errors="replace"),
        }

    def read_file(self, path: str) -> bytes:
        result = subprocess.run(
            [PYTHON, "-I", "-c", READ_FILE, path, str(MAX_FILE_BYTES)],
            cwd="/",
            env={},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60,
            **self._as_user(),
        )
        if result.returncode == 2:
            raise HelperError(404, "file not found")
        if result.returncode == 3:
            raise HelperError(400, "path is a directory")
        if result.returncode == 4:
            raise HelperError(413, "file exceeds the helper limit")
        if result.returncode != 0:
            raise HelperError(403, "file could not be read")
        return result.stdout

    def write_files(self, files: list[tuple[str, str]]) -> None:
        result = subprocess.run(
            [PYTHON, "-I", "-c", WRITE_FILES],
            cwd="/",
            env={},
            input=json.dumps(files).encode("utf-8"),
            capture_output=True,
            timeout=120,
            **self._as_user(),
        )
        if result.returncode != 0:
            raise HelperError(403, "files could not be written")


class HelperHandler(http.server.BaseHTTPRequestHandler):
    server_version = "keyfleet-runner-helper/1"

    @property
    def state(self) -> HelperState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args: Any) -> None:
        # Requests can contain notebook data and credentials; do not log them.
        return

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _empty(self, status: int = 204) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _body(self) -> dict[str, Any]:
        value = self.headers.get("Content-Length")
        if value is None:
            raise HelperError(411, "Content-Length is required")
        try:
            length = int(value)
        except ValueError as exc:
            raise HelperError(400, "invalid Content-Length") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise HelperError(413, "request body exceeds the helper limit")
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise HelperError(400, "incomplete request body")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise HelperError(400, "request body must be JSON") from exc
        if not isinstance(parsed, dict):
            raise HelperError(400, "request body must be an object")
        return parsed

    def _dispatch(self, method: str) -> None:
        if not self.state.authenticate(self.headers.get("Authorization")):
            raise HelperError(401, "unauthorized")
        path, _, query = self.path.partition("?")
        if method == "GET" and path == "/health":
            self._json(200, {"ok": True, "protocolVersion": PROTOCOL_VERSION})
            return
        if method == "POST" and path == "/exec":
            self._json(200, self.state.execute(self._body()))
            return
        if method == "GET" and path == "/files/read":
            requested = urllib.parse.parse_qs(query).get("path", [""])[0]
            if not requested:
                raise HelperError(400, "path is required")
            data = self.state.read_file(requested)
            self._json(200, {"contentBase64": base64.b64encode(data).decode("ascii")})
            return
        if method == "POST" and path == "/files/write":
            self._write_files(self._body())
            return
        if method == "POST" and path == "/env":
            self._set_environment(self._body())
            return
        if method == "POST" and path == "/processes":
            self._json(201, {"id": self.state.processes.start(self._body())})
            return
        if path.startswith("/processes/"):
            process_id, _, action = path[len("/processes/") :].partition("/")
            process_id = urllib.parse.unquote(process_id)
            if method == "POST" and action == "wait-port":
                self._wait_port(process_id, self._body())
                self._json(200, {"ready": True})
                return
            if method == "GET" and action == "logs":
                self._json(200, self.state.processes.logs(process_id))
                return
            if method == "DELETE" and not action:
                name = urllib.parse.parse_qs(query).get("signal", ["TERM"])[0].upper()
                sig = getattr(signal, f"SIG{name}", None)
                if not isinstance(sig, signal.Signals) or sig in {signal.SIGKILL, signal.SIGSTOP}:
                    raise HelperError(400, "unsupported process signal")
                self.state.processes.kill(process_id, sig)
                self._empty()
                return
        raise HelperError(404, "route not found")

    def _write_files(self, payload: dict[str, Any]) -> None:
        files = payload.get("files")
        if not isinstance(files, list) or not files:
            raise HelperError(400, "files must be a non-empty list")
        total = 0
        checked: list[tuple[str, str]] = []
        for entry in files:
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("path"), str)
                or not isinstance(entry.get("contentBase64"), str)
            ):
                raise HelperError(400, "each file requires path and contentBase64")
            try:
                size = len(base64.b64decode(entry["contentBase64"], validate=True))
            except (binascii.Error, ValueError) as exc:
                raise HelperError(400, "invalid base64 file content") from exc
            if size > MAX_FILE_BYTES:
                raise HelperError(413, "file exceeds the helper limit")
            total += size
            checked.append((entry["path"], entry["contentBase64"]))
        if len(checked) > 1 and total > MAX_WRITE_BATCH_BYTES:
            raise HelperError(413, "file batch exceeds the batch limit")
        self.state.write_files(checked)
        self._json(200, {"written": len(checked)})

    def _set_environment(self, payload: dict[str, Any]) -> None:
        forced = payload.get("forced", {})
        defaults = payload.get("defaults", {})
        if not isinstance(forced, dict) or not isinstance(defaults, dict):
            raise HelperError(400, "forced and defaults must be objects")
        for key, value in [*forced.items(), *defaults.items()]:
            if not isinstance(key, str) or not isinstance(value, str):
                raise HelperError(400, "environment values must be strings")
        self.state.update_environment(forced, defaults)
        self._json(200, {"ok": True})

    def _wait_port(self, process_id: str, payload: dict[str, Any]) -> None:
        item = self.state.processes.get(process_id)
        port = payload.get("port")
        if not isinstance(port, int) or port < 1 or port > 65535:
            raise HelperError(400, "port must be an integer between 1 and 65535")
        timeout = _bounded_timeout(payload.get("timeoutMs"), 30_000)
        mode = payload.get("mode", "tcp")
        path = payload.get("path", "/")
        deadline = time.monotonic() + timeout if timeout else None
        while deadline is None or time.monotonic() < deadline:
            if item["process"].poll() is not None:
                self.state.processes.capture_finished(item)
                raise HelperError(409, "process exited before port became ready")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2) as connection:
                    if mode == "http":
                        target = path if isinstance(path, str) and path.startswith("/") else "/"
                        request = f"GET {target} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                        connection.sendall(request.encode("ascii"))
                        if not connection.recv(64):
                            raise OSError("empty HTTP response")
                    return
            except OSError:
                time.sleep(0.05)
        raise HelperError(408, f"timed out waiting for port {port}")

    def _handle(self, method: str) -> None:
        try:
            self._dispatch(method)
        except HelperError as exc:
            self._json(exc.status, {"error": str(exc)})
        except Exception:
            self._json(500, {"error": "helper request failed"})

    def do_GET(self) -> None:  # noqa: N802
        self._handle("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._handle("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._handle("DELETE")


class HelperServer(http.server.ThreadingHTTPServer):
    # Fly's private network is IPv6; the helper listens there and on loopback.
    address_family = socket.AF_INET6
    daemon_threads = True

    def __init__(self, address: tuple[str, int], state: HelperState):
        super().__init__(address, HelperHandler)
        self.state = state


def run_server(token: str) -> None:
    port = int(os.environ.get("MARIMOHUB_AGENT_PORT", "2717"))
    server = HelperServer(("::", port), HelperState(token))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--token-fd":
        with os.fdopen(int(sys.argv[2]), "rb") as token_stream:
            run_server(token_stream.read().decode("utf-8"))
        raise SystemExit(0)
    if sys.argv[1:]:
        raise SystemExit("usage: helper.py")
    # Move the token out of the environment: re-run with it on an inherited pipe,
    # so this process's /proc environ never carries it.
    encoded_token = os.environ.get(TOKEN_VARIABLE, "").encode("utf-8")
    if len(encoded_token) > 4096:
        raise SystemExit(f"{TOKEN_VARIABLE} must not exceed 4096 bytes")
    token_fd, token_writer = os.pipe()
    try:
        os.write(token_writer, encoded_token)
    finally:
        os.close(token_writer)
    os.set_inheritable(token_fd, True)
    environment = dict(os.environ)
    environment.pop(TOKEN_VARIABLE, None)
    os.execve(
        PYTHON,
        [PYTHON, "-I", os.path.abspath(__file__), "--token-fd", str(token_fd)],
        environment,
    )
