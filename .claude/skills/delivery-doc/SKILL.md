---
name: delivery-doc
description: Generates a merged PR's delivery doc in the lioramilbaum.com repo (deliveries/<date>-<slug>.md, AGENTS.md rule 6) after the PR merges, and adds it in a separate docs PR that changes only deliveries/ (one open docs PR is reused). Before a merge, clears Qodo's findings on a PR until its qodo-findings status is success (AGENTS.md rule 9). Runs scripts/generate-delivery.sh and verifies with --check. Trigger when the user says "delivery doc", "delivery-doc", "write the delivery doc", "generate the delivery", "fill in the delivery notes", "update the delivery doc", "Qodo has reviewed, update the doc", "delivery evidence for PR N", "clear Qodo findings", "triage Qodo", "dismiss Qodo findings", "docs PR", "add the delivery doc for PR N", "PR N merged", or asks for the delivery doc of a lioramilbaum.github.io PR. Never hand-write evidence; this skill only runs the generator.
---

# Delivery doc

Writes `deliveries/<PR open date>-<branch slug>.md` for a PR to lioramilbaum/lioramilbaum.github.io by running `scripts/generate-delivery.sh`. Every section is generated from the PR description, the CI runs, the two homepage builds, and Qodo's review comment. Do not write or edit evidence by hand.

The doc comes after the PR merges (AGENTS.md rule 6). It goes into a docs PR, one that changes only `deliveries/`. Before the merge, this skill only clears Qodo's findings (AGENTS.md rule 9).

Inside the feature-workflow or pr-audit-fix skills, the git-ops subagent runs the git and gh commands in the steps below.

Inputs: the PR number `N`. If it is missing, ask for it. The repo is `lioramilbaum/lioramilbaum.github.io` (upstream). The clone needs two remotes: `origin` (the `lmilbaum` fork, where branches are pushed) and `upstream` (the repo).

Set `REPO=lioramilbaum/lioramilbaum.github.io`.

## Steps

0. **Route on the PR's state.**
   - Renovate first: `gh api repos/$REPO/pulls/$N --jq .user.login`. If it is `renovate[bot]`, stop: Renovate PRs are exempt. (REST reports the bot as `renovate[bot]`; `gh pr view` reports `app/renovate`.) This applies to both parts.
   - Run `gh pr view $N --repo $REPO --json state,isDraft,files`.
     - `OPEN`: run Part A. Say that the doc comes after the merge.
     - `MERGED`: if every changed path starts with `deliveries/` (`gh pr view $N --repo $REPO --json files --jq '[.files[].path] | all(startswith("deliveries/"))'` prints `true`), stop: a docs PR needs no doc of its own. Otherwise run Part B.
     - `CLOSED` (not merged): stop. A PR that closed without merging gets no doc.

## Part A: before the merge (AGENTS.md rule 9)

Part A applies to a code PR and to a docs PR alike. It has no end date. `N` is the PR being triaged: the code PR before its merge, or the docs PR when B8 runs Part A.

A1. **Require all of these.** Stop at the first one that fails and say which one.
   - Exactly one commit above upstream: `git fetch upstream main --quiet` then `test "$(git rev-list --count upstream/main..HEAD)" = 1`.
   - A clean tree: `test -z "$(git status --porcelain)"`.
   - Local HEAD is the PR head: `test "$(git rev-parse HEAD)" = "$(gh pr view $N --repo $REPO --json headRefOid --jq .headRefOid)"`. A stale checkout must not push over the PR.
   - An open PR from `lmilbaum:<current branch>`: `gh pr view $N --repo $REPO --json state,headRefName,headRepositoryOwner --jq '[.state, .headRefName, .headRepositoryOwner.login] | @tsv'` must print `OPEN`, the current branch, and `lmilbaum`.

