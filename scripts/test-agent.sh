#!/usr/bin/env bash
# Tests for the agent runner (AGENTS.md Setup, the agent run): scripts/agent-run.sh, and the
# argument of scripts/build-site.sh it relies on. Offline: no network, no Docker, no model. Each
# case builds a throwaway upstream, fork and clone around the real runner, prompt, build wrapper
# and check-site.yml. docker, gh, claude, the checks, qodo-status.sh and git's push are stubs on
# PATH or fixtures, and sleep is a no-op. The docker stub runs what a container would run, with only
# the -e variables in its environment (the build and the checks use docker; the model does not).
# The claude stub is run with the environment the runner gives it (env -i) and its own HOME, so a
# case's fixture directory is kept in the stub itself (setup_repos writes it in). Prints one ok or
# FAIL line per case and exits 1 if any case fails. The runner itself is copied from this checkout,
# so a broken or missing runner fails the cases that need it.
set -euo pipefail
unset GITHUB_ACTIONS

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-agent.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)  # physical, as the runner's own paths are (its deny rules match them)
trap 'rm -rf "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin"
failures=0
ncase=0
fx=""
repo=lioramilbaum/lioramilbaum.github.io
real_git=$(command -v git)
bash_bin=$(command -v bash)
command -v jq >/dev/null 2>&1 || { echo "error: jq is needed by the gh stub" >&2; exit 1; }

# Stubs -----------------------------------------------------------------------

# git: the runner's git (first on its PATH). A push is logged, and the stub asks GIT_ASKPASS for
# the credentials as git's prompt would, into askpass.log. It fails on request: a file git-fail-SUB
# in the fixture directory fails git SUB; git-fail-amend fails a commit --amend, and
# git-fail-push-lease fails a push with a lease.
cat > "$bin/git" <<STUB
#!/usr/bin/env bash
sub=""
skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -c|-C) skip=1 ;; -*) ;; *) sub=\$a; break ;; esac
done
case " \$* " in *" --amend "*) [ -e "\$HOME/git-fail-amend" ] && { echo "git stub: simulated amend failure" >&2; exit 1; } ;; esac
case " \$* " in *" --force-with-lease"*) [ -e "\$HOME/git-fail-push-lease" ] && { echo "git stub: simulated lease failure" >&2; exit 1; } ;; esac
[ -e "\$HOME/git-fail-\$sub" ] && { echo "git stub: simulated \$sub failure" >&2; exit 1; }
if [ "\$sub" = push ]; then
  echo "\$*" >> "\$HOME/git-push.log"
  if [ -n "\${GIT_ASKPASS:-}" ]; then
    { "\$GIT_ASKPASS" "Username for 'https://github.com':"; "\$GIT_ASKPASS" "Password for 'https://x-access-token@github.com':"; } >> "\$HOME/askpass.log"
  fi
fi
exec "$real_git" "\$@"
STUB

cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: logs its arguments and the token it was given, keeps each --body-file as body-N.md, and
# serves the fixture for the call from $HOME (issue.json, pr-list.json, qodo-comments.json,
# pr-checks.json, pr-url), with --jq applied by jq. A file gh-fail-<command>-<subcommand> makes that call fail. A file
# gh-raw-<command>-<subcommand> is printed as the call's output, unfiltered by --jq.
set -euo pipefail
fx=$HOME
echo "$* [token=${GH_TOKEN:-unset}] [cwd=$(pwd -P)]" >> "$fx/gh-calls.log"
if [ -e "$fx/gh-fail-match" ] && [[ "$*" == *"$(cat "$fx/gh-fail-match")"* ]]; then echo "gh: simulated failure" >&2; exit 1; fi
if [ -e "$fx/gh-fail-$1-$2" ]; then echo "gh: simulated failure" >&2; exit 1; fi
if [ -e "$fx/gh-raw-$1-$2" ]; then cat "$fx/gh-raw-$1-$2"; exit 0; fi
jq_expr=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --jq) jq_expr=$arg ;;
    --body-file)
      n=$(( $(cat "$fx/body-count" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$fx/body-count"
      cp "$arg" "$fx/body-$n.md"
      ;;
  esac
  prev=$arg
done
case "$1 $2" in
  "issue view") src=$fx/issue.json ;;
  "pr list") src=$fx/pr-list.json ;;
  "api graphql")
    # The page the cursor names (-f after=CURSOR), when the case has that page; the first page otherwise.
    src=$fx/qodo-comments.json
    for a in "$@"; do
      if [[ "$a" == after=* && -e "$fx/qodo-comments-${a#after=}.json" ]]; then src=$fx/qodo-comments-${a#after=}.json; fi
    done
    ;;
  "pr create") src=$fx/pr-url ;;
  "pr checks") src=$fx/pr-checks.json ;;
  *) exit 0 ;;
esac
if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "$src"; else cat "$src"; fi
STUB

# agent-test-plan FILE COUNTER: prints the next line of FILE (one line per call, counted in
# COUNTER). Past the last line, the last line repeats.
cat > "$bin/agent-test-plan" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$2" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$2"
total=$(wc -l < "$1" | tr -d ' ')
if [ "$n" -gt "$total" ]; then n=$total; fi
sed -n "${n}p" "$1"
STUB

# claude: records each call in the fixture (argv, environment, working directory, prompt, and the --add-dir
# directory as it was at the call), then acts on the next line of claude-plan. The actions: edit (a new file in
# the clone, the PR body and verdicts), nobody (a new file and the verdicts, no PR body), none
# (the verdicts only), empty (the PR body and verdicts, no change), write PATH (a file at PATH, the
# body and verdicts), move SRC DEST (SRC moved to DEST, the body and verdicts), gitconfig (a change to
# .git/config and a new file), rmio (a new file, then the --add-dir directory is removed), fail (exit 3), silent (nothing, not even verdicts), leak
# (prints its token, then exits 3). The escapes, which a container should stop: tamper-askpass and
# tamper-qodo (overwrite the runner's askpass and main's qodo-status.sh, in its private directory),
# tamper-awk (overwrite main's qodo-review.awk, in its private directory), insteadof (a
# url rewrite in the throwaway HOME's and the fixture's .gitconfig, then a change), plant-body (the PR body names both tokens) and
# plant-file (a file in the change holds the model's token). weaken (rewrites the clone's check-site.sh
# to pass, and writes broken.txt, which main's copy of the checker rejects) and tamper-check (overwrites
# main's check-site.sh in its private directory). tamper-delivery (overwrites main's check-delivery.sh, which
# qodo-status.sh runs) and tamper-nested (appends to main's scripts/agent/prompt.md, a file below the top
# of scripts/) are caught the same way.
cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
# @FX@ is the fixture directory: setup_repos writes it in, since the runner gives this stub its own HOME.
set -euo pipefail
fx=@FX@
n=$(( $(cat "$fx/claude-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$fx/claude-count"
addir=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --add-dir ]; then addir=$arg; fi
  prev=$arg
done
printf '%s\n' "$@" > "$fx/claude-$n.argv"
env > "$fx/claude-$n.env"
pwd > "$fx/claude-$n.cwd"
cat > "$fx/claude-$n.prompt"
rm -rf "$fx/claude-$n-io"
cp -R "$addir" "$fx/claude-$n-io"
body() {
  printf '## Why\n\nstub why, call %s\n\n## How\n\nstub how\n\n## What\n\nstub what\n\n## Assistance and third-party material\n\nnone\n\n## Limitations\n\nnone\n' "$n" > "$addir/pr-body.md"
}
verdict() { echo "verdict from call $n: fixed" > "$addir/verdicts.md"; }
action=$(agent-test-plan "$fx/claude-plan" "$fx/claude-plan-count")
case "$action" in
  edit) echo "change $n" > "fix-$n.txt"; body; verdict ;;
  nobody) echo "change $n" > "fix-$n.txt"; verdict ;;
  none) verdict ;;
  empty) body; verdict ;;
  write\ *) path=${action#write }; mkdir -p "$(dirname "$path")"; echo "change $n" > "$path"; body; verdict ;;
  move\ *) rest=${action#move }; mkdir -p "$(dirname "${rest##* }")"; mv "${rest% *}" "${rest##* }"; body; verdict ;;
  gitconfig)
    printf '[url "https://evil.example/"]\n\tinsteadOf = https://github.com/\n' >> .git/config
    echo "change $n" > "fix-$n.txt"; body; verdict ;;
  rmio) echo "change $n" > "fix-$n.txt"; body; verdict; rm -rf "$addir" ;;
  tamper-askpass) printf 'echo tampered\n' > "$(dirname "$addir")/priv/askpass"; body; verdict ;;
  tamper-awk) printf '' > "$(dirname "$addir")/priv/main/scripts/qodo-review.awk"; body; verdict ;;
  tamper-qodo) printf 'echo tampered\n' > "$(dirname "$addir")/priv/main/scripts/qodo-status.sh"; body; verdict ;;
  insteadof)
    printf '[url "%s"]\n\tinsteadOf = %s\n' "$fx/evil.git" "$fx/fork.git" >> "$HOME/.gitconfig"
    printf '[url "%s"]\n\tinsteadOf = %s\n' "$fx/evil.git" "$fx/fork.git" >> "$fx/.gitconfig"
    git init -q --bare -b main "$fx/evil.git"
    echo "change $n" > "fix-$n.txt"; body; verdict ;;
  plant-body)
    echo "change $n" > "fix-$n.txt"; body
    echo "Leaked: test-fork-token and test-pr-token." >> "$addir/pr-body.md"; verdict ;;
  plant-file) echo "change $n" > "fix-$n.txt"; body; verdict; echo "$CLAUDE_CODE_OAUTH_TOKEN" > leak.txt ;;
  weaken) printf 'exit 0\n' > scripts/check-site.sh; echo "change $n" > broken.txt; body; verdict ;;
  tamper-check) printf 'exit 0\n' > "$(dirname "$addir")/priv/main/scripts/check-site.sh"; body; verdict ;;
  tamper-delivery) printf 'echo tampered\n' > "$(dirname "$addir")/priv/main/scripts/check-delivery.sh"; body; verdict ;;
  tamper-nested) printf 'echo tampered\n' >> "$(dirname "$addir")/priv/main/scripts/agent/prompt.md"; body; verdict ;;
  silent) ;;
  leak) echo "the token is $CLAUDE_CODE_OAUTH_TOKEN"; exit 3 ;;
  fail) exit 3 ;;
  *) echo "claude stub: unknown plan step $action" >&2; exit 9 ;;
