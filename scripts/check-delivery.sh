#!/usr/bin/env bash
# AGENTS.md rule 6: checks the PR's own delivery doc against the PR head. It asks
# two questions. Does the doc exist? If not, CI warns and passes. Was the doc
# generated for this head's content digest (the tree without the doc and its
# screenshots)? If not, it fails. Once the delivery window has ended, the check
# passes without reading the doc. Renovate PRs are skipped in the workflow.
#
# Usage: scripts/check-delivery.sh                 (CI: the PR's doc, from the environment)
#        scripts/check-delivery.sh --digest COMMIT DOC
#        scripts/check-delivery.sh --window        (exit 0 open, 3 ended)
# Environment: HEAD_SHA, PR_CREATED_AT and HEAD_REF name the doc, as in
# generate-delivery.sh. NOW overrides the clock (tests use it). AWK selects awk.
set -euo pipefail
LC_ALL=C

cd "$(dirname "$0")/.."

# The delivery window ends here: exclusive, the end of Dec 12 CET (AGENTS.md rule 6).
cutoff=2026-12-12T23:00:00Z
window_open() {
  local now
  now=${NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  [[ "$now" < "$cutoff" ]]
}

# digest COMMIT DOC: the digest of COMMIT's tree without DOC and DOC's screenshot
# directory. Amending the doc into the commit leaves it unchanged.
digest() {
  # shellcheck disable=SC2016 # awk program, not the shell
  git ls-tree -r --full-tree "$1" \
    | "${AWK:-awk}" -F'\t' -v doc="$2" -v dir="${2%.md}/" \
      'index($2, dir) == 1 || $2 == doc { next } { print }' \
    | git hash-object --stdin
}

case "${1:-}" in
  --window)
    if window_open; then echo "delivery window is open until $cutoff"; exit 0; fi
    echo "delivery window ended at $cutoff"
    exit 3
    ;;
  --digest)
    [[ $# -eq 3 ]] || { echo "usage: scripts/check-delivery.sh --digest COMMIT DOC" >&2; exit 1; }
    digest "$2" "$3"
    exit 0
    ;;
  "") ;;
  *) echo "usage: scripts/check-delivery.sh [--window | --digest COMMIT DOC]" >&2; exit 1 ;;
esac

# say LEVEL FILE MESSAGE: annotates in GitHub Actions, otherwise prints to stderr.
say() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::$1 file=$2::$3"
  else
    echo "$1: $2: $3" >&2
  fi
}
fail() { say error "$1" "$2"; exit 1; }

if ! window_open; then
  echo "notice: the delivery window has ended; the delivery doc is no longer checked"
  exit 0
fi

: "${HEAD_SHA:?set HEAD_SHA to the PR head commit}"
: "${PR_CREATED_AT:?set PR_CREATED_AT to the PR open time}"
: "${HEAD_REF:?set HEAD_REF to the PR head branch}"
[[ "$PR_CREATED_AT" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T ]] \
  || fail deliveries/ "PR_CREATED_AT is not an ISO time: $PR_CREATED_AT"
date=${BASH_REMATCH[1]}
case "$HEAD_REF" in
  */*) slug=${HEAD_REF#*/} ;;
  *) slug=$HEAD_REF ;;
esac
doc="deliveries/$date-$slug.md"

git rev-parse --verify --quiet "$HEAD_SHA^{commit}" >/dev/null \
  || fail "$doc" "HEAD_SHA $HEAD_SHA is not a commit in this clone"

if ! git cat-file -e "$HEAD_SHA:$doc" 2>/dev/null; then
  say warning "$doc" "no delivery doc at $doc in $HEAD_SHA; the delivery-doc skill writes it (AGENTS.md rule 6)"
  exit 0
fi

recorded=$(git show "$HEAD_SHA:$doc" | tr -d '\r' \
  | sed -nE 's/^<!-- delivery: content=([0-9a-f]{40}) .*-->$/\1/p' | tail -n1)
[[ -n "$recorded" ]] || fail "$doc" "no delivery metadata comment; run scripts/generate-delivery.sh (AGENTS.md rule 6)"

want=$(digest "$HEAD_SHA" "$doc")
[[ "$recorded" == "$want" ]] \
  || fail "$doc" "stale: the doc was generated for content $recorded but $HEAD_SHA has content $want; run scripts/generate-delivery.sh and amend the doc"
echo "$doc: ok (content $want)"
