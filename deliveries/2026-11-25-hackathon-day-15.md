# docs: list the Day 15 submission on the hackathon page

**PR:** [#149](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/149) · **Opened:** 2026-11-25 · **Hackathon:** [Day 15: Show your factory](https://github.com/orgs/qodo-hackathon/discussions/17).

## Why

_From the PR description (author-written)._

The hackathon page's "My submissions" list stopped at Day 14, although Day 15 is posted. Day 15 is "Show your factory": a public LinkedIn post that links to the "How a change ships" section of this page. Readers of the list couldn't reach that submission.

## How

_From the PR description (author-written)._

- One more line in the list, in the same form as Days 1 to 14, and one more URL in the list that `scripts/check-site.sh` asserts on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh` needs no change to its code. The link is a discussion comment, so it is checked twice (the page link, and an API lookup that the comment exists), which takes the page from 36 jobs to 38: 23 links and 15 lookups. At the batch cap of 20 that is still two batches, 264 s in the worst case, inside CI's 5-minute step timeout.
- The script's header comment is the worked example a maintainer uses to decide when the cap must change, so its numbers are updated to the page as it is now.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: Day 15 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 23 links and 15 lookups (38 jobs).

## Evidence

- Ran in CI: [run 45555415497](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45555415497) on 54f3462 (content 001dcb51f344be8054670ab0def1faf75b3ebb82). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 4f07770 build.
- Local: built the head and the merge-base (4f07770) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `001dcb51f344be8054670ab0def1faf75b3ebb82`. Its latest review is content `001dcb51f344be8054670ab0def1faf75b3ebb82`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- Red CI run (AGENTS.md rule 8): [run 45555236103](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45555236103) on the deliberately broken revision abfed20 (this PR without the Day 15 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/17#discussioncomment-19879890`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 38 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The Day 16 link still fits the two-batch budget (40 jobs). The Day 17 link starts a third batch, so the cap or the timeout must change before it is added.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 15: Show your factory](https://github.com/orgs/qodo-hackathon/discussions/17).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/149 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-25-hackathon-day-15.md))

## What I completed

The hackathon page's "My submissions" list stopped at Day 14, although Day 15 is posted. Day 15 is "Show your factory": a public LinkedIn post that links to the "How a change ships" section of this page. Readers of the list couldn't reach that submission.

- `docs/qodo-software-factory-hackathon.md`: Day 15 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 23 links and 15 lookups (38 jobs).

## Evidence

- Ran in CI: [run 45555415497](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45555415497) on 54f3462 (content 001dcb51f344be8054670ab0def1faf75b3ebb82). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 4f07770 build.
- Local: built the head and the merge-base (4f07770) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `001dcb51f344be8054670ab0def1faf75b3ebb82`. Its latest review is content `001dcb51f344be8054670ab0def1faf75b3ebb82`.

Qodo's latest review lists no findings.

- Red CI run (AGENTS.md rule 8): [run 45555236103](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45555236103) on the deliberately broken revision abfed20 (this PR without the Day 15 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/17#discussioncomment-19879890`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 38 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The Day 16 link still fits the two-batch budget (40 jobs). The Day 17 link starts a third batch, so the cap or the timeout must change before it is added.

## Assistance and third-party material

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=001dcb51f344be8054670ab0def1faf75b3ebb82 head=54f346223f4a441c82e79b4179f993dbb6958b54 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