esac
STUB

# checks: records any token in its environment, then acts on the next line of checks-plan. The step
# tamper writes a guarded path (.claude/settings.json) and fails.
cat > "$bin/agent-test-check" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
fx=$HOME
env | grep -E '^(AGENT_FORK_TOKEN|AGENT_PR_TOKEN|GH_TOKEN|GITHUB_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' >> "$fx/checks-tokens.txt" || true
echo "checks ran" >> "$fx/checks-runs.log"
step=$(agent-test-plan "$fx/checks-plan" "$fx/checks-plan-count")
if [ "$step" = pass ]; then echo "checks pass"; exit 0; fi
if [ "$step" = tamper ]; then
  mkdir -p .claude; echo '{"hooks": {}}' > .claude/settings.json
  echo "build failed: the checks changed a guarded path (fixture)"; exit 1
fi
echo "build failed: _site/index.html is missing (fixture)"
exit 1
STUB

# qodo-status.sh's stand-in: logs its arguments, then prints the next line of qodo-plan, "EXIT OPEN"
# (OPEN "-" or absent: no open line). setup_repos also copies it to main's scripts/qodo-status.sh.
cat > "$bin/agent-test-qodo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
fx=$HOME
echo "$*" >> "$fx/qodo-calls.log"
step=$(agent-test-plan "$fx/qodo-plan" "$fx/qodo-plan-count")
read -r rc open <<< "$step" || true
open=${open:--}
echo "head: 1111111111111111111111111111111111111111"
if [ "$open" != - ]; then echo "open: $open"; fi
if [ -e "$fx/qodo-leak" ]; then echo "leaked: $AGENT_FORK_TOKEN and $CLAUDE_CODE_OAUTH_TOKEN"; fi
echo "status: stub"
exit "$rc"
STUB

# docker: "info" succeeds unless docker-down is in the fixture. "run" logs its arguments to
# docker-N.argv (one per line, N counted per run), then runs its command on this host as a
# container would: with only the -e variables in its environment (HOME stays the fixture, which
# the other stubs read), in the -w directory, and with --entrypoint in front of the command. An
# image with no command (the build) does nothing. Each docker run is one container.
cat > "$bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
fx=$HOME
if [ "$1" = info ]; then
  if [ -e "$fx/docker-down" ]; then echo "Cannot connect to the Docker daemon (fixture)" >&2; exit 1; fi
  exit 0
fi
[ "$1" = run ] || { echo "docker stub: unsupported: $*" >&2; exit 9; }
shift
n=$(( $(cat "$fx/docker-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$fx/docker-count"
printf '%s\n' "$@" > "$fx/docker-$n.argv"
envs=()
mounts=()
wd=""
entry=""
cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rm|-i) shift ;;
    -e) envs+=("$2"); shift 2 ;;
    -v) mounts+=("$2"); shift 2 ;;
    -w) wd=$2; shift 2 ;;
    --entrypoint) entry=$2; shift 2 ;;
    --tmpfs|--network|--user|--platform) shift 2 ;;
    -*) echo "docker stub: unknown option $1" >&2; exit 9 ;;
    *) shift; cmd=("$@"); break ;;
  esac
