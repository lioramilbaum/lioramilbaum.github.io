# feat: start the coding agent on an issue when the owner labels it ready-for-agent (#52)

**PR:** [#54](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/54) · **Opened:** 2026-11-08 · **Hackathon:** Day 4: [Automate your factory's first job](https://github.com/orgs/qodo-hackathon/discussions/6).

## Why

_From the PR description (author-written)._

Until now, every ticket on this site started with me opening a Claude Code session and prompting it. Day 4 of the Qodo Software Factory hackathon asks the factory to pick up work on its own. Here the trigger is a label: when I add `ready-for-agent` to an issue I wrote, a GitHub Actions workflow takes the ticket from there to a PR that Qodo has reviewed. I still decide what goes in and what merges.

## How

_From the PR description (author-written)._

`.github/workflows/agent-run.yml` runs on `issues: labeled`. It runs only when I added `ready-for-agent` to an issue I wrote, in this repo, and the issue is not a pull request. It has `contents: read` only, a 180-minute timeout, and one run at a time. It runs main's copy of `scripts/agent-run.sh`, which does every step that needs a token:

1. **Intake.** The issue must be open, mine, and carry an `## Acceptance criteria` checklist (rule 10), with no branch or PR for it yet. The label moves to `agent-working`.
2. **Change.** Claude Code (`claude -p`, pinned in `scripts/agent/package-lock.json`) gets a fixed prompt (`scripts/agent/prompt.md`) and the issue body as untrusted data. It has only Read, Edit, Write, Glob and Grep, in restricted mode, with deny rules for `/proc`, `/etc` and the runner's private files. It runs with a throwaway home directory and only its own OAuth token in its environment.
3. **Checks.** main's `build-site.sh` builds the change in Docker with no network. The change's own `check-site.sh` runs in a container with no network and no secrets. On failure the log goes back to the model, up to 2 retries.
4. **Guards.** The run refuses a change to `.github/`, `.claude/`, the runner itself, `build-site.sh`, `deliveries/` or `CNAME`, and an empty change.
5. **PR.** One commit with the `Co-Authored-By` trailer, pushed to my fork, and a PR upstream with `Closes #N` and the issue's checklist. Tokens are redacted from every text the run posts.
6. **Qodo.** Up to 3 rounds: wait for Qodo's review of the head (`scripts/qodo-status.sh`), have the model fix each finding or give a verdict, re-run the checks, amend, force-push with lease. No open findings ends with `agent-done`. Any stop comments on the issue with the stage and the round, and labels it `agent-stuck`.

Two fine-grained tokens limit what a run can do, whatever the model is told: one can only write my fork's contents, the other can only manage this repo's PRs and issues. Neither can push to upstream, so a run cannot merge, push to `main` or touch `screenshots`.

## What

_From the PR description (author-written)._

- `.github/workflows/agent-run.yml` (new): the trigger.
- `scripts/agent-run.sh` (new): the runner.
- `scripts/agent/package.json`, `scripts/agent/package-lock.json` (new): Claude Code pinned by version and integrity.
- `scripts/agent/prompt.md` (new): the model's fixed instructions.
- `scripts/test-agent.sh` (new): 75 offline cases with stubs for `docker`, `gh`, `claude`, the checks and `qodo-status.sh`, run by a new "Test the agent runner" step in `.github/workflows/check-site.yml`.
- `scripts/check-workflows.sh`: pins `agent-run.yml`'s trigger, guard (only `&&` terms), permissions, timeout, Node version, actions and where its secrets may appear.
- `scripts/build-site.sh`: an optional directory argument, so the runner builds the change with main's copy of the script.
- `AGENTS.md`: Setup describes the run, its secrets, its labels and its residual risks; Verify lists `test-agent.sh`; rules 5 and 8 name the new checks and the new script.
- `.gitignore`: `scripts/agent/node_modules/`.

## Evidence

- Ran in CI: [run 42552156932](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42552156932) on 7d4d66e (content 33e6aee65ece65a7d9e47c2f847580c3b17968f9). Jobs: build: success.
- Homepage: unchanged. The head build (H 5840ed9dc06ed8bfc09b7fd6698c7f0457f045b6) matches the merge-base b8d9d7b build.
- Local: built the head and the merge-base (b8d9d7b) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `766cc326d9e50c5f0886d477989d726e4c3a08b2`, `4e7426ad647f579d7368c98567aced7b7dcfec8b`, `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`, `e7cdb8d64108e9018f7feed5745b7ce005110e32`, `33e6aee65ece65a7d9e47c2f847580c3b17968f9`. Its latest review is content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.

- Unsafe labels can reach agent secrets (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`.
- An added step can expose agent secrets (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`, `4e7426ad647f579d7368c98567aced7b7dcfec8b`.
- Failed checks discard Qodo verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`.
- Failed comments erase Qodo verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `4e7426ad647f579d7368c98567aced7b7dcfec8b`, `5d19e561d2631c958046a7aaecc9639b3ab63c6f`.
- Agent changes can bypass the site check (🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Agent-ready PRs can have failing CI (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Some labeled issues never start a run (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`.
- A changed helper can read runner tokens (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Swapped secrets pass workflow checks (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Protected files can reach the agent PR (🐞 Bug). No longer listed by Qodo. Reviewed in content `e7cdb8d64108e9018f7feed5745b7ce005110e32`.
- A failed site build is never exercised by a CI test (📎 Requirement gap). No longer listed by Qodo. Reviewed in content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.
- Successful rounds lose review verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.

Open findings in Qodo's latest review: 0.

_From the PR description (author-written)._

- **Dismissed as intentional, with the owner's approval: "Some labeled issues never start a run".** Only one agent run happens at a time, on purpose, because two runs would race for the same branch names. Re-queuing a dropped run would mean the runner adds `ready-for-agent` again, and a label added with a token starts a workflow, so a run could trigger itself. The limit is documented in AGENTS.md Setup. A dropped issue keeps its `ready-for-agent` label, so it stays visible; relabel it to retry.
- **Dismissed as deferred, with the owner's approval: "A failed site build is never exercised by a CI test".** The runner already handles a failed build. What's missing is a test where the build fails, which rule 8 requires, so until #55 lands one failure path has no CI coverage. Tracked in #55.
- **Dismissed as deferred, with the owner's approval: "Successful rounds lose review verdicts".** The runner posts the model's verdicts on every stop, but not after a round that pushes a fix successfully. Tracked in #56.

## Assistance and third-party material

_From the PR description (author-written)._

Planned, written and reviewed with Claude Code (Claude Opus 5.5), in a planner → executor → reviewer loop with three review rounds. The runner calls Claude Code (`@anthropic-ai/claude-code` 2.1.319, from npm) and uses the GitHub CLI. The design compared notes with other Day 4 submissions in discussion #6, most of which run a local poller with the owner's own `gh` login.

## Limitations

_From the PR description (author-written)._

- CI cannot fire `issues: labeled`, so the workflow itself first runs after this merges. CI covers it with `check-workflows.sh`'s assertions and covers the runner's logic with `test-agent.sh`. The real run, on a ticket I pick and give acceptance criteria, is the end-to-end test.
- The real Claude Code call, the three secrets and the real GitHub API calls are not exercised in CI: no secret is available there. Whether Claude Code's deny rules actually block `/proc` reads is first checked on the real run.
- Claude Code's permission rules, not an OS boundary, stand between the model and the runner's process environment. The narrow tokens are the backstop.
- The run cannot dismiss Qodo findings or mark them implemented (Qodo's tools aren't reachable from Actions), and it does not generate the delivery doc. I do both.
- A ticket that needs a workflow change, including the CI wiring rule 8 requires for a new test, ends `agent-stuck`: `.github/` is guarded.
- Before the first run I have to create the four labels and the three secrets, and allow fine-grained tokens in the org.
- No delivery doc in this PR (rule 6): it is generated after the merge, from the merged PR, and added in a follow-up PR, as #36 did for #35 (see #48). Until then CI's delivery-doc job warns and stays green.
- Red CI runs for the new checks (rule 8), each from a deliberately broken revision that was then replaced by this PR's commit:
  - `scripts/check-workflows.sh` with `|| true` added to `agent-run.yml`'s guard: [run 42519304768](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42519304768) fails with "job run if has ||".
  - `scripts/test-agent.sh` with the runner's acceptance-criteria gate removed: [run 42519393410](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42519393410) fails case a, "an issue without acceptance criteria stops before the model".

## Discussion post

For the owner to post in the day's thread. The skill never posts to the hackathon discussions.

````markdown
## Challenge

Day 4: [Automate your factory's first job](https://github.com/orgs/qodo-hackathon/discussions/6).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/54 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-08-issue-52-agent-run.md))

## What I completed

Until now, every ticket on this site started with me opening a Claude Code session and prompting it. Day 4 of the Qodo Software Factory hackathon asks the factory to pick up work on its own. Here the trigger is a label: when I add `ready-for-agent` to an issue I wrote, a GitHub Actions workflow takes the ticket from there to a PR that Qodo has reviewed. I still decide what goes in and what merges.

- `.github/workflows/agent-run.yml` (new): the trigger.
- `scripts/agent-run.sh` (new): the runner.
- `scripts/agent/package.json`, `scripts/agent/package-lock.json` (new): Claude Code pinned by version and integrity.
- `scripts/agent/prompt.md` (new): the model's fixed instructions.
- `scripts/test-agent.sh` (new): 75 offline cases with stubs for `docker`, `gh`, `claude`, the checks and `qodo-status.sh`, run by a new "Test the agent runner" step in `.github/workflows/check-site.yml`.
- `scripts/check-workflows.sh`: pins `agent-run.yml`'s trigger, guard (only `&&` terms), permissions, timeout, Node version, actions and where its secrets may appear.
- `scripts/build-site.sh`: an optional directory argument, so the runner builds the change with main's copy of the script.
- `AGENTS.md`: Setup describes the run, its secrets, its labels and its residual risks; Verify lists `test-agent.sh`; rules 5 and 8 name the new checks and the new script.
- `.gitignore`: `scripts/agent/node_modules/`.

## Evidence

- Ran in CI: [run 42552156932](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42552156932) on 7d4d66e (content 33e6aee65ece65a7d9e47c2f847580c3b17968f9). Jobs: build: success.
- Homepage: unchanged. The head build (H 5840ed9dc06ed8bfc09b7fd6698c7f0457f045b6) matches the merge-base b8d9d7b build.
- Local: built the head and the merge-base (b8d9d7b) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `766cc326d9e50c5f0886d477989d726e4c3a08b2`, `4e7426ad647f579d7368c98567aced7b7dcfec8b`, `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`, `e7cdb8d64108e9018f7feed5745b7ce005110e32`, `33e6aee65ece65a7d9e47c2f847580c3b17968f9`. Its latest review is content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.

- Unsafe labels can reach agent secrets (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`.
- An added step can expose agent secrets (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`, `4e7426ad647f579d7368c98567aced7b7dcfec8b`.
- Failed checks discard Qodo verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `766cc326d9e50c5f0886d477989d726e4c3a08b2`.
- Failed comments erase Qodo verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `4e7426ad647f579d7368c98567aced7b7dcfec8b`, `5d19e561d2631c958046a7aaecc9639b3ab63c6f`.
- Agent changes can bypass the site check (🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Agent-ready PRs can have failing CI (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`, `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Some labeled issues never start a run (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5d19e561d2631c958046a7aaecc9639b3ab63c6f`.
- A changed helper can read runner tokens (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Swapped secrets pass workflow checks (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6e08ee9eff0466c2485fb19b970a9c7fb377d6f3`.
- Protected files can reach the agent PR (🐞 Bug). No longer listed by Qodo. Reviewed in content `e7cdb8d64108e9018f7feed5745b7ce005110e32`.
- A failed site build is never exercised by a CI test (📎 Requirement gap). No longer listed by Qodo. Reviewed in content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.
- Successful rounds lose review verdicts (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `33e6aee65ece65a7d9e47c2f847580c3b17968f9`.

Open findings in Qodo's latest review: 0.

- CI cannot fire `issues: labeled`, so the workflow itself first runs after this merges. CI covers it with `check-workflows.sh`'s assertions and covers the runner's logic with `test-agent.sh`. The real run, on a ticket I pick and give acceptance criteria, is the end-to-end test.
- The real Claude Code call, the three secrets and the real GitHub API calls are not exercised in CI: no secret is available there. Whether Claude Code's deny rules actually block `/proc` reads is first checked on the real run.
- Claude Code's permission rules, not an OS boundary, stand between the model and the runner's process environment. The narrow tokens are the backstop.
- The run cannot dismiss Qodo findings or mark them implemented (Qodo's tools aren't reachable from Actions), and it does not generate the delivery doc. I do both.
- A ticket that needs a workflow change, including the CI wiring rule 8 requires for a new test, ends `agent-stuck`: `.github/` is guarded.
- Before the first run I have to create the four labels and the three secrets, and allow fine-grained tokens in the org.
- No delivery doc in this PR (rule 6): it is generated after the merge, from the merged PR, and added in a follow-up PR, as #36 did for #35 (see #48). Until then CI's delivery-doc job warns and stays green.
- Red CI runs for the new checks (rule 8), each from a deliberately broken revision that was then replaced by this PR's commit:
  - `scripts/check-workflows.sh` with `|| true` added to `agent-run.yml`'s guard: [run 42519304768](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42519304768) fails with "job run if has ||".
  - `scripts/test-agent.sh` with the runner's acceptance-criteria gate removed: [run 42519393410](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42519393410) fails case a, "an issue without acceptance criteria stops before the model".

## Assistance and third-party material

Planned, written and reviewed with Claude Code (Claude Opus 5.5), in a planner → executor → reviewer loop with three review rounds. The runner calls Claude Code (`@anthropic-ai/claude-code` 2.1.319, from npm) and uses the GitHub CLI. The design compared notes with other Day 4 submissions in discussion #6, most of which run a local poller with the owner's own `gh` login.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=33e6aee65ece65a7d9e47c2f847580c3b17968f9 homepage=5840ed9dc06ed8bfc09b7fd6698c7f0457f045b6 qodo-open=0 -->
