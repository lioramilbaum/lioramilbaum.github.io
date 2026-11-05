#!/usr/bin/env bash
# Tests for the delivery-doc tooling (AGENTS.md rule 6): generate-delivery.sh and the
# check in check-delivery.sh. Offline by default: no Docker and no network. Each case
# builds a throwaway git repo with the real scripts and template. gh is a stub on PATH
# that serves fixture JSON and applies --jq with jq. BUILD_SITE and SNAPSHOT are stubs.
# "--snapshot" runs the one Docker test instead: snapshot-site.sh must reject a page
# that the browser sees as 404. It needs Docker and no network.
# Prints one line per case and exits 1 if any case fails. Set AWK to test another
# awk (default: awk).
set -euo pipefail
unset GITHUB_ACTIONS
# The clock is fixed: the window is open on this date, and the cases set NOW themselves.
export NOW=2026-11-06T12:00:00Z

mode=offline
case "${1:-}" in
  --snapshot) mode=snapshot ;;
  "") ;;
  *) echo "usage: scripts/test-delivery.sh [--snapshot]" >&2; exit 1 ;;
esac

awk_bin=${AWK:-awk}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-delivery.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=0
doc_name=deliveries/2026-11-05-demo-change.md
stem=2026-11-05-demo-change
trailer='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

# report NAME STATUS [DETAIL]: STATUS 0 is a pass.
report() {
  if [ "$2" -eq 0 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    [ -z "${3:-}" ] || echo "     $3"
    failures=$((failures + 1))
  fi
}

# png_width FILE: the IHDR width. BSD od prints a trailing blank line, so only
# the first non-empty line is read.
# shellcheck disable=SC2016 # awk program, not the shell
png_width() { od -An -tu1 -j16 -N4 "$1" | "$awk_bin" 'NF { print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4; exit }'; }

if [ "$mode" = snapshot ]; then
  command -v docker >/dev/null 2>&1 || { echo "error: docker is needed for --snapshot" >&2; exit 1; }
  # A page that exists, and a path that does not: the browser sees a 404 for it.
  mkdir -p "$tmp/site"
  printf '<html><h1>Snapshot page</h1></html>\n' > "$tmp/site/index.html"
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
  # All interfaces: on native Linux, host-gateway is the Docker bridge, not 127.0.0.1.
  python3 -m http.server "$port" --bind 0.0.0.0 --directory "$tmp/site" >"$tmp/http.log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  ready=0
  for _ in $(seq 1 10); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || { echo "error: the fixture server did not answer on port $port (see $tmp/http.log)" >&2; exit 1; }
  if bash "$root/scripts/snapshot-site.sh" "http://host.docker.internal:$port" "$tmp/shot-ok" >"$tmp/shot-ok.log" 2>&1 \
    && [ -s "$tmp/shot-ok/desktop.png" ] && [ "$(png_width "$tmp/shot-ok/desktop.png")" -eq 1280 ]; then
    report "snapshot: a 200 page writes desktop.png at 1280 px" 0
  else
    report "snapshot: a 200 page writes desktop.png at 1280 px" 1 "$(cat "$tmp/shot-ok.log")"
  fi
  if bash "$root/scripts/snapshot-site.sh" "http://host.docker.internal:$port/nope" "$tmp/shot-404" >"$tmp/shot-404.log" 2>&1; then
    report "snapshot: a page the browser sees as 404 fails with no PNG" 1 "snapshot succeeded"
  elif [ -e "$tmp/shot-404/desktop.png" ]; then
    report "snapshot: a page the browser sees as 404 fails with no PNG" 1 "a PNG was left behind"
  elif ! grep -qF 'returned HTTP 404 to the browser' "$tmp/shot-404.log"; then
    report "snapshot: a page the browser sees as 404 fails with no PNG" 1 "failed for another reason: $(cat "$tmp/shot-404.log")"
  else
    report "snapshot: a page the browser sees as 404 fails with no PNG" 0
  fi
  if [ "$failures" -ne 0 ]; then exit 1; fi
  echo "snapshot tests passed (docker)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is needed by the gh stub" >&2; exit 1; }
awk_version=$({ "$awk_bin" --version </dev/null 2>/dev/null || "$awk_bin" -W version </dev/null 2>/dev/null; } | head -n 1) || true
echo "awk: $awk_bin ${awk_version:-unknown}"
bin="$tmp/bin"
mkdir -p "$bin"

# Stubs -----------------------------------------------------------------------

cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: serves $GH_FIXTURES files and applies --jq with jq. It logs every call's
# argv. A -F value with "@" is what gh would read from a file: it is recorded as a
# violation and the call fails.
set -euo pipefail
prev=""
for arg in "$@"; do
  if [ "$prev" = -F ]; then
    case "$arg" in
      *=@*|@*) echo "$*" >> "$GH_FIXTURES/gh-violations.log"; exit 3 ;;
    esac
  fi
  prev=$arg
