---
name: delivery-doc
description: Generates and maintains the delivery doc for a PR in the lioramilbaum.com repo (deliveries/<date>-<slug>.md, AGENTS.md rule 6). Runs scripts/generate-delivery.sh once CI and Qodo have reviewed the PR, amends the PR's single commit, force-pushes, and verifies with --check. Trigger when the user says "delivery doc", "delivery-doc", "write the delivery doc", "generate the delivery", "fill in the delivery notes", "update the delivery doc", "Qodo has reviewed, update the doc", "delivery evidence for PR N", or asks for the delivery doc of a lioramilbaum.github.io PR. Never hand-write evidence; this skill only runs the generator.
---

# Delivery doc

Writes `deliveries/<PR open date>-<branch slug>.md` for a PR to lioramilbaum/lioramilbaum.github.io by running `scripts/generate-delivery.sh`. Every section is generated from the PR description, the CI runs, the two homepage builds, and Qodo's review comment. Do not write or edit evidence by hand.

Inside the feature-workflow or pr-audit-fix skills, the git-ops subagent runs the git and gh commands in the steps below.

Inputs: the PR number `N`. If it is missing, ask for it. The repo is `lioramilbaum/lioramilbaum.github.io` (upstream); the branch is pushed to the `lmilbaum` fork (`origin`). Run this skill from the clone that pushed the PR: a fresh clone can lack the head commit, and then its CI run lookup can cite a later run and show a diff.

Set `REPO=lioramilbaum/lioramilbaum.github.io`.

## Steps

1. **Stop early if the doc does not apply.**
   - Run `bash scripts/check-delivery.sh --window`. Exit 0 means the window is open; exit 3 means it has ended (2026-12-12 23:00 UTC). Report that and stop. Any other exit means stop and report the error.
   - Run `gh pr view $N --repo $REPO --json author --jq .author.login`. If it is `renovate[bot]`, stop: Renovate PRs are exempt.

2. **Require all of these before generating.** Stop at the first one that fails and say which one.
   - Exactly one commit above upstream: `git fetch upstream main --quiet` then `test "$(git rev-list --count upstream/main..HEAD)" = 1`.
   - A clean tree: `test -z "$(git status --porcelain)"`.
   - Local HEAD is the PR head: `test "$(git rev-parse HEAD)" = "$(gh pr view $N --repo $REPO --json headRefOid --jq .headRefOid)"`. A stale checkout must not generate or push over the PR.
   - An open PR from `lmilbaum:<current branch>`: `gh pr view $N --repo $REPO --json state,headRefName,headRepositoryOwner --jq '[.state, .headRefName, .headRepositoryOwner.login] | @tsv'` must print `OPEN`, the current branch, and `lmilbaum`.
   - The PR description has the required sections. `gh pr view $N --repo $REPO --json body --jq .body` must contain each of these as a line of its own: `## Why`, `## How`, `## What`, `## Assistance and third-party material`, `## Limitations`. If one is missing, ask the owner to add it to the PR description (see `.github/pull_request_template.md`).

3. **Wait until the evidence is ready for the head.** Let `SHA=$(git rev-parse HEAD)`.
   - CI: poll `gh run list --repo $REPO --commit $SHA --workflow "Check site" --json status,conclusion,databaseId` until the run's `status` is `completed`. Wait about 30 seconds between polls and give up after 20 minutes. A red `delivery-doc` here is expected if a doc from earlier content is in the tree: the generator does not count that job.
   - Qodo: unless the PR is a draft (`gh pr view $N --repo $REPO --json isDraft`), also wait until Qodo's latest comment names a commit with the same content as the head, and give up after 20 minutes. A draft gets no Qodo review; mark it ready before the final run. Read the comment with `gh api graphql -F owner=lioramilbaum -F name=lioramilbaum.github.io -F n=$N -f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){comments(first:100){nodes{author{login} body}}}}}' --jq '[.data.repository.pullRequest.comments.nodes[] | select(.author.login | startswith("qodo-code-review")) | select(.body | contains("Code Review by Qodo")) | .body] | last // empty'`. Take the 40-character commit from the marker `<!-- https://github.com/.../commit/<sha> -->` and compare the two content digests. Let `DOC` be `deliveries/$(gh pr view $N --repo $REPO --json createdAt --jq .createdAt | cut -c1-10)-<branch without its type prefix>.md`. Then `bash scripts/check-delivery.sh --digest <qodo-sha> $DOC` must equal `bash scripts/check-delivery.sh --digest $SHA $DOC`. If Qodo's commit is not in the local clone, report that and stop.

4. **Generate the doc.** From the repo root, run `scripts/generate-delivery.sh --pr $N`. It builds the head and the merge-base, takes one desktop screenshot of the head only when the homepage changed (Docker and network needed), and writes the doc and any screenshot under `deliveries/`. If it fails, report its message and fix the cause (a missing PR section, or CI not yet passing). Do not patch the output by hand.

5. **Amend and push.**
   - `git add deliveries/` (the doc and its `deliveries/<stem>/` directory, if present).
   - `git commit --amend --no-edit`.
   - Check that the last line of the message is the `Co-Authored-By:` trailer from the session's attribution reminder. If it is missing, add it with `git commit --amend` and push. Do not ask first.
   - `git push --force-with-lease origin <branch>`.

6. **Confirm on the new commit.** Wait for CI on the new SHA as in step 3, and require the new run's `delivery-doc` job to be `success`. Then, unless the PR is a draft (a draft gets no Qodo review), wait for Qodo to re-review: its latest "Code Review by Qodo" comment must name the new SHA. If it has not named the new SHA after 5 minutes, accept a comment whose content digest equals the new head's. In either case the comment must have had no edits for about 2 minutes. Give up after 20 minutes and report. Only then run `scripts/generate-delivery.sh --pr $N --check`. A doc-only amend changes no digest, so a diff now means an input moved (Qodo's findings or the PR description).
   - Exit 0 ("is current"): done.
   - Exit 1 with a diff: regenerate with step 4, then repeat step 5. Repeat at most three times. If the diff is still there after three, or if Qodo keeps reacting to the doc's own text, stop and show the owner the diff.
   - Exit 1 without a diff (for example no passing run): report the message and stop.

## Rules

- Never write, edit or paste evidence by hand. Fix the input (the PR description, CI, the code) and regenerate.
- Never post to the hackathon discussions, and never merge. The owner posts the discussion block.
- Never change the existing docs in `deliveries/`.
- Never add a second commit. The doc goes into the PR's single commit (the global rule: one commit per PR).
