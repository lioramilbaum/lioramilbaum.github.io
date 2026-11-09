#!/usr/bin/env bash
# Tests for the delivery-doc tooling (AGENTS.md rule 6): generate-delivery.sh, the
# check in check-delivery.sh, and qodo-status.sh (AGENTS.md rule 9). Offline by default:
# no Docker and no network. Each case
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
# A file named gh-fail-<command>-<subcommand> makes that call fail (qodo-status cases).
if [ -e "$GH_FIXTURES/gh-fail-$1-$2" ]; then echo "gh: simulated failure" >&2; exit 1; fi
case "$1 $2" in
  "pr view") fixture=$GH_FIXTURES/pr.json ;;
  "run list") fixture=$GH_FIXTURES/runs.json ;;
  "run view") fixture=$GH_FIXTURES/run-$3.json ;;
  "api repos/"*"/pulls/"*)
    if [ -e "$GH_FIXTURES/gh-fail-pulls" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    fixture=$GH_FIXTURES/pull.json ;;
  "api repos/"*"/statuses/"*)
    if [ -e "$GH_FIXTURES/gh-fail-status" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    fixture=$GH_FIXTURES/status-reply.json ;;
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
# date: the gate cases' clock. A case that sets $GH_FIXTURES/clock gets that time; any other call
# gets the real date. nap: the gate's wait (QODO_GATE_SLEEP): it logs the wait and, if the case set
# $GH_FIXTURES/clock-next, moves the clock there.
cat > "$bin/date" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GH_FIXTURES:-}" ] && [ -e "$GH_FIXTURES/clock" ]; then cat "$GH_FIXTURES/clock"; else exec /bin/date "$@"; fi
STUB
cat > "$bin/nap" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_FIXTURES/naps.log"
if [ -e "$GH_FIXTURES/clock-next" ]; then cp "$GH_FIXTURES/clock-next" "$GH_FIXTURES/clock"; fi
STUB
chmod +x "$bin/gh" "$bin/build-site" "$bin/snapshot" "$bin/date" "$bin/nap"

# Helpers ---------------------------------------------------------------------

# new_case NAME: a repo with the real delivery scripts and template, a base
# homepage, and a fixture directory (outside the repo) for the gh stub.
new_case() {
  CASE="$tmp/$1"
  FX="$tmp/$1-fx"
  mkdir -p "$CASE/scripts" "$CASE/deliveries" "$CASE/site-src/assets/images" "$FX"
  cp "$root/scripts/generate-delivery.sh" "$root/scripts/check-delivery.sh" "$root/scripts/qodo-review.awk" "$CASE/scripts/"
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

# drop_from_clone CASE: expires the reflogs and prunes unreachable objects, so a commit that no
# branch reaches is gone from the clone (as a commit a PR force-pushed over is).
drop_from_clone() {
  git -C "$1" reflog expire --expire=now --all
  git -C "$1" gc -q --prune=now
}

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

# fx_pr HEAD_SHA BODY_FILE: the PR as gh would report it, merged (PR_STATE overrides).
# mergedAt is 2026-11-06 unless PR_MERGED_AT is set (empty gives null): after every fixture run.
fx_pr() {
  jq -n --arg head "$1" --arg base "$BASE" --arg state "${PR_STATE:-MERGED}" --rawfile body "$2" \
    --arg merged "${PR_MERGED_AT-2026-11-06T00:00:00Z}" '{
    state: $state,
    title: "Demo change",
    createdAt: "2026-11-05T09:00:00Z",
    mergedAt: (if $merged == "" then null else $merged end),
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

# review_clear SHA: a Qodo review with no open findings, in the layout of PR #34's final body.
review_clear() {
  printf '<h3>Code Review by Qodo</h3>\n\n<br/>\n\n'
  printf '<img src="https://img.shields.io/badge/High-634FD1?style=flat-square" height="20px" alt="Action required">\n\n_Nice, no open findings for this group_\n\n<br/>\n\n'
  printf '<img src="https://img.shields.io/badge/Medium-634FD1?style=flat-square" height="20px" alt="Remediation recommended">\n\n_Nice, no open findings for this group_\n\n<br/>\n\n'
  printf '<img src="https://img.shields.io/badge/Low-634FD1?style=flat-square" height="20px" alt="Informational">\n\n_Nice, no open findings for this group_\n\n<br/>\n\n'
  printf '<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$1"
}

# review_great SHA: a Qodo review with no findings, in the "Great, no issues found!" layout
# (PR #35's body).
review_great() {
  printf '<h3>Code Review by Qodo</h3>\n<code>🐞 Bugs (0)</code>  <code>📘 Rule violations (0)</code>  <code>📎 Requirement gaps (0)</code>\n\n<br/>\n\n'
  printf '<h3>Great, no issues found!</h3>\nQodo reviewed your code and found no material issues that require review\n\n<br/>\n\n'
  printf '<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$1"
}

# review_groups SHA HIGH MEDIUM LOW: a Qodo review with one badge group per severity, in PR #34's
# layout. Each state is nice (the clear line), open (no clear line, no finding) or finding (a block
# with no "<summary> N." line, so no parse reads it).
review_groups() {
  local sha=$1 sev state
  shift
  printf '<h3>Code Review by Qodo</h3>\n\n<br/>\n\n'
  for sev in High Medium Low; do
    state=$1
    shift
    printf '<img src="https://img.shields.io/badge/%s-634FD1?style=flat-square" height="20px" alt="Severity">\n\n' "$sev"
    case "$state" in
      nice) printf '_Nice, no open findings for this group_\n\n' ;;
      finding) printf '<details><summary>Unparsed finding</summary>\n\nA finding in markup this parse does not read.\n\n</details>\n\n' ;;
    esac
    printf '<br/>\n\n'
  done
  printf '<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$sha"
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
      {id: "IC_qodo", url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_qodo",
        createdAt: "2026-11-05T15:50:27Z", lastEditedAt: null, author: {login: "qodo-code-review"}, body: $body},
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

# fx_qodo_clear SHA: Qodo's latest review of SHA lists no open findings.
fx_qodo_clear() {
  review_clear "$1" > "$FX/review-clear.md"
  fx_qodo "$FX/review-clear.md"
}

# fx_qodo_pair BODY_A AT_A BODY_B AT_B: two Qodo comments on one page, A listed first (ids
# IC_a and IC_b), each created at its AT and never edited.
fx_qodo_pair() {
  jq -n --rawfile a "$1" --arg ta "$2" --rawfile b "$3" --arg tb "$4" '{data: {repository: {pullRequest: {comments: {
    pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [
      {id: "IC_a", url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_a",
        createdAt: $ta, lastEditedAt: null, author: {login: "qodo-code-review"}, body: $a},
      {id: "IC_b", url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_b",
        createdAt: $tb, lastEditedAt: null, author: {login: "qodo-code-review"}, body: $b}
    ]}}}}}' > "$FX/comments-null.json"
}