done
echo "$*" >> "$GH_FIXTURES/gh-calls.log"
case "$1 $2" in
  "pr view") fixture=$GH_FIXTURES/pr.json ;;
  "run list") fixture=$GH_FIXTURES/runs.json ;;
  "run view") fixture=$GH_FIXTURES/run-$3.json ;;
  "api graphql")
    query=""; id=""; after=""
    for arg in "$@"; do
      case "$arg" in
        query=*) query=$arg ;;
        id=*) id=${arg#id=} ;;
        after=*) after=${arg#after=} ;;
      esac
    done
    case "$query" in
      *comments\(*) fixture=$GH_FIXTURES/comments-${after:-null}.json ;;
      *userContentEdits*) fixture=$GH_FIXTURES/edits-$id-${after:-first}.json ;;
      *) echo "gh stub: unsupported query" >&2; exit 2 ;;
    esac
    ;;
  *) echo "gh stub: unsupported call: $*" >&2; exit 2 ;;
esac
jq_expr=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --jq ]; then jq_expr=$arg; fi
  prev=$arg
done
if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "$fixture"; else cat "$fixture"; fi
STUB

# A PNG with the given IHDR width, plus optional padding (bytes).
cat > "$bin/png-lib.sh" <<'LIB'
# be32 N: the four bytes of N, big-endian, as printf escapes.
be32() {
  printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) \
    $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}
# write_png FILE WIDTH [PAD]: signature, IHDR (width, height 720), then PAD zero bytes.
write_png() {
  {
    printf '\211PNG\r\n\032\n\000\000\000\015IHDR'
    printf "$(be32 "$2")"
    printf "$(be32 720)"
    printf '\010\006\000\000\000'
    if [ -n "${3:-}" ]; then head -c "$3" /dev/zero; fi
  } > "$1"
}
LIB

cat > "$bin/build-site" <<'STUB'
#!/usr/bin/env bash
# Stub BUILD_SITE: the homepage is whatever site-src holds in this worktree.
set -euo pipefail
rm -rf _site
cp -R site-src _site
STUB

cat > "$bin/snapshot" <<'STUB'
#!/usr/bin/env bash
# Stub SNAPSHOT: checks the local server answers (127.0.0.1 stands in for
# host.docker.internal), then writes desktop.png. SNAP_PAD adds bytes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/png-lib.sh"
url=$1
out=$2
curl -fsS -o /dev/null "${url/host.docker.internal/127.0.0.1}"
mkdir -p "$out"
write_png "$out/desktop.png" 1280 "${SNAP_PAD:-}"
STUB
chmod +x "$bin/gh" "$bin/build-site" "$bin/snapshot"

# Helpers ---------------------------------------------------------------------

# new_case NAME: a repo with the real delivery scripts and template, a base
# homepage, and a fixture directory (outside the repo) for the gh stub.
new_case() {
  CASE="$tmp/$1"
  FX="$tmp/$1-fx"
  mkdir -p "$CASE/scripts" "$CASE/deliveries" "$CASE/site-src/assets/images" "$FX"
  cp "$root/scripts/generate-delivery.sh" "$root/scripts/check-delivery.sh" "$CASE/scripts/"
  cp "$root/deliveries/TEMPLATE.md" "$CASE/deliveries/TEMPLATE.md"
  printf '<html><h1>Base homepage</h1><img src="/assets/images/profile.jpg"><link rel="icon" href="/favicon.ico"></html>\n' \
    > "$CASE/site-src/index.html"
  printf 'profile-v1' > "$CASE/site-src/assets/images/profile.jpg"
  printf 'icon-v1' > "$CASE/site-src/favicon.ico"
  git -C "$CASE" init -q
  commit_all base
  BASE=$(git -C "$CASE" rev-parse HEAD)
}

commit_all() {  # commit_all MESSAGE
  git -C "$CASE" add -A
  git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q --allow-empty -m "$1"
}

head_sha() { git -C "$CASE" rev-parse HEAD; }

body_full() {
  cat <<'BODY'
## Why

Readers cannot see how a delivery was made.

## How

- Generated from the PR description and CI.

## What

A generated delivery doc.

## Assistance and third-party material

No third-party code.

## Limitations

Only the homepage is captured.

## Hackathon

Day 3: Demo day (https://github.com/orgs/qodo-hackathon/discussions/9)

## Qodo notes

Qodo's point about screenshots was fair.
BODY
}

body_plain() {
  cat <<'BODY'
## Why

A plain PR.

## How

Plainly.

## What

Nothing much.

## Assistance and third-party material

None.

## Limitations

None known.
BODY
}

# fx_pr HEAD_SHA BODY_FILE: the PR as gh would report it.
fx_pr() {
  jq -n --arg head "$1" --arg base "$BASE" --rawfile body "$2" '{
    title: "Demo change",
    createdAt: "2026-11-05T09:00:00Z",
    headRefName: "feat/demo-change",
    headRefOid: $head,
    baseRefOid: $base,
    url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24",
    body: $body
  }' > "$FX/pr.json"
}

# fx_runs [ID SHA BUILD DELIVERY-DOC]...: Check site runs on the branch, each with
# the conclusions of its build and delivery-doc jobs (and the job file gh run view reads).
fx_runs() {
  local runs='[]' id sha build delivery at
  while [ $# -ge 4 ]; do
    id=$1; sha=$2; build=$3; delivery=$4
    at=$(printf '2026-11-05T%02d:00:00Z' $(( id - 101 + 10 )))
    runs=$(jq -c --argjson id "$id" --arg sha "$sha" --arg at "$at" '. + [{
      databaseId: $id, headSha: $sha, status: "completed", createdAt: $at, event: "pull_request",
      url: ("https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/" + ($id | tostring))
    }]' <<< "$runs")
    jq -n --arg b "$build" --arg d "$delivery" \
      '{jobs: [{name: "build", conclusion: $b}, {name: "delivery-doc", conclusion: $d}]}' > "$FX/run-$id.json"
    shift 4
  done
  printf '%s\n' "$runs" > "$FX/runs.json"
}

