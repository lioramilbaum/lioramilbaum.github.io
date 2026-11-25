#!/usr/bin/env bash
# AGENTS.md rule 9: posts the qodo-findings commit status on a PR's head. Success while Qodo's
# latest review of the head lists no open findings, failure while it lists any (or a layout
# scripts/qodo-review.awk does not know), pending until Qodo has reviewed the head and the review
# has settled. Renovate PRs get success (exempt). Runs from main (.github/workflows/
# qodo-findings.yml), so PR code never runs here: the PR's commits are read as objects only.
#
# A review Qodo skipped as trivial (qodo-status.sh's open: skipped) is success on a docs PR that
# changes only files under deliveries/ (not deliveries/TEMPLATE.md), and pending on any other PR
# (AGENTS.md rule 9). That case reads the PR's changed files, checks the list is whole against the
# PR's changed-file count, and posts nothing if the head changed during the checks.
#
# Usage: scripts/qodo-gate.sh --pr N [--fetch REMOTE]
#   --fetch REMOTE  passed to qodo-status.sh, which fetches a commit this clone lacks.
#
# Test hooks: QODO_GATE_SLEEP replaces sleep (the wait between settling checks). gh is found on
# PATH. GITHUB_RUN_ID and GITHUB_SERVER_URL (set by Actions) make the run's page the target URL
# of a status that has no review to link to.
set -euo pipefail

