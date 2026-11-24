#!/usr/bin/env bash
# AGENTS.md Setup, the agent run: when an issue closes, removes the agent run's labels (ready-for-agent,
# agent-working, agent-stuck and agent-done) from it. Its other labels stay, and a label the issue does
# not have is not removed. Run by .github/workflows/agent-labels.yml with GITHUB_TOKEN (issues: write).
# scripts/test-agent.sh tests it with a gh stub.
set -euo pipefail

repo=lioramilbaum/lioramilbaum.github.io

usage() {
  echo "usage: scripts/agent-labels.sh --issue N" >&2
  exit 1
}

[[ $# -eq 2 && "$1" == --issue ]] || usage
issue=$2
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || { echo "error: --issue must be a positive issue number, got: $issue" >&2; exit 1; }

if ! labels=$(gh issue view "$issue" --repo "$repo" --json labels --jq '.labels[].name'); then
  echo "error: could not read the labels of issue #$issue" >&2
  exit 1
fi

remove=()
names=()
for label in ready-for-agent agent-working agent-stuck agent-done; do
  if grep -qxF -- "$label" <<< "$labels"; then
    remove+=(--remove-label "$label")
    names+=("$label")
  fi
done

if [[ ${#remove[@]} -eq 0 ]]; then
  echo "skipped: issue #$issue has none of the agent run's labels"
  exit 0
fi

if ! gh issue edit "$issue" --repo "$repo" "${remove[@]}" >/dev/null; then
  echo "error: could not remove ${names[*]} from issue #$issue" >&2
  exit 1
fi
echo "removed: ${names[*]} from issue #$issue"
