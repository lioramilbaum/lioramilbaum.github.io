"""Unit tests for scripts/story.py, run by scripts/test-story.sh under a coverage gate (AGENTS.md rule 8)."""

import hashlib
import io
import json
import os
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORY = os.path.join(SCRIPTS, "story.py")
# The fixture is generated from story.js itself under Node, by the generator in the #173 pull request description; the blob guard below ties it to that file.
STORY_JS = os.path.normpath(os.path.join(SCRIPTS, "..", ".claude", "workflows", "story.js"))
FIXTURE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "story_js_vectors.json")
sys.path.insert(0, SCRIPTS)

import story  # noqa: E402

with open(FIXTURE_PATH, encoding="utf-8") as handle:
    FIXTURE = json.load(handle)

USAGE = "usage: python3 scripts/story.py [--request-file PATH]\n"
HELLO_MARKER = "<!-- story-request: d58b3fa700ef68b8 -->"
REFUSAL_PREFIX = "test_refusal_"


def capture(call):
    """Run call() and return (exit code, stdout, stderr) for the SystemExit it raises."""
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            call()
        except SystemExit as exc:
            return exc.code, out.getvalue(), err.getvalue()
    raise AssertionError("expected SystemExit, got a normal return")


class TempCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.dir = directory.name

    def request_file(self, data, name="request.txt"):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as handle:
            handle.write(data)
        return path


class StoryTest(TempCase):
    def test_request_file_without_a_path_prints_usage_and_exits_2(self):
        self.assertEqual(capture(lambda: story.main(["--request-file"])), (2, "", USAGE))

    def test_unknown_argument_prints_usage_and_exits_2(self):
        self.assertEqual(capture(lambda: story.main(["nope"])), (2, "", USAGE))

    def test_extra_arguments_print_usage_and_exit_2(self):
        self.assertEqual(capture(lambda: story.main(["--request-file", "a", "b"])), (2, "", USAGE))

    def test_old_python_refuses_with_no_argv(self):
        with mock.patch.object(story.sys, "version_info", (3, 10, 0)):
            self.assertEqual(capture(lambda: story.main([])), (1, "", "error: story.py needs Python 3.11 or later; this is Python 3.10\n"))

    def test_old_python_refuses_before_a_command(self):
        with mock.patch.object(story.sys, "version_info", (3, 10, 0)):
            self.assertEqual(capture(lambda: story.main(["nope"])), (1, "", "error: story.py needs Python 3.11 or later; this is Python 3.10\n"))

    def test_minimum_python_gets_past_the_check(self):
        with mock.patch.object(story.sys, "version_info", (3, 11, 0)):
            self.assertEqual(capture(lambda: story.main(["nope"])), (2, "", USAGE))

    def test_fail_prints_error_and_exits_1(self):
        self.assertEqual(capture(lambda: story.fail("x")), (1, "", "error: x\n"))

    def test_repo_constant(self):
        self.assertEqual(story.REPO, "lioramilbaum/lioramilbaum.github.io")

    def test_main_entry_point_exits_2_with_usage(self):
        with mock.patch.object(sys, "argv", ["story.py", "nope"]):
            code, out, err = capture(lambda: runpy.run_path(STORY, run_name="__main__"))
        self.assertEqual((code, out, err), (2, "", USAGE))

    def test_valid_request_file_prints_its_marker_and_exits_1(self):
        path = self.request_file(b"hello world\n")
        self.assertEqual(
            capture(lambda: story.main(["--request-file", path])),
            (1, "", f"error: the request's marker is {HELLO_MARKER}, but filing is not built yet (#207); no issue was filed\n"),
        )

    def test_valid_stdin_request_prints_its_marker_and_exits_1(self):
        with mock.patch.object(story.sys, "stdin", io.TextIOWrapper(io.BytesIO(b"hello world\n"))):
            self.assertEqual(
                capture(lambda: story.main([])),
                (1, "", f"error: the request's marker is {HELLO_MARKER}, but filing is not built yet (#207); no issue was filed\n"),
            )


