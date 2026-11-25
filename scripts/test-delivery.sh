#!/usr/bin/env bash
# Tests for the delivery-doc tooling (AGENTS.md rule 6): generate-delivery.sh, the
# check in check-delivery.sh, qodo-status.sh (AGENTS.md rule 9), and delivery-run.sh (the Delivery
# doc workflow, cases dr...). Offline by default:
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
# argv, and the token it was given (gh-token.log: the first word is GH_TOKEN). A -F value
# with "@" is what gh would read from a file: it is recorded as a violation and the call
# fails. A --body-file is kept as body-<command>-<subcommand>.md.
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
# One line per call: a GraphQL query has newlines, so its argv is joined before it is logged.
echo "${GH_TOKEN:-none} $(printf '%s ' "$@" | tr '\n' ' ')" >> "$GH_FIXTURES/gh-token.log"
prev=""
for arg in "$@"; do
  if [ "$prev" = --body-file ]; then cp "$arg" "$GH_FIXTURES/body-$1-$2.md"; fi
  prev=$arg
done
# A file named gh-fail-<command>-<subcommand> makes that call fail (qodo-status cases).
if [ -e "$GH_FIXTURES/gh-fail-$1-$2" ]; then echo "gh: simulated failure" >&2; exit 1; fi
# gh-fail-add-assignee makes the --add-assignee edit fail (the delivery run cases).
if [ "$1 $2" = "pr edit" ] && [ -e "$GH_FIXTURES/gh-fail-add-assignee" ]; then
  case " $* " in *" --add-assignee "*) echo "gh: simulated failure" >&2; exit 1 ;; esac
fi
case "$1 $2" in
  "pr view")
    if [ -e "$GH_FIXTURES/pr-${3:-x}.fail" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    fixture=$GH_FIXTURES/pr.json
    if [ -e "$GH_FIXTURES/pr-${3:-x}.json" ]; then fixture=$GH_FIXTURES/pr-$3.json; fi
    # pr-N-view-K.json answers the K-th view of PR N (a re-read that sees the head from before a push).
    c=$(cat "$GH_FIXTURES/pr-${3:-x}-calls" 2>/dev/null || echo 0)
    c=$((c + 1))
    echo "$c" > "$GH_FIXTURES/pr-${3:-x}-calls"
    # pr-N-view-K.fail makes only the K-th view fail (the delivery run's second read of a reused body).
    if [ -e "$GH_FIXTURES/pr-${3:-x}-view-$c.fail" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    if [ -e "$GH_FIXTURES/pr-${3:-x}-view-$c.json" ]; then fixture=$GH_FIXTURES/pr-$3-view-$c.json; fi ;;
  "pr list") fixture=$GH_FIXTURES/prlist.json ;;
  "pr create") fixture=$GH_FIXTURES/pr-create-out.txt ;;
  "pr edit") fixture=/dev/null ;;
  "run list") fixture=$GH_FIXTURES/runs.json ;;
  "run view") fixture=$GH_FIXTURES/run-$3.json ;;
  "api repos/"*"/commits/"*"/pulls")
    # The lookup's n-th call reads pulls-n.json when the case has one, else pulls.json.
    if [ -e "$GH_FIXTURES/gh-fail-commit-pulls" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    n=$(cat "$GH_FIXTURES/pulls-calls" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$GH_FIXTURES/pulls-calls"
    fixture=$GH_FIXTURES/pulls-$n.json
    [ -e "$fixture" ] || fixture=$GH_FIXTURES/pulls.json ;;
  "api repos/"*"/pulls/"*"/files")
    # The PR's changed files (the qodo-gate cases): pr-files.json, a list of {filename, previous_filename};
    # pr-files.fail makes the call fail.
    if [ -e "$GH_FIXTURES/pr-files.fail" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    fixture=$GH_FIXTURES/pr-files.json ;;
  "api repos/"*"/pulls/"*)
    if [ -e "$GH_FIXTURES/gh-fail-pulls" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    # pull-N.json is PR N's pulls read; pull-N.404 and pull-N.500 make it fail (a missing PR, another error).
    num=${2##*/}
    if [ -e "$GH_FIXTURES/pull-$num.404" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -e "$GH_FIXTURES/pull-$num.500" ]; then echo "gh: HTTP 500" >&2; exit 1; fi
    fixture=$GH_FIXTURES/pull.json
    if [ -e "$GH_FIXTURES/pull-$num.json" ]; then fixture=$GH_FIXTURES/pull-$num.json; fi
    # pull-N-read-K.json (or pull-N-read-K.fail) answers the K-th pulls read of PR N in the case (the
    # qodo-gate skipped cases: the changed-file count is read 2nd, the head again 3rd).
    k=$(cat "$GH_FIXTURES/pull-$num-calls" 2>/dev/null || echo 0)
    k=$((k + 1))
    echo "$k" > "$GH_FIXTURES/pull-$num-calls"
    if [ -e "$GH_FIXTURES/pull-$num-read-$k.fail" ]; then echo "gh: simulated failure" >&2; exit 1; fi
    if [ -e "$GH_FIXTURES/pull-$num-read-$k.json" ]; then fixture=$GH_FIXTURES/pull-$num-read-$k.json; fi ;;
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
      *comments\(*)
        # on-comments-read, when a case set it, runs at each comments read (a hook: the doc merging during the wait).
        if [ -x "$GH_FIXTURES/on-comments-read" ]; then "$GH_FIXTURES/on-comments-read"; fi
        # comments-poll-K.json answers the K-th comments read of the run (a Qodo review that settles later).
        k=$(cat "$GH_FIXTURES/comments-calls" 2>/dev/null || echo 0)
        k=$((k + 1))
        echo "$k" > "$GH_FIXTURES/comments-calls"
        fixture=$GH_FIXTURES/comments-poll-$k.json
        [ -e "$fixture" ] || fixture=$GH_FIXTURES/comments-${after:-null}.json ;;
      *userContentEdits*) fixture=$GH_FIXTURES/edits-$id-${after:-first}.json ;;
      *pullRequests\(*)
        # merged-prs.json is the recently merged PRs (delivery run); merged-prs.fail makes the list fail.
        if [ -e "$GH_FIXTURES/merged-prs.fail" ]; then echo "gh: simulated failure" >&2; exit 1; fi
        fixture=$GH_FIXTURES/merged-prs.json ;;
      *) echo "gh stub: unsupported query" >&2; exit 2 ;;
    esac
    ;;
  *) echo "gh stub: unsupported call: $*" >&2; exit 2 ;;
esac
# A fixture with @HEAD@ names this clone's HEAD (the PR's head as the run left it).
if grep -q '@HEAD@' "$fixture" 2>/dev/null; then
  sed "s/@HEAD@/$(git rev-parse HEAD)/" "$fixture" > "$GH_FIXTURES/resolved.json"
  fixture=$GH_FIXTURES/resolved.json
fi
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
# Stub BUILD_SITE: the homepage is whatever site-src holds in this worktree. With GH_FIXTURES set it
# logs the names of any token variable in its environment (build-env.log): the delivery run must not
# pass the PATs or the read token to a build, which runs the merged head's code. The test checks the
# build's environment only; it does not check /proc.
set -euo pipefail
if [ -n "${GH_FIXTURES:-}" ]; then
  : >> "$GH_FIXTURES/build-env.log"
  env | sed -En 's/^(AGENT_[A-Z_]*TOKEN|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)=.*/\1/p' >> "$GH_FIXTURES/build-env.log"
fi
rm -rf _site
cp -R site-src _site
STUB

# git and python3 wrappers (delivery-run cases): each call's argv goes to git.log or python3.log
# (when GH_FIXTURES is set), then the real tool runs. The tests check the push's lease and the
# preview server's bind address.
real_git=$(command -v git)
real_python=$(command -v python3)
sed "s|@REAL@|$real_git|" > "$bin/git" <<'STUB'
#!/usr/bin/env bash
# A push is answered the way git answers its credential prompts: GIT_ASKPASS is asked for the username and
# the password, and askpass.log records both answers (the delivery run cases check the askpass script).
if [ -n "${GH_FIXTURES:-}" ]; then
  echo "$*" >> "$GH_FIXTURES/git.log"
  case " $* " in
    *" push "*)
      if [ -n "${GIT_ASKPASS:-}" ]; then
        u=$("$GIT_ASKPASS" "Username for 'https://github.com': ")
        p=$("$GIT_ASKPASS" "Password for 'https://x-access-token@github.com': ")
        echo "user=$u pass=$p" >> "$GH_FIXTURES/askpass.log"
      fi ;;
  esac
fi
# fail-git-arg (a fixture's text): a git call whose argv holds the text fails, as a simulated failure of that call.
if [ -n "${GH_FIXTURES:-}" ] && [ -e "$GH_FIXTURES/fail-git-arg" ]; then
  case " $* " in
    *"$(cat "$GH_FIXTURES/fail-git-arg")"*) echo "simulated git failure: $*" >&2; exit 1 ;;
  esac
fi
# before-main-push (a fixture's script, run once before a push of the fork's main): the race cases move a ref
# between the run's read and its push. The script runs with no fixtures, so its own git calls are not logged.
if [ -n "${GH_FIXTURES:-}" ] && [ -e "$GH_FIXTURES/before-main-push" ]; then
  case " $* " in
    *" push "*":refs/heads/main "*)
      mv "$GH_FIXTURES/before-main-push" "$GH_FIXTURES/before-main-push.ran"
      GH_FIXTURES= bash "$GH_FIXTURES/before-main-push.ran" ;;
  esac
fi
exec @REAL@ "$@"
STUB
sed "s|@REAL@|$real_python|" > "$bin/python3" <<'STUB'
#!/usr/bin/env bash
[ -z "${GH_FIXTURES:-}" ] || echo "$*" >> "$GH_FIXTURES/python3.log"
exec @REAL@ "$@"
STUB

# check-fail: a DELIVERY_CHECK stub that fails as check-delivery.sh does on a stale doc.
cat > "$bin/check-fail" <<'STUB'
#!/usr/bin/env bash
echo "error: deliveries/2026-11-05-demo-change.md: stale: the doc was generated for other content" >&2
exit 1
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
chmod +x "$bin/gh" "$bin/build-site" "$bin/snapshot" "$bin/date" "$bin/nap" "$bin/git" "$bin/python3"

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
    baseRefName: "main",
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

