# chore: test a failed site build in the agent runner's checks

**PR:** [#170](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/170) · **Opened:** 2026-11-26

## Why

_From the PR description (author-written)._

In `scripts/agent-run.sh`, `checks_once` returns early when main's `build-site.sh` fails (`|| return 1`), but no test made that build fail. Dropping the early return, or sending a build failure down another path, would have left CI green. Qodo raised this on #54, and AGENTS.md rule 8 requires a CI test for each failure path.

## How

_From the PR description (author-written)._

The docker stub in `scripts/test-agent.sh` reads a per-case `build-plan` (`pass` or `fail`; any other line is an error) and logs each build. Inside `checks_once`, `set -e` is off because it is called in an `||` list, so without the early return a failed build is silently ignored when both check containers pass. The new cases therefore leave the checks passing and assert that the build failure alone decides the outcome.

Scratch mutation, run locally on the final test file with `|| return 1` removed from `checks_once` (then reverted). 103 cases passed and the two new ones failed:

```
FAIL d: the build fails every run, stop at the checks stage before any check container, no push or PR
       needed: test 0 -ne 0
FAIL d: the build fails once, the model gets the build log, the run carries on
       needed: test 1 -eq 2
2 agent test case(s) failed
```

(The excerpt leaves out the runner and `ls` lines printed between each FAIL and its `needed` line.)

## What

_From the PR description (author-written)._

- Test-only change to `scripts/test-agent.sh`: the stub switch and two cases.
- Build fails every run: the run stops at the `checks` stage (run 3 of 3), no check container runs, the build error reaches the model and the stop comment, and there is no commit, push or PR.
- Build fails once: the model is called again with the failing log, and the run ends `agent-done`.

How to test: `bash scripts/test-agent.sh` (needs jq; no Docker or network), and `scripts/check-workflows.sh`.

Review: a separate reviewer agent found one HIGH (the "no commit" criterion was not asserted), one MEDIUM and two LOWs. All four are fixed, and the final pass reported no findings.

Qodo then raised one Low finding (an empty build plan gave a sed error under GNU sed instead of the stub's unknown-step message); fixed in the stub, with the suite and the mutation re-run.

## Evidence

- Ran in CI: [run 45943075742](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45943075742) on f678440 (content 7bb7271b70012f43c3da97e3a5ab52c1d50bfa36). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 2606aff build.
- Local: built the head and the merge-base (2606aff) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `8f964344c3f2f2b9d9443b4d0b04bb0d11bf924a`, `7bb7271b70012f43c3da97e3a5ab52c1d50bfa36`. Its latest review is content `7bb7271b70012f43c3da97e3a5ab52c1d50bfa36`.

- Empty build plans report a shell error (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `8f964344c3f2f2b9d9443b4d0b04bb0d11bf924a`.

Open findings in Qodo's latest review: 0.

The PR description has no `## Qodo notes` section.

## Assistance and third-party material

_From the PR description (author-written)._

Planned, written and reviewed with Claude Code agents, approved by the owner. No third-party material.

## Limitations

_From the PR description (author-written)._

- The build is stubbed: the cases cover how the runner handles a failing `build-site.sh` build, not a real Jekyll failure in Docker.
- The mutation output above is from a local scratch run, as the issue asks; no deliberately broken revision was pushed. This PR changes only test code and adds no new check.

## Discussion post

This PR has no `## Hackathon` section, so there is no discussion post.
<!-- delivery: content=7bb7271b70012f43c3da97e3a5ab52c1d50bfa36 head=f678440f2800ad3f8c178c33b94ffa82158e34ed homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
