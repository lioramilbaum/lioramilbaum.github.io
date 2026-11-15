---
name: delivery-doc
description: Reads and checks the Delivery doc workflow's work on a merged PR in the lioramilbaum.com repo (AGENTS.md rule 6): the workflow alone generates the PR's delivery doc (deliveries/<date>-<slug>.md) and opens or amends its docs PR after the merge. After a red run, this skill re-dispatches the workflow once the cause is fixed; it never writes a doc or opens, pushes to or amends a docs PR by hand. Before a merge, clears Qodo's findings on a PR until its qodo-findings status is success (AGENTS.md rule 9). Trigger when the user says "delivery doc", "delivery-doc", "write the delivery doc", "generate the delivery", "fill in the delivery notes", "update the delivery doc", "Qodo has reviewed, update the doc", "delivery evidence for PR N", "clear Qodo findings", "triage Qodo", "dismiss Qodo findings", "docs PR", "add the delivery doc for PR N", "PR N merged", or asks for the delivery doc of a lioramilbaum.github.io PR. Never hand-write evidence or a docs PR.
---

# Delivery doc

The Delivery doc workflow (`.github/workflows/delivery-doc.yml`, which runs `scripts/delivery-run.sh`) writes `deliveries/<PR open date>-<branch slug>.md` for a merged PR by running `scripts/generate-delivery.sh`, and opens or amends the docs PR that carries it. Every section is generated from the PR description, the CI runs, the two homepage builds, and Qodo's review comment. Do not write or edit evidence by hand, and do not open, push to or amend a docs PR by hand.

The doc comes after the PR merges (AGENTS.md rule 6). It goes into a docs PR, one that changes only `deliveries/`. Before the merge, this skill only clears Qodo's findings (AGENTS.md rule 9).

Inside the feature-workflow or pr-audit-fix skills, the git-ops subagent runs the git and gh commands in the steps below.

Inputs: the PR number `N`. If it is missing, ask for it. The repo is `lioramilbaum/lioramilbaum.github.io` (upstream). Part A pushes to the fork, so the clone needs two remotes: `origin` (the `lmilbaum` fork, where branches are pushed) and `upstream` (the repo).

Set `REPO=lioramilbaum/lioramilbaum.github.io`.

## Steps

0. **Route on the PR's state.**
   - Renovate first: `gh api repos/$REPO/pulls/$N --jq .user.login`. If it is `renovate[bot]`, stop: Renovate PRs are exempt. (REST reports the bot as `renovate[bot]`; `gh pr view` reports `app/renovate`.) This applies to both parts.
   - Run `gh pr view $N --repo $REPO --json state,isDraft,files`.
     - `OPEN`: run Part A. Say that the doc comes after the merge.
     - `MERGED`: if every changed path starts with `deliveries/` (`gh pr view $N --repo $REPO --json files --jq '[.files[].path] | all(startswith("deliveries/"))'` prints `true`), stop: a docs PR needs no doc of its own. Otherwise run Part B.
     - `CLOSED` (not merged): stop. A PR that closed without merging gets no doc.

## Part A: before the merge (AGENTS.md rule 9)

Part A applies to a code PR and to a docs PR alike. It has no end date. `N` is the code PR being triaged before its merge. On a docs PR, `$D` is the docs PR, and Part A is read-only there (B3).

A1. **Require all of these.** Stop at the first one that fails and say which one.
   - Exactly one commit above upstream: `git fetch upstream main --quiet` then `test "$(git rev-list --count upstream/main..HEAD)" = 1`.
   - A clean tree: `test -z "$(git status --porcelain)"`.
   - Local HEAD is the PR head: `test "$(git rev-parse HEAD)" = "$(gh pr view $N --repo $REPO --json headRefOid --jq .headRefOid)"`. A stale checkout must not push over the PR.
   - An open PR from `lmilbaum:<current branch>`: `gh pr view $N --repo $REPO --json state,headRefName,headRepositoryOwner --jq '[.state, .headRefName, .headRepositoryOwner.login] | @tsv'` must print `OPEN`, the current branch, and `lmilbaum`.

