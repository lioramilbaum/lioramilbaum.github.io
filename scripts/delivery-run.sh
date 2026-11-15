#!/usr/bin/env bash
# AGENTS.md rule 6, the Delivery doc workflow (.github/workflows/delivery-doc.yml). After a code PR
# merges to main, this makes its delivery doc with scripts/generate-delivery.sh and adds it to the
# docs PR the owner merges: a new one, or the one already open (one commit, changing only
# deliveries/). The workflow runs it on each push to main and on a manual dispatch. It skips, and
# logs why, a docs PR, a Renovate PR, a direct push (a single-parent commit that names no PR), a doc
# already on main, and any run after the delivery window ends. It fails, and opens or changes
# nothing, when an input it needs cannot be read, or when the push's commit is a merge or names a PR
# that the lookup did not find (AGENTS.md rule 11).
#
# Usage: scripts/delivery-run.sh --event push|workflow_dispatch --sha SHA [--pr N]
#   --pr N  the PR to generate for. A manual run needs it; a push finds its PR from its commit.
# Environment: GH_TOKEN is the read token, for every gh call but the PR writes.
# AGENT_FORK_TOKEN (contents and workflows write on the owner's fork) pushes the docs branch, and fast-forwards the
# fork's main to upstream's before that push, with a plain git push (sync_fork_main; AGENTS.md Setup). The Workflows
# permission is needed because GitHub refuses a token push that adds or changes workflow files without it. The sync
# runs on the push path only, after every skip, so a skipped run makes no write. AGENT_PR_TOKEN (pull requests and
# issues write upstream) opens and edits the docs PR, so CI runs on it.
# The two tokens are copied into shell variables and removed from the environment before the
# script runs any script, git command or build, so none of them inherits them. The script's first lines (the cd through
# dirname) run before the removal and see the tokens, and code
# running as the same user could read them from /proc. Every script this run executes is code already
# merged to main, trusted as much as this script, since a merged change could change any of them. git
# gets the fork token from an askpass script, on the push command only.
# Test hooks: DELIVERY_SLEEP (seconds between polls, lookup tries and PR re-reads; default 30),
# DELIVERY_QODO_POLLS (default 40), DELIVERY_FORK_URL (the fork; default the owner's fork),
# DELIVERY_CHECK (replaces scripts/check-delivery.sh in the check of the new commit). gh and git
# are found on PATH.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
repo=lioramilbaum/lioramilbaum.github.io
owner=lmilbaum
author_name="Liora Milbaum"
author_email="7271026+lmilbaum@users.noreply.github.com"
ident=(-c "user.name=$author_name" -c "user.email=$author_email")
fork_url=${DELIVERY_FORK_URL:-https://github.com/lmilbaum/lioramilbaum.github.io.git}
sleep_s=${DELIVERY_SLEEP:-30}
qodo_polls=${DELIVERY_QODO_POLLS:-40}
checker=${DELIVERY_CHECK:-scripts/check-delivery.sh}

usage() {
  echo "usage: scripts/delivery-run.sh --event push|workflow_dispatch --sha SHA [--pr N]" >&2
  exit 1
}
die() { echo "error: $*" >&2; exit 1; }
warn() { echo "::warning::$*"; }
skip() { echo "skipped: $*"; exit 0; }

# git_run ARGS: git with no global or system config and no hooks, as scripts/agent-run.sh runs it.
git_run() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 command git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# lookup_pr: sets pr_list to the numbers of the PRs merged into main whose merge commit is $sha.
lookup_pr() {
  pr_list=$(gh api "repos/$repo/commits/$sha/pulls" \
    --jq "[.[] | select(.merged_at != null and .merge_commit_sha == \"$sha\" and .base.ref == \"main\")] | .[].number") \
    || die "could not list the PRs of commit $sha"
}

# merged_by_commit: sets merged_by_commit to the numbers of the recently merged PRs (into main) whose merge
# commit is $sha, from GitHub's list of merged PRs. That list does not depend on the commit lookup, which can
# lag a merge, so it finds a rebase merge or a squash whose subject names no PR.
merged_by_commit() {
  local query
  # shellcheck disable=SC2016 # GraphQL variables, not the shell
  query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { pullRequests(states: MERGED, baseRefName: "main", first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number mergeCommit { oid } } } } }'
  merged_by_commit=$(gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -f query="$query" \
    --jq ".data.repository.pullRequests.nodes[] | select(.mergeCommit.oid == \"$sha\") | .number") \
    || die "could not list the recently merged PRs to find the PR of commit $sha"
}