done
if [ -n "$entry" ]; then cmd=("$entry" ${cmd[@]+"${cmd[@]}"}); fi
if [ ${#cmd[@]} -eq 0 ]; then exit 0; fi
# The working directory is a container path: the host directory mounted there.
for m in ${mounts[@]+"${mounts[@]}"}; do
  rest=${m#*:}
  if [ "${rest%%:*}" = "$wd" ]; then wd=${m%%:*}; fi
done
# A mounted path the command names (main's check-site.sh) is the host file the container would see.
for m in ${mounts[@]+"${mounts[@]}"}; do
  rest=${m#*:}
  for i in "${!cmd[@]}"; do cmd[$i]=${cmd[$i]//"${rest%%:*}"/"${m%%:*}"}; done
done
inner=(env -i "PATH=$PATH" "HOME=$fx")
for e in ${envs[@]+"${envs[@]}"}; do
  case "$e" in
    HOME=*) ;;
    *=*) inner+=("$e") ;;
    *) if [ -n "${!e:-}" ]; then inner+=("$e=${!e}"); fi ;;
  esac
done
if [ -n "$wd" ]; then cd "$wd"; fi
exec "${inner[@]}" "${cmd[@]}"
STUB

chmod +x "$bin"/*

# Fixtures and helpers ---------------------------------------------------------

footer_text='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
std_body=$(printf 'The footer shows the wrong year.\n\n## Acceptance criteria\n\n- [ ] The footer shows the current year\n- [x] A CI assertion covers it\n\n## Notes\n\nISSUE-BODY-MARKER\n')
# shellcheck disable=SC2016 # the checklist's text, not expansion
std_checklist=$'- [ ] The footer shows the current year\n- [x] A CI assertion covers it'

# issue_fixture TITLE BODY [LABELS_JSON] [AUTHOR]: the issue the stub serves.
issue_fixture() {
  local labels=${3:-'[{"name":"bug"}]'}
  jq -n --arg title "$1" --arg body "$2" --argjson labels "$labels" \
    --arg author "${4:-lmilbaum}" \
    '{state: "OPEN", title: $title, author: {login: $author}, labels: $labels, body: $body}' > "$fx/issue.json"
}

# new_case: a fresh fixture directory with the default plans and fixtures: a bug with criteria,
# checks that pass, Qodo clear on the first look, CI green on the head, and no open PR.
new_case() {
  ncase=$((ncase + 1))
  fx=$tmp/case-$ncase
  mkdir -p "$fx" "$fx/tmp"
  printf 'edit\n' > "$fx/claude-plan"
  printf 'pass\n' > "$fx/checks-plan"
  printf '0 0\n' > "$fx/qodo-plan"
  printf '[]\n' > "$fx/pr-list.json"
  printf '[{"name":"check-site","bucket":"pass"},{"name":"qodo-findings","bucket":"pass"},{"name":"snapshot-site","bucket":"skipping"}]\n' > "$fx/pr-checks.json"
  echo "https://github.com/lioramilbaum/lioramilbaum.github.io/pull/99" > "$fx/pr-url"
  jq -n '{data: {repository: {pullRequest: {comments: {nodes: [
    {createdAt: "2026-11-08T10:00:00Z", author: {login: "qodo-code-review[bot]"},
     body: "Code Review by Qodo\n<!-- x/commit/1111111111111111111111111111111111111111 -->\nNice, no open findings for this group."}
  ]}}}}}' > "$fx/qodo-comments.json"
  issue_fixture "Footer year is stale" "$std_body"
}

# setup_repos: the upstream (up.git, origin of the clone), the fork (fork.git) and the clone. main
# holds the runner, its prompt, the build wrapper, check-site.yml (the image tag) and snapshot-site.sh
# (the image), as the workflow's checkout has them; its check-site.sh and qodo-status.sh are the
# stand-ins. The clone has
# a Claude Code copy (the claude stub) under scripts/agent/node_modules, as npm ci leaves it, unless
# no_claude is set. no_image makes main's snapshot-site.sh lack its image line.
setup_repos() {
  local seed=$fx/seed
  git init -q -b main "$seed"
  git -C "$seed" config user.name test
  git -C "$seed" config user.email test@example.com
  mkdir -p "$seed/scripts/agent" "$seed/.github/workflows" "$seed/.claude"
  cp "$root/scripts/agent-run.sh" "$seed/scripts/agent-run.sh"
  cp "$root/scripts/agent/prompt.md" "$seed/scripts/agent/prompt.md"
  cp "$root/scripts/build-site.sh" "$seed/scripts/build-site.sh"
  cp "$root/.github/workflows/check-site.yml" "$seed/.github/workflows/check-site.yml"
  cp "$root/.gitignore" "$seed/.gitignore"
  if [[ -n "${no_image:-}" ]]; then
    sed 's/^image=/imagex=/' "$root/scripts/snapshot-site.sh" > "$seed/scripts/snapshot-site.sh"
  else
    cp "$root/scripts/snapshot-site.sh" "$seed/scripts/snapshot-site.sh"
  fi
  cp "$bin/agent-test-qodo" "$seed/scripts/qodo-status.sh"
  cp "$root/scripts/qodo-review.awk" "$seed/scripts/qodo-review.awk"
  # check-delivery.sh is a stand-in too: main's qodo-status.sh runs it, so the runner's checksums cover it.
  echo 'echo "check-delivery stand-in"' > "$seed/scripts/check-delivery.sh"
  # The checker is a stand-in: the real check-site.sh needs a built site, and the fixture has none. It
  # fails while broken.txt is in the directory it runs from (the change a test makes). It logs its run
  # and any token in its environment, as the checks' stub does, since main's copy runs in the container.
  cat > "$seed/scripts/check-site.sh" <<'FIXTURE'
#!/usr/bin/env bash
env | grep -E '^(AGENT_FORK_TOKEN|AGENT_PR_TOKEN|GH_TOKEN|GITHUB_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' >> "$HOME/checks-tokens.txt" || true
echo "check-site ran" >> "$HOME/check-site-runs.log"
if [[ -e broken.txt ]]; then echo "check-site: broken.txt is in the clone (fixture)"; exit 1; fi
echo "check-site passes (fixture)"
FIXTURE
  echo '{}' > "$seed/.claude/settings.json"
  echo "# Site" > "$seed/README.md"
  mkdir -p "$seed/deliveries"
  echo "# Delivery" > "$seed/deliveries/x.md"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "seed"
  git init -q --bare -b main "$fx/up.git"
  git init -q --bare -b main "$fx/fork.git"
  git -C "$seed" push -q "$fx/up.git" main
  git -C "$seed" push -q "$fx/fork.git" main
  git -C "$seed" rev-parse main > "$fx/seed-sha"
  git clone -q "$fx/up.git" "$fx/repo"
  git -C "$fx/repo" config user.name test
  git -C "$fx/repo" config user.email test@example.com
  if [[ -z "${no_claude:-}" ]]; then
    mkdir -p "$fx/repo/scripts/agent/node_modules/.bin"
    sed "s|@FX@|$fx|g" "$bin/claude" > "$fx/repo/scripts/agent/node_modules/.bin/claude"
    chmod +x "$fx/repo/scripts/agent/node_modules/.bin/claude"
  fi
}

# docker_values FLAG FILE: the argument after each FLAG in a docker argv file (one argument per line).
docker_values() { awk -v f="$1" 'prev == f { print } { prev = $0 }' "$2"; }
# abs DIR: DIR as a process in it sees its working directory (PWD).
abs() { (cd "$1" && pwd); }

# need COMMAND...: the command must succeed, or the case fails with it named.
need() { "$@" || { echo "  needed: $*" >&2; return 1; }; }
# need_not COMMAND...: the command must fail.
need_not() { if "$@"; then echo "  must not: $*" >&2; return 1; fi; }
# contains TEXT FILE...: TEXT is in the files.
contains() {
  local text=$1
  shift
  [[ "$(cat "$@")" == *"$text"* ]]
}

# has TEXT SUBSTRING: the string contains the substring.
has() { [[ "$1" == *"$2"* ]]; }

# common: what no run may do (the cases' shared guarantees, AGENTS.md Setup): no merge, no push to
# main or screenshots, no ready-for-agent added, and the upstream still has only main.
common() {
  need_not grep -q 'pr merge' "$fx/gh-calls.log"
  need_not grep -q 'add-label ready-for-agent' "$fx/gh-calls.log"
  need test "$(git -C "$fx/up.git" for-each-ref --format='%(refname)' refs/heads)" = refs/heads/main
  need test "$(git -C "$fx/up.git" rev-parse refs/heads/main)" = "$(cat "$fx/seed-sha")"
  need test "$(git -C "$fx/fork.git" rev-parse refs/heads/main)" = "$(cat "$fx/seed-sha")"
  need_not grep -q 'HEAD:refs/heads/main\|screenshots' "$fx/git-push.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/screenshots
  need_not ls -d "$fx"/tmp/agent-run.*
}

# run_runner ISSUE: runs the runner in the case's clone (set up once per case), with the test
# tokens unless the case blanks one first (tok_claude, tok_fork, tok_pr). runner_path replaces the
# runner's PATH (the default is the stubs and the test's PATH). checks_cmd_test replaces the clone's
# checks command (AGENT_CHECKS; default the checks stub), for a case that runs the clone's own
# check-site.sh. Sets rc_runner, prints the runner's output for a failing case, and checks common.
run_runner() {
  if [[ ! -d "$fx/repo" ]]; then setup_repos; fi
  set +e
  (
    cd "$fx/repo"
    env PATH="${runner_path-$bin:$PATH}" HOME="$fx" TMPDIR="$fx/tmp" \
      ${denied_dirs:+AGENT_DENIED_DIRS="$denied_dirs"} \
      CLAUDE_CODE_OAUTH_TOKEN="${tok_claude-test-claude-token}" \
      AGENT_FORK_TOKEN="${tok_fork-test-fork-token}" \
      AGENT_PR_TOKEN="${tok_pr-test-pr-token}" \
      AGENT_CHECKS="${checks_cmd_test-agent-test-check}" \
      AGENT_SLEEP=true \
      AGENT_FORK_URL="$fx/fork.git" \
      "$bash_bin" scripts/agent-run.sh --issue "$1"
  ) > "$fx/runner.log" 2>&1
  rc_runner=$?
  set -e
  sed 's/^/  runner: /' "$fx/runner.log" >&2
  common
}

# run_case NAME FUNCTION: runs one case in a subshell. A failing command fails the case; the case's
# output is shown then.
run_case() {
  local name=$1 out rc=0
  shift
  ncase=$((ncase + 1))
  out=$tmp/out-$ncase.log
  set +e
  ( set -e; "$@" ) > "$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    sed 's/^/     /' "$out" | tail -n 30
    failures=$((failures + 1))
  fi
}

# Cases ------------------------------------------------------------------------

case_a_no_criteria() {
  new_case
  issue_fixture "Footer year is stale" "The footer shows the wrong year. No checklist here."
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not test -e "$fx/claude-count"
  need grep -qi 'acceptance criteria' "$fx"/body-*.md
  need grep -qF -- '--add-label agent-stuck' "$fx/gh-calls.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_b_happy_path() {
  new_case
  run_runner 41
  need test "$rc_runner" -eq 0
  # One commit above main, pushed to the fork's fix branch, with the owner's author and the trailer.
  need test "$(git -C "$fx/fork.git" rev-list --count main..fix/issue-41)" -eq 1
  need test "$(git -C "$fx/fork.git" log -1 --format=%s fix/issue-41)" = "fix: Footer year is stale"
  need test "$(git -C "$fx/fork.git" log -1 --format='%an <%ae>' fix/issue-41)" = "Liora Milbaum <7271026+lmilbaum@users.noreply.github.com>"
  last=$(git -C "$fx/fork.git" log -1 --format=%B fix/issue-41 | sed '/^[[:space:]]*$/d' | tail -n 1)
  need test "$last" = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  need grep -qF "HEAD:refs/heads/fix/issue-41" "$fx/git-push.log"
  need test "$(cat "$fx/askpass.log")" = "$(printf 'x-access-token\ntest-fork-token')"
  need_not grep -q test-fork-token "$fx/git-push.log"
  # The PR: on upstream, from the owner's fork, with the PR token, the closing line and the checklist.
  need grep -qF -- "pr create --repo $repo --head lmilbaum:fix/issue-41 --base main" "$fx/gh-calls.log"
  need grep -q 'pr create.*\[token=test-pr-token\]' "$fx/gh-calls.log"
  need contains "Closes #41" "$fx"/body-*.md
  need contains "$std_checklist" "$fx"/body-*.md
  need contains "stub why, call 1" "$fx"/body-*.md
  need contains "$footer_text" "$fx"/body-*.md
  need_not contains "ISSUE-BODY-MARKER" "$fx"/body-*.md
  # The model: the issue is a data file, not on its command line.
  need_not grep -qF "ISSUE-BODY-MARKER" "$fx/claude-1.argv"
  need grep -qF "ISSUE-BODY-MARKER" "$fx/claude-1-io/issue.md"
  # The checks ran with no token in their environment.
  need_not test -s "$fx/checks-tokens.txt"
  # The build (docker-1) is main's build-site.sh on the clone, with no network. The clone's copy of the
  # checks (docker-2) runs with no network, no environment, and the clone read-only. main's copy
  # (docker-3) runs the same way, with main's check-site.sh mounted read-only from the private directory.
  need test "$(docker_values --network "$fx/docker-1.argv")" = none
  need grep -qxF -- "$(abs "$fx/repo"):/github/workspace" "$fx/docker-1.argv"
  need test "$(docker_values --network "$fx/docker-2.argv")" = none
  need test "$(docker_values -e "$fx/docker-2.argv")" = ""
  need test "$(docker_values -v "$fx/docker-2.argv")" = "$(abs "$fx/repo"):/clone:ro"
  need test "$(docker_values -w "$fx/docker-2.argv")" = /clone
  need test "$(docker_values --entrypoint "$fx/docker-2.argv")" = bash
  local work
  work=$(dirname "$(awk 'prev == "--add-dir" { print } { prev = $0 }' "$fx/claude-1.argv")")
  need test "$(docker_values --network "$fx/docker-3.argv")" = none
  need test "$(docker_values -e "$fx/docker-3.argv")" = ""
  need test "$(docker_values -w "$fx/docker-3.argv")" = /clone
  need test "$(docker_values --entrypoint "$fx/docker-3.argv")" = bash
  need grep -qxF -- "$(abs "$fx/repo"):/clone:ro" "$fx/docker-3.argv"
  need grep -qxF -- "$work/priv/main/scripts/check-site.sh:/main-check-site.sh:ro" "$fx/docker-3.argv"
  need grep -qxF -- 'bash /main-check-site.sh _site' "$fx/docker-3.argv"
  need test "$(wc -l < "$fx/check-site-runs.log" | tr -d ' ')" -eq 1
  # The PR head's checks are read with the PR token.
  need grep -q '^pr checks 99 .*\[token=test-pr-token\]' "$fx/gh-calls.log"
  # gh runs from the work directory, never from the clone (a clone's .git/config is the model's to write).
  need_not grep -qF "[cwd=$(cd "$fx/repo" && pwd -P)]" "$fx/gh-calls.log"
  need grep -q "\[cwd=.*/agent-run\.[^/]*\]" "$fx/gh-calls.log"
  need grep -qF -- "--add-label agent-done" "$fx/gh-calls.log"
  need grep -qF "ready for the owner" "$fx/gh-calls.log"
}