class ReadRequestTest(TempCase):
    def test_missing_request_file_is_refused_with_its_reason(self):
        path = os.path.join(self.dir, "missing.txt")
        self.assertEqual(
            capture(lambda: story.main(["--request-file", path])),
            (1, "", f"error: cannot read the request file {path}: No such file or directory; no issue was filed\n"),
        )

    def test_a_directory_is_refused_with_its_reason(self):
        self.assertEqual(
            capture(lambda: story.main(["--request-file", self.dir])),
            (1, "", f"error: cannot read the request file {self.dir}: Is a directory; no issue was filed\n"),
        )

    def test_control_characters_in_the_path_keep_the_error_on_one_line(self):
        for char, escaped in (("\n", "\\n"), ("\r", "\\r"), ("\x1b", "\\x1b"), ("\x7f", "\\x7f"), ("\x85", "\\x85"), ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
            with self.subTest(char=escaped):
                path = os.path.join(self.dir, "a" + char + "b.txt")
                shown = os.path.join(self.dir, "a" + escaped + "b.txt")
                self.assertEqual(
                    capture(lambda: story.main(["--request-file", path])),
                    (1, "", f"error: cannot read the request file {shown}: No such file or directory; no issue was filed\n"),
                )

    def test_a_non_ascii_path_is_shown_unaltered(self):
        path = os.path.join(self.dir, "caf\u00e9 \u2603.txt")
        self.assertEqual(
            capture(lambda: story.main(["--request-file", path])),
            (1, "", f"error: cannot read the request file {path}: No such file or directory; no issue was filed\n"),
        )

    def test_a_stdin_read_error_is_refused_with_its_reason(self):
        stdin = mock.Mock()
        stdin.buffer.raw.read.side_effect = OSError(5, "Input/output error")
        with mock.patch.object(story.sys, "stdin", stdin):
            self.assertEqual(
                capture(lambda: story.main([])),
                (1, "", "error: cannot read the request from stdin: Input/output error; no issue was filed\n"),
            )

    def test_stdin_is_read_when_no_path_is_given(self):
        with mock.patch.object(story.sys, "stdin", io.TextIOWrapper(io.BytesIO(b"hello world\n"))):
            self.assertEqual(story.read_request(None), "hello world")

    def test_non_utf8_is_refused(self):
        for data in (b"\xff", b"caf\xc3", b"\xed\xa0\x80"):
            with self.subTest(data=data):
                path = self.request_file(data)
                self.assertEqual(
                    capture(lambda: story.main(["--request-file", path])),
                    (1, "", "error: the request is not valid UTF-8; no issue was filed\n"),
                )

    def test_blank_requests_are_refused(self):
        self.assertEqual(len(FIXTURE["blank"]), 6)
        blanks = [b"", b" \t\n", "\ufeff".encode("utf-8")] + [entry["input"].encode("utf-8") for entry in FIXTURE["blank"]]
        for data in blanks:
            with self.subTest(data=data):
                path = self.request_file(data)
                self.assertEqual(
                    capture(lambda: story.main(["--request-file", path])),
                    (1, "", "error: the request is blank; no issue was filed\n"),
                )

    def test_python_only_whitespace_is_not_refused(self):
        path = self.request_file("\x1c\x1d\x1e\x1f\x85".encode("utf-8"))
        self.assertEqual(story.read_request(path), "\x1c\x1d\x1e\x1f\x85")

    def test_request_vectors_trim_and_mark_as_story_js_does(self):
        inputs = [vector["input"] for vector in FIXTURE["requests"]]
        self.assertEqual(len(inputs), 11)
        self.assertIn("\ufeffhello world\u00a0", inputs)
        self.assertIn("\u00a0nbsp\u00a0 vector\u00a0", inputs)
        for vector in FIXTURE["requests"]:
            with self.subTest(input=vector["input"]):
                path = self.request_file(vector["input"].encode("utf-8"))
                request = story.read_request(path)
                self.assertEqual(request, vector["trimmed"])
                self.assertEqual(story.request_marker(request), vector["marker"])

    def test_bom_request_gets_its_full_error_line(self):
        path = self.request_file("\ufeffhello world\u00a0".encode("utf-8"))
        self.assertEqual(
            capture(lambda: story.main(["--request-file", path])),
            (1, "", f"error: the request's marker is {HELLO_MARKER}, but filing is not built yet (#207); no issue was filed\n"),
        )

    def test_stub_claude_is_never_called_on_a_refusal(self):
        with tempfile.TemporaryDirectory() as bindir:
            log = os.path.join(bindir, "calls.log")
            stub = os.path.join(bindir, "claude")
            with open(stub, "w", encoding="utf-8") as handle:
                handle.write(f'#!/bin/sh\necho called >> "{log}"\n')
            os.chmod(stub, 0o755)
            env = dict(os.environ, PATH=bindir + os.pathsep + os.environ.get("PATH", ""))
            result = subprocess.run([sys.executable, "-I", STORY], input=b" \t\n", capture_output=True, env=env, check=False, timeout=30)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"error: the request is blank; no issue was filed\n")
            self.assertFalse(os.path.exists(log))


