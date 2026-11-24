# docs: list the Day 14 submission on the hackathon page

**PR:** [#144](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/144) · **Opened:** 2026-11-24 · **Hackathon:** [Day 14: Turn your quality gate into a workflow](https://github.com/orgs/qodo-hackathon/discussions/16).

## Why

_From the PR description (author-written)._

The hackathon page's "My submissions" list stopped at Day 13, although Day 14 is posted. Readers of the page couldn't reach the Day 14 submission, where a Qodo approval workflow labelled a clean PR and an approval guard on `.github/**` kept a workflow change for my review.

## How

_From the PR description (author-written)._

- One more line in the list, in the same form as Days 1 to 13, and one more URL in the list that `scripts/check-site.sh` asserts on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh` needs no change to its code. The link is a discussion comment, so it is checked twice (the page link, and an API lookup that the comment exists), which takes the page from 32 jobs to 34: 20 links and 14 lookups. At the batch cap of 18 that is still two batches, 264 s in the worst case, inside CI's 5-minute step timeout.
- The script's header comment is the worked example a maintainer uses to decide when the cap must change, so its numbers are updated to the page as it is now. Qodo asked for that on the Day 13 link (PR #140), and for the red CI run below.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: Day 14 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 20 links and 14 lookups (34 jobs).

## Evidence

- Ran in CI: [run 45452656647](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45452656647) on 9bf9a83 (content bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base f6f6f37 build.
- Local: built the head and the merge-base (f6f6f37) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c`. Its latest review is content `bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- Red CI run (AGENTS.md rule 8): [run 45452356993](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45452356993) on the deliberately broken revision 1020c6e (this PR without the Day 14 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/16#discussioncomment-19864914`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 34 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The Day 15 link still fits the two-batch budget (36 jobs). The Day 16 link starts a third batch, so the cap or the timeout must change before it is added.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 14: Turn your quality gate into a workflow](https://github.com/orgs/qodo-hackathon/discussions/16).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/144 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-24-hackathon-day-14.md))

## What I completed

The hackathon page's "My submissions" list stopped at Day 13, although Day 14 is posted. Readers of the page couldn't reach the Day 14 submission, where a Qodo approval workflow labelled a clean PR and an approval guard on `.github/**` kept a workflow change for my review.

- `docs/qodo-software-factory-hackathon.md`: Day 14 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 20 links and 14 lookups (34 jobs).

## Evidence

- Ran in CI: [run 45452656647](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45452656647) on 9bf9a83 (content bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base f6f6f37 build.
- Local: built the head and the merge-base (f6f6f37) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c`. Its latest review is content `bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c`.

Qodo's latest review lists no findings.

- Red CI run (AGENTS.md rule 8): [run 45452356993](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45452356993) on the deliberately broken revision 1020c6e (this PR without the Day 14 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/16#discussioncomment-19864914`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 34 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The Day 15 link still fits the two-batch budget (36 jobs). The Day 16 link starts a third batch, so the cap or the timeout must change before it is added.

## Assistance and third-party material

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=bce8b721d8ad0fb47b31494d3066aeeaa4c73c5c head=9bf9a83fd6d6fe25e85153e94d34d321fe4aeab4 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