# check_direct_push: the lookup found no merged PR for the push's commit, after its tries. Then the recently
# merged PRs are listed: one with this commit as its merge commit is the commit's PR (found by merge commit); more
# than one is an error. Otherwise a subject that names PR #N (a merge subject, or a trailing (#N)) is read
# directly: if PR #N is merged into main with this commit as its merge commit, the run continues with it; if it
# is not, or does not exist, the commit is a direct push and is skipped; any other read error fails. A merge
# commit whose subject names no PR fails. A single-parent commit that names no PR is a direct push.
check_direct_push() {
  local parents nparents subject named pr_line merged mcs base mcount
  merged_by_commit
  mcount=$(printf '%s\n' "$merged_by_commit" | grep -c . || true)
  case "$mcount" in
    0) ;;
    1)
      n=$merged_by_commit
      echo "found by merge commit: PR #$n has $sha as its merge commit; continuing with PR #$n"
      return 0
      ;;
    *) die "$mcount merged PRs have merge commit $sha ($(printf '%s' "$merged_by_commit" | tr '\n' ' ')); the run cannot tell which one it is" ;;
  esac
  if ! git_run cat-file -e "$sha^{commit}" 2>/dev/null; then
    git_run fetch --quiet --no-tags origin "$sha" \
      || die "no merged PR has merge commit $sha, and the commit could not be fetched to check whether it is a merge"
  fi
  parents=$(git_run rev-list --parents -n1 "$sha") || die "could not read the parents of $sha"
  nparents=$(( $(printf '%s\n' "$parents" | wc -w) - 1 ))
  subject=$(git_run log -1 --format=%s "$sha") || die "could not read the subject of $sha"
  named=$(printf '%s\n' "$subject" | sed -nE 's/^Merge pull request #([0-9]+).*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' | head -n1)
  if [[ -z "$named" ]]; then
    if (( nparents > 1 )); then
      die "no merged PR is listed for commit $sha, and it is a merge commit whose subject names no PR; the run cannot tell which PR it is"
    fi
    skip "no merged PR has merge commit $sha (a direct push)"
  fi
  if pr_line=$(gh api "repos/$repo/pulls/$named" --jq '[(.merged_at != null), .merge_commit_sha, .base.ref] | @tsv' 2>"$work/pr-named.err"); then
    IFS=$'\t' read -r merged mcs base <<< "$pr_line"
    if [[ "$merged" == true && "$mcs" == "$sha" && "$base" == main ]]; then
      n=$named
      echo "no merged PR is listed for commit $sha; its subject names PR #$named, merged into main with this commit: continuing with PR #$named"
      return 0
    fi
    skip "no merged PR has merge commit $sha (a direct push); PR #$named, which its subject names, is not merged into main with this commit"
  fi
  if grep -q 'HTTP 404' "$work/pr-named.err"; then
    skip "no merged PR has merge commit $sha (a direct push); PR #$named, which its subject names, does not exist"
  fi
  die "could not read PR #$named, which the subject of $sha names: $(cat "$work/pr-named.err")"
}

# wait_qodo PR: polls scripts/qodo-status.sh until Qodo's review of the head is settled (AGENTS.md rule 9).
# A review that is still changing, names other content, or does not exist is not settled either: the run
# polls up to qodo_polls times, then fails, naming the last state.
wait_qodo() {
  local poll=0 rc out state
  while :; do
    poll=$((poll + 1))
    rc=0
    out=$(bash scripts/qodo-status.sh --pr "$1" --fetch origin 2>&1) || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) state="still waiting (its quiet period has not passed)" ;;
      3) state="stale (its review names other content)" ;;
      4) state="no review (Qodo has not reviewed the head)" ;;
      *) die "scripts/qodo-status.sh failed (exit $rc): $out" ;;
    esac
    if (( poll >= qodo_polls )); then
      die "Qodo's review of PR #$1 did not settle after $poll polls: $state (scripts/qodo-status.sh exit $rc); the doc needs the settled review (AGENTS.md rule 9)"
    fi
    sleep "$sleep_s"
  done
}

# pr_text PR...: "#A", "#A and #B" or "#A, #B and #C".
pr_text() {
  local count=$# i=0 text="" n
  for n in "$@"; do
    i=$((i + 1))
    if (( i == 1 )); then text="#$n"
    elif (( i == count )); then text="$text and #$n"
    else text="$text, #$n"
    fi
  done
  printf '%s\n' "$text"
}

