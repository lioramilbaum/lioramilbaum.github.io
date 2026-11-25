# docs: list the Day 18 submission on the hackathon page

**PR:** [#159](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/159) · **Opened:** 2026-11-25 · **Hackathon:** [Day 18: Turn a red build into useful feedback](https://github.com/orgs/qodo-hackathon/discussions/20), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/20#discussioncomment-19890666

## Why

_From the PR description (author-written)._

The hackathon page lists each day's submission. Day 18 ("Turn a red build into useful feedback") was posted on 2026-11-25 and was not on the page.

## How

_From the PR description (author-written)._

- One list entry, in the form of the earlier days. `scripts/check-site.sh` asserts the link on the built page (AGENTS.md rule 3).
- The new link takes `scripts/check-links.sh` from 42 to 44 jobs. The cap stays 25: a batch of 25 links (66 s), then a batch of 1 link and 18 lookups (198 s), 264 s in all. Only the budget comment's counts change.
- No workflow file changes.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: the Day 18 entry in "My submissions".
- `scripts/check-site.sh`: the Day 18 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: the budget comment says 26 links and 18 lookups (44 jobs). `cap=25` is unchanged.

## Evidence

- Ran in CI: [run 45624657157](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45624657157) on a3e197c (content 13217f32be8071762415a8de1283dbc2ffbe2368). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 2554e19 build.
- Local: built the head and the merge-base (2554e19) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `13217f32be8071762415a8de1283dbc2ffbe2368`. Its latest review is content `13217f32be8071762415a8de1283dbc2ffbe2368`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45624498481](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45624498481) on `8f7b6a3`, the revision without the page's Day 18 line, failed with `hackathon page link missing: …discussions/20#discussioncomment-19890666`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 18: Turn a red build into useful feedback](https://github.com/orgs/qodo-hackathon/discussions/20), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/20#discussioncomment-19890666

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/159 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-25-hackathon-day-18.md))

## What I completed

The hackathon page lists each day's submission. Day 18 ("Turn a red build into useful feedback") was posted on 2026-11-25 and was not on the page.

- `docs/qodo-software-factory-hackathon.md`: the Day 18 entry in "My submissions".
- `scripts/check-site.sh`: the Day 18 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: the budget comment says 26 links and 18 lookups (44 jobs). `cap=25` is unchanged.

## Evidence

- Ran in CI: [run 45624657157](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45624657157) on a3e197c (content 13217f32be8071762415a8de1283dbc2ffbe2368). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 2554e19 build.
- Local: built the head and the merge-base (2554e19) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `13217f32be8071762415a8de1283dbc2ffbe2368`. Its latest review is content `13217f32be8071762415a8de1283dbc2ffbe2368`.

Qodo's latest review lists no findings.

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45624498481](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45624498481) on `8f7b6a3`, the revision without the page's Day 18 line, failed with `hackathon page link missing: …discussions/20#discussioncomment-19890666`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.

## Assistance and third-party material

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=13217f32be8071762415a8de1283dbc2ffbe2368 head=a3e197c471ce4a3520dabb2ef822603c16487adc homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
