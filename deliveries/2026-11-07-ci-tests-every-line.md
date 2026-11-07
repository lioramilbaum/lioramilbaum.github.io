# docs: require CI tests for every line a PR adds or changes

**PR:** [#35](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/35) · **Opened:** 2026-11-07

## Why

_From the PR description (author-written)._

PR #34 (issue #27) first checked its new code by hand: one-off mutation runs for check-site.sh's failure paths, a link-check script run by hand, and a manual browser check of the share button. None of that runs again on the next PR. I want every line a PR adds or changes to be tested in CI, so a regression turns CI red instead of waiting for someone to repeat a manual step.

## How

_From the PR description (author-written)._

- AGENTS.md gets rule 8: CI must exercise every line of code a PR adds or changes. Every new branch or failure path needs a CI test that fails without it. Nothing counts if it's verified only by hand. Anything that truly can't run in CI goes in the PR's Limitations, with the reason.
- Test code is exempt. Checks and tests (`scripts/check-*.sh`, `scripts/test-*.sh` and the `check-site.yml` steps that run them) must run in CI, but don't need tests of their own. A new check must still go red in CI once, against a deliberately broken revision, with that run linked in the PR.
- Every other script (`build-site.sh`, `snapshot-site.sh`, `generate-delivery.sh`), the workflows, the layouts and `_config.yml` count as code. For layouts and config, a `check-site.sh` assertion on the built site counts.
- The rule covers new and changed lines only, so code already on `main` doesn't fail it the day it lands.
- It's appended as rule 8 rather than inserted. Scripts, the PR template, the delivery-doc skill, earlier delivery docs and the Qodo rules cite rules 6 and 7 by number.
- The PR template's comment now says the Limitations section must name anything CI can't test (rule 8).

## What

_From the PR description (author-written)._

- `AGENTS.md`: new rule 8, appended after rule 7. No existing line changes.
- `.github/pull_request_template.md`: one line in the leading comment.

## Evidence

- Ran in CI: [run 42411719746](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42411719746) on 1c46e88 (content 85f4233230356bf5f3be0311aade1ac1d2362e44). Jobs: build: success.
- Homepage: unchanged. The head build (H 11fcbbe5c29957f489772ff32321790da0b2b5d8) matches the merge-base 83907d3 build.
- Local: built the head and the merge-base (83907d3) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `85f4233230356bf5f3be0311aade1ac1d2362e44`. Its latest review is content `85f4233230356bf5f3be0311aade1ac1d2362e44`.

Qodo's latest review lists no findings.

The PR description has no `## Qodo notes` section.

## Assistance and third-party material

_From the PR description (author-written)._

Planned and written with Claude Code agents running Anthropic Claude models: planners, executors and reviewers. I set the rule's scope and wording and approved each change. No third-party material.

## Limitations

_From the PR description (author-written)._

- This PR changes only Markdown: a rule in AGENTS.md and a comment in the PR template. It adds no code, so rule 8 has nothing to test here. CI still builds the site, runs check-site.sh (which asserts AGENTS.md isn't published), and runs the delivery tests.
- CI doesn't enforce rule 8 itself; reviewers and Qodo do.
- Qodo doesn't re-sync the rules I added by hand. After merge I'll check whether it imported rule 8 and, if not, add a matching Qodo rule by hand.

## Discussion post

This PR has no `## Hackathon` section, so there is no discussion post.
<!-- delivery: content=85f4233230356bf5f3be0311aade1ac1d2362e44 homepage=11fcbbe5c29957f489772ff32321790da0b2b5d8 -->