# fx_qodo_edited_at AT: the fixture's Qodo comment was last edited at AT (lastEditedAt).
fx_qodo_edited_at() {
  jq --arg at "$1" '(.data.repository.pullRequest.comments.nodes[] | select(.id == "IC_qodo") | .lastEditedAt) = $at' \
    "$FX/comments-null.json" > "$FX/comments-edited.json"
  mv "$FX/comments-edited.json" "$FX/comments-null.json"
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

# stale_case NAME: a docs commit whose doc names a merged head with other content: the doc
# was generated for the PR head, then its head= was pointed at the base commit.
stale_case() {
  pr_case "$1" other plain
  gen "$CASE"
  sed -E "s/ head=[0-9a-f]{40} / head=$BASE /" "$CASE/$doc_name" > "$FX/stale.md"
  cp "$FX/stale.md" "$CASE/$doc_name"
  commit_all "a docs commit with a stale doc"
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

# check CASE [NOW] [GITHUB_ACTIONS]: runs check-delivery.sh in CASE as CI runs it on a PR:
# HEAD is the PR and HEAD^1 its base. CHECK_BASE, if set, is passed as BASE_SHA. Sets
# CHECK_RC to its status.
check() {
  CHECK_RC=0
  (cd "$1" && unset BASE_SHA && if [ -n "${CHECK_BASE:-}" ]; then export BASE_SHA=$CHECK_BASE; fi \
    && NOW="${2:-$NOW}" GITHUB_ACTIONS="${3:-}" bash scripts/check-delivery.sh) > "$FX/check.log" 2>&1 || CHECK_RC=$?
  return 0
}

# win CASE NOW: runs check-delivery.sh --window at NOW. Sets WIN_RC.
win() {
  WIN_RC=0
  (cd "$1" && NOW="$2" bash scripts/check-delivery.sh --window) > /dev/null 2>&1 || WIN_RC=$?
  return 0
}

# qs_setup: copies qodo-status.sh into the case. If the script is missing, the copy fails
# quietly and the case fails when it runs the script.
qs_setup() { cp "$root/scripts/qodo-status.sh" "$CASE/scripts/" 2>/dev/null || true; }

# qstat CASE NOW [ARGS]: runs scripts/qodo-status.sh in CASE with the stubs, the clock at
# NOW. Sets QSTAT_RC; stdout goes to $FX/qs.out and stderr to $FX/qs.err.
qstat() {
  local c=$1 now=$2
  shift 2
  QSTAT_RC=0
  (cd "$c" && PATH="$bin:$PATH" GH_FIXTURES="$FX" QODO_STATUS_NOW="$now" bash scripts/qodo-status.sh "$@") \
    > "$FX/qs.out" 2> "$FX/qs.err" || QSTAT_RC=$?
  return 0
}

# qstat_is TEXT: the last qstat's stdout is exactly TEXT.
qstat_is() { [ "$(cat "$FX/qs.out")" = "$1" ]; }

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
fx_qodo_clear "$(head_sha)"
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

# a2. Digest agreement: the generated doc, committed alone as a docs PR, passes the check,
# and its metadata names the merged head.
a2_head=$(head_sha)
commit_all "delivery doc"
check "$CASE"
if [ "$CHECK_RC" -eq 0 ] && grep -q 'ok (content' "$FX/check.log" \
  && grep -qF "merged head $a2_head" "$FX/check.log" && grep -qF " head=$a2_head " "$CASE/$doc_name"; then
  report "a2. digest agreement: check passes the generated doc, which names the merged head" 0
else
  report "a2. digest agreement: check passes the generated doc, which names the merged head" 1 "$(cat "$FX/check.log")"
fi

# b. Unchanged homepage: no screenshot, the "no visible change" line, and no PNG dir.
pr_case b other plain
fx_qodo_clear "$(head_sha)"
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
check "$CASE"
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

# d. A doc whose merged head has other content is stale: check fails with an annotation;
# regenerating from the merged PR fixes it.
stale_case d
check "$CASE" "" 1
if [ "$CHECK_RC" -ne 0 ] && grep -q '::error' "$FX/check.log" && grep -q 'stale' "$FX/check.log"; then
  report "d. a doc whose merged head has other content fails with ::error" 0
else
  report "d. a doc whose merged head has other content fails with ::error" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
fx_qodo_clear "$(git -C "$CASE" rev-parse HEAD^1)"
gen "$CASE"
commit_all "regenerated doc"
check "$CASE"
if [ "$CHECK_RC" -eq 0 ]; then
  report "d2. the doc regenerated from the merged PR passes" 0
else
  report "d2. the doc regenerated from the merged PR passes" 1 "$(cat "$FX/gen.log") $(cat "$FX/check.log")"
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

# fin. The final CI run (AGENTS.md rule 6): two passing Check site runs on the merged head's
# content; the doc cites the later one (102), not the earlier (101). A later failing run (103)
# is not cited. --check then finds the doc current.
pr_case fin home full
fx_runs 101 "$(head_sha)" success success 102 "$(head_sha)" success success 103 "$(head_sha)" failure success
fx_qodo_clear "$(head_sha)"
gen "$CASE"
fin_gen_rc=$GEN_RC
gen "$CASE" --check
if [ "$fin_gen_rc" -eq 0 ] && [ "$GEN_RC" -eq 0 ] && grep -q 'is current' "$FX/gen.log" \
  && grep -qF "[run 102]" "$CASE/$doc_name" && ! grep -qF "[run 101]" "$CASE/$doc_name" \
  && ! grep -qF "[run 103]" "$CASE/$doc_name"; then
  report "fin. the latest passing CI run on the merged content is cited" 0
else
  report "fin. the latest passing CI run on the merged content is cited" 1 "$(cat "$FX/gen.log")"
fi

# fet. A Check site run whose commit is not in the clone is fetched by SHA from --fetch's remote and
# cited. Run 102's commit G (the head's content, pushed to the remote under refs/pull/24/head and
# pruned from the clone) is fetched, so the doc cites 102. --fetch with no value is a usage error.
pr_case fet other plain
fet_h=$(head_sha)
fet_g=$(git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit-tree "$fet_h^{tree}" -p "$BASE" -m same-content)
fet_remote=$tmp/fet-remote.git
git init -q --bare "$fet_remote"
git -C "$fet_remote" config uploadpack.allowAnySHA1InWant true
git -C "$CASE" push -q "file://$fet_remote" "$fet_g:refs/pull/24/head"
drop_from_clone "$CASE"
fet_gone=no
if ! git -C "$CASE" cat-file -e "$fet_g^{commit}" 2>/dev/null; then fet_gone=yes; fi
fx_runs 101 "$fet_h" success success 102 "$fet_g" success success
fx_qodo_clear "$fet_h"
gen "$CASE" --fetch "file://$fet_remote"
fet_a_rc=$GEN_RC; fet_a_log=$(cat "$FX/gen.log"); fet_a_ok=no
if [ "$fet_a_rc" -eq 0 ] && grep -qF "[run 102]" "$CASE/$doc_name" && ! grep -qF "[run 101]" "$CASE/$doc_name"; then
  fet_a_ok=yes
fi
gen "$CASE" --fetch
fet_b_rc=$GEN_RC
if [ "$fet_gone" = yes ] && [ "$fet_a_ok" = yes ] && [ "$fet_b_rc" -eq 1 ] && grep -qF 'usage:' "$FX/gen.log"; then
  report "fet. a run's commit missing from the clone is fetched by SHA and cited; --fetch with no value is usage" 0
else
  report "fet. a run's commit missing from the clone is fetched by SHA and cited; --fetch with no value is usage" 1 "pruned $fet_gone; a rc $fet_a_rc: $fet_a_log; b rc $fet_b_rc: $(cat "$FX/gen.log")"
fi

# fet2. A Check site run whose commit is missing and cannot be fetched. An older one is skipped and
# the newer run is cited (102). A newer one stops the generator: it could be the final run, so no
# doc is written.
pr_case fet2 other plain
fet2_h=$(head_sha)
fet2_g=$(git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit-tree "$fet2_h^{tree}" -p "$BASE" -m same-content)
drop_from_clone "$CASE"
fet2_remote=$tmp/fet2-remote.git
git init -q --bare "$fet2_remote"
fx_qodo_clear "$fet2_h"
fx_runs 101 "$fet2_g" success success 102 "$fet2_h" success success
gen "$CASE" --fetch "file://$fet2_remote"
fet2_a_rc=$GEN_RC; fet2_a_ok=no
if [ "$fet2_a_rc" -eq 0 ] && grep -qF "[run 102]" "$CASE/$doc_name"; then fet2_a_ok=yes; fi
rm -f "$CASE/$doc_name"
fx_runs 101 "$fet2_h" success success 102 "$fet2_g" success success
gen "$CASE" --fetch "file://$fet2_remote"
if [ "$fet2_a_ok" = yes ] && [ "$GEN_RC" -ne 0 ] && grep -qF 'could not be fetched' "$FX/gen.log" && [ ! -e "$CASE/$doc_name" ]; then
  report "fet2. an unfetchable run older than the cited one is skipped; a newer one stops the generator" 0
else
  report "fet2. an unfetchable run older than the cited one is skipped; a newer one stops the generator" 1 "a rc $fet2_a_rc ok $fet2_a_ok; b rc $GEN_RC: $(cat "$FX/gen.log")"
fi

# reu. A Check site run created after the PR merged belongs to a later PR on a reused branch, so
# it is ignored. Run 101 (created before the merge) and run 102 (after it, on the same content)
# both pass: the doc cites 101. Then run 102 is on a commit the clone lacks and no remote has:
# it does not stop the generator, and the doc still cites 101.
pr_case reu other plain
reu_h=$(head_sha)
reu_g=$(git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit-tree "$reu_h^{tree}" -p "$BASE" -m same-content)
PR_MERGED_AT=2026-11-05T10:30:00Z fx_pr "$reu_h" "$FX/body.md"
fx_qodo_clear "$reu_h"
fx_runs 101 "$reu_h" success success 102 "$reu_g" success success
gen "$CASE"
reu_a_rc=$GEN_RC; reu_a_log=$(cat "$FX/gen.log"); reu_a_ok=no
if [ "$reu_a_rc" -eq 0 ] && grep -qF "[run 101]" "$CASE/$doc_name" && ! grep -qF "[run 102]" "$CASE/$doc_name"; then
  reu_a_ok=yes
fi
rm -f "$CASE/$doc_name"
drop_from_clone "$CASE"
fx_runs 101 "$reu_h" success success 102 "$reu_g" success success
gen "$CASE" --fetch "file://$tmp/reu-missing.git"
reu_b_rc=$GEN_RC; reu_b_ok=no
if [ "$reu_b_rc" -eq 0 ] && grep -qF "[run 101]" "$CASE/$doc_name" && ! grep -qF "[run 102]" "$CASE/$doc_name"; then
  reu_b_ok=yes
fi
if [ "$reu_a_ok" = yes ] && [ "$reu_b_ok" = yes ]; then
  report "reu. a run created after the merge is not cited, and an unfetchable one does not stop the generator" 0
else
  report "reu. a run created after the merge is not cited, and an unfetchable one does not stop the generator" 1 "a rc $reu_a_rc: $reu_a_log; b rc $reu_b_rc: $(cat "$FX/gen.log")"
fi

# mrg. A PR whose mergedAt is missing (null) is refused: the generator cannot tell which runs
# came before the merge. No doc is written.
pr_case mrg other plain
PR_MERGED_AT='' fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] && grep -qF 'no usable mergedAt' "$FX/gen.log" && [ ! -e "$CASE/$doc_name" ]; then
  report "mrg. a PR with no mergedAt is refused" 0
else
  report "mrg. a PR with no mergedAt is refused" 1 "rc $GEN_RC: $(cat "$FX/gen.log")"
fi

# opn. A PR that has not merged is refused: its doc is generated after the merge, and no doc
# is written.
pr_case opn other plain
PR_STATE=OPEN fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
if [ "$GEN_RC" -ne 0 ] && grep -qF 'is OPEN, not merged' "$FX/gen.log" && [ ! -e "$CASE/$doc_name" ]; then
  report "opn. an open PR is refused and no doc is written" 0
else
  report "opn. an open PR is refused and no doc is written" 1 "rc $GEN_RC: $(cat "$FX/gen.log")"
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

# qo1. Qodo's latest review of the head lists one finding: the doc records 1, the generator
# says so, and the docs check passes with a ::warning: qodo-open is evidence of Qodo's final
# review, and the qodo-findings status was the merge gate (AGENTS.md rule 9).
pr_case qo1 home plain
h1=$(head_sha)
review_body "$h1" medium 'u-open-1|Doc omits the Qodo state|📘 Rule violation' > "$FX/review-open.md"
fx_qodo "$FX/review-open.md"
gen "$CASE"
qo1_gen=ok
if [ "$GEN_RC" -ne 0 ] || ! grep -qF 'qodo-open=1 -->' "$CASE/$doc_name" \
  || ! grep -qF "Open findings in Qodo's latest review: 1." "$CASE/$doc_name"; then
  qo1_gen="$(cat "$FX/gen.log")"
fi
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$qo1_gen" = ok ] && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'open finding' "$FX/check.log" \
  && ! grep -q '::error' "$FX/check.log"; then
  report "qo1. one open Qodo finding: the doc records 1 and check passes with a ::warning" 0
else
  report "qo1. one open Qodo finding: the doc records 1 and check passes with a ::warning" 1 "gen: $qo1_gen; rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# qo0. An earlier Qodo body had a finding that the latest review no longer lists, and the
# latest review of the head is clear: the doc records 0 and the check passes.
pr_case qo0 other plain
h1=$(head_sha)
review_body "$BASE" medium 'u-old-2|Earlier finding is gone|🐞 Bug' > "$FX/review-old.md"
review_clear "$h1" > "$FX/review-clear.md"
fx_qodo "$FX/review-clear.md" 2026-11-05T15:59:06Z "$FX/review-old.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=0 -->' "$CASE/$doc_name" \
  && grep -qF "Open findings in Qodo's latest review: 0." "$CASE/$doc_name" \
  && grep -qF 'No longer listed by Qodo.' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q 'no open Qodo findings' "$FX/check.log"; then
  report "qo0. an earlier finding no longer listed: the doc records 0 and check passes" 0
else
  report "qo0. an earlier finding no longer listed: the doc records 0 and check passes" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qoc. Qodo's only review of the head is the "Great, no issues found!" layout: no findings,
# so the doc records 0 through the no-findings branch and the check passes.
pr_case qoc other plain
review_great "$(head_sha)" > "$FX/review-great.md"
fx_qodo "$FX/review-great.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=0 -->' "$CASE/$doc_name" \
  && grep -qF "Qodo's latest review lists no findings." "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ]; then
  report "qoc. a clear 'Great, no issues found!' review: the doc records 0 and check passes" 0
else
  report "qoc. a clear 'Great, no issues found!' review: the doc records 0 and check passes" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qou. Qodo's latest review of the head lists no findings, in a layout the generator does not know
# and with no clear phrase: the doc records unknown and says the review could not be read, and the
# docs check passes with a ::warning (AGENTS.md rule 9). No finding is counted as zero here.
pr_case qou other plain
h1=$(head_sha)
printf '<h3>Code Review by Qodo</h3>\n\n<p>Qodo finished a pass on this change.</p>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$h1" > "$FX/review-unknown.md"
fx_qodo "$FX/review-unknown.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=unknown -->' "$CASE/$doc_name" \
  && grep -qF "could not be read: it has no finding the generator can parse" "$CASE/$doc_name" \
  && ! grep -qF "lists no findings." "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'could not be read' "$FX/check.log"; then
  report "qou. a clear-less review with no known finding layout: the doc records unknown and check warns" 0
else
  report "qou. a clear-less review with no known finding layout: the doc records unknown and check warns" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qoh. The High group holds a finding block that no parse reads and has no clear line, while the
# Medium and Low groups say Nice. Not every group is clear, so the doc records unknown, not 0.
pr_case qoh other plain
h1=$(head_sha)
review_groups "$h1" finding nice nice > "$FX/review-high.md"
fx_qodo "$FX/review-high.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=unknown -->' "$CASE/$doc_name" \
  && grep -qF "could not be read: it has no finding the generator can parse" "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log"; then
  report "qoh. a High group with an unparsed finding and no clear line, the others Nice: the doc records unknown" 0
else
  report "qoh. a High group with an unparsed finding and no clear line, the others Nice: the doc records unknown" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qog. PR #35's "Great, no issues found!" with a stray "View" severity header: a View header means a
# group is listed, so the review is not clear and the doc records unknown, not 0.
pr_case qog other plain
h1=$(head_sha)
{ printf '<details><summary><ins><strong>View high (1)</strong></ins></summary><br/>\n\n'; review_great "$h1"; } > "$FX/review-great-view.md"
fx_qodo "$FX/review-great-view.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=unknown -->' "$CASE/$doc_name" \
  && ! grep -qF "lists no findings." "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log"; then
  report "qog. a Great review with a stray View header: the doc records unknown, not 0" 0
else
  report "qog. a Great review with a stray View header: the doc records unknown, not 0" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qoe. The last group (Low) is open at the end of the review, with no clear line after it. The
# groups before it say Nice, so only the end-of-version rule makes this unclear.
pr_case qoe other plain
h1=$(head_sha)
review_groups "$h1" nice nice open > "$FX/review-open-low.md"
fx_qodo "$FX/review-open-low.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=unknown -->' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log"; then
  report "qoe. the last group has no clear line at the end of the review: the doc records unknown" 0
else
  report "qoe. the last group has no clear line at the end of the review: the doc records unknown" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qof. An earlier review had a finding that the latest review no longer lists, and the latest review
# has an unparsed High finding with the others Nice. Nothing open is parsed, the review is not clear,
# so the doc records unknown rather than the 0 that the stale finding would give.
pr_case qof other plain
h1=$(head_sha)
review_body "$BASE" medium 'u-old-3|Earlier finding is gone|🐞 Bug' > "$FX/review-old.md"
review_groups "$h1" finding nice nice > "$FX/review-new.md"
fx_qodo "$FX/review-new.md" 2026-11-05T15:59:06Z "$FX/review-old.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=unknown -->' "$CASE/$doc_name" \
  && grep -qF 'No longer listed by Qodo.' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log"; then
  report "qof. an earlier finding gone, the latest review unreadable: the doc records unknown, not 0" 0
else
  report "qof. an earlier finding gone, the latest review unreadable: the doc records unknown, not 0" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qox. Qodo's latest review names the base commit, not the head's content: the doc records
# other, and the check passes with a ::warning.
pr_case qox other plain
review_clear "$BASE" > "$FX/review-base.md"
fx_qodo "$FX/review-base.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=other -->' "$CASE/$doc_name" \
  && grep -qF "its findings are not cleared" "$CASE/$doc_name" && ! grep -qF "lists no findings" "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'other content' "$FX/check.log"; then
  report "qox. a review of other content: the doc records other and check warns" 0
else
  report "qox. a review of other content: the doc records other and check warns" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qol. Two Qodo versions: an earlier one names a commit with the head's content, and the
# latest names the base commit. The latest is the one that counts, so the doc records other
# and the check warns.
pr_case qol other plain
h1=$(head_sha)
review_clear "$h1" > "$FX/review-head.md"
review_clear "$BASE" > "$FX/review-base.md"
fx_qodo "$FX/review-base.md" 2026-11-05T15:59:06Z "$FX/review-head.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=other -->' "$CASE/$doc_name" \
  && grep -qF "its findings are not cleared" "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'other content' "$FX/check.log"; then
  report "qol. the latest of two Qodo versions is of other content: the doc records other and check warns" 0
else
  report "qol. the latest of two Qodo versions is of other content: the doc records other and check warns" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qop. Qodo's latest review names the base commit and lists a finding: the finding is not
# cleared, so the doc records other and says so.
pr_case qop other plain
review_body "$BASE" medium 'u-base-1|Finding on the base|🐞 Bug' > "$FX/review-base.md"
fx_qodo "$FX/review-base.md"
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=other -->' "$CASE/$doc_name" \
  && grep -qF "its findings are not cleared" "$CASE/$doc_name"; then
  report "qop. a finding in a review of other content is not cleared: the doc records other" 0
else
  report "qop. a finding in a review of other content is not cleared: the doc records other" 1 "$(cat "$FX/gen.log")"
fi

# qon. No Qodo comment at all: the doc records none and the check warns.
pr_case qon other plain
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=none -->' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'had not reviewed' "$FX/check.log"; then
  report "qon. no Qodo review: the doc records none and check warns" 0
else
  report "qon. no Qodo review: the doc records none and check warns" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qom. A doc from before the Qodo state was recorded (no qodo-open= field), with the right
# digest: the check fails with "no Qodo state".
pr_case qom other plain
fx_qodo_clear "$(head_sha)"
gen "$CASE"
sed -E 's/ qodo-open=[a-z0-9]+ -->$/ -->/' "$CASE/$doc_name" > "$FX/qom.md"
cp "$FX/qom.md" "$CASE/$doc_name"
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && ! grep -qF 'qodo-open=' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -ne 0 ] && grep -q 'no Qodo state' "$FX/check.log"; then
  report "qom. a doc with no Qodo state in its metadata fails the check" 0