cd "$(dirname "$0")/.."
repo=lioramilbaum/lioramilbaum.github.io
context=qodo-findings
pr=""
fetch=""
usage() {
  echo "usage: scripts/qodo-gate.sh --pr N [--fetch REMOTE]" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage; pr=$2; shift ;;
    --fetch) [ $# -ge 2 ] && [ -n "$2" ] || usage; fetch=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

die() { echo "error: $*" >&2; exit 1; }

# post SHA STATE DESCRIPTION [URL]: sets the status on SHA. Every field goes through -f (a raw
# string, never read from a file).
post() {
  local sha=$1 st=$2 desc=$3 url=${4:-}
  local fields=(-f "state=$st" -f "context=$context" -f "description=$desc")
  if [[ -n "$url" ]]; then fields+=(-f "target_url=$url"); fi
  gh api "repos/$repo/statuses/$sha" --method POST "${fields[@]}" >/dev/null \
    || die "could not set the $context status on $sha"
  echo "status: $sha $st: $desc"
}

# run_url: this workflow run's page, when Actions set GITHUB_RUN_ID.
run_url() {
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$GITHUB_RUN_ID"
  fi
}

# field NAME OUT: the value of NAME in qodo-status.sh's output OUT.
field() { printf '%s\n' "$2" | sed -n "s/^$1: //p"; }

# target_url OUT: the review Qodo's comment links to, else this run's page.
target_url() {
  local review
  review=$(field review "$1")
  if [[ -n "$review" && "$review" != none ]]; then echo "$review"; else run_url; fi
}

facts=$(gh api "repos/$repo/pulls/$pr" --jq '[.state, .draft, .user.login, .head.sha] | @tsv') \
  || die "could not read PR $pr with gh"
IFS=$'\t' read -r state draft login SHA <<< "$facts"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "PR $pr has no usable head SHA ($SHA)"

if [[ "$state" != open ]]; then
  echo "PR $pr is $state; no status to set"
  exit 0
fi
if [[ "$login" == "renovate[bot]" ]]; then
  post "$SHA" success "Renovate PR: exempt from Qodo review (AGENTS.md rule 9)"
  exit 0
fi
if [[ "$draft" == true ]]; then
  post "$SHA" pending "Draft: Qodo reviews this PR once it is marked ready"
  exit 0
fi

# qodo-status.sh decides: 0 settled, 2 waiting (Qodo's comment changed less than 5 minutes ago),
# 3 stale, 4 no review. Settling is re-checked every 30 s, 12 times at most.
fetch_args=()
if [[ -n "$fetch" ]]; then fetch_args=(--fetch "$fetch"); fi
waits=0
while :; do
  rc=0
  out=$(bash scripts/qodo-status.sh --pr "$pr" ${fetch_args[@]+"${fetch_args[@]}"}) || rc=$?
  if [ "$rc" -eq 2 ]; then
    head=$(field head "$out")
    if [ "$waits" -eq 0 ]; then
      post "$head" pending "Qodo's review is settling (5 quiet minutes)" "$(target_url "$out")"
    fi
    if [ "$waits" -lt 12 ]; then
      waits=$((waits + 1))
      ${QODO_GATE_SLEEP:-sleep} 30
      continue
    fi
    post "$head" pending "Qodo's review is still changing; its next edit re-runs this check" \
      "$(target_url "$out")"
    exit 0
  fi
  break
done

case "$rc" in
  0)
    head=$(field head "$out")
    open=$(field open "$out")
    case "$open" in
      0) post "$head" success "Qodo's latest review of this head lists no open findings" "$(target_url "$out")" ;;
      unknown) post "$head" failure "Qodo's review could not be read; update scripts/qodo-review.awk (AGENTS.md rule 9)" \
        "$(target_url "$out")" ;;
      skipped)
        # Qodo skipped the review as trivial, so the head was not reviewed. A docs PR (only
        # deliveries/ changes, and not the template) is success: its generated docs are checked on
        # the merged head. The template is not checked anywhere, so it is not docs here. The list
        # is whole only if it has as many files as the PR's changed_files (pulls/N/files caps at
        # 3,000). Any other PR is pending until the owner asks for a review or merges knowing.
        files_rc=0
        files=$(gh api "repos/$repo/pulls/$pr/files" --paginate \
          --jq '.[] | [.filename, (.previous_filename // "")] | @tsv') || files_rc=$?
        if [[ "$files_rc" -ne 0 || -z "$files" ]]; then
          post "$SHA" error "Could not list this PR's changed files; see the workflow run" "$(run_url)"
          exit 1
        fi
        # One line per file in $files; $paths has one line per path (a rename's old path too).
        paths=$(awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i != "") print $i }' <<< "$files")
        nfiles=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
        count_rc=0
        changed=$(gh api "repos/$repo/pulls/$pr" --jq .changed_files) || count_rc=$?
        if [[ "$count_rc" -ne 0 ]]; then
          post "$SHA" error "Could not read this PR's changed-file count; see the workflow run" "$(run_url)"
          exit 1
        fi
        outcome=success
        reason="Qodo skipped the review as trivial; this docs PR changes only deliveries/ (AGENTS.md rule 9)"
        if grep -qv '^deliveries/' <<< "$paths" || grep -qx 'deliveries/TEMPLATE.md' <<< "$paths"; then
          outcome=pending
          reason="Qodo skipped the review of this head as trivial; ask Qodo for a review, or merge knowing (AGENTS.md rule 9)"
        elif ! [[ "$changed" =~ ^[0-9]+$ ]] || [[ "$changed" -ne "$nfiles" ]]; then
          outcome=pending
          reason="Qodo skipped the review as trivial and the PR's file list is incomplete; ask Qodo for a review (AGENTS.md rule 9)"
        fi
        # The head the status goes on must still be the PR's head. A push during the checks above
        # is posted by its own gate run, so nothing is posted here (rule 11: say so, and why).
        now_rc=0
        now_head=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha) || now_rc=$?
        if [[ "$now_rc" -ne 0 ]] || ! [[ "$now_head" =~ ^[0-9a-f]{40}$ ]]; then
          post "$SHA" error "Could not read this PR's head; see the workflow run" "$(run_url)"
          exit 1
        fi
        if [[ "$now_head" != "$head" ]]; then
          echo "skipped the status: the head changed during the check (${head:0:7} to ${now_head:0:7}); the push's own gate run decides"
          exit 0
        fi
        post "$head" "$outcome" "$reason" "$(target_url "$out")"
        ;;
      ''|*[!0-9]*) die "qodo-status.sh reported open: $open" ;;
      *) post "$head" failure "Qodo lists $open open finding(s); fix or dismiss each (AGENTS.md rule 9)" \
        "$(target_url "$out")" ;;
    esac
    ;;
  3)
    head=$(field head "$out")
    reviewed=$(field reviewed "$out")
    post "$head" pending "Qodo has not reviewed this head yet; its latest review is of ${reviewed:0:7}" \
      "$(target_url "$out")"
    ;;
  4)
    post "$(field head "$out")" pending "Qodo has not reviewed this PR yet" "$(target_url "$out")"
    ;;
  *)
    printf '%s\n' "$out" >&2
    post "$SHA" error "Could not read Qodo's review; see the workflow run" "$(run_url)"
    exit 1
    ;;
esac
