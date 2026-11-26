# docs: list the Day 19 submission on the hackathon page

**PR:** [#167](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/167) · **Opened:** 2026-11-26 · **Hackathon:** [Day 19: What is your factory learning?](https://github.com/orgs/qodo-hackathon/discussions/21), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/21#discussioncomment-19925544

## Why

_From the PR description (author-written)._

The hackathon page lists each day's submission. Day 19 ("What is your factory learning?") was posted on 2026-11-26 and was not on the page.

## How

_From the PR description (author-written)._

- One list entry, in the form of the earlier days. `scripts/check-site.sh` asserts the link on the built page (AGENTS.md rule 3).
- The new link takes `scripts/check-links.sh` from 44 to 46 jobs. The cap stays 25: a batch of 25 links (66 s), then a batch of 2 links and 19 lookups (198 s), 264 s in all. Only the budget comment's counts change.
- No workflow file changes.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: the Day 19 entry in "My submissions".
- `scripts/check-site.sh`: the Day 19 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: the budget comment says 27 links and 19 lookups (46 jobs). `cap=25` is unchanged.

## Evidence

- Ran in CI: [run 45848870526](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45848870526) on c95b444 (content a901cfbebe2afe4d1a636aa559a7b44d53af7139). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 81eb756 build.
- Local: built the head and the merge-base (81eb756) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `a901cfbebe2afe4d1a636aa559a7b44d53af7139`. Its latest review is content `a901cfbebe2afe4d1a636aa559a7b44d53af7139`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (planner, executor, reviewer and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45848749287](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45848749287) on `1d4ce87`, the revision without the page's Day 19 line, failed with `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/21#discussioncomment-19925544`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 19: What is your factory learning?](https://github.com/orgs/qodo-hackathon/discussions/21), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/21#discussioncomment-19925544

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/167 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-26-hackathon-day-19.md))

## What I completed

The hackathon page lists each day's submission. Day 19 ("What is your factory learning?") was posted on 2026-11-26 and was not on the page.

- `docs/qodo-software-factory-hackathon.md`: the Day 19 entry in "My submissions".
- `scripts/check-site.sh`: the Day 19 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: the budget comment says 27 links and 19 lookups (46 jobs). `cap=25` is unchanged.

## Evidence

- Ran in CI: [run 45848870526](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45848870526) on c95b444 (content a901cfbebe2afe4d1a636aa559a7b44d53af7139). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 81eb756 build.
- Local: built the head and the merge-base (81eb756) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `a901cfbebe2afe4d1a636aa559a7b44d53af7139`. Its latest review is content `a901cfbebe2afe4d1a636aa559a7b44d53af7139`.

Qodo's latest review lists no findings.

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45848749287](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45848749287) on `1d4ce87`, the revision without the page's Day 19 line, failed with `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/21#discussioncomment-19925544`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.

## Assistance and third-party material

- Claude Code (planner, executor, reviewer and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=a901cfbebe2afe4d1a636aa559a7b44d53af7139 head=c95b444278a4f738e38c6baf813072cc4b9de184 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
