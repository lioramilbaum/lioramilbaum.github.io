#!/usr/bin/env python3
"""Command-line entry point for the story workflow. Its commands are added in later changes."""
from __future__ import annotations

import sys
from typing import NoReturn

REPO = "lioramilbaum/lioramilbaum.github.io"
MIN_PYTHON = (3, 11)
USAGE = "usage: python3 scripts/story.py COMMAND (none is available yet)"


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def usage() -> NoReturn:
    print(USAGE, file=sys.stderr)
    raise SystemExit(2)


def main(argv: list[str]) -> int:
    if sys.version_info[:2] < MIN_PYTHON:
        fail("story.py needs Python 3.11 or later; this is Python %d.%d" % sys.version_info[:2])
    usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
