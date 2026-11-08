#!/usr/bin/env bash
# AGENTS.md rule 9: posts the qodo-findings commit status on a PR's head. Success while Qodo's
# latest review of the head lists no open findings, failure while it lists any (or a layout
# scripts/qodo-review.awk does not know), pending until Qodo has reviewed the head and the review
# has settled. Renovate PRs get success (exempt). Runs from main (.github/workflows/
# qodo-findings.yml), so PR code never runs here: the PR's commits are read as objects only.
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
