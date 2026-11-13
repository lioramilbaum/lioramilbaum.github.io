#!/usr/bin/env bash
# Network check. CI runs it as a non-blocking last step of the build job (the site
# build itself is offline); run it by hand too. GETs every absolute http(s) href on
# a built page and prints "<code> <url>". Exits non-zero if any response is not 2xx.
# The LinkedIn share-offsite URL is skipped: it redirects to a login page.
#
# Checks start in batches of 8 background jobs, and each batch waits for its slowest
# job before the next starts. A job takes at most one link's retry budget (about
# 66 s), or about 200 s for a discussion comment lookup (up to 3 API pages, each with
# the same budget). So the worst case is the sum over batches: 66 s for a batch of
# links only, 200 s for a batch with a comment lookup. This page has 11 links and 5
# comment lookups (16 jobs), in two batches: 8 links, then 3 links and 5 lookups. The
# worst case is 66 s + 198 s = 264 s (a lookup is 3 pages of 66 s), inside CI's 5-minute
# step timeout with 36 s to spare. The second batch is full: no job slots are left. A
# 17th job starts a third batch, which adds at least 66 s and takes the worst case past
# 300 s, so the time budget must change before another link or comment lookup is added.
# Check that sum before adding links or comment lookups.
#
# Discussion comment links (https://github.com/<o>/<r>/discussions/<n>#discussioncomment-<id>)
# are also looked up through the REST API: 200 if the discussion has the comment,
# 404 if it does not. The lookup reads only the first 300 comments (3 pages of 100),
# so a comment beyond that reports 404 as a false warning. A missing discussion also
# reports 404. GITHUB_TOKEN, if set, raises the API rate limit and is sent to
# api.github.com only.
#
# Usage: scripts/check-links.sh [PAGE]   (default: the built hackathon page)
# shellcheck disable=SC2329 # get, link and comment are called indirectly, by start.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
page="${1:-$root/_site/docs/qodo-software-factory-hackathon/index.html}"
# Page-level failure: a message on stderr, and a ::warning:: under GITHUB_ACTIONS.
fail() {
  echo "error: $1" >&2
  [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::warning::$1"
  exit 1
}
test -r "$page" || fail "page not found or unreadable: $page; run scripts/build-site.sh first"
ua='Mozilla/5.0 (compatible; lioramilbaum.com-link-check; +https://github.com/lioramilbaum/lioramilbaum.github.io)'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
api=(-H 'Accept: application/vnd.github+json')
# The token goes in a mode-600 header file, so it never appears on curl's argv (ps).
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  (umask 077; printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$tmp/auth")
  api+=(-H @"$tmp/auth")
fi

get() { curl -sSL -A "$ua" --connect-timeout 10 --max-time 20 --retry 2 --retry-delay 3 --retry-all-errors "$@"; }
hrefs() {
  grep -Eo 'href="https?://[^"]*"' "$page" | sed -E 's/^href="//; s/"$//' \
    | grep -v '^https://www\.linkedin\.com/sharing/share-offsite/' || true
}
# link URL: "<code> <URL>" for the page itself.
link() { echo "$(get -o /dev/null -w '%{http_code}' "$1" || true) $1"; }
# comment URL: "<code> <URL>": 200 if the discussion has the comment (replies
# included), 404 if not, else the API's code. Up to 3 pages of 100.
comment() {
  local id=${1##*#discussioncomment-} discussion=${1#https://github.com/} p code=404 count
  discussion=${discussion%%#*}
  for p in 1 2 3; do
    code=$(get -o "$tmp/$id.json" -w '%{http_code}' "${api[@]}" \
      "https://api.github.com/repos/$discussion/comments?per_page=100&page=$p" || true)
    [[ "$code" == 200 ]] || break
    if grep -Fq "#discussioncomment-$id\"" "$tmp/$id.json"; then break; fi
    code=404
    count=$(grep -o '#discussioncomment-[0-9]*"' "$tmp/$id.json" | wc -l || true)
    (( count == 100 )) || break
  done
  echo "$code $1"
}

# At most $cap checks run at once: every $cap-th job waits for the batch before it.
cap=8
n=0
start() {
  n=$((n + 1))
  "$@" > "$tmp/$n" &
  if (( n % cap == 0 )); then wait; fi
}
[[ -n "$(hrefs)" ]] || fail "link check: no absolute http(s) links on $page"
while IFS= read -r url; do
  start link "$url"
done < <(hrefs | sed -E 's/#.*$//' | sort -u)
while IFS= read -r url; do
  start comment "$url"
done < <(hrefs | grep -E '^https://github\.com/[^/]+/[^/]+/discussions/[0-9]+#discussioncomment-[0-9]+$' | sort -u || true)
wait

failed=0
for ((i = 1; i <= n; i++)); do
  code='' url=''
  read -r code url < "$tmp/$i" || true
  echo "${code:-000} $url"
  if ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    failed=1
    [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::warning::link check: HTTP ${code:-000} from $url"
  fi
done
exit "$failed"