class StdinTest(TempCase):
    def setUp(self):
        super().setUp()
        self.bindir = os.path.join(self.dir, "bin")
        os.mkdir(self.bindir)
        self.log = os.path.join(self.dir, "calls.log")
        stub = os.path.join(self.bindir, "claude")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(f'#!/bin/sh\necho called >> "{self.log}"\n')
        os.chmod(stub, 0o755)
        self.env = dict(os.environ, PATH=self.bindir + os.pathsep + os.environ.get("PATH", ""))

    def test_closed_stdin_is_refused_with_its_reason(self):
        with mock.patch.object(story.sys, "stdin", None):
            self.assertEqual(
                capture(lambda: story.main([])),
                (1, "", "error: cannot read the request from stdin: Bad file descriptor; no issue was filed\n"),
            )

    def test_non_blocking_empty_stdin_is_refused_with_its_reason(self):
        stdin = mock.Mock()
        stdin.buffer.raw.read.return_value = None
        with mock.patch.object(story.sys, "stdin", stdin):
            self.assertEqual(
                capture(lambda: story.main([])),
                (1, "", "error: cannot read the request from stdin: Resource temporarily unavailable; no issue was filed\n"),
            )

    def test_partial_non_blocking_stdin_is_refused_with_its_reason(self):
        stdin = mock.Mock()
        stdin.buffer.raw.read.side_effect = [b"hello ", None]
        with mock.patch.object(story.sys, "stdin", stdin):
            self.assertEqual(
                capture(lambda: story.main([])),
                (1, "", "error: cannot read the request from stdin: Resource temporarily unavailable; no issue was filed\n"),
            )

    def test_stdin_chunks_are_joined_until_eof(self):
        stdin = mock.Mock()
        stdin.buffer.raw.read.side_effect = [b"hello", b" world\n", b""]
        with mock.patch.object(story.sys, "stdin", stdin):
            self.assertEqual(story.read_request(None), "hello world")

    def test_closed_stdin_in_a_real_process_is_refused(self):
        command = f'exec "{sys.executable}" -I "{STORY}" <&-'
        result = subprocess.run(["/bin/sh", "-c", command], capture_output=True, env=self.env, check=False, timeout=30)
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"", b"error: cannot read the request from stdin: Bad file descriptor; no issue was filed\n"),
        )
        self.assertFalse(os.path.exists(self.log))

    def test_non_blocking_empty_stdin_in_a_real_process_is_refused(self):
        read_end, write_end = os.pipe()
        self.addCleanup(os.close, read_end)
        self.addCleanup(os.close, write_end)
        os.set_blocking(read_end, False)
        result = subprocess.run([sys.executable, "-I", STORY], stdin=read_end, capture_output=True, env=self.env, check=False, timeout=30)
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"", b"error: cannot read the request from stdin: Resource temporarily unavailable; no issue was filed\n"),
        )
        self.assertFalse(os.path.exists(self.log))

    def test_partial_non_blocking_stdin_in_a_real_process_is_refused(self):
        # The write end stays open, so the child reads "hello " and then gets EAGAIN, not EOF.
        read_end, write_end = os.pipe()
        self.addCleanup(os.close, read_end)
        self.addCleanup(os.close, write_end)
        os.write(write_end, b"hello ")
        os.set_blocking(read_end, False)
        result = subprocess.run([sys.executable, "-I", STORY], stdin=read_end, capture_output=True, env=self.env, check=False, timeout=30)
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"", b"error: cannot read the request from stdin: Resource temporarily unavailable; no issue was filed\n"),
        )
        self.assertFalse(os.path.exists(self.log))

    def test_blocking_stdin_written_in_two_parts_is_read_whole(self):
        # However the pipe splits the two writes, the child reads to EOF, so the marker is the one for "hello world".
        command = [sys.executable, "-I", STORY]
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env) as proc:
            proc.stdin.write(b"hello ")
            proc.stdin.flush()
            try:
                out, err = proc.communicate(b"world\n", timeout=30)
            finally:
                proc.kill()
        self.assertEqual(
            (proc.returncode, out, err),
            (1, b"", f"error: the request's marker is {HELLO_MARKER}, but filing is not built yet (#207); no issue was filed\n".encode("utf-8")),
        )
        self.assertFalse(os.path.exists(self.log))