A2. **Wait for Qodo.** Unless the PR is a draft (`gh pr view $N --repo $REPO --json isDraft`), poll `scripts/qodo-status.sh --pr $N` about every 30 seconds until it exits 0 (settled): Qodo's latest review names the head or a commit with the same content, and its comment has had no edits for 5 minutes. Exit 2 (waiting) means the review names the head but its comment changed less than 5 minutes ago. Exit 3 (stale) or 4 (no-review) means Qodo has not reviewed the head yet: keep waiting, and mark a draft ready first, since a draft gets no review. Give up after 20 minutes and report. Keep the reason for the quiet period: Qodo often posts a review in two passes, and on PR #34 the second came up to 3.5 minutes after the first. Exit 1 is an error (for example, Qodo's commit is not in the local clone): report its message and stop.

A3. **Clear Qodo's findings (AGENTS.md rule 9).**
   - List them: call qodo-managed-tools `get-pr-review-findings` with `https://github.com/$REPO/pull/$N`. Open means pending, partial_implementation, not_implemented or focus_areas_edited. Qodo's latest comment (A2) must list the same findings. If the tools are unavailable, use the comment and tell the owner. A comment that names the head (`scripts/qodo-status.sh --pr $N` exits 0) and lists no findings is enough to continue. If a finding needs a tool action (mark implemented or dismiss) and the tools are down, stop and hand the owner the open list.
   - Verify each open finding against the code at the head.
     - Real: fix it in the PR's single commit. `git add <files>` for the fix files only, check that `git diff --cached` shows just that fix, then `git commit --amend --no-edit`, check the trailer, `git push --force-with-lease origin <branch>`, and go back to A1. After Qodo's re-review, if it still lists the finding, call `pr-review-mark-implemented`. Never before the fix is pushed.
     - Not real: dismiss it with `pr-review-dismiss`. Dismiss a false_positive yourself, with an explanation that cites evidence (the code at the head, a command and its output, or the revision it was raised against). For intentional, deferred or rejected, or any High finding, first show the owner the finding, the reason and the explanation, and wait for approval. Then add `- <finding title>: dismissed (<reason>). <explanation>` to the PR description's `## Qodo notes` section (`gh pr edit $N --repo $REPO --body-file <file>`).
     - On a docs PR, a finding about the generated doc's text is never fixed by hand, because that hand-writes evidence. Fix its input instead (the merged PR's description; Part B then regenerates the doc), or dismiss it with evidence.
   - After any closure, poll `scripts/qodo-status.sh --pr $N` as in A2 until it exits 0, then list again. Go on to A4 only when no finding is open: `get-pr-review-findings` returns no open finding and the comment lists none, or the tools are down and `scripts/qodo-status.sh --pr $N` exits 0 with the comment listing none.
   - If three re-reviews in a row each add a new finding, stop and give the owner the open list. The PR is not ready.

A4. **Confirm the qodo-findings status.** Check it with `gh api repos/$REPO/commits/$(git rev-parse HEAD)/statuses --jq '[.[] | select(.context == "qodo-findings")][0].state'`. If it prints nothing, dispatch the workflow (`gh workflow run "Qodo findings" --repo $REPO -f pr=$N`), then poll the same query about every 30 seconds for up to 10 minutes until it prints a state. If it prints anything other than `success`, the PR is not ready: report it. Then report to the owner: Qodo lists no open findings; name each finding fixed and each dismissed, with its reason; the PR is ready for her to merge. After a code PR merges, run Part B on it. A docs PR needs nothing further after it merges.

## Part B: after the merge

B1. **Check the window.** Run `bash scripts/check-delivery.sh --window`. Exit 0 means the window is open. Exit 3 means it has ended (2026-12-12 23:00 UTC): no doc applies, so report that and stop. Any other exit means stop and report the error.

