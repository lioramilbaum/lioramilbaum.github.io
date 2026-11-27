"""Unit tests for scripts/story.py, run by scripts/test-story.sh under a coverage gate (AGENTS.md rule 8)."""

import io
import os
import runpy
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORY = os.path.join(SCRIPTS, "story.py")
sys.path.insert(0, SCRIPTS)

import story  # noqa: E402


def capture(call):
    """Run call() and return (exit code, stdout, stderr) for the SystemExit it raises."""
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            call()
        except SystemExit as exc:
            return exc.code, out.getvalue(), err.getvalue()
    raise AssertionError("expected SystemExit, got a normal return")


class StoryTest(unittest.TestCase):
    def test_no_command_prints_usage_and_exits_2(self):
        self.assertEqual(capture(lambda: story.main([])), (2, "", "usage: python3 scripts/story.py COMMAND (none is available yet)\n"))

    def test_unknown_command_prints_usage_and_exits_2(self):
        self.assertEqual(capture(lambda: story.main(["nope"])), (2, "", "usage: python3 scripts/story.py COMMAND (none is available yet)\n"))

    def test_old_python_refuses_with_no_argv(self):
        with mock.patch.object(story.sys, "version_info", (3, 10, 0)):
            self.assertEqual(capture(lambda: story.main([])), (1, "", "error: story.py needs Python 3.11 or later; this is Python 3.10\n"))

    def test_old_python_refuses_before_a_command(self):
        with mock.patch.object(story.sys, "version_info", (3, 10, 0)):
            self.assertEqual(capture(lambda: story.main(["nope"])), (1, "", "error: story.py needs Python 3.11 or later; this is Python 3.10\n"))

    def test_minimum_python_gets_past_the_check(self):
        with mock.patch.object(story.sys, "version_info", (3, 11, 0)):
            self.assertEqual(capture(lambda: story.main([])), (2, "", "usage: python3 scripts/story.py COMMAND (none is available yet)\n"))

    def test_fail_prints_error_and_exits_1(self):
        self.assertEqual(capture(lambda: story.fail("x")), (1, "", "error: x\n"))

    def test_repo_constant(self):
        self.assertEqual(story.REPO, "lioramilbaum/lioramilbaum.github.io")

    def test_main_entry_point_exits_2_with_usage(self):
        with mock.patch.object(sys, "argv", ["story.py"]):
            code, out, err = capture(lambda: runpy.run_path(STORY, run_name="__main__"))
        self.assertEqual((code, out, err), (2, "", "usage: python3 scripts/story.py COMMAND (none is available yet)\n"))
