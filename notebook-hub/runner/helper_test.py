"""Tests for the runner helper, run as root inside the runner image:

    docker run --rm --sysctl net.ipv6.conf.all.disable_ipv6=0 \
      -v "$PWD/runner/helper_test.py:/opt/runner-test/helper_test.py:ro" \
      keyfleet/notebook-runner:<pin> \
      /usr/local/bin/python3 -I -m unittest discover -s /opt/runner-test -p '*_test.py' -v

They start the shipped /opt/runner/helper.py the way the entrypoint does.
"""

from __future__ import annotations

import base64
import json
import os
import pwd
import secrets
import socket
import subprocess
import time
import unittest
import urllib.error
import urllib.request
from typing import Any

HELPER = "/opt/runner/helper.py"
PYTHON = "/usr/local/bin/python3"
TOKEN = secrets.token_hex(32)


def free_port() -> int:
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
        probe.bind(("::1", 0))
        return probe.getsockname()[1]


class HelperTest(unittest.TestCase):
    helper: subprocess.Popen[bytes]
    port: int

    @classmethod
    def setUpClass(cls) -> None:
        cls.port = free_port()
        # The image environment, as Fly gives the entrypoint, plus the machine's two settings.
        environment = dict(os.environ) | {
            "MARIMOHUB_AGENT_TOKEN": TOKEN,
            "MARIMOHUB_AGENT_PORT": str(cls.port),
        }
        cls.helper = subprocess.Popen([PYTHON, "-I", HELPER], env=environment)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                if cls.call("GET", "/health")[0] == 200:
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("helper did not start")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.helper.terminate()
        cls.helper.wait()

    @classmethod
    def call(
        cls,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        token: str | None = TOKEN,
    ) -> tuple[int, dict[str, Any]]:
        request = urllib.request.Request(
            f"http://[::1]:{cls.port}{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}
            | ({} if token is None else {"Authorization": f"Bearer {token}"}),
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"{}")

    def run_command(self, command: str, **extra: Any) -> dict[str, Any]:
        status, body = self.call("POST", "/exec", {"command": command, **extra})
        self.assertEqual(status, 200, body)
        return body

    def test_health_reports_protocol(self) -> None:
        self.assertEqual(self.call("GET", "/health"), (200, {"ok": True, "protocolVersion": 1}))

    def test_requires_the_token(self) -> None:
        self.assertEqual(self.call("GET", "/health", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/health", token="x" * 64)[0], 401)

    def test_commands_run_as_the_notebook_user(self) -> None:
        result = self.run_command('id -un; id -Gn; printf "%s\\n" "$HOME" "$PWD"')
        self.assertEqual(result["stdout"].split(), ["appuser", "appuser", "/home/appuser", "/workspace"])

    def test_commands_find_the_notebook_python(self) -> None:
        result = self.run_command("python3 -c 'import marimo; print(marimo.__version__)'")
        self.assertEqual(result["stdout"].strip(), "0.25.2")

    def test_token_never_reaches_command_environment(self) -> None:
        status, _ = self.call(
            "POST", "/env", {"forced": {"MARIMOHUB_AGENT_TOKEN": TOKEN, "SEEN": "yes"}, "defaults": {}}
        )
        self.assertEqual(status, 200)
        result = self.run_command("env", env={"MARIMOHUB_AGENT_TOKEN": TOKEN})
        self.assertIn("SEEN=yes", result["stdout"])
        self.assertNotIn("MARIMOHUB_AGENT_TOKEN", result["stdout"])
        self.assertNotIn(TOKEN, result["stdout"])

    def test_helper_environment_has_no_token(self) -> None:
        with open(f"/proc/{self.helper.pid}/environ", "rb") as stream:
            self.assertNotIn(TOKEN.encode(), stream.read())

    def test_notebook_user_cannot_find_the_token_in_proc(self) -> None:
        # Search every process environment and command line the notebook user can
        # open; the helper's own entries are root-only. The pattern comes from a
        # file so the search's own command line does not hold the token.
        with open("/tmp/token-pattern", "w") as stream:
            stream.write(TOKEN)
        os.chmod("/tmp/token-pattern", 0o644)
        result = self.run_command(
            "grep -rs -l -F -f /tmp/token-pattern /proc/[0-9]*/environ /proc/[0-9]*/cmdline; "
            f"cat /proc/{self.helper.pid}/environ >/dev/null 2>&1 && echo readable || echo denied"
        )
        os.unlink("/tmp/token-pattern")
        self.assertEqual(result["stdout"].strip(), "denied")

    def test_files_round_trip_and_belong_to_the_notebook_user(self) -> None:
        content = bytes(range(256))
        status, body = self.call(
            "POST",
            "/files/write",
            {"files": [{"path": "/workspace/nested/data.bin", "contentBase64": base64.b64encode(content).decode()}]},
        )
        self.assertEqual((status, body), (200, {"written": 1}))
        status, body = self.call("GET", "/files/read?path=/workspace/nested/data.bin")
        self.assertEqual(status, 200)
        self.assertEqual(base64.b64decode(body["contentBase64"]), content)
        self.assertEqual(os.stat("/workspace/nested/data.bin").st_uid, pwd.getpwnam("appuser").pw_uid)

    def test_file_reads_and_writes_cannot_reach_root_files(self) -> None:
        with open("/root/secret.txt", "w") as stream:
            stream.write("root only")
        os.chmod("/root/secret.txt", 0o600)
        link = "/workspace/planted-link.txt"
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink("/root/secret.txt", link)
        self.assertEqual(self.call("GET", f"/files/read?path={link}")[0], 403)
        self.assertEqual(self.call("GET", "/files/read?path=/proc/1/environ")[0], 403)
        status, _ = self.call(
            "POST", "/files/write", {"files": [{"path": "/etc/planted", "contentBase64": "eA=="}]}
        )
        self.assertEqual(status, 403)
        self.assertFalse(os.path.exists("/etc/planted"))

    def test_missing_file_and_directory(self) -> None:
        self.assertEqual(self.call("GET", "/files/read?path=/workspace/absent")[0], 404)
        self.assertEqual(self.call("GET", "/files/read?path=/workspace")[0], 400)

    def test_failing_command_reports_its_exit_code(self) -> None:
        result = self.run_command("echo out; echo err >&2; exit 7")
        self.assertEqual(result, {"success": False, "exitCode": 7, "stdout": "out\n", "stderr": "err\n"})

    def test_command_timeout(self) -> None:
        self.assertEqual(self.run_command("sleep 5", timeoutMs=200)["exitCode"], 124)

    def test_processes_start_wait_log_and_stop(self) -> None:
        port = free_port()
        status, body = self.call(
            "POST",
            "/processes",
            {
                "command": f"id -un; exec python3 -m http.server {port} --bind 127.0.0.1",
                "processId": "web",
            },
        )
        self.assertEqual((status, body), (201, {"id": "web"}))
        status, _ = self.call("POST", "/processes/web/wait-port", {"port": port, "mode": "http", "timeoutMs": 10_000})
        self.assertEqual(status, 200)
        self.assertEqual(self.call("GET", "/processes/web/logs")[1]["stdout"], "appuser\n")
        self.assertEqual(self.call("DELETE", "/processes/web?signal=TERM")[0], 204)
        self.assertEqual(self.call("GET", "/processes/web/logs")[0], 404)

    def test_refuses_kill_signal(self) -> None:
        self.call("POST", "/processes", {"command": "sleep 30", "processId": "sleeper"})
        self.assertEqual(self.call("DELETE", "/processes/sleeper?signal=KILL")[0], 400)
        self.assertEqual(self.call("DELETE", "/processes/sleeper")[0], 204)


if __name__ == "__main__":
    unittest.main()
