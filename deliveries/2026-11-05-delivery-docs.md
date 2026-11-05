# Every PR ships a delivery doc (AGENTS.md rule 6)

**PR:** [lioramilbaum/lioramilbaum.github.io#22](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/22) · **Opened:** 2026-11-05 · **Hackathon:** [Day 2: Your factory, your rules](https://github.com/orgs/qodo-hackathon/discussions/4)

## Why

Each PR I open here is a delivery in the Qodo Software Factory hackathon. The evidence for each one (why it changed, how, which checks ran, what Qodo said) was scattered across PR bodies and chat. Qodo also clears resolved findings from its comment, so the lessons disappear unless I capture them before the fix.

## How

- One dated doc per PR in `deliveries/`, copied from `deliveries/TEMPLATE.md`. Its headings follow the hackathon's daily template.
- A CI check (`scripts/check-delivery.sh`, run by the `delivery-doc` job) fails a PR that has no doc or a doc missing a required `##` heading. It checks only the headings, not their content. It only warns on the Qodo TODO marker, because Qodo has only reviewed PRs after they leave draft. On #19 and #20 it commented within about a minute of the PR being marked ready, and never while it was a draft. Renovate PRs are exempt.
- The folder is excluded from the site, and `check-site.sh` asserts that it is not published.
- AGENTS.md rule 6 tells agents to follow the convention. I expect Qodo to import AGENTS.md as review standards (Day 2); Qodo's Review Standards UI will confirm it.

Rejected options, and why:

- `_deliveries/`: it looks like a Jekyll collection.
- `.github/`: it is hidden from judges browsing the repo.
- `docs/hackathon/`: it would be published.
- A PR template: agents open PRs with `gh pr create --body`, which bypasses it.
- Failing CI on the Qodo TODO marker: Qodo has only reviewed PRs after they leave draft, so every PR would start red.

## What

| File | Change |
| --- | --- |
| `deliveries/TEMPLATE.md` | New template. Its `## ` headings are the ones CI requires. |
| `scripts/check-delivery.sh` | New check: file name, required headings, Qodo TODO warning. Runs under bash 3.2. Fences follow CommonMark, using plain awk. |
| `scripts/test-check-delivery.sh` | New regression tests for the checker: fence rules, required sections, names, CRLF. |
| `.github/workflows/check-site.yml` | New `delivery-doc` job on pull requests. Skipped for Renovate PRs. |
| `_config.yml` | `deliveries/` added to `exclude:`, so the folder is not published. |
| `scripts/check-site.sh` | Asserts that `_site/deliveries` does not exist. |
| `AGENTS.md` | Verify commands, rule 6, and the post-review steps in Workflow. |
| `deliveries/2026-11-05-delivery-docs.md` | This doc. |

## Evidence

Local checks, run on this branch:

- `shellcheck scripts/*.sh`: clean. `actionlint -ignore 'label "ubuntu-26.04" is unknown' .github/workflows/*.yml`: clean. The local actionlint (1.7.12) does not know the `ubuntu-26.04` label, so the flag is needed.
- `bash scripts/check-delivery.sh b1d0d64 HEAD` in a scratch worktree with a throwaway commit (never pushed): warns about the Qodo TODO marker, prints `deliveries/2026-11-05-delivery-docs.md: ok`, exit 0. Same result under `/bin/bash` 3.2.
- Failure cases, each exit 1: dropping `## What I learned from the Qodo review` names the missing section; dropping the top-level `## Evidence` fails even though the same heading remains inside the Discussion post example; renaming the doc to `deliveries/delivery-docs.md` gives a naming error; removing the doc gives "no delivery doc added or updated". `check-delivery.sh HEAD HEAD` also fails with no doc. The no-doc case runs the empty-array path under bash 3.2. A CRLF copy of the doc passes, and a `~~~` fence containing `## X` added to the template does not make `## X` required.
- Site: `scripts/build-site.sh` and `bash scripts/check-site.sh _site` pass, and `_site/deliveries` does not exist. Copying `deliveries/` into `_site` makes `check-site.sh` fail with "repo-only path published: deliveries". Without the exclude, the offline local build fails: jekyll-optional-front-matter renders the doc with the theme layout, whose `site.title` triggers a GitHub metadata API lookup that cannot run with `--network none`. A networked build would instead publish the doc, which is why `check-site.sh` asserts it is absent.
- `scripts/test-check-delivery.sh` (13 cases: the real doc, CRLF, missing doc, missing section, bad name, and the fence rules) passes under macOS `/bin/bash` with BWK awk 20200816, Ubuntu 24.04's default mawk 1.3.4 20240123, and gawk 5.2.1. The pre-fix checker from de7730e fails the Qodo case on macOS awk, and exits 100 on mawk because of the interval regex panic.

The `delivery-doc` job passed on PR #22 at de7730e, so the runner's awk accepts the interval regex that crashes Ubuntu 24.04's mawk 1.3.4. The runner's `awk` is gawk 5.3.2, as logged by `test-check-delivery.sh` in [run 42056303381](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42056303381), so CI accepted the old interval regex that crashes mawk, and all 13 regression cases pass there. Not verified before merge: the Renovate skip (only the `if:` expression is reviewed). Qodo re-reviewed 6501e80 and reported no open findings.

## Screenshot or demo

No visible change on lioramilbaum.com.

## What I learned from the Qodo review

Qodo reviewed commit de7730e within two minutes of this PR leaving draft, and posted one MEDIUM finding, "Docs can pass with sections inside examples" ([comment](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/22#issuecomment-6661744429)).

- **Useful:** Qodo found a regression introduced by my own earlier fix. Adding `~~~` support made a tilde line inside a backtick example close the block, so example headings could again satisfy required sections. My reviewer had listed nested fences as a known limitation; Qodo showed a concrete way that limitation breaks the check. Fixed by tracking the opening fence character and length (CommonMark rules), with regression tests.
- **Questioned:** nothing; the finding was correct.
- **Missed:** Qodo did not flag the `{0,3}` interval regex that panics on mawk 1.3.4 (Ubuntu 24.04's default awk); my executor agent found it while fixing the finding. It still passed in CI because the GitHub runner uses gawk 5.3.2, but running the check locally on Ubuntu would have crashed. The earlier HIGH finding (example headings satisfying required sections) was fixed before Qodo saw this PR, so it doesn't count as a miss.
- **Changed in the factory:** the fence parser now follows CommonMark; a regression test script (`scripts/test-check-delivery.sh`) runs in CI (gawk 5.3.2 on the runner); I ran it locally under BWK awk, mawk and gawk; and the lesson: when a reviewer documents a limitation, test that limitation.

## Assistance and third-party material

Built with Claude Code agents running Anthropic Claude models: a planner, an executor and a reviewer. I chose the design and approved each change. No third-party code.

## Limitations

- Main isn't branch-protected, so a red `delivery-doc` check is advisory until it is made required.
- The Qodo section can only be filled once Qodo has reviewed the PR, which so far has happened only after it left draft.
- The doc link on main returns 404 until this PR merges.

## Discussion post

One Day 2 block. Paste it as a top-level comment in the Day 2 thread.

### Day 2: Your factory, your rules (https://github.com/orgs/qodo-hackathon/discussions/4)

```markdown
## Challenge

Day 2, November 3, 2026: Your factory, your rules

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/22 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-05-delivery-docs.md))

## What I completed

Every PR needs a delivery doc, because its evidence was scattered and Qodo clears findings once they are fixed. I made it rule 6 in AGENTS.md.
- A dated doc per PR, copied from `deliveries/TEMPLATE.md`.
- A CI check (`delivery-doc` job) that fails on a missing doc or a missing `## ` heading (headings only, not content) and warns on the Qodo TODO marker.
- The folder is excluded from the site, and `check-site.sh` asserts it.

## Evidence

- AGENTS.md: https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/AGENTS.md
- The rule, quoted: "Copy findings into the doc before fixing them: Qodo rewrites its comment to "no open findings" once they are resolved."
- The story: Qodo clears resolved findings from its comment, so the lessons are lost unless they are captured before the fix.
- Qodo imported rule 6 as a Review Standard: TODO(qodo): confirm in Qodo's Review Standards
- Checks: the `delivery-doc` CI job and `scripts/check-delivery.sh` run locally. Results are in the delivery doc.

## What I learned / what is blocked

Qodo: its MEDIUM finding showed that my earlier fence fix let a tilde line inside a backtick example close the block, so example headings could satisfy required sections. I fixed it with CommonMark fence rules and a regression test (run locally under three awks, and in CI); Qodo also missed the mawk crash in the interval regex, which I found while fixing. Limitations: a red check is advisory on main, and the Qodo section waits until Qodo has reviewed the PR, which so far has happened only after it left draft.

## Assistance and third-party material

Built with Claude Code agents running Anthropic Claude models: a planner, an executor and a reviewer. I chose the design and approved each change. No third-party code.

## Optional demo

No visible change on lioramilbaum.com.
```