case_c_checks_never_pass() {
  new_case
  printf 'fail\n' > "$fx/checks-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

case_d_checks_pass_on_third() {
  new_case
  printf 'fail\nfail\npass\n' > "$fx/checks-plan"
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(cat "$fx/claude-count")" -eq 3
  need grep -q 'build failed' "$fx/claude-2-io/checks-log.txt"
  need grep -q 'run 1 of 3' "$fx/claude-2.prompt"
  need grep -q 'run 2 of 3' "$fx/claude-3.prompt"
  need grep -qF -- '--add-label agent-done' "$fx/gh-calls.log"
}

case_d_checks_always_fail() {
  new_case
  printf 'fail\n' > "$fx/checks-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 3
  need test "$(wc -l < "$fx/checks-runs.log" | tr -d ' ')" -eq 3
  need grep -q 'stopped at the checks stage' "$fx"/body-*.md
  need grep -q 'build failed' "$fx"/body-*.md
  need_not grep -q 'pr create' "$fx/gh-calls.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
  need grep -qF -- '--add-label agent-stuck' "$fx/gh-calls.log"
}

case_e_qodo_three_rounds() {
  new_case
  printf '0 2\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  # One implement call and one per round; the pushes are the first plus one lease per round.
  need test "$(cat "$fx/claude-count")" -eq 4
  need test "$(wc -l < "$fx/git-push.log" | tr -d ' ')" -eq 4
  need test "$(grep -c -- '--force-with-lease=refs/heads/fix/issue-41:' "$fx/git-push.log")" -eq 3
  need test "$(git -C "$fx/fork.git" rev-list --count main..fix/issue-41)" -eq 1
  need grep -q 'round 3 of 3' "$fx"/body-*.md
  need grep -q 'verdict from call 4' "$fx"/body-*.md
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
}

case_e_qodo_clears_after_fix() {
  new_case
  printf '0 2\n0 0\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(cat "$fx/claude-count")" -eq 2
  need test "$(grep -c -- '--force-with-lease=refs/heads/fix/issue-41:' "$fx/git-push.log")" -eq 1
  need test "$(git -C "$fx/fork.git" rev-list --count main..fix/issue-41)" -eq 1
  need grep -qF -- '--add-label agent-done' "$fx/gh-calls.log"
}

case_f_qodo_never_settles() {
  new_case
  printf '3\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(wc -l < "$fx/qodo-calls.log" | tr -d ' ')" -eq 40
  need grep -q 'still waiting for Qodo' "$fx"/body-*.md
  need test "$(cat "$fx/claude-count")" -eq 1
}

case_g_qodo_unknown_layout() {
  new_case
  printf '0 unknown\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(wc -l < "$fx/qodo-calls.log" | tr -d ' ')" -eq 1
  need test "$(cat "$fx/claude-count")" -eq 1
  need grep -q 'open: unknown' "$fx"/body-*.md
}

case_h_model_flags() {
  new_case
  run_runner 41
  need test "$rc_runner" -eq 0
  # The exact argv of the model's call: the restricted mode, the five file tools, the deny rules
  # (claude_deny in scripts/agent-run.sh; keep this list in step with it), and $io as the added
  # directory. The working directory is the clone.
  local io work repo home expected deny=() argv_file=$fx/claude-1.argv
  io=$(awk 'prev == "--add-dir" { print } { prev = $0 }' "$argv_file")
  work=$(dirname "$io")
  repo=$(cat "$fx/claude-1.cwd")
  deny=(
    "Read(//proc/**)" "Read(//etc/**)"
    "Read(//${work#/}/priv/**)" "Read(//${fx#/}/.config/**)" "Read(//${fx#/}/.docker/**)"
    "Read(//${fx#/}/.ssh/**)" "Read(//${fx#/}/.gitconfig)"
    "Edit(//${repo#/}/.git/**)" "Edit(//${repo#/}/.claude/**)" "Edit(//${repo#/}/.mcp.json)"
    "Edit(//${repo#/}/.github/**)" "Edit(//${repo#/}/CNAME)" "Edit(//${repo#/}/deliveries/**)"
    "Edit(//${repo#/}/scripts/agent-run.sh)" "Edit(//${repo#/}/scripts/agent/**)"
    "Edit(//${repo#/}/scripts/build-site.sh)"
  )
  expected=$(printf '%s\n' -p --model claude-opus-5-5 --max-turns 120 --restricted \
    --permission-prompts none --tools Read Edit Write Glob Grep \
    --allowedTools Read Edit Write Glob Grep --disallowedTools "${deny[@]}" --add-dir "$io")
  need test "$(cat "$argv_file")" = "$expected"
  need test "$repo" = "$(abs "$fx/repo")"
  # Its environment: exactly the token, PATH and a throwaway HOME (not the runner's HOME).
  home=$(sed -n 's/^HOME=//p' "$fx/claude-1.env")
  need test "$(dirname "$home")" = "$work"
  need test "$(basename "$home")" = home
  need test "$home" != "$fx"
  need grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=test-claude-token' "$fx/claude-1.env"
  need_not grep -qE '^(AGENT_FORK_TOKEN|AGENT_PR_TOKEN|GH_TOKEN|GITHUB_TOKEN)=' "$fx/claude-1.env"
  need_not grep -qF -- 'test-fork-token' "$fx/claude-1.env"
}

case_i_guarded_path() {
  local path=$1
  new_case
  printf 'write %s\n' "$path" > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'may not change' "$fx"/body-*.md
  need grep -q "$path" "$fx"/body-*.md
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_i_renamed_out SRC DEST: a model that moves a guarded file to an allowed path is refused. The diff
# must list the old path too (--no-renames), or the rename hides SRC and the move is committed.
case_i_renamed_out() {
  new_case
  printf 'move %s %s\n' "$1" "$2" > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "may not change: $1" "$fx"/body-*.md
  need_not grep -q 'pr create' "$fx/gh-calls.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_j_empty_change() {
  new_case
  printf 'empty\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'The change is empty' "$fx"/body-*.md
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_k_branch_on_fork() {
  new_case
  setup_repos
  git -C "$fx/repo" push -q "$fx/fork.git" HEAD:refs/heads/fix/issue-41
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not test -e "$fx/claude-count"
  need grep -q 'already exists on the fork' "$fx"/body-*.md
}

case_k_open_pr_for_issue() {
  new_case
  printf '[{"number": 50, "headRefName": "feat/other", "body": "Some text.\\n\\nCloses #41"}]\n' > "$fx/pr-list.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not test -e "$fx/claude-count"
  need grep -q 'already cover issue #41: #50' "$fx"/body-*.md
}

case_k_open_pr_on_branch() {
  new_case
  printf '[{"number": 51, "headRefName": "fix/issue-41", "body": ""}]\n' > "$fx/pr-list.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not test -e "$fx/claude-count"
  need grep -q 'already cover issue #41: #51' "$fx"/body-*.md
}

case_l_not_owners_issue() {
  new_case
  issue_fixture "Footer year is stale" "$std_body" '[{"name":"bug"}]' someone-else
  run_runner 41
  need test "$rc_runner" -ne 0
  need_not test -e "$fx/claude-count"
  need grep -q 'was not written by lmilbaum' "$fx"/body-*.md
}

case_m_model_fails() {
  new_case
  printf 'fail\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'exited with status 3 on call 1' "$fx"/body-*.md
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_n_no_pr_body() {
  new_case
  printf 'nobody\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 1
  need grep -q 'did not write' "$fx"/body-*.md
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_o_round_changes_nothing() {
  new_case
  printf 'edit\nnone\n' > "$fx/claude-plan"
  printf '0 2\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 2
  need test "$(wc -l < "$fx/git-push.log" | tr -d ' ')" -eq 1
  need grep -q 'Round 1 of 3 changed nothing' "$fx"/body-*.md
  need grep -q 'verdict from call 2' "$fx"/body-*.md
}

# case_qodo_checks_exhausted: a Qodo round whose checks stay failing stops at the checks stage, and the
# model's verdicts from that round are on the PR first (the verdicts file is in the work directory,
# which the exit removes). Calls: implement (1), the round (2, which writes the verdicts and a change),
# and two silent check fixes (3 and 4), so the verdicts file is still the round's.
case_qodo_checks_exhausted() {
  new_case
  printf 'edit\nedit\nsilent\nsilent\n' > "$fx/claude-plan"
  printf 'pass\nfail\n' > "$fx/checks-plan"
  printf '0 2\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 4
  need grep -q 'stopped at the checks stage (run 3 of 3)' "$fx"/body-*.md
  need grep -q "The agent's verdicts on Qodo's findings" "$fx"/body-*.md
  need grep -q 'verdict from call 2' "$fx"/body-*.md
  need grep -q 'pr comment 99' "$fx/gh-calls.log"
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
}

# case_qodo_verdicts_unposted: a Qodo round that stops, with the verdicts comment failing to post, says
# so in the stop comment (not that the verdicts are on the PR) and writes the verdicts to the run log.
# The gh stub fails only the verdicts comment (its --body-file name is in gh-fail-match), so the
# stop comments on the issue and the PR still post. Calls: implement (1) and the round (2, which
# writes the verdicts and no change).
case_qodo_verdicts_unposted() {
  new_case
  printf 'edit\nnone\n' > "$fx/claude-plan"
  printf '0 2\n' > "$fx/qodo-plan"
  printf 'verdicts-comment.md\n' > "$fx/gh-fail-match"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'changed nothing' "$fx"/body-*.md
  need grep -q 'could not be posted on the PR; they are in the run log' "$fx"/body-*.md
  need_not grep -q "verdicts are on the PR" "$fx"/body-*.md
  need grep -q 'verdict from call 2' "$fx/runner.log"
}

case_p_qodo_status_fails() {
  new_case
  printf '1 -\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'qodo-status.sh failed (exit 1)' "$fx"/body-*.md
  need test "$(cat "$fx/claude-count")" -eq 1
}

case_q_missing_token() {
  new_case
  tok_pr=
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'AGENT_PR_TOKEN is not set' "$fx/runner.log"
  need_not test -e "$fx/gh-calls.log"
  need_not test -e "$fx/claude-count"
}

case_q_missing_claude() {
  new_case
  no_claude=1
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'no claude binary' "$fx/runner.log"
  need_not test -e "$fx/gh-calls.log"
}

# case_read_denied_prefix DIR: the clone, or $io, under a directory the model's Read rules deny (on the
# runner, /home) stops before claude is called. DIR is a fixture directory, named by the case's argument;
# AGENT_DENIED_DIRS names it, since a test cannot create /home.
case_read_denied_prefix() {
  new_case
  denied_dirs="$fx/$1"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'Read rules deny' "$fx/runner.log"
  need_not test -e "$fx/claude-count"
  need_not test -e "$fx/gh-calls.log"
}

case_r_feature_branch() {
  new_case
  issue_fixture "Add a reading list" "$std_body" '[{"name":"enhancement"}]'
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(git -C "$fx/fork.git" log -1 --format=%s feat/issue-41)" = "feat: Add a reading list"
  need grep -qF -- "--head lmilbaum:feat/issue-41" "$fx/gh-calls.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_s_model_changes_git_config() {
  new_case
  printf 'gitconfig\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q '.git/config changed during the run' "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

case_t_qodo_comment_missing() {
  new_case
  printf '0 2\n' > "$fx/qodo-plan"
  jq -n '{data: {repository: {pullRequest: {comments: {nodes: []}}}}}' > "$fx/qodo-comments.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 1
  need grep -q 'was not found' "$fx"/body-*.md
}

case_qodo_undecodable() {
  new_case
  printf '0 2\n' > "$fx/qodo-plan"
  # The review's one comment line, with a body that is not base64 (@base64 never makes one, so the
  # gh stub prints the line itself).
  printf 'PAGE|false|\nQCOMMENT|2026-11-08T10:00:00Z|!!!not-base64!!!\n' > "$fx/gh-raw-api-graphql"
  run_runner 41
  need test "$rc_runner" -ne 0
  # One call: the initial change. The stop comes before the fix round's call.
  need test "$(cat "$fx/claude-count")" -eq 1
  need grep -qF "could not decode Qodo's review comment" "$fx"/body-*.md
}

case_u_unexpected_failure() {
  new_case
  printf 'edit\nrmio\n' > "$fx/claude-plan"
  printf 'fail\n' > "$fx/checks-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'failed unexpectedly' "$fx"/body-*.md
  need grep -qF -- '--add-label agent-stuck' "$fx/gh-calls.log"
}

case_usage() {
  new_case
  run_runner abc
  need test "$rc_runner" -ne 0
  need grep -q 'usage: scripts/agent-run.sh --issue N' "$fx/runner.log"
}

case_closed_issue() {
  new_case
  jq '.state = "CLOSED"' "$fx/issue.json" > "$fx/issue2.json"
  mv "$fx/issue2.json" "$fx/issue.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'is not open' "$fx"/body-*.md
  need_not test -e "$fx/claude-count"
}

# case_tool_missing TOOL: the runner stops before any step when TOOL is not on its PATH.
case_tool_missing() {
  new_case
  local d=$fx/no-$1 f
  mkdir -p "$d"
  for f in "$bin"/*; do
    if [[ "$(basename "$f")" != "$1" ]]; then ln -s "$f" "$d/"; fi
  done
  if [[ "$1" != jq ]]; then ln -s "$(command -v jq)" "$d/"; fi
  runner_path=$d
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "$1 is not installed" "$fx/runner.log"
  need_not test -e "$fx/gh-calls.log"
  need_not test -e "$fx/claude-count"
}

# case_docker_down: the runner stops at once when the Docker daemon does not answer.
case_docker_down() {
  new_case
  : > "$fx/docker-down"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "cannot connect to the Docker daemon" "$fx/runner.log"
  need_not test -e "$fx/claude-count"
}

# case_image_unreadable: main's snapshot-site.sh has no image line, so the runner stops before the model.
case_image_unreadable() {
  new_case
  no_image=1
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "could not read the Playwright image" "$fx"/body-*.md
  need_not test -e "$fx/claude-count"
}

# case_tamper_awk: a model that rewrites main's qodo-review.awk, which qodo-status.sh reads, is caught
# before the push (host_sums covers the file).
case_tamper_awk() {
  new_case
  printf 'tamper-awk\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_qodo_second_page: Qodo's review is on the second page of the PR's comments, and the runner
# still reads it (the findings go to the model as qodo-review.md).
case_qodo_second_page() {
  new_case
  printf '0 2\n0 0\n' > "$fx/qodo-plan"
  jq -n '{data: {repository: {pullRequest: {comments: {pageInfo: {hasNextPage: true, endCursor: "c1"},
    nodes: [{createdAt: "2026-11-08T09:00:00Z", author: {login: "someone"}, body: "an ordinary comment"}]}}}}}' > "$fx/qodo-comments.json"
  jq -n '{data: {repository: {pullRequest: {comments: {pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [{createdAt: "2026-11-08T10:00:00Z", author: {login: "qodo-code-review[bot]"},
     body: "Code Review by Qodo\nPAGE-TWO-FINDING: the second page is read."}]}}}}}' > "$fx/qodo-comments-c1.json"
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(cat "$fx/claude-count")" -eq 2
  need grep -qF "PAGE-TWO-FINDING" "$fx/claude-2-io/qodo-review.md"
}

# case_qodo_status_leak: qodo-status.sh prints the runner's tokens. The stop comment and the runner's
# own log (the Actions log is public) hold none of them.
case_qodo_status_leak() {
  new_case
  printf '9 -\n' > "$fx/qodo-plan"
  : > "$fx/qodo-leak"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "qodo-status.sh failed (exit 9)" "$fx"/body-*.md
  need grep -qF "leaked: [redacted] and [redacted]" "$fx"/body-*.md
  need_not grep -qF -e test-fork-token -e test-claude-token "$fx"/body-*.md "$fx/runner.log"
}

# case_guarded_token_path: a change whose file name holds the model's token is refused, and the stop
# comment and the runner's log name the path with the token redacted.
case_guarded_token_path() {
  new_case
  printf 'write .github/workflows/test-claude-token.yml\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "may not change: .github/workflows/[redacted].yml" "$fx"/body-*.md
  need_not grep -qF -e test-claude-token "$fx"/body-*.md "$fx/runner.log"
}

# case_askpass_tampered: a model that rewrites the askpass script in the private directory (its rules
# keep it out) is caught before the push, which would have used it.
case_askpass_tampered() {
  new_case
  printf 'tamper-askpass\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not test -e "$fx/askpass.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_qodo_status_tampered: a model that rewrites main's qodo-status.sh is caught before Qodo is read.
case_qodo_status_tampered() {
  new_case
  printf 'tamper-qodo\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/qodo-calls.log"
}

# case_insteadof: a url rewrite the model writes to $HOME/.gitconfig has no effect on the push,
# which still goes to the fork.
case_insteadof() {
  new_case
  printf 'insteadof\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(git -C "$fx/fork.git" rev-list --count main..fix/issue-41)" -eq 1
  need_not git -C "$fx/evil.git" rev-parse --verify -q refs/heads/fix/issue-41
}

# case_planted_body_redacted: tokens the model writes into the PR body are redacted before gh sees it.
case_planted_body_redacted() {
  new_case
  printf 'plant-body\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -eq 0
  need grep -qF '[redacted]' "$fx"/body-*.md
  need_not grep -q 'test-fork-token' "$fx"/body-*.md
  need_not grep -q 'test-pr-token' "$fx"/body-*.md
}

# case_token_in_change: a change that holds the model's token is refused before the commit.
case_token_in_change() {
  new_case
  printf 'plant-file\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "contains one of the run's tokens" "$fx"/body-*.md
  need_not grep -q 'test-claude-token' "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

# case_checks_touch_guarded: checks that change a guarded path stop the run before the model's next
# call, so that call never runs a changed .claude/ config.
case_checks_touch_guarded() {
  new_case
  printf 'tamper\n' > "$fx/checks-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 1
  need grep -qF '.claude/settings.json' "$fx"/body-*.md
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

# case_weakened_clone_checker: a model that rewrites the clone's check-site.sh to pass, with a change
# main's copy rejects. The clone's copy passes; main's copy fails, so every run fails and the run stops
# at the checks stage after two fixes, with main's copy named in the log.
case_weakened_clone_checker() {
  new_case
  printf 'weaken\n' > "$fx/claude-plan"
  checks_cmd_test='bash scripts/check-site.sh _site'
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(cat "$fx/claude-count")" -eq 3
  need grep -qF "main's copy of check-site.sh failed" "$fx"/body-*.md
  need_not grep -qF "the clone's copy of check-site.sh failed" "$fx"/body-*.md
  need grep -q 'stopped at the checks stage (run 3 of 3)' "$fx"/body-*.md
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
  need_not git -C "$fx/fork.git" rev-parse --verify -q refs/heads/fix/issue-41
}

# case_tamper_check: a model that rewrites main's check-site.sh, in the runner's private directory, is
# caught before the push (host_sums covers the file).
case_tamper_check() {
  new_case
  printf 'tamper-check\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_tamper_delivery: a model that rewrites main's check-delivery.sh, which qodo-status.sh runs from the
# private directory, is caught before Qodo is read. Without the checksum on every file under main's
# scripts/, the rewrite would run with the tokens in qodo-status.sh's environment.
case_tamper_delivery() {
  new_case
  printf 'tamper-delivery\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/qodo-calls.log"
  need_not test -e "$fx/git-push.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_tamper_nested: a model that rewrites a file below main's scripts/ top level (scripts/agent/prompt.md)
# is caught before the push: the checksums cover the whole tree, not only its top level.
case_tamper_nested() {
  new_case
  printf 'tamper-nested\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "A file the runner reads or runs from its private directory changed" "$fx"/body-*.md
  need_not test -e "$fx/git-push.log"
  need_not grep -q 'pr create' "$fx/gh-calls.log"
}

# case_ci_failed: a check that failed on the PR head stops the run at the ci stage, naming it. The
# qodo-findings status is not a check the run waits on, so its failure is not named.
case_ci_failed() {
  new_case
  printf '[{"name":"check-site","bucket":"fail"},{"name":"snapshot-site","bucket":"cancel"},{"name":"qodo-findings","bucket":"fail"}]\n' > "$fx/pr-checks.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'stopped at the ci stage' "$fx"/body-*.md
  need grep -qF 'CI failed on the PR head: check-site, snapshot-site.' "$fx"/body-*.md
  need test "$(cat "$fx/claude-count")" -eq 1
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
  need grep -qF -- '--add-label agent-stuck' "$fx/gh-calls.log"
}

# case_ci_pending_forever: a check still running after the polls (40, as the default) stops the run,
# waiting for CI.
case_ci_pending_forever() {
  new_case
  printf '[{"name":"check-site","bucket":"pending"}]\n' > "$fx/pr-checks.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(grep -c '^pr checks ' "$fx/gh-calls.log")" -eq 40
  need grep -q 'stopped at the ci stage' "$fx"/body-*.md
  need grep -q 'waiting for CI' "$fx"/body-*.md
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
  need grep -qF -- '--add-label agent-stuck' "$fx/gh-calls.log"
}

# case_ci_none_reported: no check reported on the head is not green, so the run waits, then stops.
case_ci_none_reported() {
  new_case
  printf '[]\n' > "$fx/pr-checks.json"
  run_runner 41
  need test "$rc_runner" -ne 0
  need test "$(grep -c '^pr checks ' "$fx/gh-calls.log")" -eq 40
  need grep -q 'waiting for CI' "$fx"/body-*.md
  need_not grep -q -- '--add-label agent-done' "$fx/gh-calls.log"
}

# case_ci_qodo_gate_ignored: the qodo-findings status is still pending, and the other checks have
# passed: the run does not wait on Qodo's gate, and is done.
case_ci_qodo_gate_ignored() {
  new_case
  printf '[{"name":"check-site","bucket":"pass"},{"name":"qodo-findings","bucket":"pending"}]\n' > "$fx/pr-checks.json"
  run_runner 41
  need test "$rc_runner" -eq 0
  need test "$(grep -c '^pr checks ' "$fx/gh-calls.log")" -eq 1
  need grep -qF -- '--add-label agent-done' "$fx/gh-calls.log"
}

# case_ci_unreadable: gh's checks output that is not JSON stops the run, rather than waiting on it.
case_ci_unreadable() {
  new_case
  printf 'no checks here\n' > "$fx/gh-raw-pr-checks"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF "could not read the checks of PR 99" "$fx"/body-*.md
  need_not grep -qF -- '--add-label agent-done' "$fx/gh-calls.log"
}

# The build wrapper (AGENTS.md rule 8: its new argument has a test). With no argument it builds its
# own checkout. With one, it builds that directory, and reads the image tag from its own checkout.
case_build_site_default() {
  new_case
  mkdir -p "$fx/copy/scripts" "$fx/copy/.github/workflows"
  cp "$root/scripts/build-site.sh" "$fx/copy/scripts/"
  cp "$root/.github/workflows/check-site.yml" "$fx/copy/.github/workflows/"
  env PATH="$bin:$PATH" HOME="$fx" "$bash_bin" "$fx/copy/scripts/build-site.sh" > "$fx/build.log" 2>&1
  need grep -qxF -- "$(abs "$fx/copy"):/github/workspace" "$fx/docker-1.argv"
}

case_build_site_argument() {
  new_case
  mkdir -p "$fx/copy/scripts" "$fx/copy/.github/workflows" "$fx/other/.github/workflows"
  cp "$root/scripts/build-site.sh" "$fx/copy/scripts/"
  cp "$root/.github/workflows/check-site.yml" "$fx/copy/.github/workflows/"
  sed 's|@[0-9a-f]\{40\} # v[0-9][0-9.]*|@0000000000000000000000000000000000000000 # v9.9.9|' \
    "$root/.github/workflows/check-site.yml" > "$fx/other/.github/workflows/check-site.yml"
  (cd "$fx" && env PATH="$bin:$PATH" HOME="$fx" "$bash_bin" "$fx/copy/scripts/build-site.sh" "$fx/other") \
    > "$fx/build.log" 2>&1
  need grep -qxF -- "$(abs "$fx/other"):/github/workspace" "$fx/docker-1.argv"
  need grep -q 'jekyll-build-pages:v[0-9]' "$fx/docker-1.argv"
  need_not grep -q 'v9\.9\.9' "$fx/docker-1.argv"
}

# case_step_fails MARKER EXPECTED [QODO_PLAN]: the file MARKER in the fixture directory makes one
# git or gh step fail (see the stubs); the run stops there, saying EXPECTED.
case_step_fails() {
  new_case
  if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" > "$fx/qodo-plan"; fi
  : > "$fx/$1"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF -- "$2" "$fx"/body-*.md
}

case_token_redacted() {
  new_case
  printf 'leak\n' > "$fx/claude-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -qF '[redacted]' "$fx"/body-*.md
  need_not grep -q test-claude-token "$fx"/body-*.md
}

case_no_verdicts_file() {
  new_case
  printf 'edit\nsilent\n' > "$fx/claude-plan"
  printf '0 2\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'changed nothing' "$fx"/body-*.md
  need grep -q 'wrote no verdicts file' "$fx"/body-*.md
}

case_qodo_no_open_count() {
  new_case
  printf '0 -\n' > "$fx/qodo-plan"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'reported no open count' "$fx"/body-*.md
}

case_pr_url_unparsed() {
  new_case
  echo "not a url" > "$fx/pr-url"
  run_runner 41
  need test "$rc_runner" -ne 0
  need grep -q 'printed no PR number' "$fx"/body-*.md
}

# The label and comments after a successful run are best effort: a failure is a warning, and the
# run is still done.
case_ready_warning() {  # case_ready_warning MATCH WARNING
  new_case
  printf '%s\n' "$1" > "$fx/gh-fail-match"
  run_runner 41
  need test "$rc_runner" -eq 0
  need grep -qF "warning: $2" "$fx/runner.log"
  need grep -qF -- '--add-label agent-done' "$fx/gh-calls.log"
}

run_case "a: an issue without acceptance criteria stops before the model" case_a_no_criteria
run_case "b: happy path, one commit to the fork, PR upstream, ready for the owner" case_b_happy_path
run_case "c: checks that always fail stop before any push" case_c_checks_never_pass
run_case "d: checks fail twice, then pass, after two fixes" case_d_checks_pass_on_third
run_case "d: checks always fail, stop after the retry limit with the log" case_d_checks_always_fail
run_case "e: Qodo open every round, three rounds, leases, stop names round 3 of 3" case_e_qodo_three_rounds
run_case "e: Qodo clears after one fix round, the PR is ready" case_e_qodo_clears_after_fix
run_case "f: Qodo never settles, the wait ends after 20 minutes" case_f_qodo_never_settles
run_case "g: Qodo lists an unknown layout, stop at once" case_g_qodo_unknown_layout
run_case "h: the model runs with the restricted mode, exact allow and deny rules, a throwaway HOME" case_h_model_flags
run_case "i: an edit under .github/ stops before the commit" case_i_guarded_path .github/workflows/rogue.yml
run_case "i: an edit under deliveries/ stops before the commit" case_i_guarded_path deliveries/2026-11-08-x.md
run_case "i: an edit under .claude/ stops before the commit" case_i_guarded_path .claude/settings.json
run_case "i: an edit to build-site.sh stops before the commit" case_i_guarded_path scripts/build-site.sh
run_case "i: an edit to the runner stops before the commit" case_i_guarded_path scripts/agent-run.sh
run_case "i: a move of a file under deliveries/ to docs/ stops before the commit" case_i_renamed_out deliveries/x.md docs/x.md
run_case "i: a move of a file under .github/ to docs/ stops before the commit" case_i_renamed_out .github/workflows/check-site.yml docs/check-site.yml
run_case "j: an empty change stops before the commit" case_j_empty_change
run_case "k: a branch on the fork stops before the model" case_k_branch_on_fork
run_case "k: an open PR closing the issue stops before the model" case_k_open_pr_for_issue
run_case "k: an open PR on the branch stops before the model" case_k_open_pr_on_branch
run_case "l: an issue not written by the owner stops before the model" case_l_not_owners_issue
run_case "m: the model exits with an error, stop" case_m_model_fails
run_case "n: the model writes no PR body, stop" case_n_no_pr_body
run_case "o: a Qodo round that changes nothing posts the verdicts and stops" case_o_round_changes_nothing
run_case "o: a Qodo round whose checks stay failing posts the verdicts, then stops at the checks stage" case_qodo_checks_exhausted
run_case "p: qodo-status.sh fails, stop" case_p_qodo_status_fails
run_case "q: a missing token stops before any call" case_q_missing_token
run_case "q: a missing claude binary stops before any call" case_q_missing_claude
run_case "q: a clone under a directory the model's Read rules deny stops before any call" case_read_denied_prefix repo
run_case "q: a TMPDIR under a directory the model's Read rules deny stops before any call" case_read_denied_prefix tmp
run_case "r: an enhancement branches as feat" case_r_feature_branch
run_case "s: a change to .git/config stops before any push" case_s_model_changes_git_config
run_case "t: Qodo's comment is missing, stop" case_t_qodo_comment_missing
run_case "t: Qodo's comment does not decode, stop before the fix round" case_qodo_undecodable
run_case "u: an unexpected failure still gets the stop comment and label" case_u_unexpected_failure

run_case "v: the usage errors stop before any call" case_usage
run_case "v: a closed issue stops before the model" case_closed_issue
run_case "w: git cannot fetch main, stop" case_step_fails git-fail-fetch "could not fetch main from origin"
run_case "w: git cannot read main, stop" case_step_fails git-fail-rev-parse "could not read main from origin"
run_case "w: git cannot list the fork's branches, stop" case_step_fails git-fail-ls-remote "could not read the branches of the fork"
run_case "w: git cannot create the branch, stop" case_step_fails git-fail-checkout "could not create branch"
run_case "w: git cannot add the worktree, stop" case_step_fails git-fail-worktree "could not check out main's scripts"
run_case "w: git cannot stage the change, stop" case_step_fails git-fail-add "could not stage the change"
run_case "w: git cannot commit, stop" case_step_fails git-fail-commit "could not commit the change"
run_case "w: git cannot amend in a Qodo round, stop" case_step_fails git-fail-amend "could not amend the commit" "0 2"
run_case "w: git cannot push the branch, stop" case_step_fails git-fail-push "could not push"
run_case "w: git cannot push a Qodo round, stop" case_step_fails git-fail-push-lease "could not push" "0 2"
run_case "w: gh cannot read the issue, stop" case_step_fails gh-fail-issue-view "could not read issue"
run_case "w: gh cannot list the open PRs, stop" case_step_fails gh-fail-pr-list "could not list the open PRs"
run_case "w: gh cannot set the agent-working label, stop" case_step_fails gh-fail-issue-edit "could not set the agent-working label"
run_case "w: gh cannot open the PR, stop" case_step_fails gh-fail-pr-create "could not open the PR"
run_case "w: gh cannot read Qodo's review comment, stop" case_step_fails gh-fail-api-graphql "could not read Qodo's review comment" "0 2"
run_case "x: a model's token in its log is redacted from the stop comment" case_token_redacted
run_case "x: a Qodo round with no verdicts file says so" case_no_verdicts_file
run_case "x: a Qodo round whose verdicts comment fails says so, and logs the verdicts" case_qodo_verdicts_unposted
run_case "x: qodo-status.sh with no open count stops" case_qodo_no_open_count
run_case "x: a PR URL with no number stops" case_pr_url_unparsed
run_case "x: a failed agent-done label is a warning" case_ready_warning "agent-done" "could not add agent-done to issue #41"
run_case "x: a failed PR comment is a warning" case_ready_warning "The agent run is done" "could not comment on PR 99"
run_case "x: a failed issue comment is a warning" case_ready_warning "PR #99 is ready for the owner" "could not comment on issue #41"

run_case "y: a missing jq stops before any step" case_tool_missing jq
run_case "y: a missing gh stops before any step" case_tool_missing gh
run_case "y: a missing git stops before any step" case_tool_missing git
run_case "y: a missing docker stops before any step" case_tool_missing docker
run_case "y: a Docker daemon that does not answer stops before any step" case_docker_down
run_case "y: main's snapshot-site.sh without an image line stops before the model" case_image_unreadable
run_case "z: a model that rewrites the askpass script is caught before the push" case_askpass_tampered
run_case "z: a model that rewrites main's qodo-review.awk is caught before the push" case_tamper_awk
run_case "z: Qodo's review on the second page of comments is read" case_qodo_second_page
run_case "z: qodo-status.sh's output with the tokens is redacted in the stop comment and the log" case_qodo_status_leak
run_case "z: a guarded path naming the model's token is redacted in the stop comment" case_guarded_token_path
run_case "z: a model that rewrites main's qodo-status.sh is caught before Qodo is read" case_qodo_status_tampered
run_case "z: a url rewrite in the model's gitconfig has no effect on the push" case_insteadof
run_case "z: tokens in the PR body are redacted before gh pr create" case_planted_body_redacted
run_case "z: a change holding the model's token is refused before the commit" case_token_in_change
run_case "z: checks that change a guarded path stop before the model's next call" case_checks_touch_guarded
run_case "z: a clone's check-site.sh rewritten to pass does not pass a change main's copy rejects" case_weakened_clone_checker
run_case "z: a model that rewrites main's check-site.sh is caught before the checks" case_tamper_check
run_case "z: a model that rewrites main's check-delivery.sh is caught before Qodo is read" case_tamper_delivery
run_case "z: a model that rewrites a file below main's scripts/ top level is caught before the push" case_tamper_nested
run_case "z: CI with a failed check stops at the ci stage, naming it" case_ci_failed
run_case "z: CI still running after the polls stops, waiting for CI" case_ci_pending_forever
run_case "z: CI with no check reported stops, waiting for CI" case_ci_none_reported
run_case "z: a pending qodo-findings status is not waited on" case_ci_qodo_gate_ignored
run_case "z: gh's checks output that is not JSON stops" case_ci_unreadable
run_case "z: gh cannot list the checks, the run waits and stops" case_step_fails gh-fail-pr-checks "waiting for CI"
run_case "z: build-site.sh with no argument builds its own checkout" case_build_site_default
run_case "z: build-site.sh with an argument builds that directory, with its own checkout's image" case_build_site_argument

if [ "$failures" -ne 0 ]; then
  echo "$failures agent test case(s) failed" >&2
  exit 1
fi
echo "agent tests passed"