class IntentTest(TempCase):
    def test_fixture_has_34_refusal_cases(self):
        # A guard: an empty or shortened fixture list fails here, and the generated methods below are counted against it.
        self.assertEqual(len(FIXTURE["refusals"]), 34)
        generated = [name for name in vars(IntentTest) if name.startswith(REFUSAL_PREFIX)]
        self.assertEqual(len(generated), len(FIXTURE["refusals"]))

    def test_bodies_match_story_js(self):
        self.assertEqual(len(FIXTURE["bodies"]), 5)
        for case in FIXTURE["bodies"]:
            with self.subTest(request=case["request"]):
                path = self.request_file(case["request"].encode("utf-8"))
                marker = story.request_marker(story.read_request(path))
                title, intent = story.check_intent(case["intent"])
                self.assertEqual(title, case["title"])
                self.assertEqual(story.issue_body(intent, marker), case["body"])

    def test_titles_at_the_limit_pass(self):
        self.assertEqual(story.title_line("b" * 80), "b" * 80)
        self.assertEqual(story.title_line("\U0001F600" * 41), "\U0001F600" * 41)

    def test_text_refuses_non_strings(self):
        self.assertEqual(story.text(None), "")
        self.assertEqual(story.text(["x"]), "")

    def test_text_collapses_js_whitespace_only(self):
        self.assertEqual(story.text(" a \u00a0\t b\n "), "a b")
        self.assertEqual(story.text("a\x85b\x1c"), "a\x85b\x1c")

    def test_js_whitespace_matches_the_javascript_set(self):
        self.assertEqual(len(FIXTURE["whitespace"]), 25)
        self.assertEqual(len(story.JS_WHITESPACE), len(FIXTURE["whitespace"]))
        self.assertEqual({ord(c) for c in story.JS_WHITESPACE}, set(FIXTURE["whitespace"]))


def refusal_test(case):
    # The factory gives each method its own case; a loop variable would leave every method on the last case.
    def test(self):
        with self.assertRaises(story.StoryError) as raised:
            story.check_intent(case["intent"])
        self.assertEqual(str(raised.exception), case["message"])

    test.__doc__ = case["name"]
    return test


# One test method per refusal case, so a failure names the case. A name collision would drop a case, so it stops the import.
for case in FIXTURE["refusals"]:
    method = REFUSAL_PREFIX + re.sub(r"[^A-Za-z0-9]+", "_", case["name"]).strip("_")
    if hasattr(IntentTest, method):
        raise RuntimeError(f"refusal fixture cases collide on the test name {method!r} ({case['name']!r})")
    setattr(IntentTest, method, refusal_test(case))


class StoryJsGuardTest(unittest.TestCase):
    def test_fixture_was_generated_from_this_story_js(self):
        with open(STORY_JS, "rb") as handle:
            data = handle.read()
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        self.assertEqual(
            blob,
            FIXTURE["source"]["blob"],
            "story.js changed since the fixture was generated: port the change to scripts/story.py, then regenerate the fixture with the generator in the #173 pull request description; never edit the blob hash by hand",
        )