else
  report "qom. a doc with no Qodo state in its metadata fails the check" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# qod. The last metadata line is in the old format (right digest, no qodo-open=), and an
# earlier line records qodo-open=0. The check reads the last line, so it fails with "no Qodo
# state" rather than taking the earlier line's 0.
pr_case qod other plain
fx_qodo_clear "$(head_sha)"
gen "$CASE"
grep '^<!-- delivery: ' "$CASE/$doc_name" | sed -E 's/ qodo-open=[a-z0-9]+ -->$/ -->/' > "$FX/qod-legacy.txt"
cat "$FX/qod-legacy.txt" >> "$CASE/$doc_name"
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=0 -->' "$CASE/$doc_name" \
  && [ "$CHECK_RC" -ne 0 ] && grep -q 'no Qodo state' "$FX/check.log"; then
  report "qod. the last metadata line has no Qodo state, though an earlier line has qodo-open=0: check fails" 0
else
  report "qod. the last metadata line has no Qodo state, though an earlier line has qodo-open=0: check fails" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
fi

# own. Only the docs the PR adds are read: a stale sibling doc and a merged doc with no
# metadata, both already on the base, leave the check green.
new_case own
printf 'old\n' > "$CASE/deliveries/2026-10-01-old.md"
printf 'stale\n<!-- delivery: content=%040d homepage=%040d -->\n' 0 0 > "$CASE/deliveries/2026-10-02-stale.md"
printf 'notes\n' > "$CASE/notes.txt"
commit_all "a change off the homepage, with two other docs"
body_plain > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
fx_runs 101 "$(head_sha)" success success
fx_qodo_clear "$(head_sha)"
gen "$CASE"
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && [ "$CHECK_RC" -eq 0 ] && grep -qF 'docs PR: 1 delivery doc(s) checked' "$FX/check.log"; then
  report "own. only the docs the PR adds are read: sibling docs do not fail the check" 0
else
  report "own. only the docs the PR adds are read: sibling docs do not fail the check" 1 "$(cat "$FX/gen.log") $(cat "$FX/check.log")"
fi

# code. A PR that changes code carries no doc: the check passes with neither a warning nor an
# error, and says the doc comes after the merge. A stale doc it also carries is not read.
pr_case code other plain
check "$CASE" "" 1
code_plain=$CHECK_RC:$(cat "$FX/check.log")
printf 'stale\n<!-- delivery: content=%040d head=%040d homepage=%040d qodo-open=0 -->\n' 0 0 0 > "$CASE/$doc_name"
printf 'more\n' >> "$CASE/notes.txt"
commit_all "a code change that also carries a stale doc"
check "$CASE" "" 1
if [ "${code_plain%%:*}" -eq 0 ] && [ "$CHECK_RC" -eq 0 ] && grep -qF 'after it merges' "$FX/check.log" \
  && ! grep -qE '::(warning|error)' "$FX/check.log" && ! grep -q '::' <<< "$code_plain"; then
  report "code. a code PR needs no delivery doc: the check passes without a warning" 0
else
  report "code. a code PR needs no delivery doc: the check passes without a warning" 1 "first: $code_plain; then rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# shot. A docs PR that changes only a screenshot and TEMPLATE.md has no doc to check: it passes.