B2. **Fetch the merged PR and check its description.**
   - `git fetch upstream main "pull/$N/head:refs/remotes/upstream/pr/$N"`.
   - A clean tree: `test -z "$(git status --porcelain)"`.
   - The PR description has the five required sections: `gh pr view $N --repo $REPO --json body --jq .body` must contain each of these as a line of its own: `## Why`, `## How`, `## What`, `## Assistance and third-party material`, `## Limitations`. If one is missing, ask the owner to add it to the PR description (see `.github/pull_request_template.md`). The owner can still edit the description after the merge, so rerun this skill after the owner does.

B3. **Pick the docs branch.** Find the open docs PR this skill reuses, if there is one:
   `gh pr list --repo $REPO --state open --json number,headRefName,headRepositoryOwner,files --jq '.[] | select(.headRepositoryOwner.login=="lmilbaum" and (.headRefName|startswith("docs/delivery-")) and all(.files[]; .path|startswith("deliveries/"))) | [.number,.headRefName] | @tsv'`
   - More than one line: stop and ask the owner which one to use.
   - One line, with branch `<branch>`: `git fetch origin <branch>` and `git switch -C <branch> origin/<branch>`. Do not rebase: CI diffs the docs PR against the base parent of its merge commit.
   - No line: `git switch -C docs/delivery-pr-$N upstream/main`. `-C` replaces a local `docs/delivery-pr-$N` that an earlier run left behind; no open docs PR exists, so any fork copy belongs to a merged or closed one.

B4. **Wait for Qodo's final review.** Run `scripts/qodo-status.sh --pr $N --fetch upstream`.
   - Exit 0 (settled): continue.
   - Exit 2 (waiting): poll every 30 seconds for up to 20 minutes. If it still exits 2 then, report and stop.
   - Exit 3 (stale) or 4 (no-review): continue. The doc will record `other` or `none`, so tell the owner.
   - Exit 1: report its message and stop.

B5. **Generate the doc.** From the repo root, run `scripts/generate-delivery.sh --pr $N`. It fetches a CI run's commit that the clone lacks from `upstream`. If it fails, report its message and fix the input (a missing PR section, or CI not yet passing). Never patch the output by hand. Its last line is `wrote <name> (… qodo-open <value>)`. Read the name and the value with:
   `sed -nE 's/^wrote (deliveries\/[^ ]+\.md) .* qodo-open ([^)]*)\)$/\1 \2/p'`

   "Restore" below means `git restore --staged --worktree -- deliveries/ && git clean -fd -- deliveries/`.
   - If `git cat-file -e upstream/main:<name>` succeeds, the doc is already on main. Existing docs are never changed: restore, and stop.
   - `git status --porcelain` must list only `<name>` and `deliveries/<stem>/`. Otherwise restore, and stop.
   - Read the value of `qodo-open`:
     - `0`: continue.
     - A number above `0`, `none` or `other`: continue to B6, and tell the owner the value. The doc records it, and CI warns.
     - `unknown`: do not commit. Restore, and stop and report to the owner. Qodo's final review has no finding the generator can parse, and not every group says it is clear: the owner decides whether `scripts/qodo-review.awk` needs a change. It is not a wait and not a triage.

B6. **Commit and push.**
   - `git add deliveries/`.
   - Reused branch, if `git diff --cached --quiet` succeeds: nothing changed (the regenerated doc is byte-identical). Skip the commit and push, and go to B8.
   - `git diff --cached --name-only | grep -v '^deliveries/'` must print nothing.
   - New branch: `git commit -m "docs: add the delivery doc for PR #$N"`, then a `Co-Authored-By:` trailer line from the session's attribution reminder as the last line of the message.
   - Reused branch: read its subject with `git log -1 --format=%s`. A docs PR keeps one commit, so amend it: `git commit --amend -m "docs: add the delivery docs for PRs #A and #N"` (naming every PR whose doc the commit carries), with the same trailer as the last line.
   - Check the trailer: the last line of the message must be the session's `Co-Authored-By:` trailer. If it is not, amend the message and push. Do not ask first.
   - Before pushing, check the new commit: `BASE_SHA=$(git merge-base upstream/main HEAD) bash scripts/check-delivery.sh` must print `<name>: ok (` for the doc and `docs PR: 1 delivery doc(s) checked`, or the count the reused branch carries.
   - New branch: `git push -u origin <branch>`. Reused branch: `git push --force-with-lease origin <branch>`.

