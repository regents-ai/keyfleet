"""`python -m keyfleet_graph --fleet <id> --db <path>`: serve one fleet's graph over stdio.

Standard output is taken for the protocol before anything else runs and file
descriptor 1 is pointed at standard error, so a stray print can never corrupt
a frame. A lock beside the database file keeps a second host off the same run.
Any failure other than a refusal ends the process without serving again.
"""

import argparse
import fcntl
import os
import re
import sys
import traceback

from keyfleet_graph import protocol

EXIT_FAILED = 70
EXIT_LOCKED = 75


def main() -> None:
    args = _arguments()
    replies = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)
    requests = os.fdopen(0, "rb", buffering=0)

    lock = open(f"{args.db}.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"locked: another host holds {args.db}", file=sys.stderr)
        os._exit(EXIT_LOCKED)

    try:
        from keyfleet_graph.host import Host

        host = Host(args.fleet, args.db)
        serve(host, requests, replies)
    except BaseException:
        traceback.print_exc()
        sys.stderr.flush()
        os._exit(EXIT_FAILED)


def serve(host, requests, replies) -> None:
    while (frame := protocol.read_frame(requests)) is not None:
        protocol.write_frame(replies, host.handle(frame))


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="keyfleet_graph")
    parser.add_argument("--fleet", required=True, type=_fleet_id)
    parser.add_argument("--db", required=True)
    return parser.parse_args()


def _fleet_id(value: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", value):
        raise argparse.ArgumentTypeError("a fleet id is lowercase letters, digits and underscores")
    return value


if __name__ == "__main__":
    main()
