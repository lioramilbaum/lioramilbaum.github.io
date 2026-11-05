#!/usr/bin/env bash
# AGENTS.md rule 6: every PR adds or updates a delivery doc,
# deliveries/<YYYY-MM-DD>-<slug>.md, that has every top-level "## " heading of
# deliveries/TEMPLATE.md. Only those headings are checked, not the content. A
# TODO(qodo) marker only warns, because Qodo has only reviewed PRs after they
# leave draft. Renovate PRs are exempted in the workflow, not here.
#
# Fenced code blocks follow CommonMark: a block opens with three or more ``` or
# ~~~ (up to three spaces of indent; a backtick info string may not contain a
# backtick). It closes only at a fence of the same character, at least as long,
# with nothing after it. "## " lines inside a block do not count. CRLF line
# endings are accepted. AWK selects the awk binary (default: awk);
# scripts/test-check-delivery.sh runs the cases under each awk.
#
# Usage: scripts/check-delivery.sh [BASE] [HEAD]
#   BASE defaults to upstream/main if it exists, else origin/main.
#   HEAD defaults to HEAD. CI runs: scripts/check-delivery.sh HEAD^1 HEAD
#   (the pull_request merge commit and its base-branch parent).
set -euo pipefail

cd "$(dirname "$0")/.."

template=deliveries/TEMPLATE.md
name_re='^deliveries/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.md$'

# fail FILE MESSAGE: annotate in GitHub Actions, otherwise print to stderr.
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=$1::$2"
  else
    echo "error: $1: $2" >&2
  fi
  exit 1
}

# warn FILE MESSAGE: does not fail the check.
warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning file=$1::$2"
  else
    echo "warning: $1: $2" >&2
  fi
}

# top_level_headings: "## " lines on stdin that are outside fenced code blocks.
# Plain string functions only (no interval expressions), so it runs on BWK
# awk, mawk and gawk.
top_level_headings() {
  # shellcheck disable=SC2016 # $0 belongs to awk, not the shell
  "${AWK:-awk}" '
    # run(s, c): length of the run of character c at the start of s.
    function run(s, c,   n) {
      n = 0
      while (substr(s, n + 1, 1) == c) n++
      return n
    }
    {
      ind = 0
      while (substr($0, ind + 1, 1) == " ") ind++
      rest = substr($0, ind + 1)
      if (fence == "") {
        ch = substr(rest, 1, 1)
        if (ind <= 3 && (ch == "`" || ch == "~")) {
          n = run(rest, ch)
          if (n >= 3 && (ch == "~" || index(substr(rest, n + 1), "`") == 0)) {
            fence = ch
            flen = n
            next
          }
        }
        if (substr($0, 1, 3) == "## ") print
      } else if (ind <= 3 && substr(rest, 1, 1) == fence) {
        n = run(rest, fence)
        if (n >= flen && substr(rest, n + 1) ~ /^[ \t]*$/) fence = ""
      }
    }
  '
}

base="${1:-}"
if [[ -z "$base" ]]; then
  if git rev-parse --verify --quiet upstream/main >/dev/null; then
    base=upstream/main
  else
    base=origin/main
  fi
fi
head="${2:-HEAD}"

test -f "$template" || fail "$template" "delivery template is missing"

headings=$(tr -d '\r' < "$template" | top_level_headings)
[[ -n "$headings" ]] || fail "$template" "no top-level '## ' headings found in the template"
required=$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' <<< "$headings")

mb=$(git merge-base "$base" "$head") \
  || fail deliveries/ "could not find a merge-base of $base and $head"

changed=$(git diff --name-only --diff-filter=AMR "$mb" "$head" -- deliveries/) \
  || fail deliveries/ "could not list changed files under deliveries/"

docs=()
while IFS= read -r f; do
  if [[ -n "$f" && "$f" != "$template" ]]; then
    docs+=("$f")
  fi
done <<< "$changed"

if [[ ${#docs[@]} -eq 0 ]]; then
  fail deliveries/ "no delivery doc added or updated under deliveries/ (AGENTS.md rule 6)"
fi

for f in "${docs[@]}"; do
  [[ "$f" =~ $name_re ]] \
    || fail "$f" "name must match deliveries/<YYYY-MM-DD>-<slug>.md (AGENTS.md rule 6)"

  content=$(git show "$head:$f" | tr -d '\r') || fail "$f" "could not read $f at $head"
  top=$(top_level_headings <<< "$content")

  while IFS= read -r heading; do
    grep -qxF -- "$heading" <<< "$top" \
      || fail "$f" "missing required section '$heading' (from $template); required sections: $required"
  done <<< "$headings"

  if grep -qF 'TODO(qodo)' <<< "$content"; then
    warn "$f" "TODO(qodo) is still present; fill it in from Qodo's review (Qodo has only reviewed PRs after they leave draft)"
  fi

  echo "$f: ok"
done