pr_case shot other plain
mkdir -p "$CASE/deliveries/$stem"
printf 'png' > "$CASE/deliveries/$stem/desktop.png"
printf '\n' >> "$CASE/deliveries/TEMPLATE.md"
commit_all "a screenshot and a template change"
check "$CASE"
if [ "$CHECK_RC" -eq 0 ] && grep -qF 'docs PR: 0 delivery doc(s) checked' "$FX/check.log"; then
  report "shot. a docs PR with only a screenshot and TEMPLATE.md passes with no doc read" 0
else
  report "shot. a docs PR with only a screenshot and TEMPLATE.md passes with no doc read" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# tab. A docs PR whose doc's name has a tab is a docs PR, and that doc is read under its own
# name: with no metadata, it fails. (Git quotes such a name unless the list is -z, and a
# quoted name is outside deliveries/, so the PR passed as a code PR.)
pr_case tab other plain
tab_doc=$'deliveries/2026-11-05-a\tb.md'
printf 'no metadata\n' > "$CASE/$tab_doc"
commit_all "a doc whose name has a tab"
check "$CASE"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'no delivery metadata' "$FX/check.log" && grep -qF "$tab_doc" "$FX/check.log"; then
  report "tab. a doc whose name has a tab is read under its own name: no metadata fails" 0
else
  report "tab. a doc whose name has a tab is read under its own name: no metadata fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# meta, nohd, unk. A doc without metadata fails; so does one whose metadata names no merged
# head (the format from before docs moved to their own PR); and so does a base that is not in
# the clone.
stale_case meta
gen "$CASE"
grep -v '^<!-- delivery: ' "$CASE/$doc_name" > "$FX/nometa.md"
cp "$FX/nometa.md" "$CASE/$doc_name"
commit_all "a doc without metadata"
check "$CASE"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'no delivery metadata' "$FX/check.log"; then
  report "meta. a doc without metadata fails" 0
else
  report "meta. a doc without metadata fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
gen "$CASE"
sed -E 's/ head=[0-9a-f]{40} / /' "$CASE/$doc_name" > "$FX/nohead.md"
cp "$FX/nohead.md" "$CASE/$doc_name"
commit_all "a doc in the old metadata format"
check "$CASE"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'no merged head' "$FX/check.log"; then
  report "nohd. a doc whose metadata names no merged head fails" 0
else
  report "nohd. a doc whose metadata names no merged head fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
CHECK_BASE=1111111111111111111111111111111111111111 check "$CASE"
if [ "$CHECK_RC" -ne 0 ] && grep -q 'not a commit' "$FX/check.log"; then
  report "unk. an unknown base fails" 0
else
  report "unk. an unknown base fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# ftch. CI's clone is shallow, so the merged head is not in it. The check fetches it from
# origin and passes. A head that origin does not have fails.
pr_case ftch other plain
fx_qodo_clear "$(head_sha)"
gen "$CASE"
mv "$CASE/$doc_name" "$FX/ftch-doc.md" 2>/dev/null || true
printf 'later\n' > "$CASE/later.txt"
commit_all "main moves on after the merge, and the docs branch starts from it"
mv "$FX/ftch-doc.md" "$CASE/$doc_name" 2>/dev/null || true
commit_all "delivery doc"
ftch_head=$(git -C "$CASE" rev-parse HEAD~2)
shallow="$tmp/ftch-shallow"
git -C "$CASE" config uploadpack.allowAnySHA1InWant true
git clone -q --depth=2 "file://$CASE" "$shallow" >/dev/null 2>&1 || mkdir -p "$shallow"
ftch_absent=0
git -C "$shallow" cat-file -e "$ftch_head^{commit}" 2>/dev/null || ftch_absent=1
check "$shallow"
ftch_rc=$CHECK_RC; ftch_log=$(cat "$FX/check.log")
{ sed -E 's/ head=[0-9a-f]{40} / head=2222222222222222222222222222222222222222 /' "$shallow/$doc_name" > "$FX/ftch-bad.md" \
  && cp "$FX/ftch-bad.md" "$shallow/$doc_name" \
  && git -C "$shallow" add -A \
  && git -C "$shallow" -c user.name=test -c user.email=t@example.invalid commit -q -m "a doc naming a head origin lacks"
} >/dev/null 2>&1 || true
check "$shallow"
if [ "$ftch_absent" -eq 1 ] && [ "$ftch_rc" -eq 0 ] && grep -qF "merged head $ftch_head" <<< "$ftch_log" \
  && [ "$CHECK_RC" -ne 0 ] && grep -q 'could not be fetched' "$FX/check.log"; then
  report "ftch. a merged head missing from a shallow clone is fetched; one origin lacks fails" 0
else
  report "ftch. a merged head missing from a shallow clone is fetched; one origin lacks fails" 1 "absent $ftch_absent; rc $ftch_rc: $ftch_log; then rc $CHECK_RC: $(cat "$FX/check.log")"
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

# doc_body NAME: the body of the doc's "## NAME" section, without the author label and blank lines.
doc_body() {
  # shellcheck disable=SC2016 # awk program, not the shell
  "$awk_bin" -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$CASE/$doc_name" 2>/dev/null \
    | sed '/^_From the PR description (author-written)\._$/d; /^[[:space:]]*$/d'
}

# ac. The real PR template has "Closes #" and "## Acceptance criteria" before "## Why"
# (AGENTS.md rule 10). Guards: section() takes each section by its exact heading only. The
# criteria carry lines a loose match would take for Why ("## Why (from the issue)", "### Why",
# "##Why", an indented "## Why"), each followed by AC-MARKER-WHY. They also carry fenced examples
# with exact headings: "## How" in a ```markdown fence, "## Why" in a ~~~ fence, and "## What" in a
# four-backtick fence that holds an inner ``` line. Each is followed by its AC-MARKER. A fenced
# "## LIM-FENCED-KEPT" line inside Limitations stays in that section's body. The filled template
# must generate, the doc's Why, How and What bodies must be exactly "Filled ...", and no AC-MARKER
# text may appear anywhere in the doc. The criteria are not copied.
# Two fence traps close the criteria, after the fences above have closed, so each opens a fence
# only if its guard is gone: "    ```" (4 spaces: an indented code line, not a fence) and
# "```not`a`fence" (a backtick info string: not a fence). Each is followed by "## Notes" (not a
# copied heading, so it stays harmless while the guard holds) and its own marker. Nothing closes
# either fence before the real Why, How and What sections. If a guard is removed, the fence
# swallows them and the case fails.
tpl=$root/.github/pull_request_template.md
pr_case ac other plain
# shellcheck disable=SC2016 # awk program, not the shell
"$awk_bin" '
  /^Closes #/ { print "Closes #24"; next }
  { print }
  /^## Acceptance criteria$/ {
    print ""
    print "- [ ] AC-MARKER the page builds"
    print "### Why"; print "AC-MARKER-WHY"
    print "##Why"; print "AC-MARKER-WHY"
    print "## Why (from the issue)"; print "AC-MARKER-WHY"
    print "    ## Why"; print "AC-MARKER-WHY"
    print "```markdown"; print "## How"; print "AC-MARKER-HOW"; print "```"
    print "~~~"; print "## Why"; print "AC-MARKER-WHY"; print "~~~"
    print "````"; print "```"; print "## What"; print "AC-MARKER-WHAT"; print "```"; print "````"
    print "    ```"; print "## Notes"; print "AC-MARKER-INDENT"
    print "```not`a`fence"; print "## Notes"; print "AC-MARKER-INFO"
  }
  /^## (Why|How|What|Assistance and third-party material|Limitations)$/ { print ""; print "Filled " substr($0, 4) "." }
  /^## Limitations$/ { print "```"; print "## LIM-FENCED-KEPT"; print "```" }
' "$tpl" > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
gen "$CASE"
ac_order=$(grep -E '^## (Acceptance criteria|Why)$' "$tpl" | tr '\n' '|')
why_body=$(doc_body Why || true)
how_body=$(doc_body How || true)
what_body=$(doc_body What || true)
if [ "$ac_order" = "## Acceptance criteria|## Why|" ] && grep -q '^Closes #' "$tpl" \
  && [ "$GEN_RC" -eq 0 ] && [ "$why_body" = "Filled Why." ] && [ "$how_body" = "Filled How." ] \
  && [ "$what_body" = "Filled What." ] && grep -qxF '## LIM-FENCED-KEPT' "$CASE/$doc_name" \
  && ! grep -qF 'AC-MARKER' "$CASE/$doc_name"; then
  report "ac. the PR template's Acceptance criteria parse cleanly and stay out of the doc" 0
else
  report "ac. the PR template's Acceptance criteria parse cleanly and stay out of the doc" 1 "order '$ac_order'; gen rc $GEN_RC; Why '$why_body' How '$how_body' What '$what_body': $(cat "$FX/gen.log")"
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
read -r om_d om_h <<< "$(sed -nE 's/^<!-- delivery: content=([0-9a-f]{40}) head=[0-9a-f]{40} homepage=([0-9a-f]{40})( qodo-open=[a-z0-9]+)? -->$/\1 \2/p' "$CASE/$doc_name")"
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
check "$CASE" 2026-12-12T23:00:00Z
if [ "$CHECK_RC" -eq 0 ] && grep -q 'ended' "$FX/check.log"; then
  report "cut. at 23:00:00Z the check passes without reading the doc" 0
else
  report "cut. at 23:00:00Z the check passes without reading the doc" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
check "$CASE" 2026-12-12T22:59:59Z
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

# qodo-status.sh (AGENTS.md rule 9). Its clock is QODO_STATUS_NOW = 2026-11-06T12:00:00Z. The
# fixture comment was created at 2026-11-05T15:50:27Z, so an unedited comment is 72573 s old.
qs_now=2026-11-06T12:00:00Z
qs_review=https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_qodo

# qs1. The review names the head and has been quiet for longer than 5 minutes: settled.
pr_case qs1 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$h1"
qstat "$CASE" "$qs_now" --pr 24
qs1_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs1_want"; then
  report "qs1. the review names the head and is quiet: settled, exit 0" 0
else
  report "qs1. the review names the head and is quiet: settled, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs2. The review names an earlier commit whose content is the head's (the head adds only