# subject_for PR...: the commit subject and the docs PR's title, naming each PR the docs PR carries.
subject_for() {
  local text
  text=$(pr_text "$@")
  if (( $# == 1 )); then
    printf 'docs: add the delivery doc for PR %s\n' "$text"
  else
    printf 'docs: add the delivery docs for PRs %s\n' "$text"
  fi
}

# meta_field DOC KEY: the value of KEY on the last delivery metadata line of DOC as HEAD has it.
meta_field() {
  local meta
  meta=$(git_run show "HEAD:$1" | tr -d '\r' | grep '^<!-- delivery: ' | tail -n1) || true
  printf '%s\n' "$meta" | sed -nE "s/.* $2=([^ ]+).*/\1/p"
}

# restore_docs: drops what this run generated under deliveries/, so nothing half-made is left behind.
restore_docs() {
  git_run restore --staged --worktree -- deliveries/ >/dev/null 2>&1 || true
  git_run clean -fdq -- deliveries/ >/dev/null 2>&1 || true
}

# push_branch OPTION...: pushes HEAD to the fork's branch. The options are -u for a new branch (git records
# the fork's URL as its upstream; no token is written) and/or --force-with-lease=... for a branch the fork
# already has. The fork token reaches git through the askpass script, as a prefix assignment on this
# command only: it is in the environment of git, never in an argument.
push_branch() {
  DELIVERY_FORK_TOKEN="$fork_token" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false push --quiet "$@" \
    "$fork_url" "HEAD:refs/heads/$branch"
}

# push_fork_main UP: pushes UP to the fork's main as a plain, non-force push, which GitHub accepts only as a
# fast-forward. No lease: --force-with-lease allows a non-fast-forward update when the lease matches, so it would
# force. The fork token reaches git through the askpass script, as in push_branch: a prefix assignment on this
# command only, never in an argument, a URL or a config.
push_fork_main() {
  DELIVERY_FORK_TOKEN="$fork_token" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false push --quiet "$fork_url" "$1:refs/heads/main"
}

# sync_fork_main: makes the fork's main equal to upstream's main before the docs branch is pushed (AGENTS.md Setup).
# The branch is based on upstream's main, and GitHub refuses a push to the fork that adds or changes workflow files
# the fork's main lacks, unless the token has the Workflows permission. Both mains are read with git, with no token.
# Equal: logged, no write. The fork's main has commits upstream lacks: the run fails and nothing is pushed. Behind:
# upstream's main is pushed to the fork's main as a fast-forward; the fork's main is then read again and must equal
# upstream's main. Nothing here forces a ref.
sync_fork_main() {
  local up fork ahead fork_now
  git_run fetch --quiet --no-tags origin "+refs/heads/main:refs/delivery/up-main" 2>"$work/sync-up.err" \
    || die "could not fetch upstream's main from origin: $(cat "$work/sync-up.err")"
  git_run fetch --quiet --no-tags "$fork_url" "+refs/heads/main:refs/delivery/fork-main" 2>"$work/sync-fork.err" \
    || die "could not fetch the fork's main from $fork_url (the fork has no main, or cannot be read): $(cat "$work/sync-fork.err")"
  up=$(git_run rev-parse --verify --quiet "refs/delivery/up-main^{commit}") || die "could not read upstream's main"
  fork=$(git_run rev-parse --verify --quiet "refs/delivery/fork-main^{commit}") || die "could not read the fork's main"
  if [[ "$up" == "$fork" ]]; then
    echo "fork current: main is $up"
    return 0
  fi
  ahead=$(git_run rev-list --count "$up..$fork" 2>"$work/sync-count.err") \
    || die "could not compare the fork's main with upstream's: $(cat "$work/sync-count.err")"
  if (( ahead > 0 )); then
    die "the fork's main ($fork) has diverged from upstream's ($up): $ahead commit(s) upstream lacks; the run never forces it; nothing is pushed"
  fi
  echo "fork behind: $fork -> $up"
  push_fork_main "$up" 2>"$work/sync-push.err" \
    || die "could not fast-forward the fork's main to $up: $(cat "$work/sync-push.err"); nothing is pushed"
  git_run fetch --quiet --no-tags "$fork_url" "+refs/heads/main:refs/delivery/fork-main" 2>"$work/sync-fork2.err" \
    || die "could not re-read the fork's main after the push: $(cat "$work/sync-fork2.err")"
  fork_now=$(git_run rev-parse --verify --quiet "refs/delivery/fork-main^{commit}") || die "could not read the fork's main after the push"
  [[ "$fork_now" == "$up" ]] || die "after the push the fork's main is $fork_now, not upstream's main ($up); nothing is pushed"
  echo "fork synced: $fork -> $up"
}

# set_docs: the docs the branch carries (the working tree's deliveries/*.md that main does not have as they
# are; a doc main lacks is added, a doc the branch removes is not listed), the PRs they name (prs_text) and
# the commit subject and PR title (subject). Both the new commit and a byte-identical reuse use it.
set_docs() {
  local docs_out d num sorted_nums=() nums=()
  docs_out=$(git_run diff --name-only --diff-filter=AM origin/main -- 'deliveries/*.md') \
    || die "could not list the docs the branch carries"
  docs=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    docs+=("$d")
  done <<< "$docs_out"
  (( ${#docs[@]} > 0 )) || die "the branch carries no delivery doc"
  for d in "${docs[@]}"; do
    num=$(sed -nE 's/^\*\*PR:\*\* \[#([0-9]+)\].*/\1/p' "$d" | head -n1)
    [[ "$num" =~ ^[1-9][0-9]*$ ]] || die "$d has no '**PR:** [#N]' line to name its PR"
    nums+=("$num")
  done
  while IFS= read -r num; do
    sorted_nums+=("$num")
  done <<< "$(printf '%s\n' "${nums[@]}" | sort -n -u)"
  prs_text=$(pr_text "${sorted_nums[@]}")
  subject=$(subject_for "${sorted_nums[@]}")
}

# write_body FILE TAIL: the docs PR's body, from the docs the branch carries (AGENTS.md rule 6). TAIL is
# a reused PR's own ## Hackathon and ## Qodo notes, kept as they are; a new PR gets them empty.
write_body() {
  local out=$1 tail=$2 d num head qopen stem shot plural=""
  if (( ${#docs[@]} > 1 )); then plural=s; fi
  {
    printf '## Acceptance criteria\n\nNo linked issue.\n\n'
    printf '## Why\n\nThis PR adds the delivery doc%s for PR%s %s, generated after the merge (AGENTS.md rule 6). The Delivery doc workflow runs scripts/generate-delivery.sh, so nothing in the doc is written by hand.\n\n' \
      "$plural" "$plural" "$prs_text"
    printf '## How\n\n'
    for d in "${docs[@]}"; do
      num=$(sed -nE 's/^\*\*PR:\*\* \[#([0-9]+)\].*/\1/p' "$d" | head -n1)
      head=$(meta_field "$d" head)
      qopen=$(meta_field "$d" qodo-open)
      [[ -n "$head" && -n "$qopen" ]] || die "$d records no head or qodo-open"
      stem=${d#deliveries/}
      stem=${stem%.md}
      if git_run cat-file -e "HEAD:deliveries/$stem/desktop.png" 2>/dev/null; then
        shot="The homepage screenshot is \`deliveries/$stem/desktop.png\`."
      else
        shot="The homepage did not change, so there is no screenshot."
      fi
      printf '%s\n' "- \`scripts/generate-delivery.sh --pr $num\` generated \`$d\` from #$num's description, its latest Check site run that passed before the merge, the merged head and merge-base builds, and Qodo's final review with its edit history. The doc records \`head=$head\` and \`qodo-open=$qopen\`. $shot"
    done
    printf '\n## What\n\n'
    for d in "${docs[@]}"; do
      printf '%s\n' "- New: \`$d\`"
    done
    printf '%s\n\n' '- A docs PR needs no delivery doc of its own (AGENTS.md rule 6).'
    printf '## Assistance and third-party material\n\n%s\n\n' \
      'Generated by scripts/generate-delivery.sh, run by the Delivery doc workflow (.github/workflows/delivery-doc.yml). No model wrote it, and there is no third-party material.'
    printf '## Limitations\n\n%s\n' 'Adds no code, so rule 8 has nothing to test here.'
    for d in "${docs[@]}"; do
      qopen=$(meta_field "$d" qodo-open)
      # Only a finding count above zero is listed: none, other and unknown never reach a commit (above).
      if [[ "$qopen" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "- \`$d\`: qodo-open is $qopen. The doc records it, and CI warns (AGENTS.md rule 9)."
      fi
    done
    printf '\n'
    if [[ -n "$tail" ]]; then
      printf '%s\n' "$tail"
    else
      printf '## Hackathon\n\n## Qodo notes\n\n'
    fi
  } > "$out"
}

main() {
  local event="" sha="" pr="" n win_out win_rc=0 count state author opened created ref base_sha head_sha
  local mb changed outside wrote got qodo_open status stray line path rc staged bad
  local verify base_now check_out docs_url pushed_sha dstate dhead head_line body old_body tail_sections
  local open_json open_total open_list open_count docs_pr="" branch reused=no reuse_sha="" rb commits files name stem
  local gen_log tries ls_out fork_now d
  local -a push_opts=()
  docs=()
  pr_list=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --event) [ $# -ge 2 ] || usage; event=$2; shift ;;
      --sha) [ $# -ge 2 ] || usage; sha=$2; shift ;;
      --pr) [ $# -ge 2 ] || usage; pr=$2; shift ;;
      *) usage ;;
    esac
    shift
  done
  case "$event" in push | workflow_dispatch) ;; *) usage ;; esac
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a commit SHA, not '$sha'"

  # The tokens: the read token stays in the environment for gh; the two PATs move into shell
  # variables and out of the environment, before any script, git command or build runs, so none inherits them.
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is not set (the read token: the workflow's github.token)"
  [[ -n "${AGENT_FORK_TOKEN:-}" ]] || die "AGENT_FORK_TOKEN is not set (the fork token, AGENTS.md Setup)"
  [[ -n "${AGENT_PR_TOKEN:-}" ]] || die "AGENT_PR_TOKEN is not set (the PR token, AGENTS.md Setup)"
  fork_token=$AGENT_FORK_TOKEN
  pr_token=$AGENT_PR_TOKEN
  unset AGENT_FORK_TOKEN AGENT_PR_TOKEN

  work=$(mktemp -d "${TMPDIR:-/tmp}/delivery-run.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  askpass="$work/askpass"
  cat > "$askpass" <<'ASKPASS'
#!/usr/bin/env bash
# git's credential prompt: the username, then the fork token from the environment of this push only.
case "$1" in
  Username*) echo x-access-token ;;
  *) printf '%s\n' "$DELIVERY_FORK_TOKEN" ;;
esac
ASKPASS
  chmod 700 "$askpass"

  # The window (AGENTS.md rule 6): after it ends, the run logs that it skipped.
  win_out=$(bash scripts/check-delivery.sh --window) || win_rc=$?
  if (( win_rc == 3 )); then skip "the delivery window ended at ${win_out##* }"; fi
  (( win_rc == 0 )) || die "could not check the delivery window: $win_out"

  # The PR: a push's commit is the merge commit of one merged PR, or of none (a direct push). The lookup
  # is tried up to four times, since the merged PR can be listed a moment after the push.
  if [[ "$event" == push ]]; then
    lookup_pr
    tries=1
    while [[ -z "$pr_list" ]] && (( tries < 4 )); do
      sleep "$sleep_s"
      tries=$((tries + 1))
      lookup_pr
    done
    count=$(printf '%s\n' "$pr_list" | grep -c . || true)
    case "$count" in
      0) check_direct_push ;;
      1) n=$pr_list ;;
      *) die "$count merged PRs have merge commit $sha ($(printf '%s' "$pr_list" | tr '\n' ' ')); the run cannot tell which one it is" ;;
    esac
  else
    [[ "$pr" =~ ^[1-9][0-9]*$ ]] || die "a manual run needs --pr N (a PR number), not '$pr'"
    n=$pr
  fi
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "PR number '$n' is not a number"

  # One read for the state and the base: a PR is documented only when it merged into main (both paths).
  IFS=$'\t' read -r state base_ref < <(gh pr view "$n" --repo "$repo" --json state,baseRefName --jq '[.state, .baseRefName] | @tsv') || true
  [[ -n "$state" ]] || die "could not read PR #$n"
  [[ "$state" == MERGED ]] || die "PR #$n is not merged (its state is $state); its delivery doc is generated after it merges (AGENTS.md rule 6)"
  [[ "$base_ref" == main ]] || die "PR #$n merged into $base_ref, not main; its delivery doc is made only for a PR merged into main (AGENTS.md rule 6)"

  # Routing (AGENTS.md rule 6): Renovate PRs are exempt; a docs PR needs no doc of its own.
  author=$(gh api "repos/$repo/pulls/$n" --jq .user.login) || die "could not read the author of PR #$n"
  if [[ "$author" == "renovate[bot]" ]]; then skip "PR #$n is a Renovate PR (exempt, AGENTS.md rule 6)"; fi

  IFS=$'\t' read -r ref created base_sha head_sha < <(gh pr view "$n" --repo "$repo" --json headRefName,createdAt,baseRefOid,headRefOid --jq '[.headRefName, .createdAt, .baseRefOid, .headRefOid] | @tsv') || true
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{40}$ ]] || die "could not read PR #$n's base and head commits"
  [[ -n "$ref" ]] || die "could not read PR #$n's branch name"
  [[ "$created" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T ]] || die "could not read PR #$n's open time ('$created')"
  opened=${BASH_REMATCH[1]}

  git_run fetch --quiet --no-tags origin main || die "could not fetch main from origin"
  git_run fetch --quiet --no-tags origin "pull/$n/head:refs/delivery/pr-$n" || die "could not fetch PR #$n's head from origin"
  mb=$(git_run merge-base "$base_sha" "$head_sha") || die "PR #$n's base and head have no merge-base"
  changed=$(git_run diff --name-only "$mb" "$head_sha") || die "could not list the files PR #$n changes"
  [[ -n "$changed" ]] || die "PR #$n changes no files, so there is no delivery doc to make"
  outside=$(printf '%s\n' "$changed" | grep -v '^deliveries/' || true)
  if [[ -z "$outside" ]]; then
    skip "PR #$n is a docs PR (every changed path is under deliveries/), which needs no doc of its own (AGENTS.md rule 6)"
  fi

  # The doc's name: the generator's rule (the PR's open date and branch slug), checked before anything else
  # that waits or writes, so a re-run for a PR whose doc is already on main skips at once. The name is
  # computed here, not printed by the generator (it has no name-only mode).
  name="deliveries/$opened-${ref#*/}.md"
  stem=${name#deliveries/}
  stem=${stem%.md}
  if git_run cat-file -e "origin/main:$name" 2>/dev/null; then
    skip "$name is already on main; existing docs are never changed (AGENTS.md rule 6)"
  fi

  # Qodo's final review (AGENTS.md rule 9): the doc records it, so wait for it.
  wait_qodo "$n"

  # The doc may have merged to main while this run waited: fetch main again and check once more, before any
  # docs branch is picked or created, so the run never proposes a replacement for an existing doc. The
  # rebase and the new branch below both use this refreshed origin/main.
  git_run fetch --quiet --no-tags origin main || die "could not fetch main from origin after the wait for Qodo"
  if git_run cat-file -e "origin/main:$name" 2>/dev/null; then
    skip "$name is already on main (it merged while this run waited for Qodo)"
  fi

  # The docs branch: the one open docs PR this run adds to (skill B3's query), or a new one. gh lists up to
  # 1000 open PRs; a list that reaches that many could hide a docs PR, so it fails.
  branch="docs/delivery-pr-$n"
  open_json=$(gh pr list --repo "$repo" --state open --limit 1000 --json number,headRefName,headRepositoryOwner,baseRefName,files) \
    || die "could not list the open PRs"
  open_total=$(jq 'length' <<< "$open_json") || die "could not read the open PRs' list"
  (( open_total < 1000 )) || die "the open PRs list reached gh's limit (1000); the run cannot be sure it sees every docs PR"
  open_list=$(jq -r '.[] | select(.headRepositoryOwner.login == "lmilbaum" and .baseRefName == "main" and (.headRefName | startswith("docs/delivery-")) and all(.files[]; .path | startswith("deliveries/"))) | [.number, .headRefName] | @tsv' <<< "$open_json") \
    || die "could not filter the open docs PRs"
  open_count=$(printf '%s\n' "$open_list" | grep -c . || true)
  case "$open_count" in
    0) git_run switch --quiet -C "$branch" origin/main || die "could not check out $branch from origin/main" ;;
    1)
      docs_pr=${open_list%%$'\t'*}
      branch=${open_list#*$'\t'}
      reused=yes
      git_run check-ref-format --branch "$branch" >/dev/null 2>&1 || die "docs PR #$docs_pr's branch '$branch' is not a valid branch name"
      git_run fetch --quiet --no-tags "$fork_url" "+refs/heads/$branch:refs/delivery/reuse" || die "could not fetch $branch from the fork"
      reuse_sha=$(git_run rev-parse --verify --quiet "refs/delivery/reuse^{commit}") || die "$branch on the fork is not a commit"
      rb=$(git_run merge-base origin/main "$reuse_sha") || die "$branch has no merge-base with origin/main"
      commits=$(git_run rev-list --count "$rb..$reuse_sha") || die "could not count the commits of $branch"
      [[ "$commits" == 1 ]] || die "docs PR #$docs_pr's branch $branch has $commits commits above main; it must have exactly one"
      files=$(git_run diff --name-only "$rb" "$reuse_sha") || die "could not list the files of $branch"
      [[ -n "$files" ]] || die "docs PR #$docs_pr's commit changes no files"
      outside=$(printf '%s\n' "$files" | grep -v '^deliveries/' || true)
      [[ -z "$outside" ]] || die "docs PR #$docs_pr's commit changes files outside deliveries/: $(printf '%s' "$outside" | tr '\n' ' ')"
      git_run switch --quiet -C "$branch" "$reuse_sha" || die "could not check out $branch"
      if ! git_run "${ident[@]}" rebase --quiet origin/main >"$work/rebase.log" 2>&1; then
        git_run rebase --abort >/dev/null 2>&1 || true
        die "rebasing $branch onto origin/main conflicts; nothing is pushed: $(tail -n 3 "$work/rebase.log" | tr '\n' ' ')"
      fi
      ;;
    *) die "$open_count open docs PRs ($(printf '%s' "$open_list" | cut -f1 | tr '\n' ' ')) could take the doc; the run cannot tell which one to add it to" ;;
  esac

  gen_log="$work/generate.log"
  if ! bash scripts/generate-delivery.sh --pr "$n" --fetch origin >"$gen_log" 2>&1; then
    cat "$gen_log" >&2
    die "scripts/generate-delivery.sh failed for PR #$n; nothing is committed or pushed"
  fi
  cat "$gen_log"

  wrote=$(sed -nE 's/^wrote (deliveries\/[^ ]+\.md) .* qodo-open ([^)]*)\)$/\1 \2/p' "$gen_log" | tail -n1)
  got=${wrote% *}
  qodo_open=${wrote##* }
  if [[ "$got" != "$name" || -z "$qodo_open" ]]; then
    restore_docs
    die "the generator printed no 'wrote $name' line (got '$wrote')"
  fi

  # Only the doc and its screenshot directory may have changed (rule 6).
  status=$(git_run status --porcelain --untracked-files=all) || die "could not read the working tree's status"
  stray=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=${line:3}
    case "$path" in
      "$name" | deliveries/"$stem"/*) ;;
      *) stray="$stray $path" ;;
    esac
  done <<< "$status"
  if [[ -n "$stray" ]]; then
    restore_docs
    die "the generator changed files outside $name and deliveries/$stem/:$stray"
  fi

  # qodo-open (AGENTS.md rule 9): 0 is clear, a positive count is a finding the doc records and the docs PR
  # names. none and other mean the generator read a review that is not the settled one the status waited
  # for, so nothing is committed. unknown is a review the generator cannot read, also nothing committed.
  case "$qodo_open" in
    0) ;;
    none | other)
      restore_docs
      die "the generator recorded qodo-open=$qodo_open for $name, but scripts/qodo-status.sh called Qodo's review settled; nothing is committed or pushed (AGENTS.md rule 9)"
      ;;
    unknown)
      restore_docs
      die "$name records qodo-open unknown: Qodo's final review has no finding the generator can parse, and not every group says it is clear. The owner decides whether scripts/qodo-review.awk needs a change (AGENTS.md rule 9). Nothing is committed or pushed."
      ;;
    *)
      if [[ ! "$qodo_open" =~ ^[1-9][0-9]*$ ]]; then
        restore_docs
        die "$name records an unexpected qodo-open '$qodo_open'"
      fi
      warn "$name records qodo-open $qodo_open (AGENTS.md rule 9): the doc records the findings, and the docs PR's Limitations names it"
      ;;
  esac

  # The commit: the owner's noreply identity, no trailer (no model writes this).
  git_run add -- deliveries/ || die "could not stage $name"
  rc=0
  git_run diff --cached --quiet || rc=$?
  case "$rc" in
    0) staged=no ;;
    1) staged=yes ;;
    *) die "could not compare the staged docs with $branch" ;;
  esac

  # Nothing staged: the regeneration is byte-identical to the doc the reused branch carries. The branch goes
  # back to the fork's head (the local rebase is dropped), and nothing is committed or pushed. The title and
  # body are still written below, so a retry after a failed edit fixes them.
  if [[ "$staged" == no ]]; then
    [[ "$reused" == yes ]] || die "$name is not new and has no change to commit"
    git_run reset --quiet --hard "$reuse_sha" || die "could not reset $branch to the fork's head"
    pushed_sha=$reuse_sha
    echo "no change: the doc for PR #$n is already current on $branch; the docs PR's base is not refreshed"
  fi

  set_docs

  if [[ "$staged" == yes ]]; then
    bad=$(git_run diff --cached --name-only | grep -v '^deliveries/' || true)
    [[ -z "$bad" ]] || die "the commit would change files outside deliveries/: $(printf '%s' "$bad" | tr '\n' ' ')"
    if [[ "$reused" == yes ]]; then
      git_run "${ident[@]}" commit --quiet --amend -m "$subject" || die "could not amend $branch"
    else
      git_run "${ident[@]}" commit --quiet -m "$subject" || die "could not commit $name"
    fi

    # The new commit is checked before it is pushed: the generator's --check, then the docs check.
    verify=$(bash scripts/generate-delivery.sh --pr "$n" --check --fetch origin 2>&1) \
      || die "scripts/generate-delivery.sh --check fails for PR #$n on the new commit; nothing is pushed: $verify"
    grep -qF "$name is current" <<< "$verify" || die "the check did not print '$name is current': $verify"
    echo "$verify"
    base_now=$(git_run merge-base origin/main HEAD) || die "the new commit has no merge-base with origin/main"
    check_out=$(BASE_SHA="$base_now" bash "$checker" 2>&1) \
      || die "the check of the new commit failed; nothing is pushed: $check_out"
    grep -qF "docs PR: ${#docs[@]} delivery doc(s) checked" <<< "$check_out" \
      || die "the check did not count ${#docs[@]} delivery doc(s): $check_out"
    for d in "${docs[@]}"; do
      grep -qF "$d: ok (" <<< "$check_out" || die "the check did not pass $d: $check_out"
    done
    echo "$check_out"

    # The push's options: the fork's branch, under a lease on the commit this run started from.
    if [[ "$reused" == yes ]]; then
      push_opts=("--force-with-lease=refs/heads/$branch:$reuse_sha")
    else
      # A new branch, unless the fork already has one: an earlier run of this workflow pushed it and then its PR
      # step failed, or its docs PR was closed unmerged. Then the branch is replaced under a lease on the SHA the
      # fork has now, so only this run's commit is left on it.
      ls_out=$(git_run ls-remote "$fork_url" "refs/heads/$branch") || die "could not read $branch on the fork"
      fork_now=${ls_out%%[[:space:]]*}
      if [[ -n "$fork_now" ]]; then
        [[ "$fork_now" =~ ^[0-9a-f]{40}$ ]] || die "the fork's $branch is not a commit: $ls_out"
        push_opts=(-u "--force-with-lease=refs/heads/$branch:$fork_now")
      else
        push_opts=(-u)
      fi
    fi
    # The fork's main is synced before the push (AGENTS.md Setup), so the docs branch is pushed onto a current main.
    sync_fork_main
    push_branch "${push_opts[@]}" || die "could not push $branch to the fork; nothing is opened"
    pushed_sha=$(git_run rev-parse HEAD) || die "could not read the pushed commit"
  fi

  # The docs PR's title and body: created, or replaced (both with the PR token). A reused PR keeps its own
  # ## Hackathon and ## Qodo notes.
  body="$work/pr-body.md"
  tail_sections=""
  if [[ "$reused" == yes ]]; then
    old_body=$(gh pr view "$docs_pr" --repo "$repo" --json body --jq .body) || die "could not read docs PR #$docs_pr"
    tail_sections=$(printf '%s\n' "$old_body" | awk '/^## (Hackathon|Qodo notes)$/ { keep = 1 } keep')
  fi
  write_body "$body" "$tail_sections"
  if [[ "$reused" == yes ]]; then
    GH_TOKEN="$pr_token" gh pr edit "$docs_pr" --repo "$repo" --title "$subject" --body-file "$body" >/dev/null \
      || die "could not update the title and body of docs PR #$docs_pr"
  else
    docs_url=$(GH_TOKEN="$pr_token" gh pr create --repo "$repo" --base main --head "$owner:$branch" \
      --assignee "$owner" --title "$subject" --body-file "$body") \
      || die "could not open the docs PR; $branch is on the fork"
    docs_pr=$(printf '%s\n' "$docs_url" | tail -n1 | sed -nE 's|^https://github.com/[^/]+/[^/]+/pull/([1-9][0-9]*)$|\1|p')
    [[ -n "$docs_pr" ]] || die "gh pr create printed no PR URL: $docs_url"
  fi

  # The assignee, every time (idempotent).
  GH_TOKEN="$pr_token" gh pr edit "$docs_pr" --repo "$repo" --add-assignee "$owner" >/dev/null \
    || die "could not assign $owner to docs PR #$docs_pr"

  # The docs PR as it now stands (AGENTS.md rule 11). GitHub can show the head from before the push for a
  # moment, so the read is repeated up to five times before the run fails.
  tries=0
  while :; do
    tries=$((tries + 1))
    head_line=$(gh pr view "$docs_pr" --repo "$repo" --json state,headRefOid --jq '[.state, .headRefOid] | @tsv') \
      || die "could not read docs PR #$docs_pr"
    IFS=$'\t' read -r dstate dhead <<< "$head_line"
    if [[ "$dstate" == OPEN && "$dhead" == "$pushed_sha" ]]; then break; fi
    if (( tries >= 5 )); then
      die "docs PR #$docs_pr is ${dstate:-unknown} at ${dhead:-no commit}, not OPEN at the pushed commit $pushed_sha (read $tries times)"
    fi
    sleep "$sleep_s"
  done
  echo "docs PR: https://github.com/$repo/pull/$docs_pr"
}

main "$@"; exit $?
