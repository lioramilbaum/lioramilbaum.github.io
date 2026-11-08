---
name: delivery-doc
description: Generates and maintains the delivery doc for a PR in the lioramilbaum.com repo (deliveries/<date>-<slug>.md, AGENTS.md rule 6). Runs scripts/generate-delivery.sh once CI and Qodo have reviewed the PR and clears Qodo's findings first (AGENTS.md rule 9), amends the PR's single commit, force-pushes, and verifies with --check. Trigger when the user says "delivery doc", "delivery-doc", "write the delivery doc", "generate the delivery", "fill in the delivery notes", "update the delivery doc", "Qodo has reviewed, update the doc", "delivery evidence for PR N", "clear Qodo findings", "triage Qodo", "dismiss Qodo findings", or asks for the delivery doc of a lioramilbaum.github.io PR. Never hand-write evidence; this skill only runs the generator.
---

# Delivery doc

Writes `deliveries/<PR open date>-<branch slug>.md` for a PR to lioramilbaum/lioramilbaum.github.io by running `scripts/generate-delivery.sh`. Every section is generated from the PR description, the CI runs, the two homepage builds, and Qodo's review comment. Do not write or edit evidence by hand.

Inside the feature-workflow or pr-audit-fix skills, the git-ops subagent runs the git and gh commands in the steps below.

Inputs: the PR number `N`. If it is missing, ask for it. The repo is `lioramilbaum/lioramilbaum.github.io` (upstream); the branch is pushed to the `lmilbaum` fork (`origin`). Run this skill from the clone that pushed the PR: a fresh clone can lack the head commit, and then its CI run lookup can cite a later run and show a diff.

Set `REPO=lioramilbaum/lioramilbaum.github.io`.

## Steps

1. **Stop early if the doc does not apply.**
   - Run `bash scripts/check-delivery.sh --window`. Exit 0 means the window is open; exit 3 means it has ended (2026-12-12 23:00 UTC). Report that. Any other exit means stop and report the error. If the window has ended, the doc no longer applies but AGENTS.md rule 9 does: check that local HEAD is the PR head (step 2's head check), wait for Qodo's review of the head as in step 3, then run step 4 and stop. Skip generating, pushing and confirming the doc. Renovate PRs still stop outright.
   - Run `gh api repos/$REPO/pulls/$N --jq .user.login`. If it is `renovate[bot]`, stop: Renovate PRs are exempt. (REST reports the bot as `renovate[bot]`; `gh pr view` reports `app/renovate`.)

2. **Require all of these before generating.** Stop at the first one that fails and say which one.
   - Exactly one commit above upstream: `git fetch upstream main --quiet` then `test "$(git rev-list --count upstream/main..HEAD)" = 1`.
   - A clean tree: `test -z "$(git status --porcelain)"`.
   - Local HEAD is the PR head: `test "$(git rev-parse HEAD)" = "$(gh pr view $N --repo $REPO --json headRefOid --jq .headRefOid)"`. A stale checkout must not generate or push over the PR.
   - An open PR from `lmilbaum:<current branch>`: `gh pr view $N --repo $REPO --json state,headRefName,headRepositoryOwner --jq '[.state, .headRefName, .headRepositoryOwner.login] | @tsv'` must print `OPEN`, the current branch, and `lmilbaum`.
   - The PR description has the required sections. `gh pr view $N --repo $REPO --json body --jq .body` must contain each of these as a line of its own: `## Why`, `## How`, `## What`, `## Assistance and third-party material`, `## Limitations`. If one is missing, ask the owner to add it to the PR description (see `.github/pull_request_template.md`).

3. **Wait until the evidence is ready for the head.** Let `SHA=$(git rev-parse HEAD)`.
   - CI: poll `gh run list --repo $REPO --commit $SHA --workflow "Check site" --json status,conclusion,databaseId` until the run's `status` is `completed`. Wait about 30 seconds between polls and give up after 20 minutes. A red `delivery-doc` here is expected if a doc from earlier content is in the tree: the generator does not count that job.
   - Qodo: unless the PR is a draft (`gh pr view $N --repo $REPO --json isDraft`), poll `scripts/qodo-status.sh --pr $N` about every 30 seconds until it exits 0 (settled): Qodo's latest review names the head or a commit with the same content, and its comment has had no edits for 5 minutes. Exit 2 (waiting) means the review names the head but its comment changed less than 5 minutes ago. Exit 3 (stale) or 4 (no-review) means Qodo has not reviewed the head yet: keep waiting, and mark a draft ready first, since a draft gets no review. Give up after 20 minutes and report. Keep the reason for the quiet period: Qodo often posts a review in two passes, and on PR #34 the second came up to 3.5 minutes after the first. Exit 1 is an error (for example, Qodo's commit is not in the local clone): report its message and stop.

