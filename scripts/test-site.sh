#!/usr/bin/env bash
# Tests the homepage's LinkedIn followers line (AGENTS.md rule 3) against _data/linkedin.yml variants.
# Each case builds a copy of this checkout with its own data, then runs check-site.sh on the result:
# valid data shows the line and passes, invalid data hides it and fails naming the missing line.
# Needs Docker and no network (build-site.sh); CI runs it in check-site.yml.
#
# Usage: scripts/test-site.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/copy"
tar -C "$root" --exclude=./.git --exclude=./_site --exclude=./_snapshots -cf - . | tar -C "$tmp/copy" -xf -

failures=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# case_run NAME DATA WANT TEXT: DATA is the file's content (empty deletes the file). WANT is
# "shown" (the check passes and the page says TEXT) or "hidden" (the check fails naming the missing line).
case_run() {
  local name=$1 data=$2 want=$3 text=$4
  local dir="$tmp/copy" page out code=0
  page="$dir/_site/index.html"
  rm -f "$dir/_data/linkedin.yml"
  if [[ -n "$data" ]]; then printf '%s\n' "$data" > "$dir/_data/linkedin.yml"; fi
  if ! "$root/scripts/build-site.sh" "$dir" > "$tmp/build.log" 2>&1; then
    fail_case "$name" "build failed"
    tail -n 20 "$tmp/build.log"
    return
  fi
  out=$(env -u GITHUB_ACTIONS bash "$root/scripts/check-site.sh" "$dir/_site" 2>&1) || code=$?
  if [[ "$want" == shown ]]; then
    (( code == 0 )) || { fail_case "$name" "check-site.sh exited $code: $out"; return; }
    grep -Fq "$text" "$page" || { fail_case "$name" "homepage lacks '$text'"; return; }
    pass "$name"
  else
    (( code == 1 )) || { fail_case "$name" "check-site.sh exited $code, not 1: $out"; return; }
    [[ "$out" == *"error: LinkedIn followers line missing from the homepage"* ]] \
      || { fail_case "$name" "check-site.sh did not name the missing line: $out"; return; }
    if grep -Fq 'LinkedIn followers' "$page" || grep -Fq 'class="followers"' "$page"; then
      fail_case "$name" "homepage still shows the followers line"
      return
    fi
    pass "$name"
  fi
}

case_run "valid data shows the line with grouping" \
  $'followers: 1234567\nas_of: 2026-01-05' shown '1,234,567 LinkedIn followers · as of Jan 5, 2026'
case_run "1000 groups to 1,000" $'followers: 1000\nas_of: 2026-11-16' shown '1,000 LinkedIn followers'
case_run "quoted digits are accepted" $'followers: "29572"\nas_of: 2026-11-16' shown '29,572 LinkedIn followers · as of Nov 16, 2026'
case_run "no data file hides the line" '' hidden ''
case_run "no followers key hides the line" $'as_of: 2026-11-16' hidden ''
case_run "zero followers hides the line" $'followers: 0\nas_of: 2026-11-16' hidden ''
case_run "comma string hides the line" $'followers: "1,234"\nas_of: 2026-11-16' hidden ''
case_run "fractional followers hides the line" $'followers: 12.5\nas_of: 2026-11-16' hidden ''
case_run "no as_of hides the line" $'followers: 29572' hidden ''
case_run "unparseable as_of hides the line" $'followers: 29572\nas_of: soon' hidden ''
case_run "negative followers hides the line" $'followers: -5\nas_of: 2026-11-16' hidden ''
case_run "followers with a suffix hides the line" $'followers: 12abc\nas_of: 2026-11-16' hidden ''
case_run "boolean followers hides the line" $'followers: true\nas_of: 2026-11-16' hidden ''
case_run "empty as_of hides the line" $'followers: 29572\nas_of: ""' hidden ''
case_run "impossible as_of date hides the line" $'followers: 29572\nas_of: 2026-13-45' hidden ''

if (( failures > 0 )); then
  echo "$failures LinkedIn followers case(s) failed"
  exit 1
fi
echo "All LinkedIn followers cases passed"
