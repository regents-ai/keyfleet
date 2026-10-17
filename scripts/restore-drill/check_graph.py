"""Opens every fleet graph restored onto the drill volume and reports on it.

Runs inside the drill machine with the image's own interpreter:

    /opt/graph_host/.venv/bin/python -I /restore-drill/check_graph.py /drill/graph

Each graph is a SQLite file in WAL mode, and a volume snapshot catches it as a
crash would, so opening it replays its log as SQLite does after a crash. The
files are the drill's copies; the live volume is never opened.

Prints one line per fleet, `<fleet id> <integrity> <events>`, and exits 1 when
there is no graph or any graph fails its integrity check.
"""

import sqlite3
import sys
from pathlib import Path


def main(graph_dir: str) -> int:
    graphs = sorted(Path(graph_dir).glob("*.sqlite"))
    if not graphs:
        print(f"no graphs in {graph_dir}")
        return 1

    failed = False
    for graph in graphs:
        conn = sqlite3.connect(graph)
        try:
            # A damaged file reports every fault; the first says enough here.
            integrity = conn.execute("PRAGMA integrity_check").fetchone()[0].splitlines()[0]
            events = conn.execute("SELECT count(*) FROM events").fetchone()[0]
        finally:
            conn.close()
        failed = failed or integrity != "ok"
        print(f"{graph.stem} {integrity} {events}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
