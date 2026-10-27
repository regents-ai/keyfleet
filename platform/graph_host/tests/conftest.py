import json
import subprocess
import sys

import pytest

from keyfleet_graph import protocol

WALLET = "0x" + "a1" * 20
CONTRACT = "0x" + "b2" * 20


def command(command_id, *, token_id=17, wallet=WALLET, contract=CONTRACT, projects=None):
    auth = {
        "key": {"chain_id": 8453, "contract": contract, "token_id": token_id},
        "ownership_epoch": 3,
        "kind": "agent",
        "operator_wallet": wallet,
        "credential_ref": "sha256:" + "0" * 64,
        "checked_at": "2026-09-22T12:00:00Z",
        "chain_block": None,
    }
    return {
        "id": command_id,
        "principal": f"member:8453:{contract}:{token_id}@3/agent:{wallet}",
        "auth": auth,
        "projects": {"general": "active"} if projects is None else projects,
    }


def request(op, body, cmd=None, req="r1"):
    message = {"v": 1, "req": req, "op": op, "body": body}
    if cmd is not None:
        message["command"] = cmd
    return message


class HostProcess:
    """The real host as the port runs it, optionally with a patch applied first."""

    def __init__(self, db, *, patch="", fleet="fleet_a", starting_goals=()):
        script = f"{patch}\nfrom keyfleet_graph.__main__ import main\nmain()\n"
        goals = json.dumps(list(starting_goals))
        self.proc = subprocess.Popen(
            [sys.executable, "-c", script, "--fleet", fleet, "--db", str(db), "--starting-goals", goals],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def send(self, message):
        """Send one request; return its reply, or None if the host died first."""
        data = json.dumps(message).encode("utf-8")
        self.proc.stdin.write(len(data).to_bytes(4, "big") + data)
        self.proc.stdin.flush()
        frame = protocol.read_frame(self.proc.stdout)
        return None if frame is None else json.loads(frame)

    def close(self):
        self.proc.stdin.close()
        return self.wait()

    def wait(self):
        code = self.proc.wait(timeout=30)
        self.proc.stdout.close()
        self.proc.stderr.close()
        return code


@pytest.fixture
def db(tmp_path):
    return tmp_path / "fleet_a.sqlite"