B7. **Open or update the docs PR.** The docs PR is not a draft: Qodo does not review drafts, so `qodo-findings` stays pending on a draft.
   - New branch: `gh pr create --repo $REPO --base main --head lmilbaum:<branch> --title "docs: add the delivery doc for PR #$N" --body-file <file>`. Write the body in a file outside the repo. It has the template's sections (`.github/pull_request_template.md`) without the `Closes` line:
     - `## Acceptance criteria`: `No linked issue.`
     - `## Why`: this PR adds the delivery doc for PR #N, generated after it merged (AGENTS.md rule 6), as its hackathon evidence.
     - `## How`: one bullet per PR. `scripts/generate-delivery.sh --pr N` generated `<name>` from #N's description, its latest Check site run that passed before the merge, the merged head and merge-base builds, and Qodo's final review with its edit history. The doc records `head=<sha>` and `qodo-open=<value>`, and a screenshot line if there is one. Nothing is hand-written.
     - `## What`: one ``New: `<name>` `` line per doc, then `A docs PR needs no delivery doc of its own (AGENTS.md rule 6).`
     - `## Assistance and third-party material`: the generator, run by Claude Code. No third-party material.
     - `## Limitations`: `Adds no code, so rule 8 has nothing to test here.`, then one line for each doc whose `qodo-open` is not 0.
     - `## Hackathon` and `## Qodo notes`: empty.
     - Then the PR attribution line from the session's attribution reminder.
   - Reused branch: the PR exists. Read its body (`gh pr view <number> --repo $REPO --json body --jq .body`), append one `How` bullet and one `What` line for the new doc, update the `Why` list of PRs, and write it back with `gh pr edit <number> --repo $REPO --body-file <file>`. Set its title to the reused commit's subject with `--title`, so the title names the same PRs.

B8. **Confirm on the docs PR.**
   - Run `scripts/generate-delivery.sh --pr $N --check` on the docs branch.
     - Exit 0: continue.
     - Exit 1 with a diff: an input moved (Qodo's review or the PR description). Regenerate (B5, then B6). Repeat at most three times, then show the owner the diff.
     - Exit 1 without a diff: report the message and stop.
   - Wait for the docs PR's Check site run: poll `gh run list --repo $REPO --commit $(git rev-parse HEAD) --workflow "Check site" --json status,conclusion,databaseId` about every 30 seconds until its `status` is `completed`, and give up after 20 minutes. Its `delivery-doc` job must be `success`. A warning is expected when `qodo-open` is not 0.
   - Run Part A with `N` set to the docs PR's number (the PR just created or reused in B7), not the merged PR's, so that its `qodo-findings` status is success.
   - Report the docs PR to the owner. The discussion block in the doc is the owner's to post. Its image and its delivery-notes link point at `main`, so they resolve once the docs PR merges.

## Rules

- Never write, edit or paste evidence by hand. Fix the input (the PR description, CI, the code) and regenerate.
- Never post to the hackathon discussions, and never merge. The owner posts the discussion block.
- Never change the existing docs in `deliveries/` on main. A doc still in an open docs PR may be regenerated.
- Never commit a delivery doc into a code PR. A docs PR has one commit and changes only `deliveries/`; adding a doc amends that commit.
- Never report a PR as ready to merge while Qodo lists an open finding (AGENTS.md rule 9).
- Dismiss on your own only a false_positive, with evidence. Ask the owner before any other reason or any High finding. "Dismiss what is not relevant" covers only the findings listed at that time on that PR.
