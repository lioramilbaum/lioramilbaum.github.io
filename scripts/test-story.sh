#!/usr/bin/env bash
# Tests scripts/story.py (AGENTS.md rule 8): the unit tests in scripts/story-tests/ run under coverage.py,
# and the report fails unless story.py has 100% line and branch coverage.
# Needs uv. Its one network step is `uv sync`: it fetches the Python in scripts/story-tests/.python-version into
# uv's own managed-Python directory, where it persists, and installs coverage.py from uv.lock (hash-checked) into
# a temp venv, which is removed on exit. The rest runs offline. CI runs it in check-site.yml.
# The coverage runs use -I and --rcfile=/dev/null, so PYTHON* variables, a cwd coverage.py, a root .coveragerc
# or pyproject config, and COVERAGE_RCFILE cannot change what is measured or reported.
#
# Usage: scripts/test-story.sh
set -euo pipefail

cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo "error: uv is not on PATH (AGENTS.md Setup)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export UV_PROJECT_ENVIRONMENT="$tmp/venv" COVERAGE_FILE="$tmp/coverage"

uv sync --project scripts/story-tests --locked --no-build --managed-python --no-progress \
  || { echo "error: uv sync failed (see uv's message above); it needs network access to fetch Python and coverage.py (AGENTS.md Setup)" >&2; exit 1; }

"$tmp/venv/bin/python" -I -m coverage run --rcfile=/dev/null --branch -m unittest discover -s scripts/story-tests -t scripts/story-tests -v
"$tmp/venv/bin/python" -I -m coverage report --rcfile=/dev/null --fail-under=100 --include=scripts/story.py --show-missing
echo "PASS story.py: unit tests pass with 100% line and branch coverage"
