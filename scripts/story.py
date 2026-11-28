#!/usr/bin/env python3
"""Command-line entry point for the story workflow. It reads a request and prints its marker; the intent checks and the body builder are not yet called from main, and the model call and filing come later."""
from __future__ import annotations

import errno
import os
import re
import sys
from typing import NoReturn

REPO = "lioramilbaum/lioramilbaum.github.io"
MIN_PYTHON = (3, 11)
USAGE = "usage: python3 scripts/story.py [--request-file PATH]"
TITLE_MAX = 80
# The whitespace that JavaScript's \s and trim() treat as space. Python's str.strip() and \s differ: they
# take U+001C-U+001F and U+0085, and miss U+FEFF. Every trim and collapse here uses this set.
JS_WHITESPACE = "\t\n\x0b\x0c\r \u00a0\u1680" + "".join(chr(c) for c in range(0x2000, 0x200B)) + "\u2028\u2029\u202f\u205f\u3000\ufeff"
JS_WHITESPACE_RUN = re.compile("[" + re.escape(JS_WHITESPACE) + "]+")
# story.js's /^#{1,6}(\s|$)/: the end of a value is the end of the string, as JavaScript's $ is without the m flag.
HEADING = re.compile("#{1,6}(?:[" + re.escape(JS_WHITESPACE) + "]|\\Z)")
# The delimiter lines, kept unchanged from story.js, whose filing prompt fences the title and body with them.
DELIMITER = re.compile(r"-----(BEGIN|END) STORY (TITLE|BODY)")
# Control characters and line separators, escaped in a message so that it stays one line.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")


class StoryError(Exception):
    """A refusal. Its message is the one line that main prints after "error: "."""


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def usage() -> NoReturn:
    print(USAGE, file=sys.stderr)
    raise SystemExit(2)


def js_trim(value: str) -> str:
    return value.strip(JS_WHITESPACE)


# One line of plain text. Whitespace is collapsed, so a value cannot start a new line in the issue.
def text(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return js_trim(JS_WHITESPACE_RUN.sub(" ", value))


def field(name: str, value: object) -> str:
    line = text(value)
    if not line:
        raise StoryError(f"story: the extracted intent has no {name}; no issue was filed")
    if HEADING.match(line):
        raise StoryError(f"story: the extracted {name} starts with a heading marker; no issue was filed")
    if DELIMITER.search(line):
        raise StoryError(f"story: the extracted {name} contains a delimiter line; no issue was filed")
    # An HTML comment opener in a value could hide the rest of the body or forge the request's marker.
    return line.replace("<!--", "&lt;!--")


def list_field(name: str, value: object) -> list[str]:
    if not isinstance(value, list) or not value:
        raise StoryError(f"story: the extracted intent has no {name}; no issue was filed")
    return [field(name, item) for item in value]


# A title is plain text, so nothing in it is escaped.
def title_line(value: object) -> str:
    line = text(value)
    if not line:
        raise StoryError("story: the extracted intent has no title; no issue was filed")
    if DELIMITER.search(line):
        raise StoryError("story: the extracted title contains a delimiter line; no issue was filed")
    length = len(line)
    if length > TITLE_MAX:
        raise StoryError(f"story: the extracted title is {length} characters, more than {TITLE_MAX}; no issue was filed")
    return line


def check_intent(extracted: dict) -> tuple[str, dict]:
    # The order is story.js's: the title first, then the goal, the why, and the two lists.
    title = title_line(extracted.get("title"))
    intent = {
        "goal": field("goal", extracted.get("goal")),
        "whyItMatters": field("whyItMatters", extracted.get("whyItMatters")),
        "inScope": list_field("inScope", extracted.get("inScope")),
        "outOfScope": list_field("outOfScope", extracted.get("outOfScope")),
    }
    return title, intent


def fnv1a(value: str, seed: int) -> str:
    h = seed
    for ch in value:
        h = ((h ^ ord(ch)) * 0x01000193) & 0xFFFFFFFF
    return format(h, "08x")


# Two FNV-1a passes over the request with its whitespace collapsed, one forwards and one backwards:
# the same request always gets the same 16 digits.
def fingerprint(value: str) -> str:
    line = text(value)
    return fnv1a(line, 0x811C9DC5) + fnv1a(line[::-1], 0x9747B28C)


def request_marker(request: str) -> str:
    return f"<!-- story-request: {fingerprint(request)} -->"


# The issue body, byte for byte as story.js builds it (the bodies vectors check that). The filing POST (#206) will send this body; main does not call this until #207.
def issue_body(intent: dict, marker: str) -> str:
    lines = [
        "## Goal",
        "",
        intent["goal"],
        "",
        "## Why it matters",
        "",
        intent["whyItMatters"],
        "",
        "## In scope",
        "",
        *[f"- {item}" for item in intent["inScope"]],
        "",
        "## Out of scope",
        "",
        *[f"- {item}" for item in intent["outOfScope"]],
        "",
        marker,
    ]
    return "\n".join(lines)


def _one_line(value: str) -> str:
    return CONTROL.sub(lambda m: m.group().encode("unicode_escape").decode("ascii"), value)


# The request is read as bytes and decoded strictly, so a byte-order mark is trimmed as JavaScript trims it.
def read_request(path: str | None) -> str:
    if path is None:
        if sys.stdin is None:
            raise StoryError(f"cannot read the request from stdin: {os.strerror(errno.EBADF)}; no issue was filed")
        try:
            # The raw stream is read to EOF because a buffered read() returns the bytes so far when a non-blocking
            # read gives None, so a request still being written would be taken as whole. Nothing has read stdin
            # before this, so the buffer is empty and reading the raw stream drops nothing.
            stream = getattr(sys.stdin.buffer, "raw", sys.stdin.buffer)
            chunks = []
            while chunk := stream.read(65536):
                chunks.append(chunk)
            data = None if chunk is None else b"".join(chunks)
        except OSError as exc:
            raise StoryError(f"cannot read the request from stdin: {exc.strerror}; no issue was filed") from exc
        # A non-blocking stdin makes a read return None while the writer is open and nothing is ready; the request
        # is refused then, whether no bytes or only part of it had arrived.
        if data is None:
            raise StoryError(f"cannot read the request from stdin: {os.strerror(errno.EAGAIN)}; no issue was filed")
    else:
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as exc:
            raise StoryError(f"cannot read the request file {_one_line(path)}: {exc.strerror}; no issue was filed") from exc
    try:
        request = data.decode("utf-8")
    except UnicodeDecodeError:
        raise StoryError("the request is not valid UTF-8; no issue was filed") from None
    request = js_trim(request)
    if not request:
        raise StoryError("the request is blank; no issue was filed")
    return request


def main(argv: list[str]) -> int:
    if sys.version_info[:2] < MIN_PYTHON:
        fail("story.py needs Python 3.11 or later; this is Python %d.%d" % sys.version_info[:2])
    if argv == []:
        path = None
    elif len(argv) == 2 and argv[0] == "--request-file":
        path = argv[1]
    else:
        usage()
    try:
        request = read_request(path)
    except StoryError as exc:
        fail(str(exc))
    fail(f"the request's marker is {request_marker(request)}, but filing is not built yet (#207); no issue was filed")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
