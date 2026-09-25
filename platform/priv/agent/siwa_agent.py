#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["eth-account>=0.13"]
# ///
"""SIWA agent client: sign in with a self-generated key, then send signed requests.

Run it with uv (dependencies install on first run):

    uv run siwa_agent.py keygen
    uv run siwa_agent.py sign-in
    uv run siwa_agent.py request POST https://example.app/api/agent/hello --body '{"name":"Astra"}'

Environment:

    SIWA_AUDIENCE   the audience you are joining, for example keyfleet (required)
    SIWA_BROKER     the SIWA server base URL (default https://siwa-server.fly.dev)
    SIWA_AGENT_HOME where the key and receipt are kept (default ~/.siwa-agent)

The private key never leaves this machine. The SIWA server only ever sees the
address, a signature over the challenge it issued, and signatures over requests.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from eth_account import Account
from eth_account.messages import encode_defunct

CHAIN_ID = 8453
DEFAULT_BROKER = "https://siwa-server.fly.dev"
RECEIPT_RENEW_MARGIN_SECONDS = 60
REQUEST_SIGNATURE_LIFETIME_SECONDS = 120
USER_AGENT = "siwa-agent-client/1.0 (python)"


class SiwaError(Exception):
    pass


def settings() -> dict:
    audience = os.environ.get("SIWA_AUDIENCE", "").strip()
    if not audience:
        raise SiwaError("set SIWA_AUDIENCE to the audience you are joining, for example keyfleet")
    broker = os.environ.get("SIWA_BROKER", DEFAULT_BROKER).strip().rstrip("/")
    home = os.path.expanduser(os.environ.get("SIWA_AGENT_HOME", "~/.siwa-agent"))
    return {"audience": audience, "broker": broker, "state_path": os.path.join(home, f"{audience}.json")}


def load_state(path: str) -> dict | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save_state(path: str, state: dict) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def require_key(path: str) -> dict:
    state = load_state(path)
    if not state or "private_key" not in state:
        raise SiwaError(f"no key at {path}; run keygen first")
    return state


def http_json(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> tuple[int, dict | str]:
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("accept", "application/json")
    request.add_header("user-agent", USER_AGENT)
    if data is not None:
        request.add_header("content-type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, decode_body(response.read())
    except urllib.error.HTTPError as error:
        return error.code, decode_body(error.read())


def decode_body(raw: bytes) -> dict | str:
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def keygen(config: dict, args: argparse.Namespace) -> None:
    existing = load_state(config["state_path"])
    if existing and not args.force:
        print(json.dumps({"address": existing["address"], "state": config["state_path"], "created": False}))
        return
    account = Account.create()
    state = {
        "audience": config["audience"],
        "broker": config["broker"],
        "address": account.address.lower(),
        "private_key": account.key.hex(),
    }
    save_state(config["state_path"], state)
    print(json.dumps({"address": state["address"], "state": config["state_path"], "created": True}))


def sign_in(config: dict, state: dict) -> dict:
    """Obtain a fresh receipt for this key and audience, and store it."""
    broker, audience, address = config["broker"], config["audience"], state["address"]
    base = {"wallet_address": address, "chain_id": CHAIN_ID, "audience": audience}
    status, nonce = http_json("POST", f"{broker}/api/shared/siwa/wallet/nonce", base)
    if status != 200 or not isinstance(nonce, dict) or nonce.get("code") != "nonce_issued":
        raise SiwaError(f"nonce request failed ({status}): {json.dumps(nonce)}")
    challenge = nonce["data"]
    signature = personal_sign(state["private_key"], challenge["message"])
    proof = {**base, "nonce": challenge["nonce"], "message": challenge["message"], "signature": signature}
    status, verified = http_json("POST", f"{broker}/api/shared/siwa/wallet/verify", proof)
    if status != 200 or not isinstance(verified, dict) or verified.get("code") != "wallet_verified":
        raise SiwaError(f"verification failed ({status}): {json.dumps(verified)}")
    data = verified["data"]
    state["receipt"] = data["receipt"]
    state["receipt_expires_at"] = data["receiptExpiresAt"]
    state["key_id"] = data["keyId"]
    save_state(config["state_path"], state)
    return data


def personal_sign(private_key: str, message: str) -> str:
    signed = Account.sign_message(encode_defunct(text=message), private_key=private_key)
    return "0x" + signed.signature.hex().removeprefix("0x")


def receipt_is_fresh(state: dict) -> bool:
    expires_at = state.get("receipt_expires_at")
    if not state.get("receipt") or not expires_at:
        return False
    expires = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    return (expires - datetime.now(timezone.utc)).total_seconds() > RECEIPT_RENEW_MARGIN_SECONDS


def ensure_receipt(config: dict, state: dict) -> None:
    if not receipt_is_fresh(state):
        sign_in(config, state)


def content_digest(body: bytes) -> str:
    return "sha-256=:" + base64.b64encode(hashlib.sha256(body).digest()).decode("ascii") + ":"


def signed_headers(state: dict, method: str, url: str, body: bytes | None) -> dict:
    """Build the SIWA signed-request headers for one request. Each call signs fresh."""
    parsed = urllib.parse.urlsplit(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    created = int(time.time())
    expires = created + REQUEST_SIGNATURE_LIFETIME_SECONDS
    nonce = "sig-nonce-" + secrets.token_hex(16)
    headers = {
        "x-siwa-receipt": state["receipt"],
        "x-key-id": state["key_id"],
        "x-timestamp": str(created),
        "x-agent-wallet-address": state["address"],
        "x-agent-chain-id": str(CHAIN_ID),
    }
    components = ["@method", "@path", "x-siwa-receipt", "x-key-id", "x-timestamp", "x-agent-wallet-address", "x-agent-chain-id"]
    if body is not None:
        headers["content-digest"] = content_digest(body)
        components.append("content-digest")
    params = (
        "(" + " ".join(f'"{component}"' for component in components) + ")"
        f";created={created};expires={expires};nonce=\"{nonce}\";keyid=\"{state['key_id']}\""
    )
    lines = []
    for component in components:
        if component == "@method":
            value = method.lower()
        elif component == "@path":
            value = path
        else:
            value = headers[component]
        lines.append(f'"{component}": {value}')
    lines.append(f'"@signature-params": {params}')
    signature = personal_sign(state["private_key"], "\n".join(lines))
    signature_bytes = bytes.fromhex(signature[2:])
    headers["signature-input"] = "sig1=" + params
    headers["signature"] = "sig1=:" + base64.b64encode(signature_bytes).decode("ascii") + ":"
    return headers


def body_bytes(args: argparse.Namespace) -> bytes | None:
    if args.body is None:
        return None
    return args.body.encode("utf-8")


def command_sign_in(config: dict, _args: argparse.Namespace) -> None:
    state = require_key(config["state_path"])
    data = sign_in(config, state)
    print(json.dumps({"address": data["walletAddress"], "audience": data["audience"], "receiptExpiresAt": data["receiptExpiresAt"]}))


def command_whoami(config: dict, _args: argparse.Namespace) -> None:
    state = require_key(config["state_path"])
    print(json.dumps({
        "address": state["address"],
        "audience": config["audience"],
        "broker": config["broker"],
        "receiptFresh": receipt_is_fresh(state),
        "receiptExpiresAt": state.get("receipt_expires_at"),
    }))


def command_headers(config: dict, args: argparse.Namespace) -> None:
    state = require_key(config["state_path"])
    ensure_receipt(config, state)
    print(json.dumps(signed_headers(state, args.method.upper(), args.url, body_bytes(args)), indent=2))


def command_request(config: dict, args: argparse.Namespace) -> None:
    state = require_key(config["state_path"])
    ensure_receipt(config, state)
    body = body_bytes(args)
    extra = dict(pair.split("=", 1) for pair in args.header)
    status, response = send_signed(state, args.method.upper(), args.url, body, extra)
    if status == 401 and isinstance(response, dict) and receipt_rejected(response):
        sign_in(config, state)
        status, response = send_signed(state, args.method.upper(), args.url, body, extra)
    print(json.dumps({"status": status, "body": response}, indent=2))
    if status >= 400:
        sys.exit(1)


def send_signed(state: dict, method: str, url: str, body: bytes | None, extra: dict) -> tuple[int, dict | str]:
    headers = {**extra, **signed_headers(state, method, url, body)}
    if body is not None:
        headers.setdefault("content-type", "application/json")
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("accept", "application/json")
    request.add_header("user-agent", USER_AGENT)
    for name, value in headers.items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, decode_body(response.read())
    except urllib.error.HTTPError as error:
        return error.code, decode_body(error.read())


def receipt_rejected(response: dict) -> bool:
    text = json.dumps(response)
    return "receipt_invalid" in text or "receipt_binding_mismatch" in text


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    keygen_parser = commands.add_parser("keygen", help="create the agent key (no-op when one exists)")
    keygen_parser.add_argument("--force", action="store_true", help="replace an existing key; the old identity is lost")
    keygen_parser.set_defaults(run=keygen)

    commands.add_parser("sign-in", help="obtain a receipt for the audience").set_defaults(run=command_sign_in)
    commands.add_parser("whoami", help="show the address and receipt state").set_defaults(run=command_whoami)

    for name, handler, help_text in (
        ("headers", command_headers, "print signed headers for a request without sending it"),
        ("request", command_request, "send a signed request and print the response"),
    ):
        sub = commands.add_parser(name, help=help_text)
        sub.add_argument("method")
        sub.add_argument("url")
        sub.add_argument("--body", help="exact request body; sign and send these bytes")
        sub.add_argument("--header", action="append", default=[], metavar="NAME=VALUE", help="extra unsigned header")
        sub.set_defaults(run=handler)

    args = parser.parse_args(argv)
    try:
        args.run(settings(), args)
    except SiwaError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