# the delivery doc): settled through the digest, exit 0.
pr_case qs2 other plain
qs_setup
r=$(head_sha)
fx_qodo_clear "$r"
# Only the doc is committed: qs_setup's copy of the script is untracked and must not join the
# head's content.
printf 'doc\n' > "$CASE/$doc_name"
git -C "$CASE" add "$doc_name"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q -m "delivery doc"
h=$(head_sha)
fx_pr "$h" "$FX/body.md"
qstat "$CASE" "$qs_now" --pr 24
qs2_want=$(cat <<EOF
head: $h
review: $qs_review
reviewed: $r
matches-head: digest
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs2_want"; then
  report "qs2. the review names a commit with the head's content: settled through the digest, exit 0" 0
else
  report "qs2. the review names a commit with the head's content: settled through the digest, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs3. The review names the head, but its comment was edited 60 s before now: waiting, exit 2.
pr_case qs3 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$h1"
fx_qodo_edited_at 2026-11-06T11:59:00Z
qstat "$CASE" "$qs_now" --pr 24
qs3_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-06T11:59:00Z
quiet: no (60s since last change, need 300s)
open: 0
status: waiting
EOF
)
if [ "$QSTAT_RC" -eq 2 ] && qstat_is "$qs3_want"; then
  report "qs3. edited 60 s ago with the default 5 minutes: waiting, exit 2" 0
else
  report "qs3. edited 60 s ago with the default 5 minutes: waiting, exit 2" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs4. The same comment, with --quiet-minutes 1: 60 s is enough, so waiting becomes settled.
pr_case qs4 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$h1"
fx_qodo_edited_at 2026-11-06T11:59:00Z
qstat "$CASE" "$qs_now" --pr 24 --quiet-minutes 1
qs4_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-06T11:59:00Z
quiet: yes (60s since last change, need 60s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs4_want"; then
  report "qs4. --quiet-minutes 1: the 60 s edit is quiet enough, settled, exit 0" 0
else
  report "qs4. --quiet-minutes 1: the 60 s edit is quiet enough, settled, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs5. The latest review is of the base commit, not of the head's content: stale, exit 3.
pr_case qs5 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$BASE"
qstat "$CASE" "$qs_now" --pr 24
qs5_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $BASE
matches-head: no
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: stale
EOF
)
if [ "$QSTAT_RC" -eq 3 ] && qstat_is "$qs5_want"; then
  report "qs5. the latest review is of the base commit: stale, exit 3" 0
else
  report "qs5. the latest review is of the base commit: stale, exit 3" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs6. No Qodo comment at all: no-review, exit 4.
pr_case qs6 other plain
qs_setup
h1=$(head_sha)
qstat "$CASE" "$qs_now" --pr 24
qs6_want=$(cat <<EOF
head: $h1
review: none
reviewed: none
matches-head: no
last-change: none
quiet: no (no review)
open: none
status: no-review
EOF
)
if [ "$QSTAT_RC" -eq 4 ] && qstat_is "$qs6_want"; then
  report "qs6. no Qodo comment: no-review, exit 4" 0
else
  report "qs6. no Qodo comment: no-review, exit 4" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs7. A Qodo comment with no commit marker: no-review, exit 4, with the comment's time.
pr_case qs7 other plain
qs_setup
h1=$(head_sha)
printf '<h3>Code Review by Qodo</h3>\n\nA review without a commit marker.\n' > "$FX/review-nomark.md"
fx_qodo "$FX/review-nomark.md"
qstat "$CASE" "$qs_now" --pr 24
qs7_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: none
matches-head: no
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: unknown
status: no-review
EOF
)
if [ "$QSTAT_RC" -eq 4 ] && qstat_is "$qs7_want"; then
  report "qs7. a Qodo comment with no commit marker: no-review, exit 4" 0
else
  report "qs7. a Qodo comment with no commit marker: no-review, exit 4" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs8. Qodo's comments are paged. The newest review, which names the head, is on page 2 and
# is by a "[bot]" login; the older review on page 1 names the base. Page 2 must be read.
pr_case qs8 other plain
qs_setup
h1=$(head_sha)
review_clear "$BASE" > "$FX/review-old.md"
review_clear "$h1" > "$FX/review-new.md"
jq -n --rawfile old "$FX/review-old.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: true, endCursor: "C1"},
  nodes: [{id: "IC_old", url: "https://example.invalid/old", createdAt: "2026-11-05T15:50:27Z", lastEditedAt: null,
    author: {login: "qodo-code-review"}, body: $old}]}}}}}' > "$FX/comments-null.json"
jq -n --rawfile new "$FX/review-new.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{id: "IC_new", url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_new",
    createdAt: "2026-11-05T16:10:00Z", lastEditedAt: null, author: {login: "qodo-code-review[bot]"}, body: $new}]}}}}}' \
  > "$FX/comments-C1.json"
qstat "$CASE" "$qs_now" --pr 24
qs8_want=$(cat <<EOF
head: $h1
review: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_new
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T16:10:00Z
quiet: yes (71400s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs8_want"; then
  report "qs8. paged comments: the newest review, on page 2, is the one read" 0
else
  report "qs8. paged comments: the newest review, on page 2, is the one read" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs9. gh fails reading the PR, and then gh fails reading the comments: error, exit 1 each.
pr_case qs9 other plain
qs_setup
touch "$FX/gh-fail-pr-view"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF 'error: could not read PR 24 with gh' "$FX/qs.err"; then
  report "qs9. a gh failure reading the PR: error, exit 1" 0
else
  report "qs9. a gh failure reading the PR: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi
rm -f "$FX/gh-fail-pr-view"
touch "$FX/gh-fail-api-graphql"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF "error: could not read Qodo's review comments on PR 24 with gh" "$FX/qs.err"; then
  report "qs9b. a gh failure reading the comments: error, exit 1" 0
else
  report "qs9b. a gh failure reading the comments: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs10. Usage errors: no --pr, a non-numeric --quiet-minutes, an unknown option, and --pr or
# --quiet-minutes as the last argument (no value). Each exits 1 with the usage line.
pr_case qs10 other plain
qs_setup
qstat "$CASE" "$qs_now"
u1=$QSTAT_RC; u1e=$(cat "$FX/qs.err")
qstat "$CASE" "$qs_now" --pr 24 --quiet-minutes x
u2=$QSTAT_RC; u2e=$(cat "$FX/qs.err")
qstat "$CASE" "$qs_now" --pr 24 --bogus
u3=$QSTAT_RC; u3e=$(cat "$FX/qs.err")
qstat "$CASE" "$qs_now" --pr
u4=$QSTAT_RC; u4e=$(cat "$FX/qs.err")
qstat "$CASE" "$qs_now" --pr 24 --quiet-minutes
u5=$QSTAT_RC; u5e=$(cat "$FX/qs.err")
if [ "$u1" -eq 1 ] && [ "$u2" -eq 1 ] && [ "$u3" -eq 1 ] && [ "$u4" -eq 1 ] && [ "$u5" -eq 1 ] \
  && printf '%s\n' "$u1e" "$u2e" "$u3e" "$u4e" "$u5e" | grep -c '^usage: scripts/qodo-status.sh' | grep -qx 5; then
  report "qs10. usage errors (no --pr, bad --quiet-minutes, unknown option, a flag with no value): exit 1" 0
else
  report "qs10. usage errors (no --pr, bad --quiet-minutes, unknown option, a flag with no value): exit 1" 1 "rc $u1 $u2 $u3 $u4 $u5: $u1e $u2e $u3e $u4e $u5e"
fi

# qs11. A QODO_STATUS_NOW that is not an ISO time is an error, exit 1.
pr_case qs11 other plain
qs_setup
qstat "$CASE" yesterday --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF 'not an ISO time' "$FX/qs.err"; then
  report "qs11. a QODO_STATUS_NOW that is not ISO: error, exit 1" 0
else
  report "qs11. a QODO_STATUS_NOW that is not ISO: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs12. The review names a commit that is not in this clone: its content cannot be compared,
# so it is an error (exit 1), not stale.
pr_case qs12 other plain
qs_setup
fx_qodo_clear 0123456789012345678901234567890123456789
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF 'is not in this clone' "$FX/qs.err"; then
  report "qs12. a reviewed commit that is not in the clone: error, exit 1" 0
else
  report "qs12. a reviewed commit that is not in the clone: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs13. No QODO_STATUS_NOW: the clock is date (faked here at 2026-11-06T12:00:00Z), and the
# same settled review as qs1 gives the same output.
pr_case qs13 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$h1"
clock2=$tmp/qs-clock
mkdir -p "$clock2"
printf '#!/bin/sh\necho 2026-11-06T12:00:00Z\n' > "$clock2/date"
chmod +x "$clock2/date"
qs13_rc=0
(cd "$CASE" && env -u QODO_STATUS_NOW PATH="$clock2:$bin:$PATH" GH_FIXTURES="$FX" bash scripts/qodo-status.sh --pr 24) \
  > "$FX/qs.out" 2> "$FX/qs.err" || qs13_rc=$?
qs13_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$qs13_rc" -eq 0 ] && qstat_is "$qs13_want"; then
  report "qs13. no QODO_STATUS_NOW: the clock is date, settled, exit 0" 0
else
  report "qs13. no QODO_STATUS_NOW: the clock is date, settled, exit 0" 1 "rc $qs13_rc: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs14. Two Qodo reviews: the newer one (naming the head) is listed first, the older one (naming
# the base) second. The newer one is read: settled, exit 0.
pr_case qs14 other plain
qs_setup
h1=$(head_sha)
review_clear "$h1" > "$FX/review-new.md"
review_clear "$BASE" > "$FX/review-old.md"
fx_qodo_pair "$FX/review-new.md" 2026-11-05T16:10:00Z "$FX/review-old.md" 2026-11-05T15:50:27Z
qstat "$CASE" "$qs_now" --pr 24
qs14_want=$(cat <<EOF
head: $h1
review: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_a
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T16:10:00Z
quiet: yes (71400s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs14_want"; then
  report "qs14. the newer review, listed first, wins over the older one listed second: settled, exit 0" 0
else
  report "qs14. the newer review, listed first, wins over the older one listed second: settled, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs15. An exact tie: both reviews were created at 2026-11-05T16:10:00Z. The later-listed one
# wins (qodo-status.sh replaces the pick unless the new time is less than the picked one), so
# IC_b, which names the base, is read: stale, exit 3.
pr_case qs15 other plain
qs_setup
h1=$(head_sha)
review_clear "$h1" > "$FX/review-new.md"
review_clear "$BASE" > "$FX/review-old.md"
fx_qodo_pair "$FX/review-new.md" 2026-11-05T16:10:00Z "$FX/review-old.md" 2026-11-05T16:10:00Z
qstat "$CASE" "$qs_now" --pr 24
qs15_want=$(cat <<EOF
head: $h1
review: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_b
reviewed: $BASE
matches-head: no
last-change: 2026-11-05T16:10:00Z
quiet: yes (71400s since last change, need 300s)
open: 0
status: stale
EOF
)
if [ "$QSTAT_RC" -eq 3 ] && qstat_is "$qs15_want"; then
  report "qs15. an exact tie in creation time: the later-listed review wins, stale, exit 3" 0
else
  report "qs15. an exact tie in creation time: the later-listed review wins, stale, exit 3" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs16. The digest matches (qs2's doc-only amend, the review naming the earlier commit), and the
# comment was edited 60 s before now (qs3): matches-head digest, waiting, exit 2.
pr_case qs16 other plain
qs_setup
r=$(head_sha)
fx_qodo_clear "$r"
printf 'doc\n' > "$CASE/$doc_name"
git -C "$CASE" add "$doc_name"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q -m "delivery doc"
h=$(head_sha)
fx_pr "$h" "$FX/body.md"
fx_qodo_edited_at 2026-11-06T11:59:00Z
qstat "$CASE" "$qs_now" --pr 24
qs16_want=$(cat <<EOF
head: $h
review: $qs_review
reviewed: $r
matches-head: digest
last-change: 2026-11-06T11:59:00Z
quiet: no (60s since last change, need 300s)
open: 0
status: waiting
EOF
)
if [ "$QSTAT_RC" -eq 2 ] && qstat_is "$qs16_want"; then
  report "qs16. the digest matches but the comment was edited 60 s ago: waiting, exit 2" 0
else
  report "qs16. the digest matches but the comment was edited 60 s ago: waiting, exit 2" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs17. The reviewed commit's tree is missing from the clone, though its commit is there (as in
# a partial clone): its digest cannot be computed. Error, exit 1, not stale.
pr_case qs17 other plain
qs_setup
fx_qodo_clear "$BASE"
t=$(git -C "$CASE" rev-parse "$BASE^{tree}")
rm "$CASE/.git/objects/${t:0:2}/${t:2}"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF "error: could not compute the content digest of $BASE" "$FX/qs.err"; then
  report "qs17. the reviewed commit's digest cannot be computed: error, exit 1" 0
else
  report "qs17. the reviewed commit's digest cannot be computed: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs18. The same, for the head's tree: the reviewed digest is computed, the head's is not. Error,
# exit 1, naming the head.
pr_case qs18 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$BASE"
t=$(git -C "$CASE" rev-parse "$h1^{tree}")
rm "$CASE/.git/objects/${t:0:2}/${t:2}"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF "error: could not compute the content digest of $h1" "$FX/qs.err"; then
  report "qs18. the head's digest cannot be computed: error, exit 1" 0
else
  report "qs18. the head's digest cannot be computed: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs19. check-delivery.sh --digest exits 0 with no output for the reviewed commit (a stub stands
# in for an empty digest, which the real script never prints): error, exit 1.
pr_case qs19 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$BASE"
mv "$CASE/scripts/check-delivery.sh" "$CASE/scripts/check-delivery-real.sh"
cat > "$CASE/scripts/check-delivery.sh" <<WRAP
#!/usr/bin/env bash
# Test stub: an empty digest for BASE, otherwise the real script.
if [ "\$1" = --digest ] && [ "\$2" = "$BASE" ]; then exit 0; fi
exec bash "\$(dirname "\$0")/check-delivery-real.sh" "\$@"
WRAP
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && grep -qF "error: the content digest of $BASE or $h1 is empty" "$FX/qs.err"; then
  report "qs19. an empty digest for the reviewed commit: error, exit 1" 0
else
  report "qs19. an empty digest for the reviewed commit: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs20. A newer comment by a lookalike login (qodo-code-review-fake) names a commit that is not in
# the clone. It is not Qodo's review, so the real older review, which names the head, is read:
# settled, exit 0. Before the allowlist, the lookalike was read and the script errored (exit 1).
pr_case qs20 other plain
qs_setup
h1=$(head_sha)
review_clear 0123456789012345678901234567890123456789 > "$FX/review-fake.md"
review_clear "$h1" > "$FX/review-real.md"
jq -n --rawfile fake "$FX/review-fake.md" --rawfile real "$FX/review-real.md" '{data: {repository: {pullRequest: {comments: {
  pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [
    {id: "IC_fake", url: "https://example.invalid/fake", createdAt: "2026-11-05T16:10:00Z", lastEditedAt: null,
      author: {login: "qodo-code-review-fake"}, body: $fake},
    {id: "IC_real", url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_real",
      createdAt: "2026-11-05T15:50:27Z", lastEditedAt: null, author: {login: "qodo-code-review"}, body: $real}
  ]}}}}}' > "$FX/comments-null.json"