4. **Clear Qodo's findings (AGENTS.md rule 9).**
   - List them: call qodo-managed-tools `get-pr-review-findings` with `https://github.com/$REPO/pull/$N`. Open means pending, partial_implementation, not_implemented or focus_areas_edited. Qodo's latest comment (step 3) must list the same findings. If the tools are unavailable, use the comment and tell the owner. A comment that names the head (`scripts/qodo-status.sh --pr $N` exits 0) and lists no findings is enough to continue. If a finding needs a tool action (mark implemented or dismiss) and the tools are down, stop and hand the owner the open list.
   - Verify each open finding against the code at the head.
     - Real: fix it in the PR's single commit. `git add <files>` for the fix files only, check that `git diff --cached` shows just that fix, then `git commit --amend --no-edit`, check the trailer, `git push --force-with-lease origin <branch>`, and go back to step 2. After Qodo's re-review, if it still lists the finding, call `pr-review-mark-implemented`. Never before the fix is pushed.
     - Not real: dismiss it with `pr-review-dismiss`. Dismiss a false_positive yourself, with an explanation that cites evidence (the code at the head, a command and its output, or the revision it was raised against). For intentional, deferred or rejected, or any High finding, first show the owner the finding, the reason and the explanation, and wait for approval. Then add `- <finding title>: dismissed (<reason>). <explanation>` to the PR description's `## Qodo notes` section (`gh pr edit $N --repo $REPO --body-file <file>`).
   - After any closure, poll `scripts/qodo-status.sh --pr $N` as in step 3 until it exits 0, then list again. Go on to step 5 only when no finding is open: `get-pr-review-findings` returns no open finding and the comment lists none, or the tools are down and `scripts/qodo-status.sh --pr $N` exits 0 with the comment listing none.
   - If three re-reviews in a row each add a new finding, stop and give the owner the open list. The PR is not ready.

5. **Generate the doc.** From the repo root, run `scripts/generate-delivery.sh --pr $N`. It builds the head and the merge-base, takes one desktop screenshot of the head only when the homepage changed (Docker and network needed), and writes the doc and any screenshot under `deliveries/`. If it fails, report its message and fix the cause (a missing PR section, or CI not yet passing). Do not patch the output by hand. The generator's last line ends with `qodo-open <value>`. If the value is a number above `0`, do not commit. Return the tree to clean (step 2 requires it: restore tracked files under `deliveries/`, remove a new doc and its directory) and go back to step 4 to clear the findings. If the value is `none` or `other`, do not commit either: return the tree to clean the same way and go back to step 3, so Qodo reviews the head (mark a draft ready first). If the value is `unknown`, do not commit: return the tree to clean the same way, and stop and report to the owner (AGENTS.md rule 9). Qodo's latest review of the head has no finding the generator can parse, and not every group says it is clear: the owner decides whether `scripts/qodo-review.awk` needs a change (a new Qodo layout is parsed there, for the generator and the gate alike). It is not a wait and not a triage: do not poll and do not clear findings.

6. **Amend and push.**
   - `git add deliveries/` (the doc and its `deliveries/<stem>/` directory, if present).
   - `git commit --amend --no-edit`.
   - Check that the last line of the message is the `Co-Authored-By:` trailer from the session's attribution reminder. If it is missing, add it with `git commit --amend` and push. Do not ask first.
   - `git push --force-with-lease origin <branch>`.

7. **Confirm on the new commit.** Wait for CI on the new SHA as in step 3, and require the new run's `delivery-doc` job to be `success`. Then, unless the PR is a draft (a draft gets no Qodo review), wait for Qodo to re-review: poll `scripts/qodo-status.sh --pr $N` as in step 3 until it exits 0. Give up after 20 minutes and report. Before running `--check`, list the findings as in step 4. If any is open, clear it (step 4), regenerate (step 5), push (step 6) and confirm again. This counts toward the three regenerations. If the generator's value is `none` or `other` instead, step 5 sends you back to step 3; that trip counts too. Then run `scripts/generate-delivery.sh --pr $N --check`. A doc-only amend changes no digest, so a diff now means an input moved (Qodo's findings or the PR description).
   - Exit 0 and no open findings: done, once the `qodo-findings` status on the new head is `success` (AGENTS.md rule 9). Check it with `gh api repos/$REPO/commits/$(git rev-parse HEAD)/statuses --jq '[.[] | select(.context == "qodo-findings")][0].state'`. If it prints nothing, check whether the workflow is on main: `git fetch upstream main` and `git cat-file -e upstream/main:.github/workflows/qodo-findings.yml`. If the file is absent (as on #46, before it merged), report that and don't treat it as a failure. If it is on main, the PR is not ready: dispatch the workflow (`gh workflow run "Qodo findings" --repo $REPO -f pr=$N`), poll the status query about every 30 seconds for up to 10 minutes until it prints a state, and report anything other than `success`. If it prints anything else, the PR is not ready: report it. Then report to the owner: Qodo lists no open findings; name each finding fixed and each dismissed, with its reason; the PR is ready for her to merge.
   - Exit 1 with a diff: regenerate with step 5 (its `qodo-open` routing applies), then repeat step 6. Repeat at most three times, counting every regeneration. If the diff is still there after three, or if Qodo keeps reacting to the doc's own text, stop and show the owner the diff.
   - Exit 1 without a diff (for example no passing run): report the message and stop.

## Rules

- Never write, edit or paste evidence by hand. Fix the input (the PR description, CI, the code) and regenerate.
- Never post to the hackathon discussions, and never merge. The owner posts the discussion block.
- Never change the existing docs in `deliveries/`.
- Never add a second commit. The doc goes into the PR's single commit (the global rule: one commit per PR).
- Never report a PR as ready to merge while Qodo lists an open finding (AGENTS.md rule 9).
- Dismiss on your own only a false_positive, with evidence. Ask the owner before any other reason or any High finding. "Dismiss what is not relevant" covers only the findings listed at that time on that PR.