A2. **Wait for Qodo.** Unless the PR is a draft (`gh pr view $N --repo $REPO --json isDraft`), poll `scripts/qodo-status.sh --pr $N` about every 30 seconds until it exits 0 (settled): Qodo's latest review names the head or a commit with the same content, and its comment has had no edits for 5 minutes. Exit 2 (waiting) means the review names the head but its comment changed less than 5 minutes ago. Exit 3 (stale) or 4 (no-review) means Qodo has not reviewed the head yet: keep waiting, and mark a draft ready first, since a draft gets no review. Give up after 20 minutes and report. Keep the reason for the quiet period: Qodo often posts a review in two passes, and on PR #34 the second came up to 3.5 minutes after the first. Exit 1 is an error (for example, Qodo's commit is not in the local clone): report its message and stop.

A3. **Clear Qodo's findings (AGENTS.md rule 9).**
   - List them: call qodo-managed-tools `get-pr-review-findings` with `https://github.com/$REPO/pull/$N`. Open means pending, partial_implementation, not_implemented or focus_areas_edited. Qodo's latest comment (A2) must list the same findings. If the tools are unavailable, use the comment and tell the owner. A comment that names the head (`scripts/qodo-status.sh --pr $N` exits 0) and lists no findings is enough to continue. If a finding needs a tool action (mark implemented or dismiss) and the tools are down, stop and hand the owner the open list.
   - Verify each open finding against the code at the head.
     - On a code PR, real: fix it in the PR's single commit. `git add <files>` for the fix files only, check that `git diff --cached` shows just that fix, then `git commit --amend --no-edit`, check the trailer, `git push --force-with-lease origin <branch>`, and go back to A1. After Qodo's re-review, if it still lists the finding, call `pr-review-mark-implemented`. Never before the fix is pushed.
     - Not real: dismiss it with `pr-review-dismiss`. Dismiss a false_positive yourself, with an explanation that cites evidence (the code at the head, a command and its output, or the revision it was raised against). For intentional, deferred or rejected, or any High finding, first show the owner the finding, the reason and the explanation, and wait for approval. Then add `- <finding title>: dismissed (<reason>). <explanation>` to the PR description's `## Qodo notes` section (`gh pr edit $N --repo $REPO --body-file <file>`).
     - On a docs PR, Part A is read-only: the agent does not fix, dismiss or mark any finding there. It reports each finding to the owner, who decides. A finding about the generated doc's text is fixed at its input (the merged PR's description) and the workflow dispatched again (B4), never by hand.
   - After any closure, poll `scripts/qodo-status.sh --pr $N` as in A2 until it exits 0, then list again. Go on to A4 only when no finding is open: `get-pr-review-findings` returns no open finding and the comment lists none, or the tools are down and `scripts/qodo-status.sh --pr $N` exits 0 with the comment listing none.
   - If three re-reviews in a row each add a new finding, stop and give the owner the open list. The PR is not ready.

A4. **Confirm the qodo-findings status.** Check it with `gh api repos/$REPO/commits/$(git rev-parse HEAD)/statuses --jq '[.[] | select(.context == "qodo-findings")][0].state'`. If it prints nothing, dispatch the workflow (`gh workflow run "Qodo findings" --repo $REPO -f pr=$N`), then poll the same query about every 30 seconds for up to 10 minutes until it prints a state. If it prints anything other than `success`, the PR is not ready: report it. Then report to the owner: Qodo lists no open findings; name each finding fixed and each dismissed, with its reason; the PR is ready for her to merge. After a code PR merges, the Delivery doc workflow handles its doc (Part B). A docs PR needs nothing further after it merges.

## Part B: after the merge (the workflow does it)

The Delivery doc workflow generates the doc and opens or amends the docs PR after every merge. It is the only way a docs PR is opened or changed: there is no manual fallback. This part reads the result, and re-dispatches the workflow after a red run.