qstat "$CASE" "$qs_now" --pr 24
qs20_want=$(cat <<EOF
head: $h1
review: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/24#issuecomment-IC_real
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs20_want"; then
  report "qs20. a lookalike login (qodo-code-review-fake) is not Qodo: the real review is read, settled, exit 0" 0
else
  report "qs20. a lookalike login (qodo-code-review-fake) is not Qodo: the real review is read, settled, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs21. The clock is one second before the review's last change (clock skew): the printed age is
# 0s, not -1s. The comparison is unchanged, so the comment is not quiet: waiting, exit 2.
pr_case qs21 other plain
qs_setup
h1=$(head_sha)
fx_qodo_clear "$h1"
qstat "$CASE" 2026-11-05T15:50:26Z --pr 24
qs21_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T15:50:27Z
quiet: no (0s since last change, need 300s)
open: 0
status: waiting
EOF
)
if [ "$QSTAT_RC" -eq 2 ] && qstat_is "$qs21_want"; then
  report "qs21. a clock one second before the last change: the age prints 0s, waiting, exit 2" 0
else
  report "qs21. a clock one second before the last change: the age prints 0s, waiting, exit 2" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs22. The number of findings: the distinct keys of the findings the review lists. Three lines
# with two keys (one listed twice) count 2; a clear "Great" review counts 0; a layout the parser
# does not know counts unknown.
pr_case qs22 other plain
qs_setup
h1=$(head_sha)
review_body "$h1" medium 'u-1|First finding|🐞 Bug' 'u-1|First finding again|🐞 Bug' 'u-2|Second finding|📘 Rule violation' > "$FX/review-two.md"
review_great "$h1" > "$FX/review-great.md"
printf '<h3>Code Review by Qodo</h3>\n\n<p>Qodo finished a pass on this change.</p>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$h1" > "$FX/review-unknown.md"
qs22_got=""
for qs22_body in review-two review-great review-unknown; do
  fx_qodo "$FX/$qs22_body.md"
  qstat "$CASE" "$qs_now" --pr 24
  qs22_got="$qs22_got|$(sed -n 's/^open: //p' "$FX/qs.out")"
done
if [ "$qs22_got" = "|2|0|unknown" ]; then
  report "qs22. open: the distinct finding keys (2), a Great review (0), an unknown layout (unknown)" 0
else
  report "qs22. open: the distinct finding keys (2), a Great review (0), an unknown layout (unknown)" 1 "got $qs22_got"
fi

# qs23. --fetch: the reviewed commit R is on the remote under refs/pull/24/head and is not in this
# clone (the head is a doc-only amend of R, and R is then pruned). R is fetched by SHA, its digest
# is the head's, and the review settles: exit 0, matches-head digest.
pr_case qs23 other plain
qs_setup
r=$(head_sha)
fx_qodo_clear "$r"
qs23_remote=$tmp/qs23-remote.git
git init -q --bare "$qs23_remote"
git -C "$qs23_remote" config uploadpack.allowAnySHA1InWant true
git -C "$CASE" push -q "file://$qs23_remote" "$r:refs/pull/24/head"
printf 'doc\n' > "$CASE/$doc_name"
git -C "$CASE" add "$doc_name"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q --amend --no-edit
h=$(head_sha)
fx_pr "$h" "$FX/body.md"
drop_from_clone "$CASE"
qs23_gone=no
if ! git -C "$CASE" cat-file -e "$r^{commit}" 2>/dev/null; then qs23_gone=yes; fi
qstat "$CASE" "$qs_now" --pr 24 --fetch "file://$qs23_remote"
qs23_want=$(cat <<EOF
head: $h
review: $qs_review
reviewed: $r
matches-head: digest
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: settled
EOF
)
if [ "$qs23_gone" = yes ] && [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs23_want"; then
  report "qs23. --fetch gets the reviewed commit from the remote: its digest matches, settled, exit 0" 0
else
  report "qs23. --fetch gets the reviewed commit from the remote: its digest matches, settled, exit 0" 1 "pruned $qs23_gone; rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs24. --fetch, and the reviewed commit is absent from the remote too: a note on stderr, the
# review counts as other content (matches-head no), stale, exit 3.
pr_case qs24 other plain
qs_setup
r=$(head_sha)
fx_qodo_clear "$r"
qs24_remote=$tmp/qs24-remote.git
git init -q --bare "$qs24_remote"
printf 'doc\n' > "$CASE/$doc_name"
git -C "$CASE" add "$doc_name"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q --amend --no-edit
h=$(head_sha)
fx_pr "$h" "$FX/body.md"
drop_from_clone "$CASE"
qstat "$CASE" "$qs_now" --pr 24 --fetch "file://$qs24_remote"
qs24_want=$(cat <<EOF
head: $h
review: $qs_review
reviewed: $r
matches-head: no
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: 0
status: stale
EOF
)
qs24_note="note: the reviewed commit $r could not be fetched from file://$qs24_remote; it counts as other content"
if [ "$QSTAT_RC" -eq 3 ] && qstat_is "$qs24_want" && grep -qxF "$qs24_note" "$FX/qs.err"; then
  report "qs24. --fetch and the reviewed commit is on no remote: a note, stale, exit 3" 0
else
  report "qs24. --fetch and the reviewed commit is on no remote: a note, stale, exit 3" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs25. --fetch, and the head is in neither this clone nor the remote: an error, exit 1.
pr_case qs25 other plain
qs_setup
fx_qodo_clear "$BASE"
fx_pr 0123456789012345678901234567890123456789 "$FX/body.md"
qs25_remote=$tmp/qs25-remote.git
git init -q --bare "$qs25_remote"
qstat "$CASE" "$qs_now" --pr 24 --fetch "file://$qs25_remote"
if [ "$QSTAT_RC" -eq 1 ] && grep -qF 'commit 0123456789012345678901234567890123456789 is not in this clone' "$FX/qs.err"; then
  report "qs25. --fetch and the head is in neither the clone nor the remote: error, exit 1" 0
else
  report "qs25. --fetch and the head is in neither the clone nor the remote: error, exit 1" 1 "rc $QSTAT_RC: $(cat "$FX/qs.err")"
fi

# qs26. --fetch with no value, or an empty one: usage, exit 1; the usage line names --fetch.
pr_case qs26 other plain
qs_setup
qstat "$CASE" "$qs_now" --pr 24 --fetch
u1=$QSTAT_RC; u1e=$(cat "$FX/qs.err")
qstat "$CASE" "$qs_now" --pr 24 --fetch ""
u2=$QSTAT_RC; u2e=$(cat "$FX/qs.err")
if [ "$u1" -eq 1 ] && [ "$u2" -eq 1 ] \
  && [ "$(printf '%s\n' "$u1e" "$u2e" | grep -c -x -F 'usage: scripts/qodo-status.sh --pr N [--quiet-minutes M] [--fetch REMOTE]')" -eq 2 ]; then
  report "qs26. --fetch with no value (or an empty one): usage, exit 1" 0
else
  report "qs26. --fetch with no value (or an empty one): usage, exit 1" 1 "rc $u1 $u2: $u1e $u2e"
fi

# qs27. The head from gh is not a commit SHA. "HEAD" names this clone's head commit, which the
# review names, so without the check the script would settle. The head must be 40 hex: error,
# exit 1, nothing on stdout.
pr_case qs27 other plain
qs_setup
fx_qodo_clear "$(head_sha)"
fx_pr HEAD "$FX/body.md"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 1 ] && [ ! -s "$FX/qs.out" ] && grep -qxF 'error: PR 24 head is not a commit SHA: HEAD' "$FX/qs.err"; then
  report "qs27. the head from gh is not a commit SHA: error, exit 1, nothing settled" 0