# review_body SHA SEVERITY SPEC...: a Qodo-style review body with one severity
# group. SPEC is "findings-uuid|title|kind".
review_body() {
  local sha=$1 sev=$2 n=0 spec u t k
  shift 2
  printf '<h3>Code Review by Qodo</h3>\n\n<details><summary><ins><strong>View %s (%s)</strong></ins></summary><br/>\n\n' "$sev" "$#"
  for spec in "$@"; do
    IFS='|' read -r u t k <<< "$spec"
    n=$((n + 1))
    printf '<details>\n<summary>  %s.  %s <code>%s</code> <code>⭐ New</code></summary>\n\n<br/>\n\n' "$n" "$t" "$k"
    printf '[Dismiss ↗](https://app.qodo.ai/findings/%s?action=dismiss&origin=git) | [View ↗](https://app.qodo.ai/findings/%s)\n\n</details>\n\n' "$u" "$u"
  done
  printf '</details>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$sha"
}

# fx_qodo LATEST_BODY_FILE [EDIT_AT EDIT_BODY_FILE]...: Qodo's comment with its edit
# history (one page). Each edit's diff is the body as of that edit.
fx_qodo() {
  local latest=$1 edits='[]'
  shift
  while [ $# -ge 2 ]; do
    edits=$(jq -c --arg at "$1" --rawfile d "$2" '. + [{editedAt: $at, diff: $d}]' <<< "$edits")
    shift 2
  done
  jq -n --rawfile body "$latest" '{data: {repository: {pullRequest: {comments: {
    pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [
      {id: "IC_qodo", createdAt: "2026-11-05T15:50:27Z", author: {login: "qodo-code-review"}, body: $body},
      {id: "IC_human", createdAt: "2026-11-05T15:51:00Z", author: {login: "someone"}, body: "a human comment"}
    ]}}}}}' > "$FX/comments-null.json"
  jq -n --argjson edits "$edits" '{data: {node: {userContentEdits: {
    pageInfo: {hasNextPage: false, endCursor: null}, nodes: $edits}}}}' > "$FX/edits-IC_qodo-first.json"
}

fx_qodo_none() {
  jq -n '{data: {repository: {pullRequest: {comments: {
    pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [{id: "IC_human", createdAt: "2026-11-05T15:51:00Z", author: {login: "someone"}, body: "a human comment"}]
  }}}}}' > "$FX/comments-null.json"
}

# pr_case NAME CHANGE BODY: a PR with one commit, CI run 101 passing on it, and no
# Qodo review. CHANGE is home (the homepage changes), other (a file off the homepage),
# photo (only profile.jpg's bytes change) or broken (the homepage loads a missing file).
# BODY is full or plain.
pr_case() {
  new_case "$1"
  case "$2" in
    home)
      printf '<html><h1>New homepage</h1><img src="/assets/images/profile.jpg"><link rel="icon" href="/favicon.ico"></html>\n' \
        > "$CASE/site-src/index.html"
      commit_all "change the homepage" ;;
    other)
      printf 'notes\n' > "$CASE/notes.txt"
      commit_all "a change that is not on the homepage" ;;
    photo)
      printf 'profile-v2' > "$CASE/site-src/assets/images/profile.jpg"
      commit_all "a new profile photo" ;;
    broken)
      printf '<img src="/missing.png">\n' > "$CASE/site-src/index.html"
      commit_all "a homepage that loads a missing file" ;;
  esac
  "body_$3" > "$FX/body.md"
  fx_pr "$(head_sha)" "$FX/body.md"
  fx_runs 101 "$(head_sha)" success success
  fx_qodo_none
}

# stale_case NAME: a PR whose doc was generated and committed, then a non-doc commit
# made it stale.
stale_case() {
  pr_case "$1" other plain
  gen "$CASE"
  commit_all "delivery doc"
  printf 'more\n' > "$CASE/notes.txt"
  commit_all "a non-doc change after the doc"
}

# gen CASE [ARGS]: runs generate-delivery.sh for PR 24 with the stubs. Output goes to
# $FX/gen.log. Sets GEN_RC to the script's status.
gen() {
  local c=$1
  shift
  GEN_RC=0
  (cd "$c" && PATH="$bin:$PATH" GH_FIXTURES="$FX" BUILD_SITE="$bin/build-site" SNAPSHOT="${SNAP_CMD:-$bin/snapshot}" \
    bash scripts/generate-delivery.sh --pr 24 "$@") > "$FX/gen.log" 2>&1 || GEN_RC=$?
  return 0
}

# check CASE HEAD_SHA [NOW] [GITHUB_ACTIONS]: runs check-delivery.sh for the case's PR
# (created 2026-11-05, branch feat/demo-change). Sets CHECK_RC to its status.
check() {
  CHECK_RC=0
  (cd "$1" && NOW="${3:-$NOW}" GITHUB_ACTIONS="${4:-}" HEAD_SHA="$2" PR_CREATED_AT=2026-11-05T09:00:00Z \
    HEAD_REF=feat/demo-change bash scripts/check-delivery.sh) > "$FX/check.log" 2>&1 || CHECK_RC=$?
  return 0
}