B1. **Find the run and its docs PR.** After the merge, find the run for the merge commit: `gh run list --repo $REPO --workflow "Delivery doc" --branch main --limit 5` (its `headSha` is the merge commit). Then find the docs PR: `gh pr list --repo $REPO --state open --json number,title,headRefName` and take the one whose branch is `docs/delivery-pr-$N` or that the run's log names.

B2. **Read the run's result.** `gh run view <id> --repo $REPO --log`, and look for the last `skipped:`, `error:` or `docs PR:` line.
   - `docs PR: <url>`: green. Go to B3.
   - `skipped:` (a docs PR, a Renovate PR, a direct push, a doc already on main, or the window ended): final. Report the reason; nothing else is done.
   - `error:` (red): the reason is named on that line. Go to B4.

B3. **Check the docs PR (read-only).** It is assigned to the owner, and its one commit changes only `deliveries/`. Run Part A on the docs PR (`$D`) read-only:
   - A2's wait, with `scripts/qodo-status.sh --pr $D --fetch upstream`: the docs PR's commits may not be in this clone, and `--fetch` gets the one it needs by SHA.
   - A3's list of findings.
   - The `qodo-findings` status of the docs PR's head, not local HEAD: `SHA=$(gh pr view $D --repo $REPO --json headRefOid --jq .headRefOid)`, then `gh api repos/$REPO/commits/$SHA/statuses --jq '[.[] | select(.context == "qodo-findings")][0].state'`. It must print `success`; if it does not, report it to the owner.

Do not run A1's branch check, any fix, any push, or any dispatch on the docs PR: it is the workflow's alone. Findings are reported to the owner, who decides. Report the docs PR to the owner. The discussion block in the doc is the owner's to post. Its image and its delivery-notes link point at `main`, so they resolve once the docs PR merges.

B4. **A red run: fix the cause, then dispatch again.**
   - Read the `error:` line and fix what it names: a PR description missing a required section (ask the owner to add it, AGENTS.md rule 6), a Qodo review that did not settle (wait, or fix the findings in Part A), a commit lookup that missed a PR (the message names the dispatch that recovers it), or a failed check.
   - A cause that is in the repo (code, a workflow, a script) is a PR of its own, not a change made here.
   - Dispatch the workflow once more: `gh workflow run "Delivery doc" --repo $REPO -f pr=$N`. If that run is green, go on to B3.
   - If the re-dispatched run fails for the same reason, or its cause is outside the repo, stop: do not dispatch again. Hand it to the owner with the run's URL and the reason. The known case is #108, a merged PR whose final head Qodo never reviewed: its doc cannot be made until Qodo reviews that head, and the owner decides what to do.
   - Never patch the doc, and never open, push to or amend the docs PR by hand.

B5. **Check the docs PR's doc (read-only).** To check the doc a docs PR carries, fetch its branch (`git fetch origin <branch>`, then `git switch --detach FETCH_HEAD`) and run `scripts/generate-delivery.sh --pr $N --check`, where `$N` is the merged code PR the doc is for (not the docs PR `$D`). It must print `is current`. It writes nothing. If it does not, dispatch the workflow again (B4).

## Rules

- Never write, edit or paste evidence by hand. Fix the input (the PR description, CI, the code) and dispatch the workflow again.
- Never open, push to or amend a docs PR by hand, and never commit a delivery doc. The Delivery doc workflow does that, and a docs PR has one commit that changes only `deliveries/`.
- Never post to the hackathon discussions, and never merge. The owner posts the discussion block.
- Never change the existing docs in `deliveries/` on main. A doc still in an open docs PR is regenerated by the workflow.
- Never report a PR as ready to merge while Qodo lists an open finding (AGENTS.md rule 9).
- Dismiss on your own only a false_positive, with evidence. Ask the owner before any other reason or any High finding. "Dismiss what is not relevant" covers only the findings listed at that time on that PR.