else
  report "qs27. the head from gh is not a commit SHA: error, exit 1, nothing settled" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs28. --fetch, and the head from gh is an option-shaped value. git fetch reads --upload-pack=
# as an option (without --) and runs its command, so the old script would run touch. The head
# is checked first: error, exit 1, and the command does not run.
pr_case qs28 other plain
qs_setup
fx_qodo_clear "$(head_sha)"
qs28_ran=$FX/qs28-ran
fx_pr "--upload-pack=touch $qs28_ran" "$FX/body.md"
git init -q --bare "$tmp/qs28-remote.git"
qstat "$CASE" "$qs_now" --pr 24 --fetch "file://$tmp/qs28-remote.git"
qs28_want="error: PR 24 head is not a commit SHA: --upload-pack=touch $qs28_ran"
if [ "$QSTAT_RC" -eq 1 ] && [ ! -e "$qs28_ran" ] && grep -qxF "$qs28_want" "$FX/qs.err"; then
  report "qs28. --fetch and the head is option-shaped: error, exit 1, no fetch runs" 0
else
  report "qs28. --fetch and the head is option-shaped: error, exit 1, no fetch runs" 1 "rc $QSTAT_RC ran $([ -e "$qs28_ran" ] && echo yes || echo no): $(cat "$FX/qs.err")"
fi

# qodo-gate.sh (AGENTS.md rule 9). Each gate case asserts the exact POST it makes, or that it makes
# none. The gate's clock is the case's $FX/clock (the date stub), or QODO_STATUS_NOW when a case
# sets GATE_QSN.
gate_now=2026-11-06T12:00:00Z
gate_review_url=$qs_review

# gate_setup: copies qodo-gate.sh and qodo-status.sh (which it runs) and a gh reply for the POST.
# A missing copy fails the case.
gate_setup() {
  cp "$root/scripts/qodo-gate.sh" "$CASE/scripts/" 2>/dev/null || true
  qs_setup
  echo '{}' > "$FX/status-reply.json"
}

# fx_pull STATE DRAFT LOGIN: the PR as the REST API reports it, its head at the case's head.
fx_pull() {
  jq -n --arg state "$1" --argjson draft "$2" --arg login "$3" --arg sha "$(head_sha)" \
    '{state: $state, draft: $draft, user: {login: $login}, head: {sha: $sha}}' > "$FX/pull.json"
}

# gate CASE NOW [ARGS]: runs scripts/qodo-gate.sh in CASE with the stubs and the clock at NOW.
# Its gh calls go to $FX/gh-calls.log and its waits to $FX/naps.log. Sets GATE_RC; stdout goes to
# $FX/gate.out and stderr to $FX/gate.err. GATE_RUN_ID and GATE_SERVER_URL set the Actions values.
gate() {
  local c=$1 now=$2
  shift 2
  GATE_RC=0
  printf '%s\n' "$now" > "$FX/clock"
  : > "$FX/gh-calls.log"
  : > "$FX/naps.log"
  (cd "$c" && PATH="$bin:$PATH" GH_FIXTURES="$FX" QODO_STATUS_NOW="${GATE_QSN:-}" \
    QODO_GATE_SLEEP="$bin/nap" GITHUB_RUN_ID="${GATE_RUN_ID:-}" GITHUB_SERVER_URL="${GATE_SERVER_URL:-}" \
    bash scripts/qodo-gate.sh "$@") > "$FX/gate.out" 2> "$FX/gate.err" || GATE_RC=$?
  return 0
}

# gate_posts: the POST calls the gate made, one per line.
gate_posts() { grep -- '--method POST' "$FX/gh-calls.log" || true; }

# post_line SHA STATE DESCRIPTION [URL]: the gh arguments of the POST the gate makes for these fields.
post_line() {
  local line="api repos/lioramilbaum/lioramilbaum.github.io/statuses/$1 --method POST -f state=$2 -f context=qodo-findings -f description=$3"
  if [ -n "${4:-}" ]; then line="$line -f target_url=$4"; fi
  printf '%s\n' "$line"
}

# g1. A Renovate PR is exempt: success, with no call to Qodo's review.
pr_case g1 other plain
gate_setup
fx_pull open false 'renovate[bot]'
gate "$CASE" "$gate_now" --pr 24
g1_want=$(post_line "$(head_sha)" success "Renovate PR: exempt from Qodo review (AGENTS.md rule 9)")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g1_want" ] && ! grep -qF 'graphql' "$FX/gh-calls.log"; then
  report "g1. a Renovate PR: success (exempt), and no review is read" 0
else
  report "g1. a Renovate PR: success (exempt), and no review is read" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g2. A draft: pending, with no read of the review.
pr_case g2 other plain
gate_setup
fx_pull open true someone
gate "$CASE" "$gate_now" --pr 24
g2_want=$(post_line "$(head_sha)" pending "Draft: Qodo reviews this PR once it is marked ready")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g2_want" ] && ! grep -qF 'graphql' "$FX/gh-calls.log"; then
  report "g2. a draft: pending, and no review is read" 0
else
  report "g2. a draft: pending, and no review is read" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g3. A closed PR gets no status at all.
pr_case g3 other plain
gate_setup
fx_pull closed false someone
gate "$CASE" "$gate_now" --pr 24
if [ "$GATE_RC" -eq 0 ] && [ -z "$(gate_posts)" ] && grep -qF 'is closed; no status to set' "$FX/gate.out"; then
  report "g3. a closed PR: exit 0, no POST" 0
else
  report "g3. a closed PR: exit 0, no POST" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.out")"
fi