# skipped_review_for HEAD OUT: PR 148's skipped review (test-fixtures/qodo-skipped-pr148.md), with
# its commit marker set to HEAD, as Qodo's comment for that head.
skipped_review_for() {
  sed "s/e950c4e13abfa7cde39dd3f18f195a8fcc253b95/$1/" "$root/scripts/test-fixtures/qodo-skipped-pr148.md" > "$2"
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

# qos. Qodo's latest review of the head is the skipped layout (PR 148's, judged trivial): the doc
# records skipped and says the head was not reviewed, and the docs check passes with a ::warning
# (AGENTS.md rule 9). No finding is counted as zero here.
pr_case qos other plain
h1=$(head_sha)
skipped_review_for "$h1" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
gen "$CASE"
commit_all "delivery doc"
check "$CASE" "" 1
if [ "$GEN_RC" -eq 0 ] && grep -qF 'qodo-open=skipped -->' "$CASE/$doc_name" \
  && grep -qF "Qodo skipped its final review of the merged head as trivial, so the head was not reviewed." "$CASE/$doc_name" \
  && ! grep -qF "lists no findings." "$CASE/$doc_name" \
  && [ "$CHECK_RC" -eq 0 ] && grep -q '::warning' "$FX/check.log" && grep -q 'skipped its final review' "$FX/check.log"; then
  report "qos. a skipped final review: the doc records skipped and says so; check passes with a warning" 0
else
  report "qos. a skipped final review: the doc records skipped and says so; check passes with a warning" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
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

# del. A docs PR that deletes a delivery doc passes: the deleted doc is not in HEAD, so it is
# skipped and never read.
new_case del
printf 'old\n' > "$CASE/deliveries/2026-10-01-old.md"
commit_all "a doc that is on the base"
git -C "$CASE" rm -q deliveries/2026-10-01-old.md
commit_all "delete a doc"
check "$CASE"
if [ "$CHECK_RC" -eq 0 ] && grep -qF 'docs PR: 0 delivery doc(s) checked' "$FX/check.log" \
  && ! grep -qF '2026-10-01-old.md' "$FX/check.log" && ! grep -qF 'no delivery metadata' "$FX/check.log" \
  && ! grep -qF 'fatal:' "$FX/check.log"; then
  report "del. a docs PR that deletes a delivery doc passes and does not read it" 0
else
  report "del. a docs PR that deletes a delivery doc passes and does not read it" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi

# deladd. A docs PR that deletes one doc and adds a valid one checks only the added doc.
new_case deladd
printf 'old\n' > "$CASE/deliveries/2026-10-01-old.md"
printf 'notes\n' > "$CASE/notes.txt"
commit_all "a change off the homepage, with an old doc"
body_plain > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
fx_runs 101 "$(head_sha)" success success
fx_qodo_clear "$(head_sha)"
gen "$CASE"
git -C "$CASE" rm -q deliveries/2026-10-01-old.md
commit_all "delivery doc"
check "$CASE"
if [ "$GEN_RC" -eq 0 ] && [ "$CHECK_RC" -eq 0 ] && grep -qF 'docs PR: 1 delivery doc(s) checked' "$FX/check.log" \
  && grep -qF "$doc_name: ok" "$FX/check.log" && ! grep -qF '2026-10-01-old.md' "$FX/check.log"; then
  report "deladd. a docs PR that deletes one doc and adds a valid one checks only the added doc" 0
else
  report "deladd. a docs PR that deletes one doc and adds a valid one checks only the added doc" 1 "gen $GEN_RC: $(cat "$FX/gen.log") check $CHECK_RC: $(cat "$FX/check.log")"
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

# cut. The window is exclusive at 2026-12-02T23:00:00Z: a stale doc passes once it has
# ended and fails one second before.
stale_case cut
check "$CASE" 2026-12-02T23:00:00Z
if [ "$CHECK_RC" -eq 0 ] && grep -q 'ended' "$FX/check.log"; then
  report "cut. at 23:00:00Z the check passes without reading the doc" 0
else
  report "cut. at 23:00:00Z the check passes without reading the doc" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
check "$CASE" 2026-12-02T22:59:59Z
if [ "$CHECK_RC" -ne 0 ] && grep -q 'stale' "$FX/check.log"; then
  report "cut. at 22:59:59Z the stale doc fails" 0
else
  report "cut. at 22:59:59Z the stale doc fails" 1 "rc $CHECK_RC: $(cat "$FX/check.log")"
fi
win "$CASE" 2026-12-02T22:59:59Z
w1=$WIN_RC
win "$CASE" 2026-12-02T23:00:00Z
w2=$WIN_RC
if [ "$w1" -eq 0 ] && [ "$w2" -eq 3 ]; then
  report "cut. --window exits 0 open, 3 ended" 0
else
  report "cut. --window exits 0 open, 3 ended" 1 "22:59:59 gave $w1, 23:00:00 gave $w2"
fi

clock=$tmp/clock
mkdir -p "$clock"
printf '#!/bin/sh\necho 2026-12-02T23:00:00Z\n' > "$clock/date"
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

# qs29. Qodo skipped its review of the head as trivial (PR 148's layout): the review names the head
# and is quiet, so it is settled, and open reads skipped, not 0 and not unknown.
pr_case qs29 other plain
qs_setup
h1=$(head_sha)
skipped_review_for "$h1" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
qstat "$CASE" "$qs_now" --pr 24
qs29_want=$(cat <<EOF
head: $h1
review: $qs_review
reviewed: $h1
matches-head: yes
last-change: 2026-11-05T15:50:27Z
quiet: yes (72573s since last change, need 300s)
open: skipped
status: settled
EOF
)
if [ "$QSTAT_RC" -eq 0 ] && qstat_is "$qs29_want"; then
  report "qs29. a skipped review (PR 148's layout) of the head: open skipped, settled, exit 0" 0
else
  report "qs29. a skipped review (PR 148's layout) of the head: open skipped, settled, exit 0" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs30. The skip sentence with a group opener (a Medium badge, with no clear line): the layout is
# not one the parser reads as skipped, so open is unknown, never skipped.
pr_case qs30 other plain
qs_setup
h1=$(head_sha)
skipped_review_for "$h1" "$FX/review-skip.md"
printf '<img src="https://img.shields.io/badge/Medium-634FD1?style=flat-square" height="20px" alt="Remediation recommended">\n' >> "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 0 ] && grep -qxF 'open: unknown' "$FX/qs.out" && ! grep -qxF 'open: skipped' "$FX/qs.out"; then
  report "qs30. the skip sentence with a group opener: open unknown, never skipped" 0
else
  report "qs30. the skip sentence with a group opener: open unknown, never skipped" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
fi

# qs31. The skip sentence with no "No findings to report" heading (the heading half of the skip
# condition): the layout is not one the parser reads as skipped, so open is unknown, never skipped.
pr_case qs31 other plain
qs_setup
h1=$(head_sha)
skipped_review_for "$h1" "$FX/review-skip.md"
sed '/No findings to report/d' "$FX/review-skip.md" > "$FX/review-skip-noheading.md"
fx_qodo "$FX/review-skip-noheading.md"
qstat "$CASE" "$qs_now" --pr 24
if [ "$QSTAT_RC" -eq 0 ] && grep -qxF 'open: unknown' "$FX/qs.out" && grep -qxF 'status: settled' "$FX/qs.out" && ! grep -qxF 'open: skipped' "$FX/qs.out"; then
  report "qs31. the skip sentence with no No-findings heading: open unknown, settled, never skipped" 0
else
  report "qs31. the skip sentence with no No-findings heading: open unknown, settled, never skipped" 1 "rc $QSTAT_RC: $(cat "$FX/qs.out") $(cat "$FX/qs.err")"
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

# fx_pull STATE DRAFT LOGIN [CHANGED]: the PR as the REST API reports it, its head at the case's head,
# and its changed_files (CHANGED, default 1).
fx_pull() {
  jq -n --arg state "$1" --argjson draft "$2" --arg login "$3" --arg sha "$(head_sha)" --argjson changed "${4:-1}" \
    '{state: $state, draft: $draft, user: {login: $login}, head: {sha: $sha}, changed_files: $changed}' > "$FX/pull.json"
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

# g17. Qodo skipped the review as trivial, and the PR changes only files under deliveries/: success,
# saying Qodo skipped the review, with the review as target_url.
pr_case g17 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 2
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}, {"filename": "deliveries/2026-11-05-demo/desktop.png"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g17_want=$(post_line "$(head_sha)" success "Qodo skipped the review as trivial; this docs PR changes only deliveries/ (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g17_want" ]; then
  report "g17. a skipped review on a PR that changes only deliveries/: success, saying so" 0
else
  report "g17. a skipped review on a PR that changes only deliveries/: success, saying so" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g18. Qodo skipped the review and the PR also changes notes.txt: pending, saying Qodo skipped the
# review of this head, not success.
pr_case g18 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 2
printf '%s\n' '[{"filename": "notes.txt"}, {"filename": "deliveries/x.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g18_want=$(post_line "$(head_sha)" pending "Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g18_want" ]; then
  report "g18. a skipped review on a PR that also changes notes.txt: pending, not success" 0
else
  report "g18. a skipped review on a PR that also changes notes.txt: pending, not success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g19. A rename out of deliveries/ (deliveries/x.md, previous_filename scripts/x.sh) counts by its old
# path too: pending, not success.
pr_case g19 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone
printf '%s\n' '[{"filename": "deliveries/x.md", "previous_filename": "scripts/x.sh"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g19_want=$(post_line "$(head_sha)" pending "Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g19_want" ]; then
  report "g19. a rename out of scripts/ into deliveries/: pending, counted by its old path" 0
else
  report "g19. a rename out of scripts/ into deliveries/: pending, counted by its old path" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g20. Qodo skipped the review, and the PR's changed files cannot be read: an error on the head,
# exit 1 (rule 11), both when the call fails and when it returns an empty list.
pr_case g20 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone
g20_want=$(post_line "$(head_sha)" error "Could not list this PR's changed files; see the workflow run")
touch "$FX/pr-files.fail"
gate "$CASE" "$gate_now" --pr 24
g20a_ok=0
if [ "$GATE_RC" -eq 1 ] && [ "$(gate_posts)" = "$g20_want" ]; then g20a_ok=1; fi
rm -f "$FX/pr-files.fail"
printf '[]\n' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
if [ "$g20a_ok" -eq 1 ] && [ "$GATE_RC" -eq 1 ] && [ "$(gate_posts)" = "$g20_want" ]; then
  report "g20. the changed files cannot be read, or are empty: error on the head, exit 1" 0
else
  report "g20. the changed files cannot be read, or are empty: error on the head, exit 1" 1 "a $g20a_ok rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g21. Qodo skipped the review, and the only changed file is deliveries-evil/x.md: pending, not
# success. The docs-PR test is a prefix on deliveries/ with its slash, so a sibling directory does not count.
pr_case g21 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone
printf '%s\n' '[{"filename": "deliveries-evil/x.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g21_want=$(post_line "$(head_sha)" pending "Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g21_want" ]; then
  report "g21. a skipped review on a PR that changes only deliveries-evil/: pending, not success" 0
else
  report "g21. a skipped review on a PR that changes only deliveries-evil/: pending, not success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g22. Qodo skipped the review, the listed files are all docs, but the PR has 3 changed files: the
# list is not known to be whole, so pending, not success (pulls/N/files caps at 3,000 files).
pr_case g22 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 3
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}, {"filename": "deliveries/2026-11-05-demo/desktop.png"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g22_want=$(post_line "$(head_sha)" pending "Qodo skipped the review as trivial and the PR's file list is incomplete; ask Qodo for a review (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g22_want" ]; then
  report "g22. a list with fewer files than changed_files: pending, saying the list is incomplete" 0
else
  report "g22. a list with fewer files than changed_files: pending, saying the list is incomplete" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g23. Qodo skipped the review, and the PR's changed-file count cannot be read (the call fails): an
# error on the head, exit 1 (rule 11), not a success on the list alone.
pr_case g23 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 2
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}, {"filename": "deliveries/2026-11-05-demo/desktop.png"}]' > "$FX/pr-files.json"
touch "$FX/pull-24-read-2.fail"
gate "$CASE" "$gate_now" --pr 24
g23_want=$(post_line "$(head_sha)" error "Could not read this PR's changed-file count; see the workflow run")
if [ "$GATE_RC" -eq 1 ] && [ "$(gate_posts)" = "$g23_want" ]; then
  report "g23. the changed-file count cannot be read: error on the head, exit 1" 0
else
  report "g23. the changed-file count cannot be read: error on the head, exit 1" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g24. A docs file renamed within deliveries/ is one file: its two paths do not make the list look
# longer than the PR's changed_files (1), so success.
pr_case g24 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 1
printf '%s\n' '[{"filename": "deliveries/x.md", "previous_filename": "deliveries/old.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g24_want=$(post_line "$(head_sha)" success "Qodo skipped the review as trivial; this docs PR changes only deliveries/ (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g24_want" ]; then
  report "g24. a docs file renamed within deliveries/ counts once: success" 0
else
  report "g24. a docs file renamed within deliveries/ counts once: success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g25. The PR's head changes between the status's head and the re-read (a push during the checks):
# no status is posted for this run, the line says so, and the gate exits 0 (rule 11).
pr_case g25 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 2
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}, {"filename": "deliveries/2026-11-05-demo/desktop.png"}]' > "$FX/pr-files.json"
jq '.head.sha = "0123456789abcdef0123456789abcdef01234567"' "$FX/pull.json" > "$FX/pull-24-read-3.json"
gate "$CASE" "$gate_now" --pr 24
if [ "$GATE_RC" -eq 0 ] && [ -z "$(gate_posts)" ] && grep -qF 'the head changed during the check' "$FX/gate.out"; then
  report "g25. the head changed during the check: no POST, a line saying so, exit 0" 0
else
  report "g25. the head changed during the check: no POST, a line saying so, exit 0" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.out") $(cat "$FX/gate.err")"
fi

# g26. The head re-read fails: an error on the head, exit 1 (rule 11), not a success on the old head.
pr_case g26 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 2
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}, {"filename": "deliveries/2026-11-05-demo/desktop.png"}]' > "$FX/pr-files.json"
touch "$FX/pull-24-read-3.fail"
gate "$CASE" "$gate_now" --pr 24
g26_want=$(post_line "$(head_sha)" error "Could not read this PR's head; see the workflow run")
if [ "$GATE_RC" -eq 1 ] && [ "$(gate_posts)" = "$g26_want" ]; then
  report "g26. the head re-read fails: error on the head, exit 1" 0
else
  report "g26. the head re-read fails: error on the head, exit 1" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g27. Qodo skipped the review, and the only changed file is deliveries/TEMPLATE.md: pending. The
# template is what every doc is built from, and nothing checks it (AGENTS.md rule 9).
pr_case g27 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 1
printf '%s\n' '[{"filename": "deliveries/TEMPLATE.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g27_want=$(post_line "$(head_sha)" pending "Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g27_want" ]; then
  report "g27. a skipped review on a PR that changes only deliveries/TEMPLATE.md: pending, not success" 0
else
  report "g27. a skipped review on a PR that changes only deliveries/TEMPLATE.md: pending, not success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g28. A doc renamed from deliveries/TEMPLATE.md: the old path counts, so pending, not success.
pr_case g28 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 1
printf '%s\n' '[{"filename": "deliveries/x.md", "previous_filename": "deliveries/TEMPLATE.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g28_want=$(post_line "$(head_sha)" pending "Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g28_want" ]; then
  report "g28. a doc renamed from deliveries/TEMPLATE.md: pending, counted by its old path" 0
else
  report "g28. a doc renamed from deliveries/TEMPLATE.md: pending, counted by its old path" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g29. Qodo skipped the review, the listed files are all docs, but changed_files is not a number (null):