# win CASE NOW: runs check-delivery.sh --window at NOW. Sets WIN_RC.
win() {
  WIN_RC=0
  (cd "$1" && NOW="$2" bash scripts/check-delivery.sh --window) > /dev/null 2>&1 || WIN_RC=$?
  return 0
}

# post_spacing_ok FILE: in the discussion post, exactly one blank line precedes every
# "## " heading except the first. Fails if the post has fewer than two headings.
post_spacing_ok() {
  # shellcheck disable=SC2016 # awk program, not the shell
  "$awk_bin" '
    $0 == "````markdown" { on = 1; first = 1; prev = $0; prev2 = ""; next }
    on && $0 == "````" { on = 0 }
    on && /^## / {
      n++
      if (first) first = 0
      else if (!(prev == "" && prev2 != "")) bad = 1
    }
    on && $0 == "" && prev == "" { bad = 1 }
    on { prev2 = prev; prev = $0 }
    END { exit (bad || n < 2) ? 1 : 0 }' "$1"
}

# Cases -----------------------------------------------------------------------

# a. The homepage changed: desktop.png is written and embedded at 1280 px; no phone.
pr_case a home full
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF "![Homepage on desktop]($stem/desktop.png)" "$CASE/$doc_name" \
  && grep -qF "![Homepage on desktop](https://raw.githubusercontent.com/lioramilbaum/lioramilbaum.github.io/main/deliveries/$stem/desktop.png)" "$CASE/$doc_name" \
  && grep -qF 'Homepage: changed.' "$CASE/$doc_name" \
  && [ "$(png_width "$CASE/deliveries/$stem/desktop.png")" -eq 1280 ] \
  && [ ! -e "$CASE/deliveries/$stem/phone.png" ] && ! grep -qi 'phone' "$CASE/$doc_name"; then
  report "a. homepage changed: desktop.png written, embedded, 1280 px; no phone" 0
else
  report "a. homepage changed: desktop.png written, embedded, 1280 px; no phone" 1 "$(cat "$FX/gen.log")"
fi

# a2. Digest agreement: the generated doc, committed, passes the check with the PR's
# created time and branch.
commit_all "delivery doc"
check "$CASE" "$(head_sha)"
if [ "$CHECK_RC" -eq 0 ] && grep -q 'ok (content' "$FX/check.log"; then
  report "a2. digest agreement: check passes the generated doc" 0
else
  report "a2. digest agreement: check passes the generated doc" 1 "$(cat "$FX/check.log")"
fi

# b. Unchanged homepage: no screenshot, the "no visible change" line, and no PNG dir.
pr_case b other plain
mkdir -p "$CASE/deliveries/$stem"
printf 'x' > "$CASE/deliveries/$stem/desktop.png"
gen "$CASE" --check
if [ "$GEN_RC" -ne 0 ] && grep -qF 'would remove' "$FX/gen.log"; then
  report "b0. --check reports a PNG dir left for an unchanged homepage" 0
else
  report "b0. --check reports a PNG dir left for an unchanged homepage" 1 "$(cat "$FX/gen.log")"
fi
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'No visible change on the homepage.' "$CASE/$doc_name" \
  && grep -qF 'Homepage: unchanged.' "$CASE/$doc_name" \
  && [ ! -d "$CASE/deliveries/$stem" ]; then
  report "b. homepage unchanged: no PNG dir, no-change line" 0
else
  report "b. homepage unchanged: no PNG dir, no-change line" 1 "$(cat "$FX/gen.log")"
fi
commit_all "delivery doc"
check "$CASE" "$(head_sha)"
if [ "$CHECK_RC" -eq 0 ]; then
  report "b2. check passes with no screenshot" 0
else
  report "b2. check passes with no screenshot" 1 "$(cat "$FX/check.log")"
fi

# c. Only the bytes of profile.jpg differ: the homepage still counts as changed.
pr_case c photo plain
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'Homepage: changed.' "$CASE/$doc_name" && [ -f "$CASE/deliveries/$stem/desktop.png" ]; then
  report "c. only profile.jpg bytes differ: changed" 0
else
  report "c. only profile.jpg bytes differ: changed" 1 "$(cat "$FX/gen.log")"
fi

# d. A non-doc commit after generation makes the doc stale: check fails with an
# annotation; regenerating fixes it.
stale_case d
h2=$(head_sha)
h1=$(git -C "$CASE" rev-parse HEAD~2)
check "$CASE" "$h2" "" 1
if [ "$CHECK_RC" -ne 0 ] && grep -q '::error' "$FX/check.log" && grep -q 'stale' "$FX/check.log"; then
  report "d. stale doc after a non-doc commit fails with ::error" 0
else
  report "d. stale doc after a non-doc commit fails with ::error" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
fx_pr "$h2" "$FX/body.md"
fx_runs 101 "$h1" success success 102 "$h2" success success
gen "$CASE"
commit_all "regenerated doc"
check "$CASE" "$(head_sha)"
if [ "$CHECK_RC" -eq 0 ]; then
  report "d2. regenerated doc passes after the change" 0