# g4. Qodo's latest review of the head is clear: success, linking the review.
pr_case g4 other plain
gate_setup
fx_qodo_clear "$(head_sha)"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g4_want=$(post_line "$(head_sha)" success "Qodo's latest review of this head lists no open findings" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g4_want" ]; then
  report "g4. a clear review of the head: success, with the review as target_url" 0
else
  report "g4. a clear review of the head: success, with the review as target_url" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g5. Two findings open: failure, with the count.
pr_case g5 other plain
gate_setup
review_body "$(head_sha)" medium 'u-1|One finding|🐞 Bug' 'u-2|Two finding|🐞 Bug' > "$FX/review.md"
fx_qodo "$FX/review.md"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g5_want=$(post_line "$(head_sha)" failure "Qodo lists 2 open finding(s); fix or dismiss each (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g5_want" ]; then
  report "g5. two open findings: failure, with the count" 0
else
  report "g5. two open findings: failure, with the count" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g6. A layout the parser does not know: failure, pointing at scripts/qodo-review.awk.
pr_case g6 other plain
gate_setup
printf '<h3>Code Review by Qodo</h3>\n\n<p>Qodo finished a pass on this change.</p>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$(head_sha)" > "$FX/review.md"
fx_qodo "$FX/review.md"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g6_want=$(post_line "$(head_sha)" failure "Qodo's review could not be read; update scripts/qodo-review.awk (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g6_want" ]; then
  report "g6. an unknown layout: failure, pointing at scripts/qodo-review.awk" 0
else
  report "g6. an unknown layout: failure, pointing at scripts/qodo-review.awk" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g7. Qodo's latest review is of the base commit: pending, naming that commit.
pr_case g7 other plain
gate_setup
fx_qodo_clear "$BASE"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g7_want=$(post_line "$(head_sha)" pending "Qodo has not reviewed this head yet; its latest review is of ${BASE:0:7}" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g7_want" ]; then
  report "g7. a review of the base commit: pending, naming it" 0
else
  report "g7. a review of the base commit: pending, naming it" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g8. No review: pending. The target is this run's page when Actions set the run, on the server
# Actions names (or github.com when it names none), and none outside Actions.
pr_case g8 other plain
gate_setup
fx_qodo_none
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g8_want=$(post_line "$(head_sha)" pending "Qodo has not reviewed this PR yet")
g8_ok=1
if [ "$GATE_RC" -ne 0 ] || [ "$(gate_posts)" != "$g8_want" ]; then g8_ok=0; fi
GATE_RUN_ID=77
gate "$CASE" "$gate_now" --pr 24
g8_want=$(post_line "$(head_sha)" pending "Qodo has not reviewed this PR yet" "https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/77")
if [ "$GATE_RC" -ne 0 ] || [ "$(gate_posts)" != "$g8_want" ]; then g8_ok=0; fi
GATE_SERVER_URL=https://ghe.example.invalid
gate "$CASE" "$gate_now" --pr 24
g8_want=$(post_line "$(head_sha)" pending "Qodo has not reviewed this PR yet" "https://ghe.example.invalid/lioramilbaum/lioramilbaum.github.io/actions/runs/77")
if [ "$GATE_RC" -ne 0 ] || [ "$(gate_posts)" != "$g8_want" ]; then g8_ok=0; fi
GATE_RUN_ID=""; GATE_SERVER_URL=""
if [ "$g8_ok" -eq 1 ]; then
  report "g8. no review: pending, with the run's page as target_url when Actions set it" 0
else
  report "g8. no review: pending, with the run's page as target_url when Actions set it" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g9. The review was edited 60 s before the clock, and the first wait moves the clock 6 minutes on:
# pending while it settles, then success after one wait.
pr_case g9 other plain
gate_setup
fx_qodo_clear "$(head_sha)"
fx_qodo_edited_at 2026-11-06T11:59:00Z
fx_pull open false someone
printf '2026-11-06T12:06:00Z\n' > "$FX/clock-next"
gate "$CASE" "$gate_now" --pr 24
g9_want=$(printf '%s\n%s\n' \
  "$(post_line "$(head_sha)" pending "Qodo's review is settling (5 quiet minutes)" "$gate_review_url")" \
  "$(post_line "$(head_sha)" success "Qodo's latest review of this head lists no open findings" "$gate_review_url")")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g9_want" ] && [ "$(wc -l < "$FX/naps.log" | tr -d ' ')" -eq 1 ]; then
  report "g9. a review still settling: pending, then success after one 30 s wait" 0
else
  report "g9. a review still settling: pending, then success after one 30 s wait" 1 "rc $GATE_RC: $(gate_posts) naps $(cat "$FX/naps.log")"
fi

# g10. The clock never moves on: twelve waits, then pending "still changing", exit 0.
pr_case g10 other plain
gate_setup
fx_qodo_clear "$(head_sha)"
fx_qodo_edited_at 2026-11-06T11:59:00Z
fx_pull open false someone
GATE_QSN=2026-11-06T12:00:00Z
gate "$CASE" "$gate_now" --pr 24
GATE_QSN=""
g10_want=$(printf '%s\n%s\n' \
  "$(post_line "$(head_sha)" pending "Qodo's review is settling (5 quiet minutes)" "$gate_review_url")" \
  "$(post_line "$(head_sha)" pending "Qodo's review is still changing; its next edit re-runs this check" "$gate_review_url")")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g10_want" ] && [ "$(wc -l < "$FX/naps.log" | tr -d ' ')" -eq 12 ]; then
  report "g10. a review that never settles: twelve waits, then pending, exit 0" 0
else
  report "g10. a review that never settles: twelve waits, then pending, exit 0" 1 "rc $GATE_RC: $(gate_posts) naps $(wc -l < "$FX/naps.log")"
fi

# g11. Reading the review fails: error on the head, with the run's page, and exit 1.
pr_case g11 other plain
gate_setup
touch "$FX/gh-fail-api-graphql"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g11_want=$(post_line "$(head_sha)" error "Could not read Qodo's review; see the workflow run")
if [ "$GATE_RC" -eq 1 ] && [ "$(gate_posts)" = "$g11_want" ] && grep -qF 'could not read Qodo' "$FX/gate.err"; then
  report "g11. a failed read of the review: error on the head, exit 1" 0
else
  report "g11. a failed read of the review: error on the head, exit 1" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g12. The status cannot be set: exit 1, naming the commit.
pr_case g12 other plain
gate_setup
touch "$FX/gh-fail-status"
fx_pull open true someone
gate "$CASE" "$gate_now" --pr 24
if [ "$GATE_RC" -eq 1 ] && grep -qF "error: could not set the qodo-findings status on $(head_sha)" "$FX/gate.err"; then
  report "g12. a status that cannot be posted: exit 1, naming the commit" 0
else
  report "g12. a status that cannot be posted: exit 1, naming the commit" 1 "rc $GATE_RC: $(cat "$FX/gate.err")"
fi

# g13. Usage: no --pr, a non-numeric --pr, and --fetch with no value. Each exits 1 with the usage
# line and makes no gh call.
pr_case g13 other plain
gate_setup
g13_ok=1
# shellcheck disable=SC2086 # the argument lists are word-split on purpose
for g13_args in "" "--pr x" "--pr 24 --fetch"; do
  gate "$CASE" "$gate_now" $g13_args
  if [ "$GATE_RC" -ne 1 ] || ! grep -qxF 'usage: scripts/qodo-gate.sh --pr N [--fetch REMOTE]' "$FX/gate.err" \
    || [ -s "$FX/gh-calls.log" ]; then
    g13_ok=0
  fi
done
if [ "$g13_ok" -eq 1 ]; then
  report "g13. usage: no --pr, a non-numeric one, or --fetch with no value: exit 1, no gh call" 0
else
  report "g13. usage: no --pr, a non-numeric one, or --fetch with no value: exit 1, no gh call" 1 "$(cat "$FX/gate.err")"
fi

# g14. qodo-status.sh reports an open count that is neither a number nor unknown: the gate stops
# (exit 1) and posts nothing. The case's copy of qodo-status.sh is replaced by a stub.
pr_case g14 other plain
gate_setup
fx_pull open false someone
g14_head=$(head_sha)
cat > "$CASE/scripts/qodo-status.sh" <<STUB
#!/usr/bin/env bash
printf 'head: %s\nreview: none\nreviewed: none\nopen: weird\nstatus: settled\n' "$g14_head"
STUB
gate "$CASE" "$gate_now" --pr 24
if [ "$GATE_RC" -eq 1 ] && [ -z "$(gate_posts)" ] && grep -qF 'reported open: weird' "$FX/gate.err"; then
  report "g14. an open count that is neither a number nor unknown: exit 1, no POST" 0
else
  report "g14. an open count that is neither a number nor unknown: exit 1, no POST" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g15. --fetch REMOTE reaches qodo-status.sh. The case's copy records its arguments and reports no
# review, so the gate posts pending.
pr_case g15 other plain
gate_setup
fx_pull open false someone
g15_head=$(head_sha)
cat > "$CASE/scripts/qodo-status.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" > "$FX/qs-args.log"
printf 'head: %s\nreview: none\nreviewed: none\nopen: none\nstatus: no-review\n' "$g15_head"
exit 4
STUB
gate "$CASE" "$gate_now" --pr 24 --fetch origin
g15_want=$(post_line "$(head_sha)" pending "Qodo has not reviewed this PR yet")
if [ "$GATE_RC" -eq 0 ] && [ "$(cat "$FX/qs-args.log")" = "--pr 24 --fetch origin" ] && [ "$(gate_posts)" = "$g15_want" ]; then
  report "g15. --fetch REMOTE is passed to qodo-status.sh" 0
else
  report "g15. --fetch REMOTE is passed to qodo-status.sh" 1 "rc $GATE_RC: $(cat "$FX/qs-args.log" 2>/dev/null) $(gate_posts)"
fi

# g16. The PR cannot be read (gh fails), or its head is not a commit SHA: exit 1, no POST.
pr_case g16 other plain
gate_setup
touch "$FX/gh-fail-pulls"
fx_pull open false someone
gate "$CASE" "$gate_now" --pr 24
g16a_ok=0
if [ "$GATE_RC" -eq 1 ] && [ -z "$(gate_posts)" ] && grep -qF 'could not read PR 24 with gh' "$FX/gate.err"; then g16a_ok=1; fi
rm -f "$FX/gh-fail-pulls"
jq -n '{state: "open", draft: false, user: {login: "someone"}, head: {sha: "not-a-sha"}}' > "$FX/pull.json"
gate "$CASE" "$gate_now" --pr 24
if [ "$g16a_ok" -eq 1 ] && [ "$GATE_RC" -eq 1 ] && [ -z "$(gate_posts)" ] && grep -qF 'no usable head SHA' "$FX/gate.err"; then
  report "g16. the PR cannot be read, or its head is not a SHA: exit 1, no POST" 0
else
  report "g16. the PR cannot be read, or its head is not a SHA: exit 1, no POST" 1 "a $g16a_ok rc $GATE_RC: $(cat "$FX/gate.err")"
fi

# agree: the generator's qodo-open and the gate's status on the same six Qodo reviews. A finding
# on the head gives 1 and failure; a clear review and a "Great" one give 0 and success; an unknown
# layout gives unknown and failure; a review of the base gives other and pending; no review gives
# none and pending.
ag_finding() { review_body "$(head_sha)" medium 'u-1|One finding|🐞 Bug' > "$FX/ag.md"; fx_qodo "$FX/ag.md"; }
ag_clear() { fx_qodo_clear "$(head_sha)"; }
ag_great() { review_great "$(head_sha)" > "$FX/ag.md"; fx_qodo "$FX/ag.md"; }
ag_unknown() {
  printf '<h3>Code Review by Qodo</h3>\n\n<p>Qodo finished a pass on this change.</p>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$(head_sha)" > "$FX/ag.md"
  fx_qodo "$FX/ag.md"
}
ag_base() { fx_qodo_clear "$BASE"; }
ag_none() { fx_qodo_none; }

# ag_want OPEN: the state AGENTS.md rule 9 gives a doc recording OPEN.
ag_want() {
  case "$1" in
    0) echo success ;;
    unknown) echo failure ;;
    other|none) echo pending ;;
    *) echo failure ;;
  esac
}

# agree_one NAME SETUP WANT_OPEN: a PR whose Qodo review SETUP writes. The generator must record
# WANT_OPEN and the gate must post the state ag_want gives it.
agree_fail=""
agree_one() {
  pr_case "$1" other plain
  gate_setup
  fx_pull open false someone
  "$2"
  gen "$CASE"
  ag_open=$(sed -nE 's/^<!-- delivery: .* qodo-open=([a-z0-9]+) -->$/\1/p' "$CASE/$doc_name" | tail -n1)
  gate "$CASE" "$gate_now" --pr 24
  ag_state=$(gate_posts | tail -n1 | sed -nE 's/.* -f state=([a-z]+) .*/\1/p')
  if [ "$ag_open" != "$3" ] || [ "$ag_state" != "$(ag_want "$3")" ]; then
    agree_fail="$agree_fail $1(open=$ag_open state=$ag_state)"
  fi
}
agree_one ag1 ag_finding 1
agree_one ag2 ag_clear 0
agree_one ag3 ag_great 0
agree_one ag4 ag_unknown unknown
agree_one ag5 ag_base other
agree_one ag6 ag_none none
if [ -z "$agree_fail" ]; then
  report "agree. the generator's qodo-open and the gate's status agree on six Qodo reviews" 0
else
  report "agree. the generator's qodo-open and the gate's status agree on six Qodo reviews" 1 "$agree_fail"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed (awk: $awk_bin)" >&2
  exit 1
fi
echo "all cases passed (awk: $awk_bin)"