# pending, saying the list is incomplete. A count that cannot be read is not a match (AGENTS.md rules 8 and 11).
pr_case g29 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone null
printf '%s\n' '[{"filename": "deliveries/2026-11-05-demo.md"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g29_want=$(post_line "$(head_sha)" pending "Qodo skipped the review as trivial and the PR's file list is incomplete; ask Qodo for a review (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g29_want" ]; then
  report "g29. a skipped review, docs-only list, changed_files not a number: pending, not success" 0
else
  report "g29. a skipped review, docs-only list, changed_files not a number: pending, not success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
fi

# g30. Qodo skipped the review, and the only changed file is deliveries/TEMPLATE.md.bak (one file, the
# count matches): success. The template rule matches the exact path deliveries/TEMPLATE.md, not a prefix.
pr_case g30 other plain
gate_setup
skipped_review_for "$(head_sha)" "$FX/review-skip.md"
fx_qodo "$FX/review-skip.md"
fx_pull open false someone 1
printf '%s\n' '[{"filename": "deliveries/TEMPLATE.md.bak"}]' > "$FX/pr-files.json"
gate "$CASE" "$gate_now" --pr 24
g30_want=$(post_line "$(head_sha)" success "Qodo skipped the review as trivial; this docs PR changes only deliveries/ (AGENTS.md rule 9)" "$gate_review_url")
if [ "$GATE_RC" -eq 0 ] && [ "$(gate_posts)" = "$g30_want" ]; then
  report "g30. a skipped review on a PR whose only file is deliveries/TEMPLATE.md.bak: success" 0
else
  report "g30. a skipped review on a PR whose only file is deliveries/TEMPLATE.md.bak: success" 1 "rc $GATE_RC: $(gate_posts) $(cat "$FX/gate.err")"
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

# delivery-run.sh (the Delivery doc workflow, AGENTS.md rule 6). Each dr case runs the real script in
# its clone, with the real generator, qodo-status.sh and check-delivery.sh. The stubs stand in for gh,
# the builds and the screenshot; git and python3 are logged and then run for real. The clone's origin
# is a bare repo holding main and the PR's ref at the clone's HEAD; the fork is a bare repo holding main at the
# same HEAD. GH_TOKEN is READ-TOKEN, and the two PATs are FORK-TOKEN and PR-TOKEN: gh-token.log says
# which one each gh call saw.

# dr_up: the clone's origin, a bare repo holding main and refs/pull/24/head at the clone's HEAD, and the fork, a
# bare repo whose main is the same HEAD (so the sync finds it current). Each call resets both.
dr_up() {
  DR_UP="$CASE-up.git"
  DR_FORK="$CASE-fork.git"
  rm -rf "$DR_UP" "$DR_FORK"
  git init -q --bare "$DR_UP"
  git init -q --bare "$DR_FORK"
  git -C "$CASE" remote remove origin 2>/dev/null || true
  git -C "$CASE" remote add origin "$DR_UP"
  git -C "$CASE" push -q -f "$DR_UP" HEAD:refs/heads/main HEAD:refs/pull/24/head
  git -C "$CASE" push -q "$DR_FORK" HEAD:refs/heads/main
}

# fx_pulls FILE SHA NUMBER...: the PRs a commit lookup returns, each merged into main at SHA.
fx_pulls() {
  local file=$1 sha=$2 out='[]' n
  shift 2
  for n in "$@"; do
    out=$(jq -c --argjson n "$n" --arg sha "$sha" \
      '. + [{number: $n, merged_at: "2026-11-06T00:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}}]' <<< "$out")
  done
  printf '%s\n' "$out" > "$FX/$file"
}

# dr_finish: the fixtures and the origin for a run on the clone's HEAD as merged PR 24 (its body is
# $FX/body.md): CI run 101 passing, Qodo's review clear, and the head pushed as main and as the PR's ref.
dr_finish() {
  local head
  unset DR_EVENT DR_PR DR_SHA DR_NOW DR_READ_TOKEN DR_FORK_TOKEN DR_PR_TOKEN DR_SERVE_HOST DR_SLEEP DR_POLLS DR_CHECK
  head=$(head_sha)
  fx_pr "$head" "$FX/body.md"
  fx_runs 101 "$head" success success
  fx_qodo_clear "$head"
  fx_pull open false someone
  fx_pulls pulls.json "$head" 24
  dr_up
  echo '[]' > "$FX/prlist.json"
  echo 'https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' > "$FX/pr-create-out.txt"
  echo '{"state": "OPEN", "headRefOid": "@HEAD@", "body": ""}' > "$FX/pr-104.json"
  cp "$root/scripts/delivery-run.sh" "$root/scripts/qodo-status.sh" "$CASE/scripts/"
  printf 'scripts/delivery-run.sh\nscripts/qodo-status.sh\n' >> "$CASE/.git/info/exclude"
  echo '2026-11-06T12:00:00Z' > "$FX/clock"
  # The recently merged PRs into main: none, so a commit with no PR found by its lookup is a direct push.
  echo '{"data": {"repository": {"pullRequests": {"nodes": []}}}}' > "$FX/merged-prs.json"
}

# dr_case NAME CHANGE BODY: pr_case's clone and PR, then the run's fixtures (dr_finish).
dr_case() {
  pr_case "$1" "$2" "$3"
  dr_finish
}

# dr_run: runs scripts/delivery-run.sh in the case as the workflow runs it: the tokens, SERVE_HOST
# 0.0.0.0, and the window open at NOW. The DR_* variables override these (an empty value is a missing
# token): DR_EVENT (push), DR_PR, DR_SHA (the HEAD), DR_NOW, DR_READ_TOKEN, DR_FORK_TOKEN, DR_PR_TOKEN,
# DR_SERVE_HOST, DR_SLEEP (0), DR_POLLS (40), DR_CHECK (a replacement for check-delivery.sh). Each
# run's logs start empty. Its output goes to $FX/run.log and its status to DR_RC.
dr_run() {
  DR_RC=0
  : > "$FX/gh-calls.log"
  : > "$FX/gh-token.log"
  : > "$FX/git.log"
  : > "$FX/python3.log"
  : > "$FX/build-env.log"
  : > "$FX/askpass.log"
  rm -f "$FX/pulls-calls" "$FX/comments-calls" "$FX"/pr-*-calls
  (cd "$CASE" && env PATH="$bin:$PATH" GH_FIXTURES="$FX" \
    GH_TOKEN="${DR_READ_TOKEN-READ-TOKEN}" AGENT_FORK_TOKEN="${DR_FORK_TOKEN-FORK-TOKEN}" \
    AGENT_PR_TOKEN="${DR_PR_TOKEN-PR-TOKEN}" \
    SERVE_HOST="${DR_SERVE_HOST-0.0.0.0}" \
    NOW="${DR_NOW-$NOW}" DELIVERY_SLEEP="${DR_SLEEP-0}" DELIVERY_QODO_POLLS="${DR_POLLS-40}" \
    DELIVERY_FORK_URL="$DR_FORK" BUILD_SITE="$bin/build-site" SNAPSHOT="$bin/snapshot" \
    ${DR_CHECK:+DELIVERY_CHECK="$DR_CHECK"} \
    bash scripts/delivery-run.sh --event "${DR_EVENT-push}" --sha "${DR_SHA-$(head_sha)}" --pr "${DR_PR-}") \
    > "$FX/run.log" 2>&1 || DR_RC=$?
  return 0
}

# dr_scratch: a clone of the case in $FX/scratch, where the fork's commits are made (W is its path).
dr_scratch() {
  rm -rf "$FX/scratch"
  git clone -q "$CASE" "$FX/scratch"
  W="$FX/scratch"
}

# dr_commit ARGS: a commit in the scratch clone, with a test identity.
dr_commit() { git -C "$W" -c user.name=test -c user.email=t@example.invalid commit -q "$@"; }

# dr_doc23 BRANCH: the fork's BRANCH, one commit above the base, adding PR 23's delivery doc. PR 23's
# head (C23, a commit on the base) is the origin's refs/pull/23/head and is fetched into the case, so the
# check can read it. Sets C23 and FORK_SHA (the branch's commit).
dr_doc23() {
  dr_scratch
  git -C "$W" checkout -q -b pr23 "$BASE"
  printf 'twenty-three\n' > "$W/notes23.txt"
  git -C "$W" add -A
  dr_commit -m "PR 23"
  C23=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q -b "$1" "$BASE"
  local digest
  digest=$(cd "$W" && bash scripts/check-delivery.sh --digest "$C23" deliveries/2026-11-04-p23.md)
  printf '# Delivery 23\n\n**PR:** [#23](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/23) · **Opened:** 2026-11-04\n\n<!-- delivery: content=%s head=%s homepage=none qodo-open=0 -->\n' \
    "$digest" "$C23" > "$W/deliveries/2026-11-04-p23.md"
  git -C "$W" add -A
  dr_commit -m "docs: add the delivery doc for PR #23"
  FORK_SHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" push -q "$DR_FORK" "$1:refs/heads/$1"
  git -C "$W" push -q "$DR_UP" "pr23:refs/pull/23/head"
  git -C "$CASE" fetch -q "$W" "+refs/heads/pr23:refs/scratch/pr23" "+refs/heads/$1:refs/scratch/$1"
}

# dr_reuse BRANCH HEADSHA: the one open docs PR, number 103, on the fork's BRANCH, with its listing and its
# view. Its body has a Hackathon and a Qodo notes section, which the run must carry over.
dr_reuse() {
  printf '[{"number": 103, "headRefName": "%s", "headRepositoryOwner": {"login": "lmilbaum"}, "baseRefName": "main", "files": [{"path": "deliveries/2026-11-04-p23.md"}]}]\n' "$1" > "$FX/prlist.json"
  cat > "$FX/reuse-body.md" <<'BODY'
## Acceptance criteria

No linked issue.

## Why

An older body.

## Hackathon

Day 4: Demo (https://github.com/orgs/qodo-hackathon/discussions/10)

## Qodo notes

Kept note: the screenshot point was fair.
BODY
  jq -n --arg head "$2" --rawfile body "$FX/reuse-body.md" '{state: "OPEN", headRefOid: $head, body: $body}' > "$FX/pr-103.json"
}

# body_has FILE LINE...: each LINE is a line of FILE.
body_has() {
  local f=$1 l
  shift
  for l in "$@"; do
    grep -qxF -- "$l" "$f" || return 1
  done
}

# fork_has BRANCH: the fork has BRANCH.
fork_has() { git -C "$DR_FORK" rev-parse -q --verify "refs/heads/$1" >/dev/null 2>&1; }

# pushed_to_fork: the run's git calls include a push.
pushed_to_fork() { grep -qF -- ' push ' "$FX/git.log"; }

# dr_fork_behind: the fork's main is the case's base, one commit behind upstream's main (the clone's HEAD), so the
# push's sync must fast-forward it.
dr_fork_behind() { git -C "$DR_FORK" update-ref refs/heads/main "$BASE"; }

# fork_main_is SHA: the fork's main is SHA.
fork_main_is() { [ "$(git -C "$DR_FORK" rev-parse refs/heads/main)" = "$1" ]; }

# main_pushed: the run pushed the fork's main (the sync's push of upstream's main).
main_pushed() { grep -qE -- ' push .*:refs/heads/main$' "$FX/git.log"; }

# askpass_fork_only N: the run made N pushes, and git's askpass was answered with the fork token for each (the
# fork token reaches git only through askpass, and only on a push).
askpass_fork_only() {
  [ "$(wc -l < "$FX/askpass.log" | tr -d ' ')" = "$1" ] \
    && [ "$(grep -cxF 'user=x-access-token pass=FORK-TOKEN' "$FX/askpass.log")" = "$1" ]
}

# no_writes: the run made no PR write (pr edit, pr create) and no push to the fork (of the docs branch or the fork's
# main). A skip path must make neither.
no_writes() { ! grep -qF -- 'pr edit' "$FX/gh-calls.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! pushed_to_fork; }

# token_ok: every gh call saw READ-TOKEN, except the PR writes (pr create and pr edit), which saw PR-TOKEN; no gh call
# has a -X method (a write). The run made at least one PR write.
token_ok() {
  awk '
    { t = $1; $1 = ""; w = ($0 ~ / pr (create|edit) /) }
    / -X / { bad = 1 }
    w { writes++; if (t != "PR-TOKEN") bad = 1; next }
    { if (t != "READ-TOKEN") bad = 1 }
    END { exit (bad || writes == 0) ? 1 : 0 }' "$FX/gh-token.log"
}

# dr_fork_refuses_main: the fork refuses a push of its main (a pre-receive hook: a stand-in for GitHub's refusal,
# not GitHub's wording).
dr_fork_refuses_main() {
  cat > "$DR_FORK/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
  if [ "$ref" = refs/heads/main ]; then echo "simulated refusal of refs/heads/main" >&2; exit 1; fi
done
exit 0
HOOK
  chmod +x "$DR_FORK/hooks/pre-receive"
}

# dr_fork_main_deletes: after the fork accepts a push of its main, the main is deleted (a post-receive hook), so the
# run's re-read of the fork's main fails.
dr_fork_main_deletes() {
  cat > "$DR_FORK/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
while read -r old new ref; do
  if [ "\$ref" = refs/heads/main ]; then git --git-dir='$DR_FORK' update-ref -d refs/heads/main; fi
done
HOOK
  chmod +x "$DR_FORK/hooks/post-receive"
}

# dr_fork_main_rewinds BASE: after the fork accepts a push of its main, the main goes back to BASE (a post-receive
# hook), so the run's confirm finds the fork's main unlike upstream's.
dr_fork_main_rewinds() {
  cat > "$DR_FORK/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
while read -r old new ref; do
  if [ "\$ref" = refs/heads/main ]; then git --git-dir='$DR_FORK' update-ref refs/heads/main '$1'; fi
done
HOOK
  chmod +x "$DR_FORK/hooks/post-receive"
}

# dr_detail: a failed case's status and the end of the run's log.
dr_detail() { echo "rc $DR_RC: $(tail -n 4 "$FX/run.log" | tr '\n' ' ')"; }

# The delivery run's section list, in the template's order (AGENTS.md rule 6 and the PR template).
dr_sections=('## Acceptance criteria' 'No linked issue.' '## Why' '## How' '## What'
  '## Assistance and third-party material' '## Limitations' '## Hackathon' '## Qodo notes')

# dr1. A merged code PR and no docs PR open: the doc is made and checked, committed to a new branch on the
# fork as the owner (no trailer), and the docs PR is opened with the PR token, assigned to the owner, with
# the template's sections and no footer.
dr_case dr1 other plain
dr_run
if [ "$DR_RC" -eq 0 ] \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && grep -qF "$doc_name is current" "$FX/run.log" \
  && grep -qF 'docs PR: 1 delivery doc(s) checked' "$FX/run.log" \
  && grep -qF -- 'pr create --repo lioramilbaum/lioramilbaum.github.io --base main --head lmilbaum:docs/delivery-pr-24 --assignee lmilbaum --title docs: add the delivery doc for PR #24' "$FX/gh-calls.log" \
  && grep -qF -- 'pr edit 104 --repo lioramilbaum/lioramilbaum.github.io --add-assignee lmilbaum' "$FX/gh-calls.log" \
  && [ "$(git -C "$DR_FORK" log -1 --format='%an <%ae>|%s' refs/heads/docs/delivery-pr-24)" = 'Liora Milbaum <7271026+lmilbaum@users.noreply.github.com>|docs: add the delivery doc for PR #24' ] \
  && ! git -C "$DR_FORK" log -1 --format=%B refs/heads/docs/delivery-pr-24 | grep -qi 'co-authored-by' \
  && git -C "$DR_FORK" show --name-only --format= refs/heads/docs/delivery-pr-24 | grep -qxF "$doc_name" \
  && body_has "$FX/body-pr-create.md" "${dr_sections[@]}" \
  && ! grep -qF 'Generated with' "$FX/body-pr-create.md" \
  && grep -qF -- 'push --quiet -u ' "$FX/git.log" \
  && grep -qF -- '--limit 1000' "$FX/gh-calls.log" \
  && token_ok; then
  report "dr1. a new docs PR: created with the PR token, assigned, checked, the owner's commit and body" 0
else
  report "dr1. a new docs PR: created with the PR token, assigned, checked, the owner's commit and body" 1 "$(dr_detail)"
fi

# dr2. An open docs PR for PR 23 on the fork: its one commit is rebased onto main and amended with PR 24's
# doc. The commit, the title and the body name both PRs; the body keeps its Hackathon and Qodo notes; the
# push is leased to the commit the run started from; and the fork has one commit above main.
dr_case dr2 other plain
dr_doc23 docs/delivery-pr-23
start_sha=$FORK_SHA
pr_head=$(head_sha)
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -eq 0 ] \
  && [ "$(git -C "$DR_FORK" rev-list --count "$pr_head..refs/heads/docs/delivery-pr-23")" = 1 ] \
  && [ "$(git -C "$DR_FORK" rev-parse 'refs/heads/docs/delivery-pr-23^')" = "$pr_head" ] \
  && [ "$(git -C "$DR_FORK" log -1 --format=%s refs/heads/docs/delivery-pr-23)" = 'docs: add the delivery docs for PRs #23 and #24' ] \
  && git -C "$DR_FORK" show --name-only --format= refs/heads/docs/delivery-pr-23 | grep -qxF "$doc_name" \
  && git -C "$DR_FORK" show --name-only --format= refs/heads/docs/delivery-pr-23 | grep -qxF deliveries/2026-11-04-p23.md \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --title docs: add the delivery docs for PRs #23 and #24 --body-file' "$FX/gh-calls.log" \
  && grep -qF 'Kept note: the screenshot point was fair.' "$FX/body-pr-edit.md" \
  && grep -qF 'Day 4: Demo' "$FX/body-pr-edit.md" \
  && grep -qF -- "--force-with-lease=refs/heads/docs/delivery-pr-23:$start_sha" "$FX/git.log" \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --add-assignee lmilbaum' "$FX/gh-calls.log" \
  && grep -qF 'docs PR: 2 delivery doc(s) checked' "$FX/run.log" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/103' "$FX/run.log" \
  && token_ok; then
  report "dr2. a reused docs PR: one amended commit rebased on main, both PRs named, notes kept, lease on the start commit" 0
else
  report "dr2. a reused docs PR: one amended commit rebased on main, both PRs named, notes kept, lease on the start commit" 1 "$(dr_detail)"
fi

# dr3. The docs PR already holds PR 24's doc, byte for byte as the run regenerates it: nothing is committed or
# pushed, the title and body are left alone, and the owner is still assigned.
dr_case dr3 other plain
gen "$CASE"
gen_ok=$GEN_RC
cp "$CASE/$doc_name" "$FX/doc24.md"
rm -rf "$CASE/$doc_name" "$CASE/deliveries/$stem"
dr_doc23 docs/delivery-pr-23
cp "$FX/doc24.md" "$W/$doc_name"
git -C "$W" add -A
dr_commit --amend --no-edit
git -C "$W" push -q -f "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
FORK_SHA=$(git -C "$W" rev-parse HEAD)
git -C "$CASE" fetch -q "$W" "+refs/heads/docs/delivery-pr-23:refs/scratch/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 "$FORK_SHA"
dr_run
if [ "$gen_ok" -eq 0 ] && [ "$DR_RC" -eq 0 ] \
  && grep -qF 'no change: the doc for PR #24 is already current on docs/delivery-pr-23; the docs PR'\''s base is not refreshed' "$FX/run.log" \
  && [ "$(git -C "$DR_FORK" rev-parse refs/heads/docs/delivery-pr-23)" = "$FORK_SHA" ] \
  && ! pushed_to_fork \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --title docs: add the delivery docs for PRs #23 and #24 --body-file' "$FX/gh-calls.log" \
  && grep -qF 'Kept note: the screenshot point was fair.' "$FX/body-pr-edit.md" \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --add-assignee lmilbaum' "$FX/gh-calls.log" \
  && token_ok; then
  report "dr3. a byte-identical regeneration of a reused docs PR: no commit, no push, still assigned" 0
else
  report "dr3. a byte-identical regeneration of a reused docs PR: no commit, no push, still assigned" 1 "gen $gen_ok; $(dr_detail)"
fi

# dr4. A Renovate PR is skipped, and the log says why.
dr_case dr4 other plain
dr_fork_behind
fx_pull closed false 'renovate[bot]'
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && fork_main_is "$BASE" && grep -qF 'skipped: PR #24 is a Renovate PR (exempt, AGENTS.md rule 6)' "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! pushed_to_fork; then
  report "dr4. a Renovate PR is skipped: exit 0, the reason logged, no push and no PR" 0
else
  report "dr4. a Renovate PR is skipped: exit 0, the reason logged, no push and no PR" 1 "$(dr_detail)"
fi

# dr5. A PR whose every changed path is under deliveries/ is a docs PR: skipped, on a manual dispatch too.
new_case dr5
printf 'a docs change\n' > "$CASE/deliveries/2026-11-05-docs-only.md"
commit_all "a docs PR"
body_plain > "$FX/body.md"
dr_finish
dr_fork_behind
DR_EVENT=workflow_dispatch
DR_PR=24
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && fork_main_is "$BASE" && grep -qF 'skipped: PR #24 is a docs PR' "$FX/run.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" \
  && ! pushed_to_fork; then
  report "dr5. a docs PR is skipped (every changed path under deliveries/): exit 0, the reason logged" 0
else
  report "dr5. a docs PR is skipped (every changed path under deliveries/): exit 0, the reason logged" 1 "$(dr_detail)"
fi

# dr6. A push whose commit merged no PR (a direct push): both lookups are empty, so the run retries once and
# then skips, with the reason logged.
dr_case dr6 other plain
dr_fork_behind
echo '[]' > "$FX/pulls.json"
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && fork_main_is "$BASE" && grep -qF 'skipped: no merged PR has merge commit' "$FX/run.log" \
  && grep -qF 'a direct push' "$FX/run.log" && [ "$(grep -cF 'commits/' "$FX/gh-calls.log")" = 4 ] \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr6. a direct push: the lookup retried once, both empty, skipped with the reason" 0
else
  report "dr6. a direct push: the lookup retried once, both empty, skipped with the reason" 1 "$(dr_detail)"
fi

# dr6b. The lookup counts only PRs merged into main: a PR merged into another branch, and an unmerged one
# that names the commit, are not the commit's PR, so the push is a direct one.
dr_case dr6b other plain
dr_fork_behind
h=$(head_sha)
printf '[{"number": 24, "merged_at": "2026-11-06T00:00:00Z", "merge_commit_sha": "%s", "base": {"ref": "release"}}, {"number": 25, "merged_at": null, "merge_commit_sha": "%s", "base": {"ref": "main"}}]\n' "$h" "$h" > "$FX/pulls.json"
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && fork_main_is "$BASE" && grep -qF 'a direct push' "$FX/run.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr6b. the lookup ignores a PR merged into another branch and an unmerged one" 0
else
  report "dr6b. the lookup ignores a PR merged into another branch and an unmerged one" 1 "$(dr_detail)"
fi

# dr7. After the window ends, the run skips before it reads anything from GitHub.
dr_case dr7 other plain
dr_fork_behind
DR_NOW=2026-12-02T23:00:00Z
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && fork_main_is "$BASE" && grep -qF 'skipped: the delivery window ended at 2026-12-02T23:00:00Z' "$FX/run.log" \
  && [ ! -s "$FX/gh-calls.log" ]; then
  report "dr7. after the window ends: exit 0, the reason logged, no GitHub call" 0
else
  report "dr7. after the window ends: exit 0, the reason logged, no GitHub call" 1 "$(dr_detail)"
fi

# dr8. The doc is already on main (the regeneration of an existing doc): skipped, nothing is made or pushed.
dr_case dr8 other plain
h24=$(head_sha)
gen "$CASE"
gen_ok=$GEN_RC
commit_all "the delivery doc for PR 24, on main"
git -C "$CASE" push -q -f "$DR_UP" HEAD:refs/heads/main
DR_SHA=$h24
dr_fork_behind
dr_run
if [ "$gen_ok" -eq 0 ] && no_writes && fork_main_is "$BASE" && [ "$DR_RC" -eq 0 ] && grep -qF "skipped: $doc_name is already on main" "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! pushed_to_fork; then
  report "dr8. a doc already on main is skipped: nothing made, nothing pushed" 0
else
  report "dr8. a doc already on main is skipped: nothing made, nothing pushed" 1 "gen $gen_ok; $(dr_detail)"
fi

# dr9. The lookup's first try finds nothing and its retry finds PR 24: the run goes on and opens the docs PR.
dr_case dr9 other plain
echo '[]' > "$FX/pulls-1.json"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && [ "$(grep -cF 'commits/' "$FX/gh-calls.log")" = 2 ]; then
  report "dr9. the lookup retry finds the PR on the second try and the run goes on" 0
else
  report "dr9. the lookup retry finds the PR on the second try and the run goes on" 1 "$(dr_detail)"
fi

# dr10. The commit lookup fails: the run fails, names it, and opens nothing.
dr_case dr10 other plain
touch "$FX/gh-fail-commit-pulls"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not list the PRs of commit' "$FX/run.log" && ! pushed_to_fork; then
  report "dr10. the commit lookup fails: red, named, nothing pushed" 0
else
  report "dr10. the commit lookup fails: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr11. The commit matches two merged PRs: the run cannot tell which one, so it fails.
dr_case dr11 other plain
fx_pulls pulls.json "$(head_sha)" 24 25
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF '2 merged PRs have merge commit' "$FX/run.log" && ! pushed_to_fork; then
  report "dr11. two merged PRs for one commit: red, named" 0
else
  report "dr11. two merged PRs for one commit: red, named" 1 "$(dr_detail)"
fi

# dr12. A manual run for a PR that is not merged: red, named, nothing pushed.
dr_case dr12 other plain
PR_STATE=OPEN
PR_MERGED_AT=
fx_pr "$(head_sha)" "$FX/body.md"
unset PR_STATE PR_MERGED_AT
DR_EVENT=workflow_dispatch
DR_PR=24
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'PR #24 is not merged (its state is OPEN)' "$FX/run.log" && ! pushed_to_fork; then
  report "dr12. a dispatch of an unmerged PR: red, named" 0
else
  report "dr12. a dispatch of an unmerged PR: red, named" 1 "$(dr_detail)"
fi

# dr13. A PR that changes no files has no doc to make: red, named.
new_case dr13
commit_all "an empty change"
body_plain > "$FX/body.md"
dr_finish
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'PR #24 changes no files' "$FX/run.log" && ! pushed_to_fork; then
  report "dr13. a PR with an empty diff: red, named" 0
else
  report "dr13. a PR with an empty diff: red, named" 1 "$(dr_detail)"
fi

# dr14. Qodo's review names the head but was edited a minute ago: still waiting after the polls, so red.
dr_case dr14 other plain
fx_qodo_clear "$(head_sha)"
fx_qodo_edited_at 2026-11-06T11:59:00Z
DR_POLLS=2
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'did not settle after 2 polls: still waiting' "$FX/run.log" && ! pushed_to_fork; then
  report "dr14. Qodo still waiting after the polls: red, named, nothing pushed" 0
else
  report "dr14. Qodo still waiting after the polls: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr15. qodo-status.sh cannot read Qodo's review (exit 1): red, with its message.
dr_case dr15 other plain
touch "$FX/gh-fail-api-graphql"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'scripts/qodo-status.sh failed (exit 1)' "$FX/run.log" && ! pushed_to_fork; then
  report "dr15. qodo-status.sh exits 1: red, with its message" 0
else
  report "dr15. qodo-status.sh exits 1: red, with its message" 1 "$(dr_detail)"
fi

# dr16. The PR description has no ## Why: the generator refuses, the run is red, and nothing is pushed or
# opened.
dr_case dr16 other plain
printf '## How\n\nNo why here.\n\n## What\n\nx\n\n## Assistance and third-party material\n\ny\n\n## Limitations\n\nz\n' > "$FX/body.md"
fx_pr "$(head_sha)" "$FX/body.md"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "has no '## Why' section" "$FX/run.log" && ! fork_has docs/delivery-pr-24 \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr16. the generator fails (no ## Why): red, its message, nothing pushed or opened" 0
else
  report "dr16. the generator fails (no ## Why): red, its message, nothing pushed or opened" 1 "$(dr_detail)"
fi

# dr17. Qodo's final review has no finding the generator can parse (qodo-open unknown): nothing is committed.
dr_case dr17 other plain
printf '<h3>Code Review by Qodo</h3>\n\n<p>Qodo finished a pass on this change.</p>\n\n<!-- qodo-self-review-slot -->\n<!-- https://github.com/lioramilbaum/lioramilbaum.github.io/commit/%s -->\n' "$(head_sha)" > "$FX/ag.md"
fx_qodo "$FX/ag.md"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'records qodo-open unknown' "$FX/run.log" && ! fork_has docs/delivery-pr-24 \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr17. qodo-open unknown: red, nothing committed or pushed" 0
else
  report "dr17. qodo-open unknown: red, nothing committed or pushed" 1 "$(dr_detail)"
fi

# dr17b. Qodo skipped the final review as trivial (qodo-open skipped): not an error. The run goes on,
# warns that the head was not reviewed, and the docs PR records skipped.
dr_case dr17b other plain
skipped_review_for "$(head_sha)" "$FX/ag.md"
fx_qodo "$FX/ag.md"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF '::warning::PR #24' "$FX/run.log" \
  && grep -qF 'final Qodo review was skipped as trivial, so the head was not reviewed' "$FX/run.log" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && git -C "$DR_FORK" show "refs/heads/docs/delivery-pr-24:$doc_name" | grep -qF 'qodo-open=skipped -->'; then
  report "dr17b. qodo-open skipped: the run warns, goes on, and the docs PR records skipped" 0
else
  report "dr17b. qodo-open skipped: the run warns, goes on, and the docs PR records skipped" 1 "$(dr_detail)"
fi

# dr18. The generator (or anything else) leaves a file outside the doc and its screenshot directory: red.
dr_case dr18 other plain
printf 'stray\n' > "$CASE/stray.txt"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'changed files outside deliveries/' "$FX/run.log" && grep -qF 'stray.txt' "$FX/run.log" \
  && ! fork_has docs/delivery-pr-24; then
  report "dr18. a stray file outside the doc: red, named, nothing pushed" 0
else
  report "dr18. a stray file outside the doc: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr19. Two open docs PRs: the run cannot tell which one to add to, so it fails.
dr_case dr19 other plain
printf '[{"number": 103, "headRefName": "docs/delivery-pr-23", "headRepositoryOwner": {"login": "lmilbaum"}, "baseRefName": "main", "files": [{"path": "deliveries/a.md"}]}, {"number": 105, "headRefName": "docs/delivery-pr-22", "headRepositoryOwner": {"login": "lmilbaum"}, "baseRefName": "main", "files": [{"path": "deliveries/b.md"}]}]\n' > "$FX/prlist.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF '2 open docs PRs' "$FX/run.log" && ! pushed_to_fork; then
  report "dr19. two open docs PRs: red, named" 0
else
  report "dr19. two open docs PRs: red, named" 1 "$(dr_detail)"
fi

# dr20. The reused docs PR's branch has two commits: red, nothing pushed.
dr_case dr20 other plain
dr_doc23 docs/delivery-pr-23
printf 'extra\n' > "$W/deliveries/2026-11-04-extra.md"
git -C "$W" add -A
dr_commit -m "a second commit"
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'has 2 commits above main' "$FX/run.log" && ! pushed_to_fork; then
  report "dr20. a reused branch with two commits: red, named, nothing pushed" 0
else
  report "dr20. a reused branch with two commits: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr21. The reused branch's one commit changes a file outside deliveries/ (the listing said it was a docs PR):
# red, named.
dr_case dr21 other plain
dr_scratch
git -C "$W" checkout -q -b docs/delivery-pr-23 "$BASE"
printf 'outside\n' > "$W/outside.txt"
printf '# Delivery 23\n' > "$W/deliveries/2026-11-04-p23.md"
git -C "$W" add -A
dr_commit -m "a mixed commit"
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'changes files outside deliveries/: outside.txt' "$FX/run.log" && ! pushed_to_fork; then
  report "dr21. a reused branch that changes a file outside deliveries/: red, named" 0
else
  report "dr21. a reused branch that changes a file outside deliveries/: red, named" 1 "$(dr_detail)"
fi

# dr22. The reused branch's commit adds a doc that main also adds, differently: the rebase conflicts. Red,
# nothing pushed.
pr_case dr22 other plain
printf 'main version\n' > "$CASE/deliveries/2026-11-05-clash.md"
commit_all "main adds a clashing doc"
dr_finish
dr_scratch
git -C "$W" checkout -q -b docs/delivery-pr-23 "$BASE"
printf 'fork version\n' > "$W/deliveries/2026-11-05-clash.md"
git -C "$W" add -A
dr_commit -m "a clashing doc"
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'conflicts; nothing is pushed' "$FX/run.log" && ! pushed_to_fork; then
  report "dr22. the rebase onto main conflicts: red, nothing pushed" 0
else
  report "dr22. the rebase onto main conflicts: red, nothing pushed" 1 "$(dr_detail)"
fi

# dr23. The check of the new commit fails (a replacement check stands in): red, and nothing is pushed.
dr_case dr23 other plain
DR_CHECK="$bin/check-fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'the check of the new commit failed; nothing is pushed' "$FX/run.log" \
  && ! pushed_to_fork && ! fork_has docs/delivery-pr-24; then
  report "dr23. the check of the new commit fails: red, nothing pushed" 0
else
  report "dr23. the check of the new commit fails: red, nothing pushed" 1 "$(dr_detail)"
fi

# dr24. The fork cannot be read (it does not exist): the read of its branch fails first, so the run is red,
# names the read, and opens no PR.
dr_case dr24 other plain
DR_FORK="$tmp/no-such-fork.git"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read docs/delivery-pr-24 on the fork' "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr24. the fork cannot be read (no such fork): red, named, no PR opened" 0
else
  report "dr24. the fork cannot be read (no such fork): red, named, no PR opened" 1 "$(dr_detail)"
fi

# dr25. gh pr create fails: red, named.
dr_case dr25 other plain
touch "$FX/gh-fail-pr-create"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not open the docs PR' "$FX/run.log"; then
  report "dr25. gh pr create fails: red, named" 0
else
  report "dr25. gh pr create fails: red, named" 1 "$(dr_detail)"
fi

# dr26. The docs PR opens, but its assignee edit fails: red, named.
dr_case dr26 other plain
touch "$FX/gh-fail-add-assignee"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not assign lmilbaum to docs PR #104' "$FX/run.log"; then
  report "dr26. the assignee edit fails: red, named" 0
else
  report "dr26. the assignee edit fails: red, named" 1 "$(dr_detail)"
fi

# dr27. After the push the docs PR is not OPEN: red, named.
dr_case dr27 other plain
printf '{"state": "CLOSED", "headRefOid": "@HEAD@", "body": ""}\n' > "$FX/pr-104.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'docs PR #104 is CLOSED at' "$FX/run.log" \
  && grep -qF 'not OPEN at the pushed commit' "$FX/run.log"; then
  report "dr27. the docs PR is not open after the push: red, named" 0
else
  report "dr27. the docs PR is not open after the push: red, named" 1 "$(dr_detail)"
fi

# dr28. The PR token is missing: red, before anything is pushed.
dr_case dr28 other plain
DR_PR_TOKEN=
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'AGENT_PR_TOKEN is not set' "$FX/run.log" && ! pushed_to_fork \
  && ! fork_has docs/delivery-pr-24; then
  report "dr28. a missing token: red, named, nothing pushed" 0
else
  report "dr28. a missing token: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr29. Qodo's review names other content (stale) on every poll: the run is red after the polls, names the stale
# state and the exit code, and nothing is pushed or opened.
dr_case dr29 other plain
fx_qodo_clear "$BASE"
DR_POLLS=2
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'did not settle after 2 polls: stale' "$FX/run.log" \
  && grep -qF 'scripts/qodo-status.sh exit 3' "$FX/run.log" && ! pushed_to_fork && ! fork_has docs/delivery-pr-24 \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr29. Qodo's review stays stale: red after the polls, named (exit 3), nothing pushed" 0
else
  report "dr29. Qodo's review stays stale: red after the polls, named (exit 3), nothing pushed" 1 "$(dr_detail)"
fi

# dr30. Qodo has no review of the head on every poll: red after the polls, named (exit 4), nothing pushed.
dr_case dr30 other plain
fx_qodo_none
DR_POLLS=2
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'did not settle after 2 polls: no review' "$FX/run.log" \
  && grep -qF 'scripts/qodo-status.sh exit 4' "$FX/run.log" && ! pushed_to_fork \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr30. no Qodo review on every poll: red after the polls, named (exit 4), nothing pushed" 0
else
  report "dr30. no Qodo review on every poll: red after the polls, named (exit 4), nothing pushed" 1 "$(dr_detail)"
fi

# dr43. A stale review on the first poll that settles on the second: the run waits and continues, and the doc
# records no open findings (no Limitations line for qodo-open).
dr_case dr43 other plain
fx_qodo_clear "$BASE"
cp "$FX/comments-null.json" "$FX/comments-poll-1.json"
fx_qodo_clear "$(head_sha)"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && ! grep -qF 'qodo-open is' "$FX/body-pr-create.md" && ! grep -qF '::warning::' "$FX/run.log"; then
  report "dr43. a stale Qodo review on the first poll, settled on the second: the run continues" 0
else
  report "dr43. a stale Qodo review on the first poll, settled on the second: the run continues" 1 "$(dr_detail)"
fi

# dr31. Qodo lists two open findings on the head: the run continues, warns, and names the count in the Limitations.
dr_case dr31 other plain
review_body "$(head_sha)" medium 'u-1|First finding|🐞 Bug' 'u-2|Second finding|🐞 Bug' > "$FX/r.md"
fx_qodo "$FX/r.md"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF '::warning::' "$FX/run.log" && grep -qF 'qodo-open is 2.' "$FX/body-pr-create.md" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log"; then
  report "dr31. two open findings: a warning, qodo-open 2 in the Limitations, the PR opened" 0
else
  report "dr31. two open findings: a warning, qodo-open 2 in the Limitations, the PR opened" 1 "$(dr_detail)"
fi

# dr32. Tokens: each gh call sees the read token except the PR writes (pr create, pr edit), which see the PR token. The
# two pushes (the docs branch and the fork's main) are answered with the fork token by askpass, and nothing else pushes.
dr_case dr32 other plain
dr_fork_behind
dr_run
if [ "$DR_RC" -eq 0 ] && main_pushed && [ "$(grep -c ' push ' "$FX/git.log")" = 2 ] && askpass_fork_only 2 && token_ok \
  && [ -e "$FX/build-env.log" ] && [ ! -s "$FX/build-env.log" ]; then
  report "dr32. the fork token answers both pushes (docs branch and fork main); the PR token only on pr create and pr edit; no PAT in the builds" 0
else
  report "dr32. the fork token answers both pushes (docs branch and fork main); the PR token only on pr create and pr edit; no PAT in the builds" 1 "$(dr_detail); builds: $(cat "$FX/build-env.log" 2>/dev/null)"
fi

# dr33. The workflow's SERVE_HOST=0.0.0.0 reaches the head build's preview server (a homepage change, so a
# screenshot is taken).
dr_case dr33 home plain
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF -- '--bind 0.0.0.0' "$FX/python3.log"; then
  report "dr33. SERVE_HOST=0.0.0.0 binds the preview server to every interface" 0
else
  report "dr33. SERVE_HOST=0.0.0.0 binds the preview server to every interface" 1 "$(dr_detail); python3: $(cat "$FX/python3.log" 2>/dev/null)"
fi

# dr34. The generator without SERVE_HOST binds the preview server to 127.0.0.1.
pr_case dr34 home plain
fx_qodo_clear "$(head_sha)"
unset SERVE_HOST
gen "$CASE"
if [ "$GEN_RC" -eq 0 ] && grep -qF -- '--bind 127.0.0.1' "$FX/python3.log"; then
  report "dr34. the generator's default bind is 127.0.0.1" 0
else
  report "dr34. the generator's default bind is 127.0.0.1" 1 "rc $GEN_RC: $(tail -n 2 "$FX/gen.log" | tr '\n' ' ')"
fi

# dr35. A SERVE_HOST that is neither 127.0.0.1 nor 0.0.0.0 stops the generator before it reads anything.
pr_case dr35 home plain
fx_qodo_clear "$(head_sha)"
export SERVE_HOST=1.2.3.4
gen "$CASE"
unset SERVE_HOST
if [ "$GEN_RC" -ne 0 ] && grep -qF 'SERVE_HOST must be 127.0.0.1 or 0.0.0.0' "$FX/gen.log"; then
  report "dr35. SERVE_HOST other than 127.0.0.1 or 0.0.0.0 dies with its message" 0
else
  report "dr35. SERVE_HOST other than 127.0.0.1 or 0.0.0.0 dies with its message" 1 "rc $GEN_RC: $(tail -n 2 "$FX/gen.log" | tr '\n' ' ')"
fi

# dr36. A manual run for a merged PR with no docs PR open: the same as a push, with the PR number given.
dr_case dr36 other plain
DR_EVENT=workflow_dispatch
DR_PR=24
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr36. a manual run for a merged PR opens the docs PR" 0
else
  report "dr36. a manual run for a merged PR opens the docs PR" 1 "$(dr_detail)"
fi

# dr37. The fork already has docs/delivery-pr-24 from an earlier run (its PR failed, or a closed docs PR left
# it): the push replaces that branch under a lease on the SHA the fork had, and the docs PR is opened.
dr_case dr37 other plain
dr_scratch
git -C "$W" checkout -q -b docs/delivery-pr-24 "$BASE"
printf 'an earlier run\n' > "$W/deliveries/2026-11-04-earlier.md"
git -C "$W" add -A
dr_commit -m "an earlier run's commit"
old_sha=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-24:refs/heads/docs/delivery-pr-24"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF -- "--force-with-lease=refs/heads/docs/delivery-pr-24:$old_sha" "$FX/git.log" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && grep -qF -- 'pr create --repo lioramilbaum/lioramilbaum.github.io --base main --head lmilbaum:docs/delivery-pr-24' "$FX/gh-calls.log" \
  && [ "$(git -C "$DR_FORK" log -1 --format=%s refs/heads/docs/delivery-pr-24)" = 'docs: add the delivery doc for PR #24' ] \
  && token_ok; then
  report "dr37. the fork already has the branch: replaced under a lease on its SHA, the docs PR opened" 0
else
  report "dr37. the fork already has the branch: replaced under a lease on its SHA, the docs PR opened" 1 "$(dr_detail)"
fi

# dr38. The fork can be read but not written (read-only): the branch is read, the push fails, the run is red,
# names the push, and opens no PR.
dr_case dr38 other plain
chmod -R a-w "$DR_FORK"
dr_run
chmod -R u+w "$DR_FORK"
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not push docs/delivery-pr-24 to the fork' "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr38. the push to a read-only fork fails: red, named, no PR opened" 0
else
  report "dr38. the push to a read-only fork fails: red, named, no PR opened" 1 "$(dr_detail)"
fi

# dr39. The askpass script answers git's two prompts for the push: the username x-access-token, and the fork
# token as the password. The git wrapper asks the script as git does, and askpass.log records the answers.
dr_case dr39 other plain
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qxF 'user=x-access-token pass=FORK-TOKEN' "$FX/askpass.log"; then
  report "dr39. the askpass script gives the push x-access-token and the fork token" 0
else
  report "dr39. the askpass script gives the push x-access-token and the fork token" 1 "$(dr_detail); askpass: $(cat "$FX/askpass.log" 2>/dev/null)"
fi

# dr40. A merge commit whose subject names no PR, and which the lookup does not list (every try empty): red, naming
# the commit, and nothing is pushed. (The merge is of a side branch; its subject is git's default.)
dr_case dr40 other plain
h=$(head_sha)
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid checkout -q -b side "$BASE"
printf 'side\n' > "$CASE/side.txt"
git -C "$CASE" add side.txt
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid commit -q -m "a side change"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid checkout -q --detach "$h"
git -C "$CASE" -c user.name=test -c user.email=t@example.invalid merge -q --no-ff side -m "Merge branch 'side'"
merge_sha=$(head_sha)
echo '[]' > "$FX/pulls.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "no merged PR is listed for commit $merge_sha, and it is a merge commit whose subject names no PR" "$FX/run.log" \
  && ! pushed_to_fork && ! grep -qF 'skipped:' "$FX/run.log"; then
  report "dr40. a merge commit whose subject names no PR, with no PR found after the tries: red, names the commit" 0
else
  report "dr40. a merge commit whose subject names no PR, with no PR found after the tries: red, names the commit" 1 "$(dr_detail)"
fi

# dr41. A squash commit whose subject names PR #31, which the lookup does not list. PR 31 is merged into main with
# this commit, so the run reads it, continues with PR #31, and makes its doc and the docs PR.
new_case dr41
printf 'a squash\n' > "$CASE/squash.txt"
commit_all "Add the thing (#31)"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
jq -n --arg base "$BASE" --arg head "$(head_sha)" --rawfile body "$FX/body.md" '{state: "MERGED", baseRefName: "main", title: "Demo change", createdAt: "2026-11-05T09:00:00Z", mergedAt: "2026-11-06T00:00:00Z", headRefName: "feat/demo-change", headRefOid: $head, baseRefOid: $base, url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/31", body: $body}' > "$FX/pr-31.json"
jq -n --arg sha "$(head_sha)" '{merged_at: "2026-11-06T00:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, user: {login: "someone"}}' > "$FX/pull-31.json"
git -C "$CASE" push -q "$DR_UP" HEAD:refs/pull/31/head
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF 'continuing with PR #31' "$FX/run.log" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && grep -qF -- 'pr create' "$FX/gh-calls.log" && grep -qF "$doc_name is current" "$FX/run.log"; then
  report "dr41. a squash commit naming PR #31, which is merged with it: the run continues and makes PR #31's doc" 0
else
  report "dr41. a squash commit naming PR #31, which is merged with it: the run continues and makes PR #31's doc" 1 "$(dr_detail)"
fi

# dr48. A squash commit naming PR #31, which is not merged (merged_at null): a direct push, skipped, and the reason names
# PR #31.
new_case dr48
printf 'a squash\n' > "$CASE/squash.txt"
commit_all "Add the thing (#31)"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
printf '{"merged_at": null, "merge_commit_sha": "%s", "base": {"ref": "main"}, "user": {"login": "someone"}}\n' "$(head_sha)" > "$FX/pull-31.json"
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && grep -qF 'skipped: no merged PR has merge commit' "$FX/run.log" \
  && grep -qF 'PR #31, which its subject names, is not merged into main with this commit' "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! pushed_to_fork; then
  report "dr48. a subject naming PR #31, which is not merged with the commit: skipped as a direct push, the reason logged" 0
else
  report "dr48. a subject naming PR #31, which is not merged with the commit: skipped as a direct push, the reason logged" 1 "$(dr_detail)"
fi

# dr49. A subject naming PR #31 that does not exist (a 404): skipped as a direct push, the reason logged.
new_case dr49
printf 'a squash\n' > "$CASE/squash.txt"
commit_all "Add the thing (#31)"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
touch "$FX/pull-31.404"
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && grep -qF 'PR #31, which its subject names, does not exist' "$FX/run.log" \
  && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! pushed_to_fork; then
  report "dr49. a subject naming PR #31 that does not exist: skipped as a direct push, the reason logged" 0
else
  report "dr49. a subject naming PR #31 that does not exist: skipped as a direct push, the reason logged" 1 "$(dr_detail)"
fi

# dr50. Reading the PR named by the subject fails with another error (HTTP 500): red, naming PR #31 and the error.
new_case dr50
printf 'a squash\n' > "$CASE/squash.txt"
commit_all "Add the thing (#31)"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
touch "$FX/pull-31.500"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read PR #31, which the subject of' "$FX/run.log" && grep -qF 'HTTP 500' "$FX/run.log" \
  && ! pushed_to_fork; then
  report "dr50. reading the PR a subject names fails (HTTP 500): red, naming PR #31 and the error" 0
else
  report "dr50. reading the PR a subject names fails (HTTP 500): red, naming PR #31 and the error" 1 "$(dr_detail)"
fi

# dr42. gh lists 1000 open PRs, the most one call returns, so a docs PR could be past the list: red, named.
dr_case dr42 other plain
jq -n '[range(1000) | {number: ., headRefName: "feat/other", headRepositoryOwner: {login: "someone"}, files: []}]' > "$FX/prlist.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "reached gh's limit (1000)" "$FX/run.log" && grep -qF -- '--limit 1000' "$FX/gh-calls.log" \
  && ! pushed_to_fork; then
  report "dr42. the open PRs list reaches the 1000 limit: red, named, nothing pushed" 0
else
  report "dr42. the open PRs list reaches the 1000 limit: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr44. The PR re-read after the push sees the head from before it once, then the pushed head: the run passes.
dr_case dr44 other plain
printf '{"state": "OPEN", "headRefOid": "1111111111111111111111111111111111111111", "body": ""}\n' > "$FX/pr-104-view-1.json"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && [ "$(grep -cF 'pr view 104' "$FX/gh-calls.log")" = 2 ]; then
  report "dr44. the PR re-read sees the old head once, then the pushed one: the run passes" 0
else
  report "dr44. the PR re-read sees the old head once, then the pushed one: the run passes" 1 "$(dr_detail)"
fi

# dr45. A retry after a push that went through and whose title edit failed: the branch is byte-identical, and the
# retry still writes the title (for both PRs) and the body, keeping the notes.
dr_case dr45 other plain
gen "$CASE"
gen_ok=$GEN_RC
cp "$CASE/$doc_name" "$FX/doc24.md"
rm -rf "$CASE/$doc_name" "$CASE/deliveries/$stem"
dr_doc23 docs/delivery-pr-23
cp "$FX/doc24.md" "$W/$doc_name"
git -C "$W" add -A
dr_commit --amend -m "docs: add the delivery docs for PRs #23 and #24"
git -C "$W" push -q -f "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
FORK_SHA=$(git -C "$W" rev-parse HEAD)
git -C "$CASE" fetch -q "$W" "+refs/heads/docs/delivery-pr-23:refs/scratch/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 "$FORK_SHA"
dr_run
if [ "$gen_ok" -eq 0 ] && [ "$DR_RC" -eq 0 ] && grep -qF 'no change: the doc for PR #24' "$FX/run.log" \
  && ! pushed_to_fork \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --title docs: add the delivery docs for PRs #23 and #24 --body-file' "$FX/gh-calls.log" \
  && grep -qF 'Kept note: the screenshot point was fair.' "$FX/body-pr-edit.md" && token_ok; then
  report "dr45. a byte-identical retry still writes the title and body (the earlier edit failed)" 0
else
  report "dr45. a byte-identical retry still writes the title and body (the earlier edit failed)" 1 "gen $gen_ok; $(dr_detail)"
fi

# dr46. qodo-status settles on the head's clear review (the first comments read), but the generator's read finds
# no Qodo comment, so it records qodo-open none. The run is red, names the disagreement, and nothing is pushed.
dr_case dr46 other plain
fx_qodo_clear "$(head_sha)"
cp "$FX/comments-null.json" "$FX/comments-poll-1.json"
fx_qodo_none
dr_run
if [ "$DR_RC" -ne 0 ] \
  && grep -qF "error: the generator recorded qodo-open=none for $doc_name, but scripts/qodo-status.sh called Qodo's review settled" "$FX/run.log" \
  && ! pushed_to_fork && ! fork_has docs/delivery-pr-24 && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr46. the status settles but the generator records qodo-open none: red, named, nothing pushed" 0
else
  report "dr46. the status settles but the generator records qodo-open none: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr47. The same disagreement with the generator reading the base commit's review (other): red, named, nothing pushed.
dr_case dr47 other plain
fx_qodo_clear "$(head_sha)"
cp "$FX/comments-null.json" "$FX/comments-poll-1.json"
fx_qodo_clear "$BASE"
dr_run
if [ "$DR_RC" -ne 0 ] \
  && grep -qF "error: the generator recorded qodo-open=other for $doc_name, but scripts/qodo-status.sh called Qodo's review settled" "$FX/run.log" \
  && ! pushed_to_fork && ! fork_has docs/delivery-pr-24 && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr47. the status settles but the generator records qodo-open other: red, named, nothing pushed" 0
else
  report "dr47. the status settles but the generator records qodo-open other: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr51. The only open docs PR for PR 23 targets another branch (release), not main: the run does not reuse it, and
# starts a new docs branch for PR 24. (Fails without the baseRefName filter: the run would edit PR 103.)
dr_case dr51 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
sed 's/"baseRefName": "main"/"baseRefName": "release"/' "$FX/prlist.json" > "$FX/prlist.tmp" && mv "$FX/prlist.tmp" "$FX/prlist.json"
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF -- '--head lmilbaum:docs/delivery-pr-24' "$FX/gh-calls.log" \
  && ! grep -qF -- 'pr edit 103' "$FX/gh-calls.log" && ! grep -qF 'refs/delivery/reuse' "$FX/git.log"; then
  report "dr51. a docs PR that targets another branch is not reused: a new docs branch for PR 24" 0
else
  report "dr51. a docs PR that targets another branch is not reused: a new docs branch for PR 24" 1 "$(dr_detail)"
fi

# dr52. AGENT_FORK_TOKEN is missing: red, before anything is read or pushed.
dr_case dr52 other plain
DR_FORK_TOKEN=
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'AGENT_FORK_TOKEN is not set' "$FX/run.log" && ! pushed_to_fork && [ ! -s "$FX/gh-calls.log" ]; then
  report "dr52. AGENT_FORK_TOKEN is missing: red, named, nothing read or pushed" 0
else
  report "dr52. AGENT_FORK_TOKEN is missing: red, named, nothing read or pushed" 1 "$(dr_detail)"
fi

# dr53. GH_TOKEN (the read token) is missing: red, before anything is read or pushed.
dr_case dr53 other plain
DR_READ_TOKEN=
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'GH_TOKEN is not set' "$FX/run.log" && ! pushed_to_fork && [ ! -s "$FX/gh-calls.log" ]; then
  report "dr53. GH_TOKEN is missing: red, named, nothing read or pushed" 0
else
  report "dr53. GH_TOKEN is missing: red, named, nothing read or pushed" 1 "$(dr_detail)"
fi

# dr54. A --sha that is not a commit SHA: red, named.
dr_case dr54 other plain
DR_SHA=not-a-sha
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF -- '--sha must be a commit SHA' "$FX/run.log" && [ ! -s "$FX/gh-calls.log" ]; then
  report "dr54. a --sha that is not a commit SHA: red, named, no GitHub call" 0
else
  report "dr54. a --sha that is not a commit SHA: red, named, no GitHub call" 1 "$(dr_detail)"
fi

# dr55. A manual dispatch whose --pr is not a number: red, named.
dr_case dr55 other plain
DR_EVENT=workflow_dispatch
DR_PR=abc
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "a manual run needs --pr N (a PR number), not 'abc'" "$FX/run.log" && ! pushed_to_fork; then
  report "dr55. a manual dispatch with a non-numeric --pr: red, named" 0
else
  report "dr55. a manual dispatch with a non-numeric --pr: red, named" 1 "$(dr_detail)"
fi

# dr56. gh cannot read the merged PR's state: red, naming PR 24.
dr_case dr56 other plain
touch "$FX/pr-24.fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read PR #24' "$FX/run.log" && ! pushed_to_fork; then
  report "dr56. gh cannot read PR #24: red, named, nothing pushed" 0
else
  report "dr56. gh cannot read PR #24: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr57. gh cannot read PR 24's author: red, named.
dr_case dr57 other plain
touch "$FX/gh-fail-pulls"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read the author of PR #24' "$FX/run.log" && ! pushed_to_fork; then
  report "dr57. gh cannot read PR #24's author: red, named, nothing pushed" 0
else
  report "dr57. gh cannot read PR #24's author: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr58. The origin cannot be fetched (its main is gone): red, named, nothing pushed.
dr_case dr58 other plain
rm -rf "$DR_UP"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not fetch main from origin' "$FX/run.log" && ! pushed_to_fork; then
  report "dr58. the origin cannot be fetched: red, named, nothing pushed" 0
else
  report "dr58. the origin cannot be fetched: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr59. The origin has no refs/pull/24/head (the PR's ref is gone): red, naming the PR's head fetch.
dr_case dr59 other plain
git -C "$DR_UP" update-ref -d refs/pull/24/head
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not fetch PR #24's head from origin" "$FX/run.log" && ! pushed_to_fork; then
  report "dr59. the origin has no PR head ref: red, named, nothing pushed" 0
else
  report "dr59. the origin has no PR head ref: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr60. gh cannot list the open PRs: red, named.
dr_case dr60 other plain
touch "$FX/gh-fail-pr-list"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not list the open PRs' "$FX/run.log" && ! pushed_to_fork; then
  report "dr60. gh cannot list the open PRs: red, named, nothing pushed" 0
else
  report "dr60. gh cannot list the open PRs: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr61. A docs PR whose branch name git does not accept: red, named.
dr_case dr61 other plain
printf '[{"number": 103, "headRefName": "docs/delivery-bad..name", "headRepositoryOwner": {"login": "lmilbaum"}, "baseRefName": "main", "files": [{"path": "deliveries/a.md"}]}]\n' > "$FX/prlist.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "is not a valid branch name" "$FX/run.log" && ! pushed_to_fork; then
  report "dr61. a docs PR with an invalid branch name: red, named" 0
else
  report "dr61. a docs PR with an invalid branch name: red, named" 1 "$(dr_detail)"
fi

# dr62. The docs PR's branch cannot be fetched from the fork: red, named.
dr_case dr62 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
DR_FORK="$tmp/no-such-fork-62.git"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not fetch docs/delivery-pr-23 from the fork' "$FX/run.log" && ! grep -qF -- ' push ' "$FX/git.log"; then
  report "dr62. the reused docs branch cannot be fetched from the fork: red, named, nothing pushed" 0
else
  report "dr62. the reused docs branch cannot be fetched from the fork: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr63. The reused docs branch's one commit changes no file (an empty commit): red, named.
dr_case dr63 other plain
dr_scratch
git -C "$W" checkout -q -b docs/delivery-pr-23 "$BASE"
dr_commit --allow-empty -m "an empty commit"
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "docs PR #103's commit changes no files" "$FX/run.log" && ! pushed_to_fork; then
  report "dr63. a reused docs branch whose commit changes no file: red, named, nothing pushed" 0
else
  report "dr63. a reused docs branch whose commit changes no file: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr64. A doc on the reused branch has no **PR:** line to name its PR: red, named, nothing pushed.
dr_case dr64 other plain
dr_scratch
git -C "$W" checkout -q -b docs/delivery-pr-23 "$BASE"
printf 'no header here\n' > "$W/deliveries/2026-11-04-p23.md"
git -C "$W" add -A
dr_commit -m "a doc without a header"
git -C "$W" push -q "$DR_FORK" "docs/delivery-pr-23:refs/heads/docs/delivery-pr-23"
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'has no' "$FX/run.log" && grep -qF "to name its PR" "$FX/run.log" && ! pushed_to_fork; then
  report "dr64. a doc on the reused branch with no PR line: red, named, nothing pushed" 0
else
  report "dr64. a doc on the reused branch with no PR line: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr65. The reused docs PR cannot be read before the push (its body): red, naming it.
dr_case dr65 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
touch "$FX/pr-103.fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read docs PR #103' "$FX/run.log" && ! pushed_to_fork; then
  report "dr65. the reused docs PR cannot be read: red, named" 0
else
  report "dr65. the reused docs PR cannot be read: red, named" 1 "$(dr_detail)"
fi

# dr66. The reused docs PR's title and body edit fails: red, named.
dr_case dr66 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
touch "$FX/gh-fail-pr-edit"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not update the title and body of docs PR #103' "$FX/run.log"; then
  report "dr66. the reused docs PR's title and body edit fails: red, named" 0
else
  report "dr66. the reused docs PR's title and body edit fails: red, named" 1 "$(dr_detail)"
fi

# dr67. gh pr create prints no PR URL: red, named.
dr_case dr67 other plain
echo 'not a url' > "$FX/pr-create-out.txt"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'gh pr create printed no PR URL' "$FX/run.log"; then
  report "dr67. gh pr create prints no PR URL: red, named" 0
else
  report "dr67. gh pr create prints no PR URL: red, named" 1 "$(dr_detail)"
fi

# dr68. The docs PR cannot be read in the re-read after the push: red, named.
dr_case dr68 other plain
touch "$FX/pr-104.fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not read docs PR #104' "$FX/run.log"; then
  report "dr68. the docs PR cannot be re-read after the push: red, named" 0
else
  report "dr68. the docs PR cannot be re-read after the push: red, named" 1 "$(dr_detail)"
fi

# dr69. The fork can be read but not written, and a docs branch exists: the lease push fails, red, named.
dr_case dr69 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
chmod -R a-w "$DR_FORK"
dr_run
chmod -R u+w "$DR_FORK"
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not push docs/delivery-pr-23 to the fork' "$FX/run.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr69. the reused docs branch cannot be pushed (read-only fork): red, named, no PR edit" 0
else
  report "dr69. the reused docs branch cannot be pushed (read-only fork): red, named, no PR edit" 1 "$(dr_detail)"
fi

# dr70. The commit lookup is empty, the commit is not in the clone, and it cannot be fetched from origin: red, naming
# the commit, because whether it is a merge is then unknown.
dr_case dr70 other plain
echo '[]' > "$FX/pulls.json"
DR_SHA=0000000000000000000000000000000000000001
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not be fetched to check whether it is a merge' "$FX/run.log" && ! pushed_to_fork; then
  report "dr70. a direct-push commit that cannot be fetched to check: red, named" 0
else
  report "dr70. a direct-push commit that cannot be fetched to check: red, named" 1 "$(dr_detail)"
fi

# dr71. A rebase merge: one parent, a subject that names no PR, and no PR listed for it by the commit lookup. The
# recently merged PRs list PR 32 with this commit as its merge commit, so the commit is found by merge commit: the
# run continues with PR 32 and makes its doc and the docs PR.
new_case dr71
printf 'a rebased change\n' > "$CASE/rebased.txt"
commit_all "a rebased change"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
jq -n --arg base "$BASE" --arg head "$(head_sha)" --rawfile body "$FX/body.md" '{state: "MERGED", baseRefName: "main", title: "Demo change", createdAt: "2026-11-05T09:00:00Z", mergedAt: "2026-11-06T00:00:00Z", headRefName: "feat/demo-change", headRefOid: $head, baseRefOid: $base, url: "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/32", body: $body}' > "$FX/pr-32.json"
jq -n --arg sha "$(head_sha)" '{data: {repository: {pullRequests: {nodes: [{number: 32, mergeCommit: {oid: $sha}}, {number: 31, mergeCommit: {oid: "1111111111111111111111111111111111111111"}}]}}}}' > "$FX/merged-prs.json"
git -C "$CASE" push -q "$DR_UP" HEAD:refs/pull/32/head
h71=$(head_sha)
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF "found by merge commit: PR #32 has $h71 as its merge commit" "$FX/run.log" \
  && grep -qF 'docs PR: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/104' "$FX/run.log" \
  && grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr71. a rebase merge the commit lookup misses, found by the recently merged PRs: the doc is made" 0
else
  report "dr71. a rebase merge the commit lookup misses, found by the recently merged PRs: the doc is made" 1 "$(dr_detail)"
fi

# dr72. The same kind of commit, with no merged PR listed for it by either the lookup or the recently merged PRs: a
# direct push, skipped, and the log says no merged PR has this merge commit.
new_case dr72
printf 'a rebased change\n' > "$CASE/rebased.txt"
commit_all "a rebased change"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
dr_run
if [ "$DR_RC" -eq 0 ] && no_writes && grep -qF "skipped: no merged PR has merge commit $(head_sha) (a direct push)" "$FX/run.log" \
  && grep -qF -- 'pullRequests' "$FX/gh-calls.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr72. a commit no PR is listed for, by either list: skipped as a direct push, the log says so" 0
else
  report "dr72. a commit no PR is listed for, by either list: skipped as a direct push, the log says so" 1 "$(dr_detail)"
fi

# dr73. The recently merged PRs cannot be listed: red, naming the lookup, nothing pushed.
new_case dr73
printf 'a rebased change\n' > "$CASE/rebased.txt"
commit_all "a rebased change"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
touch "$FX/merged-prs.fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'could not list the recently merged PRs to find the PR of commit' "$FX/run.log" && ! pushed_to_fork; then
  report "dr73. the recently merged PRs cannot be listed: red, named, nothing pushed" 0
else
  report "dr73. the recently merged PRs cannot be listed: red, named, nothing pushed" 1 "$(dr_detail)"
fi

# dr74. Two recently merged PRs have this commit as their merge commit: red, naming both.
new_case dr74
printf 'a rebased change\n' > "$CASE/rebased.txt"
commit_all "a rebased change"
body_plain > "$FX/body.md"
dr_finish
echo '[]' > "$FX/pulls.json"
jq -n --arg sha "$(head_sha)" '{data: {repository: {pullRequests: {nodes: [{number: 32, mergeCommit: {oid: $sha}}, {number: 33, mergeCommit: {oid: $sha}}]}}}}' > "$FX/merged-prs.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF '2 merged PRs have merge commit' "$FX/run.log" && ! pushed_to_fork; then
  report "dr74. two recently merged PRs with this merge commit: red, named" 0
else
  report "dr74. two recently merged PRs with this merge commit: red, named" 1 "$(dr_detail)"
fi

# dr75. A manual dispatch for a PR merged into release, not main: red, naming the base, and nothing is written.
dr_case dr75 other plain
jq '.baseRefName = "release"' "$FX/pr.json" > "$FX/pr.tmp" && mv "$FX/pr.tmp" "$FX/pr.json"
DR_EVENT=workflow_dispatch
DR_PR=24
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF 'PR #24 merged into release, not main' "$FX/run.log" && no_writes; then
  report "dr75. a manual dispatch for a PR merged into release: red, naming the base, no write, no push" 0
else
  report "dr75. a manual dispatch for a PR merged into release: red, naming the base, no write, no push" 1 "$(dr_detail)"
fi

# dr76. The doc is already on main, and Qodo's review would still be waiting (its comment was edited a minute ago).
# The run skips at once with no Qodo poll and no write. Checked after the wait, the run would poll and then fail.
dr_case dr76 other plain
h24=$(head_sha)
gen "$CASE"
gen_ok=$GEN_RC
commit_all "the delivery doc for PR 24, on main"
git -C "$CASE" push -q -f "$DR_UP" HEAD:refs/heads/main
DR_SHA=$h24
fx_qodo_clear "$h24"
fx_qodo_edited_at 2026-11-06T11:59:00Z
DR_POLLS=2
dr_run
if [ "$gen_ok" -eq 0 ] && [ "$DR_RC" -eq 0 ] && grep -qF "skipped: $doc_name is already on main" "$FX/run.log" \
  && ! grep -qF 'comments(first' "$FX/gh-calls.log" && no_writes; then
  report "dr76. already on main while Qodo's review would wait: skipped at once, no Qodo poll, no write" 0
else
  report "dr76. already on main while Qodo's review would wait: skipped at once, no Qodo poll, no write" 1 "gen $gen_ok; $(dr_detail)"
fi

# dr77. The doc is not on main at the first check, and merges to main while the run waits for Qodo's review: a hook
# pushes the doc's commit to the origin's main at the review's read. The run fetches main again after the wait,
# finds the doc, and skips: nothing is written or pushed, and no replacement is proposed. Without the second check,
# the run would make a replacement for the existing doc.
dr_case dr77 other plain
h24=$(head_sha)
gen "$CASE"
gen_ok=$GEN_RC
commit_all "the delivery doc for PR 24, merged while the run waits"
c2=$(head_sha)
printf '#!/usr/bin/env bash\n%s -C %s push -q -f %s %s:refs/heads/main\n' "$real_git" "$CASE" "$DR_UP" "$c2" > "$FX/on-comments-read"
chmod +x "$FX/on-comments-read"
DR_SHA=$h24
dr_run
if [ "$gen_ok" -eq 0 ] && [ "$DR_RC" -eq 0 ] \
  && grep -qF "skipped: $doc_name is already on main (it merged while this run waited for Qodo)" "$FX/run.log" \
  && grep -qF 'comments(first' "$FX/gh-calls.log" && no_writes; then
  report "dr77. the doc merges to main while the run waits for Qodo: skipped after the second check, no write" 0
else
  report "dr77. the doc merges to main while the run waits for Qodo: skipped after the second check, no write" 1 "gen $gen_ok; $(dr_detail)"
fi

# dr78. A fork behind upstream, a new docs PR: the run pushes upstream's main to the fork's main as a fast-forward (the
# fork token, by askpass), logs both SHAs, opens the docs PR, and the fork's main ends at upstream's HEAD.
dr_case dr78 other plain
dr_fork_behind
h78=$(head_sha)
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF "fork behind: $BASE -> $h78" "$FX/run.log" && grep -qF "fork synced: $BASE -> $h78" "$FX/run.log" \
  && main_pushed && askpass_fork_only 2 && grep -qF -- 'pr create' "$FX/gh-calls.log" && fork_has docs/delivery-pr-24 \
  && fork_main_is "$h78" && token_ok; then
  report "dr78. a fork behind upstream, new docs PR: main fast-forwarded by the fork token, both SHAs logged, fork main at upstream's HEAD" 0
else
  report "dr78. a fork behind upstream, new docs PR: main fast-forwarded by the fork token, both SHAs logged, fork main at upstream's HEAD" 1 "$(dr_detail)"
fi

# dr79. A fork behind upstream, a reused docs PR: the fork's main is fast-forwarded, then the docs PR's one commit is
# amended and rebased onto it as dr2 does; the fork token answers both pushes.
dr_case dr79 other plain
dr_doc23 docs/delivery-pr-23
dr_fork_behind
pr_head=$(head_sha)
dr_reuse docs/delivery-pr-23 @HEAD@
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF "fork behind: $BASE -> $pr_head" "$FX/run.log" && grep -qF "fork synced: $BASE -> $pr_head" "$FX/run.log" \
  && main_pushed && askpass_fork_only 2 \
  && [ "$(git -C "$DR_FORK" rev-list --count "$pr_head..refs/heads/docs/delivery-pr-23")" = 1 ] \
  && [ "$(git -C "$DR_FORK" rev-parse 'refs/heads/docs/delivery-pr-23^')" = "$pr_head" ] \
  && grep -qF -- 'pr edit 103 --repo lioramilbaum/lioramilbaum.github.io --title docs: add the delivery docs for PRs #23 and #24 --body-file' "$FX/gh-calls.log" \
  && fork_main_is "$pr_head" && token_ok; then
  report "dr79. a fork behind upstream, reused docs PR: main fast-forwarded, the one commit amended onto it, fork token on both pushes" 0
else
  report "dr79. a fork behind upstream, reused docs PR: main fast-forwarded, the one commit amended onto it, fork token on both pushes" 1 "$(dr_detail)"
fi

# dr80. The fork's main already equals upstream's: the run logs that the fork is current and pushes nothing to the
# fork's main (only the docs branch).
dr_case dr80 other plain
h80=$(head_sha)
dr_run
if [ "$DR_RC" -eq 0 ] && grep -qF "fork current: main is $h80" "$FX/run.log" && ! main_pushed \
  && askpass_fork_only 1 && grep -qF -- 'pr create' "$FX/gh-calls.log" && fork_main_is "$h80" && token_ok; then
  report "dr80. a fork already at upstream's main: logged as current, no push to the fork's main" 0
else
  report "dr80. a fork already at upstream's main: logged as current, no push to the fork's main" 1 "$(dr_detail)"
fi

# dr81. The fork's main has a commit upstream lacks (a fork-only commit on the base): red before any push, naming both
# SHAs and the count; nothing is pushed to the fork's main, and the fork's main is left as it is.
dr_case dr81 other plain
dr_scratch
git -C "$W" checkout -q -b forkonly "$BASE"
printf 'fork only\n' > "$W/fork-only.txt"
git -C "$W" add -A
dr_commit -m "a fork-only commit"
FORK_ONLY=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q -f "$DR_FORK" "forkonly:refs/heads/main"
h81=$(head_sha)
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "the fork's main ($FORK_ONLY) has diverged from upstream's ($h81): 1 commit(s) upstream lacks" "$FX/run.log" \
  && ! main_pushed && ! pushed_to_fork && fork_main_is "$FORK_ONLY" && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr81. a fork main with a commit upstream lacks: red, both SHAs and the count named, no push, fork main unchanged" 0
else
  report "dr81. a fork main with a commit upstream lacks: red, both SHAs and the count named, no push, fork main unchanged" 1 "$(dr_detail)"
fi

# dr82. The fork refuses the push of its main (a pre-receive hook stands in for a refusal; not GitHub's wording): red,
# the fork's refusal and the run's message in the log, no push of the docs branch, no PR, and the fork's main unchanged.
dr_case dr82 other plain
dr_fork_behind
dr_fork_refuses_main
h82=$(head_sha)
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not fast-forward the fork's main to $h82: " "$FX/run.log" \
  && grep -qF 'simulated refusal of refs/heads/main' "$FX/run.log" && grep -qF 'nothing is pushed' "$FX/run.log" \
  && main_pushed && ! grep -qE -- ' push .*docs/delivery-pr-24' "$FX/git.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" \
  && fork_main_is "$BASE" && ! fork_has docs/delivery-pr-24; then
  report "dr82. the fork refuses its main: red, the refusal named, no docs-branch push, no PR, fork main unchanged" 0
else
  report "dr82. the fork refuses its main: red, the refusal named, no docs-branch push, no PR, fork main unchanged" 1 "$(dr_detail)"
fi

# dr83. The fork's main moves between the run's read and its push (a hook sets it to a commit that is not on upstream's
# main, just before the push): the push is refused, so the run is red, the fork's main keeps the moved commit, and no
# merge commit is made.
dr_case dr83 other plain
dr_fork_behind
dr_scratch
git -C "$W" checkout -q -b racey "$BASE"
printf 'racing\n' > "$W/racing.txt"
git -C "$W" add -A
dr_commit -m "a commit on the fork's main during the run"
RACE=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q "$DR_FORK" "racey:refs/heads/racing"
cat > "$FX/before-main-push" <<HOOK
#!/usr/bin/env bash
git --git-dir='$DR_FORK' update-ref refs/heads/main '$RACE'
HOOK
h83=$(head_sha)
dr_run
if [ "$DR_RC" -ne 0 ] && [ -e "$FX/before-main-push.ran" ] \
  && grep -qF "could not fast-forward the fork's main to $h83: " "$FX/run.log" && grep -qF 'rejected' "$FX/run.log" \
  && fork_main_is "$RACE" && [ "$(git -C "$DR_FORK" rev-list --parents -n1 "$RACE" | wc -w | tr -d ' ')" = 2 ] \
  && ! grep -qE -- ' push .*docs/delivery-pr-24' "$FX/git.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && ! fork_has docs/delivery-pr-24; then
  report "dr83. the fork's main moves before the push: the push is refused, red, the moved main kept, no merge commit, no PR" 0
else
  report "dr83. the fork's main moves before the push: the push is refused, red, the moved main kept, no merge commit, no PR" 1 "$(dr_detail)"
fi

# dr84. The fork accepts the push of its main, but the main is then back at the old base (a post-receive hook): the
# confirm finds the fork's main unlike upstream's, so the run is red, names both SHAs, and pushes no docs branch.
dr_case dr84 other plain
dr_fork_behind
dr_fork_main_rewinds "$BASE"
h84=$(head_sha)
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "after the push the fork's main is $BASE, not upstream's main ($h84); nothing is pushed" "$FX/run.log" \
  && main_pushed && ! grep -qE -- ' push .*docs/delivery-pr-24' "$FX/git.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" \
  && fork_main_is "$BASE"; then
  report "dr84. the fork's main is not upstream's after the push: red, both SHAs named, no docs-branch push, no PR" 0
else
  report "dr84. the fork's main is not upstream's after the push: red, both SHAs named, no docs-branch push, no PR" 1 "$(dr_detail)"
fi

# dr85. The fork has no main: red before the push, names the fork and its missing main, and pushes nothing.
dr_case dr85 other plain
git -C "$DR_FORK" update-ref -d refs/heads/main
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not fetch the fork's main from $DR_FORK (the fork has no main, or cannot be read)" "$FX/run.log" \
  && grep -qF "couldn't find remote ref refs/heads/main" "$FX/run.log" \
  && ! main_pushed && ! pushed_to_fork && ! grep -qF -- 'pr create' "$FX/gh-calls.log"; then
  report "dr85. a fork with no main: red, named (the fork's main could not be fetched), nothing pushed" 0
else
  report "dr85. a fork with no main: red, named (the fork's main could not be fetched), nothing pushed" 1 "$(dr_detail)"
fi

# dr86. Upstream's main gains a commit after the run's read (a hook moves it just before the main push): the run pushes
# the commit it read, the confirm passes, and the docs branch's base is an ancestor of the fork's main.
dr_case dr86 other plain
dr_fork_behind
h86=$(head_sha)
dr_scratch
printf 'upstream gains a commit\n' > "$W/gained.txt"
git -C "$W" add -A
dr_commit -m "a commit upstream gains during the run"
GAIN=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q "$DR_UP" "HEAD:refs/heads/gained"
cat > "$FX/before-main-push" <<HOOK
#!/usr/bin/env bash
git --git-dir='$DR_UP' update-ref refs/heads/main '$GAIN'
HOOK
dr_run
if [ "$DR_RC" -eq 0 ] && [ -e "$FX/before-main-push.ran" ] && grep -qF "fork synced: $BASE -> $h86" "$FX/run.log" \
  && main_pushed && askpass_fork_only 2 && fork_main_is "$h86" \
  && git -C "$DR_FORK" merge-base --is-ancestor "$h86" refs/heads/docs/delivery-pr-24 \
  && grep -qF -- 'pr create' "$FX/gh-calls.log" && token_ok; then
  report "dr86. upstream gains a commit after the read: the commit read is pushed and confirmed; the docs branch sits on it" 0
else
  report "dr86. upstream gains a commit after the read: the commit read is pushed and confirmed; the docs branch sits on it" 1 "$(dr_detail)"
fi

# dr88. The fetch of upstream's main from origin fails inside the sync (a simulated git failure of that fetch): red,
# named, nothing pushed to the fork's main or the docs branch, no PR. Without the die on that fetch, the run would go on.
dr_case dr88 other plain
dr_fork_behind
printf '%s\n' 'refs/delivery/up-main' > "$FX/fail-git-arg"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not fetch upstream's main from origin: simulated git failure" "$FX/run.log" \
  && ! main_pushed && ! pushed_to_fork && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && fork_main_is "$BASE"; then
  report "dr88. the fetch of upstream's main fails: red, named, nothing pushed, no PR" 0
else
  report "dr88. the fetch of upstream's main fails: red, named, nothing pushed, no PR" 1 "$(dr_detail)"
fi

# dr89. The fork's main is deleted after the push is accepted (a post-receive hook): the run's re-read of the fork's main
# fails, so it is red, names the re-read, and pushes no docs branch and opens no PR.
dr_case dr89 other plain
dr_fork_behind
dr_fork_main_deletes
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not re-read the fork's main after the push: " "$FX/run.log" \
  && grep -qF "couldn't find remote ref refs/heads/main" "$FX/run.log" && main_pushed \
  && ! grep -qE -- ' push .*docs/delivery-pr-24' "$FX/git.log" && ! grep -qF -- 'pr create' "$FX/gh-calls.log" \
  && ! git -C "$DR_FORK" rev-parse -q --verify refs/heads/main >/dev/null; then
  report "dr89. the re-read of the fork's main fails after the push: red, named, no docs-branch push, no PR" 0
else
  report "dr89. the re-read of the fork's main fails after the push: red, named, no docs-branch push, no PR" 1 "$(dr_detail)"
fi

# dr90. git fails the rev-list that compares the fork's main with upstream's (a simulated git failure of that call): red,
# named, nothing pushed, no PR, and the fork's main unchanged.
dr_case dr90 other plain
dr_fork_behind
printf '%s\n' 'rev-list --count' > "$FX/fail-git-arg"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not compare the fork's main with upstream's: simulated git failure" "$FX/run.log" \
  && ! main_pushed && ! pushed_to_fork && ! grep -qF -- 'pr create' "$FX/gh-calls.log" && fork_main_is "$BASE"; then
  report "dr90. the comparison of the fork's main with upstream's fails: red, named, nothing pushed, no PR" 0
else
  report "dr90. the comparison of the fork's main with upstream's fails: red, named, nothing pushed, no PR" 1 "$(dr_detail)"
fi

# dr91. The one open docs PR lists no files (an empty PR): it is not reused, so a new docs PR is opened on a
# new branch, and PR 103 is not edited.
dr_case dr91 other plain
dr_doc23 docs/delivery-pr-23
printf '[{"number": 103, "headRefName": "docs/delivery-pr-23", "headRepositoryOwner": {"login": "lmilbaum"}, "baseRefName": "main", "files": []}]\n' > "$FX/prlist.json"
dr_run
if [ "$DR_RC" -eq 0 ] \
  && grep -qF -- 'pr create --repo lioramilbaum/lioramilbaum.github.io --base main --head lmilbaum:docs/delivery-pr-24' "$FX/gh-calls.log" \
  && ! grep -qF -- 'pr edit 103' "$FX/gh-calls.log"; then
  report "dr91. an empty docs PR is not reused: a new docs PR is opened" 0
else
  report "dr91. an empty docs PR is not reused: a new docs PR is opened" 1 "$(dr_detail)"
fi

# dr92. The reused docs PR's body has CRLF line ends: the rebuilt body keeps its ## Hackathon and ## Qodo notes
# sections (their lines), and has no CR.
dr_case dr92 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
awk '{ printf "%s\r\n", $0 }' "$FX/reuse-body.md" > "$FX/reuse-body.crlf" && mv "$FX/reuse-body.crlf" "$FX/reuse-body.md"
jq -n --rawfile body "$FX/reuse-body.md" '{state: "OPEN", headRefOid: "@HEAD@", body: $body}' > "$FX/pr-103.json"
dr_run
if [ "$DR_RC" -eq 0 ] \
  && body_has "$FX/body-pr-edit.md" '## Hackathon' '## Qodo notes' \
    'Day 4: Demo (https://github.com/orgs/qodo-hackathon/discussions/10)' 'Kept note: the screenshot point was fair.' \
  && ! grep -qF "$(printf '\r')" "$FX/body-pr-edit.md"; then
  report "dr92. a reused docs PR with a CRLF body keeps its Hackathon and Qodo notes" 0
else
  report "dr92. a reused docs PR with a CRLF body keeps its Hackathon and Qodo notes" 1 "$(dr_detail); body: $(cat "$FX/body-pr-edit.md" 2>/dev/null)"
fi

# dr93. The reused docs PR's body has a heading the run cannot read (### Hackathon, and no ## Hackathon): red,
# named, and nothing pushed or edited.
dr_case dr93 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
printf '## Acceptance criteria\n\nNo linked issue.\n\n### Hackathon\n\nDay 4: Demo\n' > "$FX/reuse-body.md"
jq -n --rawfile body "$FX/reuse-body.md" '{state: "OPEN", headRefOid: "@HEAD@", body: $body}' > "$FX/pr-103.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "has a heading the run cannot read (### Hackathon); nothing is pushed or edited" "$FX/run.log" \
  && ! pushed_to_fork && ! grep -qF -- '--body-file' "$FX/gh-calls.log"; then
  report "dr93. a reused body with a heading the run cannot read: red, named, nothing pushed or edited" 0
else
  report "dr93. a reused body with a heading the run cannot read: red, named, nothing pushed or edited" 1 "$(dr_detail)"
fi

# dr94. The reused docs PR's body is edited between the run's two reads (the second read is the view that
# pr-103-view-2.json answers): the rebuilt body keeps the second read's ## Hackathon and ## Qodo notes, not the
# first read's, so an edit the owner made during the run is kept.
dr_case dr94 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
cat > "$FX/reuse-body-2.md" <<'BODY'
## Acceptance criteria

No linked issue.

## Why

An older body.

## Hackathon

Day 5: Demo (https://github.com/orgs/qodo-hackathon/discussions/11)

## Qodo notes

Kept note: the second read said this.
BODY
jq -n --rawfile body "$FX/reuse-body-2.md" '{state: "OPEN", headRefOid: "@HEAD@", body: $body}' > "$FX/pr-103-view-2.json"
dr_run
if [ "$DR_RC" -eq 0 ] \
  && body_has "$FX/body-pr-edit.md" '## Hackathon' '## Qodo notes' \
    'Day 5: Demo (https://github.com/orgs/qodo-hackathon/discussions/11)' 'Kept note: the second read said this.' \
  && ! grep -qF 'Day 4: Demo' "$FX/body-pr-edit.md" && ! grep -qF 'Kept note: the screenshot point was fair.' "$FX/body-pr-edit.md"; then
  report "dr94. the reused body changes between the two reads: the rebuilt body keeps the second read's notes" 0
else
  report "dr94. the reused body changes between the two reads: the rebuilt body keeps the second read's notes" 1 "$(dr_detail)"
fi

# dr95. The second read of the reused docs PR's body fails: red, named, the branch pushed, and no body edit.
dr_case dr95 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
touch "$FX/pr-103-view-2.fail"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "could not read the body of docs PR #103 again; docs/delivery-pr-23 is pushed and the body is not edited" "$FX/run.log" \
  && pushed_to_fork && ! grep -qF -- '--body-file' "$FX/gh-calls.log"; then
  report "dr95. the second read of the reused body fails: red, named, pushed, body not edited" 0
else
  report "dr95. the second read of the reused body fails: red, named, pushed, body not edited" 1 "$(dr_detail)"
fi

# dr96. The second read of the reused docs PR's body has a heading the run cannot read: red, named (the heading),
# the branch pushed, and no body edit.
dr_case dr96 other plain
dr_doc23 docs/delivery-pr-23
dr_reuse docs/delivery-pr-23 @HEAD@
printf '## Acceptance criteria\n\nNo linked issue.\n\n### Hackathon\n\nDay 5: Demo\n' > "$FX/reuse-body-2.md"
jq -n --rawfile body "$FX/reuse-body-2.md" '{state: "OPEN", headRefOid: "@HEAD@", body: $body}' > "$FX/pr-103-view-2.json"
dr_run
if [ "$DR_RC" -ne 0 ] && grep -qF "docs PR #103's body has a heading the run cannot read (### Hackathon); docs/delivery-pr-23 is pushed and the body is not edited" "$FX/run.log" \
  && pushed_to_fork && ! grep -qF -- '--body-file' "$FX/gh-calls.log"; then
  report "dr96. the second read of the reused body has a heading the run cannot read: red, named, pushed, body not edited" 0
else
  report "dr96. the second read of the reused body has a heading the run cannot read: red, named, pushed, body not edited" 1 "$(dr_detail)"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed (awk: $awk_bin)" >&2
  exit 1
fi
echo "all cases passed (awk: $awk_bin)"