else
  report "d2. regenerated doc passes after the change" 1 "$(cat "$FX/gen.log") $(cat "$FX/check.log")"
fi

# f. A missing required PR section fails clearly.
new_case f
printf 'x\n' > "$CASE/notes.txt"
commit_all "a change"
cat > "$FX/body.md" <<'BODY'
## Why

Readers cannot see how a delivery was made.

## How

Generated.

## What

A generated doc.

## Assistance and third-party material

None.
BODY
fx_pr "$(head_sha)" "$FX/body.md"
fx_runs 101 "$(head_sha)" success success
fx_qodo_none
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "f. missing Limitations section fails" 1 "generator succeeded"
elif grep -qF "'## Limitations' section" "$FX/gen.log"; then
  report "f. missing Limitations section fails" 0
else
  report "f. missing Limitations section fails" 1 "$(cat "$FX/gen.log")"
fi

# h. Findings from an earlier Qodo body that the latest body no longer lists.
pr_case h home full
h1=$(head_sha)
review_body "$BASE" medium "u-old-1|Reruns can label newer pages as old|🐞 Bug" "u-keep-2|Delivery doc reports unverified results|📘 Rule violation" > "$FX/review-1.md"
review_body "$h1" medium "u-keep-2|Delivery doc reports unverified results|📘 Rule violation" > "$FX/review-2.md"
fx_qodo "$FX/review-2.md" 2026-11-05T15:59:06Z "$FX/review-1.md"
gen "$CASE"
doc="$CASE/$doc_name"
if grep -qF 'Reruns can label newer pages as old (Medium, 🐞 Bug). No longer listed by Qodo.' "$doc" \
  && grep -qF "Delivery doc reports unverified results (Medium, 📘 Rule violation). Open in Qodo's latest review." "$doc" \
  && grep -qF "Qodo reviewed these contents (by content digest)" "$doc"; then
  report "h. earlier findings are listed as no longer listed" 0
else
  report "h. earlier findings are listed as no longer listed" 1 "$(sed -n '/What I learned/,/Assistance/p' "$doc" 2>/dev/null || cat "$FX/gen.log")"
fi

# i. A screenshot over 500 KB fails the generator.
pr_case i home plain
SNAP_PAD=600000 gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "i. oversized screenshot fails" 1 "generator succeeded"
elif grep -qF '500 KB' "$FX/gen.log"; then
  report "i. oversized screenshot fails" 0
else
  report "i. oversized screenshot fails" 1 "$(cat "$FX/gen.log")"
fi

# j. The doc name must be new on the base branch.
new_case j
printf 'old\n' > "$CASE/$doc_name"
commit_all "a doc already on the base branch"
BASE=$(head_sha)
printf 'x\n' > "$CASE/notes.txt"
commit_all "a change"
body_plain > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
fx_runs 101 "$(head_sha)" success success
fx_qodo_none
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "j. doc name already on the base branch fails" 1 "generator succeeded"
elif grep -qF 'already exists on the base branch' "$FX/gen.log"; then
  report "j. doc name already on the base branch fails" 0
else
  report "j. doc name already on the base branch fails" 1 "$(cat "$FX/gen.log")"
fi

# k. No successful Check site run for this content: the generator refuses. A failed
# build is never accepted.
pr_case k other plain
fx_runs 101 "$(head_sha)" failure success
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "k. a build failure is rejected (no passing CI run)" 1 "generator succeeded"
elif grep -qF 'no completed Check site run' "$FX/gen.log"; then
  report "k. a build failure is rejected (no passing CI run)" 0
else
  report "k. a build failure is rejected (no passing CI run)" 1 "$(cat "$FX/gen.log")"
fi

# k2. No deadlock: a failing delivery-doc job is accepted and left out of the job list.
pr_case k2 other plain
fx_runs 101 "$(head_sha)" success failure
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'Jobs: build: success.' "$CASE/$doc_name" \
  && ! grep -qF 'delivery-doc' "$CASE/$doc_name"; then
  report "k2. delivery-doc failure is accepted and absent from the job list" 0
else
  report "k2. delivery-doc failure is accepted and absent from the job list" 1 "$(cat "$FX/gen.log")"
fi

# l. A homepage that loads a file the build does not have fails the generator.
pr_case l broken plain
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "l. a homepage loading a missing file fails" 1 "generator succeeded"
elif grep -qF 'is missing' "$FX/gen.log"; then
  report "l. a homepage loading a missing file fails" 0
else
  report "l. a homepage loading a missing file fails" 1 "$(cat "$FX/gen.log")"
fi

# m. Qodo's comment list and edit history are paged (two pages each). The newest Qodo
# comment is on the second comment page, and the oldest body, whose finding is no longer
# listed, is on the second edit page. Both must be read.
pr_case m home full
h1=$(head_sha)
review_body "$BASE" medium 'u-old-1|Reruns can label	newer pages as old|🐞 Bug' > "$FX/review-old.md"
review_body "$h1" medium 'u-keep-2|Delivery doc reports unverified results|📘 Rule violation' > "$FX/review-new.md"
jq -n --rawfile old "$FX/review-old.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: true, endCursor: "C1"},
  nodes: [{id: "IC_old", createdAt: "2026-11-05T15:50:27Z", author: {login: "qodo-code-review"}, body: $old}]}}}}}' \
  > "$FX/comments-null.json"
