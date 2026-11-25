# docs: list the Day 17 submission on the hackathon page

**PR:** [#157](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/157) · **Opened:** 2026-11-25 · **Hackathon:** [Day 17: What did your agent decide?](https://github.com/orgs/qodo-hackathon/discussions/19), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/19#discussioncomment-19889971

## Why

_From the PR description (author-written)._

The hackathon page lists each day's submission. Day 17 ("What did your agent decide?") was posted on 2026-11-25 and was not on the page.

## How

_From the PR description (author-written)._

- One list entry, in the form of the earlier days. `scripts/check-site.sh` asserts the link on the built page (AGENTS.md rule 3).
- The new link takes `scripts/check-links.sh` from 40 to 42 jobs, which no longer fit two batches at a cap of 20 (worst case 462 s against the step's 5-minute timeout), so the cap is 25: a batch of 25 links (66 s), then a batch of 17 lookups (198 s), 264 s in all.
- No workflow file changes.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: the Day 17 entry in "My submissions".
- `scripts/check-site.sh`: the Day 17 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: `cap=25`, and the budget comment with the new counts, the range the cap works in, and what Day 22 needs.

## Evidence

- Ran in CI: [run 45621088354](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45621088354) on 5bf4bc5 (content c6b114a2055069b33917fb8559419da961a1535c). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 2661c68 build.
- Local: built the head and the merge-base (2661c68) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `c6b114a2055069b33917fb8559419da961a1535c`. Its latest review is content `c6b114a2055069b33917fb8559419da961a1535c`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (planner, executor, reviewer and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45620923509](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45620923509) on `4259fe7`, the revision without the page's Day 17 line, failed with `hackathon page link missing: …discussions/19#discussioncomment-19889971`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.
- 25 requests now start at once against github.com instead of 20, and 17 unauthenticated API lookups instead of 16.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 17: What did your agent decide?](https://github.com/orgs/qodo-hackathon/discussions/19), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/19#discussioncomment-19889971

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/157 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-25-hackathon-day-17.md))

## What I completed

The hackathon page lists each day's submission. Day 17 ("What did your agent decide?") was posted on 2026-11-25 and was not on the page.

- `docs/qodo-software-factory-hackathon.md`: the Day 17 entry in "My submissions".
- `scripts/check-site.sh`: the Day 17 link in the hackathon page's asserted links.
- `scripts/check-links.sh`: `cap=25`, and the budget comment with the new counts, the range the cap works in, and what Day 22 needs.

## Evidence

- Ran in CI: [run 45621088354](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45621088354) on 5bf4bc5 (content c6b114a2055069b33917fb8559419da961a1535c). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 2661c68 build.
- Local: built the head and the merge-base (2661c68) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `c6b114a2055069b33917fb8559419da961a1535c`. Its latest review is content `c6b114a2055069b33917fb8559419da961a1535c`.

Qodo's latest review lists no findings.

- The new assertion was run against a failing input in CI (AGENTS.md rule 8): [run 45620923509](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45620923509) on `4259fe7`, the revision without the page's Day 17 line, failed with `hackathon page link missing: …discussions/19#discussioncomment-19889971`.
- The 264 s figure is a worst case (every request timing out and retrying), which CI does not reproduce; a normal run takes seconds. The link check stays a non-blocking step.
- A cap of 25 holds through Day 21 (50 jobs). The Day 22 link needs the cap or the timeout changed first; the comment in `scripts/check-links.sh` says so.
- 25 requests now start at once against github.com instead of 20, and 17 unauthenticated API lookups instead of 16.

## Assistance and third-party material

- Claude Code (planner, executor, reviewer and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=c6b114a2055069b33917fb8559419da961a1535c head=5bf4bc5efef8886838ccc9c74d13ed8ecc66023b homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
