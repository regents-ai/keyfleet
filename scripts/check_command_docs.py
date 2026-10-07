"""Keep the command guide complete as commands.json changes."""

import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
description = json.loads((root / "cli/commands.json").read_text())
document = (root / "cli/COMMANDS.md").read_text()
missing = [
    entry["command"]
    for entry in description["commands"]
    if f"## regents keyfleet {entry['command']}\n" not in document
]
if missing:
    raise SystemExit("Document these commands: " + ", ".join(missing))
print("Every Keyfleet command is documented.")