jq -n --rawfile new "$FX/review-new.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [
    {id: "IC_qodo", createdAt: "2026-11-05T16:10:00Z", author: {login: "qodo-code-review"}, body: $new},
    {id: "IC_human", createdAt: "2026-11-05T16:11:00Z", author: {login: "someone"}, body: "a human comment"}]}}}}}' \
  > "$FX/comments-C1.json"
jq -n --rawfile new "$FX/review-new.md" '{data: {node: {userContentEdits: {
  pageInfo: {hasNextPage: true, endCursor: "E1"},
  nodes: [{editedAt: "2026-11-05T16:00:00Z", diff: $new}]}}}}' > "$FX/edits-IC_qodo-first.json"
jq -n --rawfile old "$FX/review-old.md" '{data: {node: {userContentEdits: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{editedAt: "2026-11-05T15:50:00Z", diff: $old}]}}}}' > "$FX/edits-IC_qodo-E1.json"
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  doc="$CASE/$doc_name"
  if grep -qF 'Reruns can label newer pages as old (Medium, ' "$doc" \
    && grep -qF '). No longer listed by Qodo.' "$doc" \
    && grep -qF 'Delivery doc reports unverified results (Medium, ' "$doc" \
    && ! grep -qF "$(printf '\t')" "$doc"; then
    report "m. paged Qodo history: the oldest version is read, tabs stripped" 0
  else
    report "m. paged Qodo history: the oldest version is read, tabs stripped" 1 "$(sed -n '/What I learned/,/Assistance/p' "$doc")"
  fi
else
  report "m. paged Qodo history: the oldest version is read, tabs stripped" 1 "$(cat "$FX/gen.log")"
fi

# p. A hostile comment id is refused before any gh call uses it, so gh never receives
# it (gh -F would read a value starting with "@" as a file).
pr_case p other plain
jq -n '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{id: "@/etc/passwd", createdAt: "2026-11-05T16:10:00Z", author: {login: "qodo-code-review"},
    body: "<h3>Code Review by Qodo</h3>"}]}}}}}' > "$FX/comments-null.json"
gen "$CASE"
if [ "$GEN_RC" -eq 0 ]; then
  report "p. a hostile comment id is refused, and gh never receives it" 1 "generator succeeded"
elif grep -qF 'not an id' "$FX/gen.log" && ! grep -qF 'etc/passwd' "$FX/gh-calls.log" 2>/dev/null; then
  report "p. a hostile comment id is refused, and gh never receives it" 0
else
  report "p. a hostile comment id is refused, and gh never receives it" 1 "$(cat "$FX/gen.log")"
fi

# r. More than one Qodo review comment: the one with the latest createdAt is read.
pr_case r other plain
h1=$(head_sha)
review_body "$BASE" medium 'u-old-1|Reruns can label newer pages as old|🐞 Bug' > "$FX/review-old.md"
review_body "$h1" medium 'u-new-1|Delivery doc reports unverified results|📘 Rule violation' > "$FX/review-new.md"
jq -n --rawfile old "$FX/review-old.md" --rawfile new "$FX/review-new.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [
    {id: "IC_old", createdAt: "2026-11-05T15:50:27Z", author: {login: "qodo-code-review"}, body: $old},
    {id: "IC_new", createdAt: "2026-11-05T16:10:00Z", author: {login: "qodo-code-review"}, body: $new}
  ]}}}}}' > "$FX/comments-null.json"
jq -n '{data: {node: {userContentEdits: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}}' \
  > "$FX/edits-IC_new-first.json"
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'Delivery doc reports unverified results (Medium, ' "$CASE/$doc_name" \
  && ! grep -qF 'Reruns can label' "$CASE/$doc_name"; then
  report "r. several Qodo comments: the latest by createdAt is read" 0
else
  report "r. several Qodo comments: the latest by createdAt is read" 1 "$(cat "$FX/gen.log")"
fi

# fp. Fixed point (AGENTS.md rule 6): an amend that adds the doc gives a new head with
# the same content digest. A Qodo re-review on the new head, with an edit that shows
# the earlier body, leaves the doc unchanged; the new head's short SHA appears nowhere
# in it and CI run 101 (the earlier head) is still the cited run.
pr_case fp home full
s1=$(head_sha)
review_body "$s1" medium 'u-keep-2|Delivery doc reports unverified results|📘 Rule violation' > "$FX/review-s1.md"
fx_qodo "$FX/review-s1.md"
gen "$CASE"
fp_gen_rc=$GEN_RC
git -C "$CASE" add -A
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q --amend --no-edit
s2=$(head_sha)
review_body "$s2" medium 'u-keep-2|Delivery doc reports unverified results|📘 Rule violation' > "$FX/review-s2.md"
fx_pr "$s2" "$FX/body.md"
fx_runs 101 "$s1" success success 102 "$s2" success success
fx_qodo "$FX/review-s2.md" 2026-11-05T15:59:06Z "$FX/review-s1.md"
gen "$CASE" --check
if [ "$fp_gen_rc" -eq 0 ] && [ "$s1" != "$s2" ] && [ "$GEN_RC" -eq 0 ] && grep -q 'is current' "$FX/gen.log" \
  && ! grep -qF "${s2:0:7}" "$CASE/$doc_name" && grep -qF "[run 101]" "$CASE/$doc_name"; then
  report "fp. fixed point: amend and Qodo re-review leave the doc current; run 101 cited" 0
