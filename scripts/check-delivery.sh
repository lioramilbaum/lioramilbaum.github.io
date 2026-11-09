#!/usr/bin/env bash
# AGENTS.md rule 6: a PR's delivery doc is generated after the PR merges and added in a
# docs PR, one that changes only files under deliveries/. A PR that changes anything
# else needs no doc, and the check passes. On a docs PR it checks each doc the PR adds
# or changes. Does its metadata name the merged head (head=)? Was it generated for that
# head's content digest? If not, it fails. Qodo's final review is evidence (qodo-open,
# AGENTS.md rule 9), not a gate: a value other than 0 warns. Once the delivery window
# has ended, the check passes without reading a doc. Renovate PRs are skipped in the
# workflow.
#
# Usage: scripts/check-delivery.sh                 (CI: the PR's docs, from the checkout)
#        scripts/check-delivery.sh --digest COMMIT DOC
#        scripts/check-delivery.sh --window        (exit 0 open, 3 ended)
# Environment: the checked-out HEAD is the PR (in CI, its merge commit) and BASE_SHA its
# base (default HEAD^1, the merge commit's base parent). A merged head missing from a
# shallow clone is fetched from origin. NOW overrides the clock (tests use it). AWK
# selects awk.
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

base=${BASE_SHA:-HEAD^1}
git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || fail deliveries/ "the base $base is not a commit in this clone"

# The PR's changes: HEAD against its base. A docs PR changes only files under deliveries/.
# Its docs are deliveries/<name>.md, not TEMPLATE.md and not a file in a screenshot directory.
# The list is NUL-delimited (-z), so git does not quote a name with a tab, a newline or a
# quote, and such a doc is read under its own name.
changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
git diff --name-only -z --no-renames "$base" HEAD > "$changed" \
  || fail deliveries/ "could not list the changes from $base to HEAD"
code=0; docs=()
while IFS= read -r -d '' path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    deliveries/TEMPLATE.md | deliveries/*/*) ;;
    deliveries/*.md) docs+=("$path") ;;
    deliveries/*) ;;
    *) code=1 ;;
  esac
done < "$changed"

if (( code )); then
  echo "notice: this PR changes files outside deliveries/, so it carries no delivery doc; its doc comes in a docs PR after it merges (AGENTS.md rule 6)"
  exit 0
fi

# check_doc DOC: DOC (in HEAD) records the merged head it was generated from, and that
# head's content digest.
check_doc() {
  local doc=$1 meta recorded head want qodo
  # The metadata is the doc's last "<!-- delivery:" line. Its values come from that one
  # line, so an earlier line cannot supply a value the last line lacks.
  meta=$(git show "HEAD:$doc" | tr -d '\r' | grep '^<!-- delivery: ' | tail -n1 || true)
  recorded=$(printf '%s\n' "$meta" | sed -nE 's/^<!-- delivery: content=([0-9a-f]{40}) .*-->$/\1/p')
  [[ -n "$recorded" ]] || fail "$doc" "no delivery metadata comment; run scripts/generate-delivery.sh (AGENTS.md rule 6)"
  head=$(printf '%s\n' "$meta" | sed -nE 's/^<!-- delivery: content=[0-9a-f]{40} head=([0-9a-f]{40}) .*-->$/\1/p')
  [[ -n "$head" ]] || fail "$doc" "the doc records no merged head (head=); regenerate it from the merged PR (AGENTS.md rule 6)"

  # CI's clone is shallow, so the merged head is usually fetched.
  if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
    git fetch --quiet --no-tags --depth=1 origin "$head" >/dev/null 2>&1 || true
  fi
  git cat-file -e "$head^{commit}" 2>/dev/null \
    || fail "$doc" "the merged head $head is not in this clone and could not be fetched from origin"

  want=$(digest "$head" "$doc")
  [[ "$recorded" == "$want" ]] \
    || fail "$doc" "stale: the doc was generated for content $recorded but its merged head $head has content $want; regenerate it from the merged PR"

  # Qodo's final review is recorded, not gated: the qodo-findings status gated the merge (rule 9).
  qodo=$(printf '%s\n' "$meta" \
    | sed -nE 's/^<!-- delivery: content=[0-9a-f]{40} .* qodo-open=(none|other|unknown|[0-9]+) -->$/\1/p')
  case "$qodo" in
    0) echo "$doc: ok (content $want, merged head $head, no open Qodo findings)"; return 0 ;;
    "") fail "$doc" "the doc records no Qodo state; regenerate it (AGENTS.md rule 9)" ;;
    none) say warning "$doc" "Qodo had not reviewed the PR when the doc was generated (AGENTS.md rule 9)" ;;
    other) say warning "$doc" "Qodo's final review was of other content than the merged head (AGENTS.md rule 9)" ;;
    unknown) say warning "$doc" "Qodo's final review could not be read: it has no finding the generator can parse, and not every group says it is clear; a new layout belongs in scripts/qodo-review.awk (AGENTS.md rule 9)" ;;
    *) say warning "$doc" "Qodo's final review listed $qodo open finding(s) (AGENTS.md rule 9)" ;;
  esac
  echo "$doc: ok (content $want, merged head $head, qodo-open $qodo)"
}

ndocs=0
for doc in ${docs[@]+"${docs[@]}"}; do
  # A doc the PR deletes is not in HEAD, so there is nothing to check.
  git cat-file -e "HEAD:$doc" 2>/dev/null || continue
  check_doc "$doc"
  ndocs=$((ndocs + 1))
done
echo "docs PR: $ndocs delivery doc(s) checked"
