"""Keep the command guide complete, and the commands in step with the browser tools.

Every command in commands.json has its section in COMMANDS.md. Every signed browser
tool in the tool manifest has a command for the same route, and a command and a tool
for one route take the same fields, so an operation means the same on both.
"""

import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
description = json.loads((root / "cli/commands.json").read_text())
manifest = json.loads((root / "platform/priv/tool_manifest.json").read_text())
document = (root / "cli/COMMANDS.md").read_text()

missing = [
    entry["command"]
    for entry in description["commands"]
    if f"## regents keyfleet {entry['command']}\n" not in document
]
if missing:
    raise SystemExit("Document these commands: " + ", ".join(missing))


def route(method, path):
    return method + " " + re.sub(r"\{[^}]+\}", "{}", path)


def command_fields(entry):
    named = entry.get("arguments", []) + entry.get("flags", []) + entry.get("stdin_fields", [])
    return {field.get("field") or field["name"] for field in named} | set(entry.get("body", {}))


commands = {}
for entry in description["commands"]:
    commands.setdefault(route(entry["method"], entry["path"]), []).append(entry)

problems = []
for tool in manifest["tools"]:
    if tool.get("authentication") != "siwa_per_request" or "route" not in tool:
        continue
    method, path = tool["route"].split(" ", 1)
    matching = commands.get(route(method, path))
    if not matching:
        problems.append(f"{tool['name']} has no command for {tool['route']}")
        continue
    fields = set(tool["operation_input_schema"]["properties"])
    for entry in matching:
        if command_fields(entry) != fields:
            only_tool = sorted(fields - command_fields(entry))
            only_command = sorted(command_fields(entry) - fields)
            problems.append(
                f"{entry['command']} and {tool['name']} take different fields: "
                f"only the tool takes {only_tool}, only the command {only_command}"
            )
if problems:
    raise SystemExit("\n".join(problems))

print("Every Keyfleet command is documented, and takes the fields its browser tool takes.")