else
  report "fp. fixed point: amend and Qodo re-review leave the doc current; run 101 cited" 1 "$(cat "$FX/gen.log")"
fi

# trl. The "Generated with" trailer is removed wherever it ends the PR description: after
# Hackathon, after Limitations, with CRLF line endings. A copy inside the text stays.
trl_fail=""
pr_case trl home full
{ body_full | sed '/^## Qodo notes/,$d'; printf '\n%s\n' "$trailer"; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] || grep -qF 'Generated with' "$CASE/$doc_name" || ! grep -qF 'Only the homepage is captured.' "$CASE/$doc_name"; then
  trl_fail="$trl_fail after-hackathon"
fi
{ body_plain; printf '\n%s\n' "$trailer"; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] || grep -qF 'Generated with' "$CASE/$doc_name"; then
  trl_fail="$trl_fail after-limitations"
fi
{ body_plain; printf '\n%s\n' "$trailer"; } | sed 's/$/\r/' > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] || grep -qF 'Generated with' "$CASE/$doc_name" || ! grep -qF 'None known.' "$CASE/$doc_name"; then
  trl_fail="$trl_fail crlf"
fi
{ printf '## Why\n\nA plain PR. %s\n\n' "$trailer"; body_plain | sed '1,3d'; printf '\n%s\n' "$trailer"; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] || [ "$(grep -c 'Generated with' "$CASE/$doc_name")" -ne 1 ]; then
  trl_fail="$trl_fail mid-body-copy"
fi
prefixed='Made it. Generated with [Claude Code](https://x.y)'
{ body_plain; printf '\n%s\n' "$prefixed"; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] || ! grep -qF "$prefixed" "$CASE/$doc_name"; then
  trl_fail="$trl_fail prefixed-line-removed"
fi
if [ -z "$trl_fail" ]; then
  report "trl. the trailer is removed after Hackathon, after Limitations and with CRLF; a mid-body copy stays" 0
else
  report "trl. the trailer is removed after Hackathon, after Limitations and with CRLF; a mid-body copy stays" 1 "failed:$trl_fail"
fi

# spc. Inside the discussion post, exactly one blank line precedes every "## " heading
# except the first.
pr_case spc home full
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && post_spacing_ok "$CASE/$doc_name"; then
  report "spc. one blank line before every heading in the discussion post" 0
else
  # shellcheck disable=SC2016 # sed program, not the shell
  report "spc. one blank line before every heading in the discussion post" 1 "$(sed -n '/````markdown/,/^````$/p' "$CASE/$doc_name" | cat -A | head -n 60)"
fi

# own. Only the PR's own doc is read: a stale sibling doc and a merged doc with no
# metadata, both in the tree when the doc is generated, leave the check green.
new_case own
printf 'old\n' > "$CASE/deliveries/2026-10-01-old.md"
printf 'stale\n<!-- delivery: content=%040d homepage=%040d -->\n' 0 0 > "$CASE/deliveries/2026-10-02-stale.md"
printf 'notes\n' > "$CASE/notes.txt"
commit_all "a change off the homepage, with two other docs"
body_plain > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
fx_runs 101 "$(head_sha)" success success
fx_qodo_none
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "$(head_sha)"
if [ "$GEN_RC" -eq 0 ] && [ "$CHECK_RC" -eq 0 ]; then
  report "own. only the PR's own doc is read: sibling docs do not fail the check" 0
else
  report "own. only the PR's own doc is read: sibling docs do not fail the check" 1 "$(cat "$FX/gen.log") $(cat "$FX/check.log")"
fi

# missing. No doc: the check warns and passes (GITHUB_ACTIONS annotates the warning).
pr_case missing other plain
commit_all "a commit with no doc"
check "$CASE" "$(head_sha)" "" 1
if [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log"; then
  report "missing. no doc: a ::warning and a pass" 0
else
  report "missing. no doc: a ::warning and a pass" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# meta, unk. A doc without metadata, and a HEAD_SHA that is not in the clone, both fail.
stale_case meta
gen "$CASE"
grep -v '^<!-- delivery: ' "$CASE/$doc_name" > "$FX/nometa.md"
cp "$FX/nometa.md" "$CASE/$doc_name"
commit_all "a doc without metadata"
check "$CASE" "$(head_sha)"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'no delivery metadata' "$FX/check.log"; then
  report "meta. a doc without metadata fails" 0
else
  report "meta. a doc without metadata fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
check "$CASE" "1111111111111111111111111111111111111111"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'not a commit' "$FX/check.log"; then
  report "unk. an unknown HEAD_SHA fails" 0
else
  report "unk. an unknown HEAD_SHA fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# hk. An empty "## Hackathon" heading (the PR template ships one) is treated as absent: no
# discussion post, no error. A non-empty section without a Day link still fails.
pr_case hk other plain
{ body_plain; printf '\n## Hackathon\n\n## Qodo notes\n\n'; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
# shellcheck disable=SC2016 # the backticks are Markdown
if [ "$GEN_RC" -eq 0 ] && grep -qF 'has no `## Hackathon` section' "$CASE/$doc_name"; then
  hk_empty=ok
else
  hk_empty="$(cat "$FX/gen.log")"
fi
{ body_plain; printf '\n## Hackathon\n\nDay 3, no link here.\n'; } > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$hk_empty" = ok ] && [ "$GEN_RC" -ne 0 ] && grep -qF 'must link the Day N discussion' "$FX/gen.log"; then
  report "hk. an empty Hackathon heading is absent; a non-empty one without a link fails" 0
else
  report "hk. an empty Hackathon heading is absent; a non-empty one without a link fails" 1 "empty: $hk_empty; gen rc $GEN_RC: $(cat "$FX/gen.log")"
fi

# au. Only the Qodo bot's comments count: a newer comment by a person that quotes the
# review heading is ignored.
pr_case au home plain
h1=$(head_sha)
review_body "$h1" medium 'u-bot-1|Bot finding stays|📘 Rule violation' > "$FX/review-bot.md"
review_body "$h1" medium 'u-human-1|Human quote is not Qodo|🐞 Bug' > "$FX/review-human.md"
jq -n --rawfile bot "$FX/review-bot.md" --rawfile human "$FX/review-human.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [
    {id: "IC_qodo", createdAt: "2026-11-05T15:50:27Z", author: {login: "qodo-code-review"}, body: $bot},
    {id: "IC_human", createdAt: "2026-11-05T16:10:00Z", author: {login: "someone"}, body: $human}
  ]}}}}}' > "$FX/comments-null.json"
jq -n '{data: {node: {userContentEdits: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}}' \
  > "$FX/edits-IC_qodo-first.json"
jq -n '{data: {node: {userContentEdits: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}}' \
  > "$FX/edits-IC_human-first.json"
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'Bot finding stays' "$CASE/$doc_name" && ! grep -qF 'Human quote' "$CASE/$doc_name"; then
  report "au. a newer comment by a person is not Qodo's review" 0
else
  report "au. a newer comment by a person is not Qodo's review" 1 "$(cat "$FX/gen.log")"
fi

# om. The metadata line of an earlier doc (content, homepage, changed, base) still gives
# the recorded homepage: regenerating an unchanged homepage needs no new screenshot.
pr_case om home full
gen "$CASE"
read -r om_d om_h <<< "$(sed -nE 's/^<!-- delivery: content=([0-9a-f]{40}) homepage=([0-9a-f]{40}) -->$/\1 \2/p' "$CASE/$doc_name")"
grep -v '^<!-- delivery: ' "$CASE/$doc_name" > "$FX/om.md"
printf '<!-- delivery: content=%s homepage=%s changed=yes base=%s -->\n' "$om_d" "$om_h" "$BASE" >> "$FX/om.md"
cp "$FX/om.md" "$CASE/$doc_name"
SNAP_CMD=/usr/bin/false
gen "$CASE"
unset SNAP_CMD
if [ "$GEN_RC" -eq 0 ] && [ -n "$om_h" ]; then
  report "om. an earlier doc's metadata line (changed=, base=) still records the homepage" 0
else
  report "om. an earlier doc's metadata line (changed=, base=) still records the homepage" 1 "$(cat "$FX/gen.log")"
fi

# cut. The window is exclusive at 2026-12-12T23:00:00Z: a stale doc passes once it has
# ended and fails one second before.
stale_case cut
h=$(head_sha)
check "$CASE" "$h" 2026-12-12T23:00:00Z
if [ "$CHECK_RC" -eq 0 ] && grep -q 'ended' "$FX/check.log"; then
  report "cut. at 23:00:00Z the check passes without reading the doc" 0
else
  report "cut. at 23:00:00Z the check passes without reading the doc" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
check "$CASE" "$h" 2026-12-12T22:59:59Z
if [ "$CHECK_RC" -ne 0 ] && grep -q 'stale' "$FX/check.log"; then
  report "cut. at 22:59:59Z the stale doc fails" 0
else
  report "cut. at 22:59:59Z the stale doc fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
win "$CASE" 2026-12-12T22:59:59Z
w1=$WIN_RC
win "$CASE" 2026-12-12T23:00:00Z
w2=$WIN_RC
if [ "$w1" -eq 0 ] && [ "$w2" -eq 3 ]; then
  report "cut. --window exits 0 open, 3 ended" 0
else
  report "cut. --window exits 0 open, 3 ended" 1 "22:59:59 gave $w1, 23:00:00 gave $w2"
fi

clock=$tmp/clock
mkdir -p "$clock"
printf '#!/bin/sh\necho 2026-12-12T23:00:00Z\n' > "$clock/date"
chmod +x "$clock/date"
clock_rc=0
(cd "$CASE" && env -u NOW PATH="$clock:$PATH" bash scripts/check-delivery.sh --window >/dev/null 2>&1) || clock_rc=$?
if [ "$clock_rc" -eq 3 ]; then
  report "cut. with NOW unset, the clock (date) at 23:00:00Z ends the window" 0
else
  report "cut. with NOW unset, the clock (date) at 23:00:00Z ends the window" 1 "exit $clock_rc"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed (awk: $awk_bin)" >&2
  exit 1
fi
echo "all cases passed (awk: $awk_bin)"
