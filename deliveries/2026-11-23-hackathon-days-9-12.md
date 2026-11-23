# docs: list the Day 9-12 submissions on the hackathon page

**PR:** [#127](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/127) · **Opened:** 2026-11-23 · **Hackathon:** [Day 12: Give your factory the full picture](https://github.com/orgs/qodo-hackathon/discussions/14).

## Why

_From the PR description (author-written)._

The hackathon page's "My submissions" list stopped at Day 8, although Days 9 to 12 are posted. Readers of the page couldn't reach the latest submissions, including Day 12, where Qodo checked PR #118 against issue #28 and found the bug fixed in PR #125.

## How

_From the PR description (author-written)._

- The four links are discussion comments, so `scripts/check-links.sh` checks each one twice: the page link, and an API lookup that the comment exists. That takes the page from 22 jobs to 30 (18 links, 12 lookups), and at the old batch cap of 12 the worst case would be 462 s, past CI's 5-minute step timeout.
- The cap goes to 18. Links are queued first, so the batches are 18 links (66 s worst case), then 12 lookups (198 s): 264 s, with 36 s to spare. Days 13 to 15 still fit at 18. The Day 16 link starts a third batch, and the comment in the script says so.
- A higher cap is worse, not better: above the number of links, the first batch holds a lookup too, and two lookup batches take 396 s.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: Days 9, 10, 11 and 12 in "My submissions", linking each posted comment.
- `scripts/check-site.sh`: asserts the four new links on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh`: batch cap 12 → 18, and the budget comment rewritten for 30 jobs.

## Evidence

- Ran in CI: [run 45105528926](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45105528926) on fb72749 (content b2e6ae10c2f31fa538671e1d62f96ee82b051ce4). Jobs: build: success.
- Homepage: unchanged. The head build (H 0e98c047fe5d5cb7aefa00db7c819bccf8308800) matches the merge-base 66d0b06 build.
- Local: built the head and the merge-base (66d0b06) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `b2e6ae10c2f31fa538671e1d62f96ee82b051ce4`. Its latest review is content `b2e6ae10c2f31fa538671e1d62f96ee82b051ce4`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (planner, executor and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- No new check, so no red CI run is needed (AGENTS.md rule 8). Locally, removing the Day 12 line made `check-site.sh` fail with `hackathon page link missing: …discussions/14#discussioncomment-19820008`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 30 checks, all 200, in 4 s. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 12: Give your factory the full picture](https://github.com/orgs/qodo-hackathon/discussions/14).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/127 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-23-hackathon-days-9-12.md))

## What I completed

The hackathon page's "My submissions" list stopped at Day 8, although Days 9 to 12 are posted. Readers of the page couldn't reach the latest submissions, including Day 12, where Qodo checked PR #118 against issue #28 and found the bug fixed in PR #125.

- `docs/qodo-software-factory-hackathon.md`: Days 9, 10, 11 and 12 in "My submissions", linking each posted comment.
- `scripts/check-site.sh`: asserts the four new links on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh`: batch cap 12 → 18, and the budget comment rewritten for 30 jobs.

## Evidence

- Ran in CI: [run 45105528926](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45105528926) on fb72749 (content b2e6ae10c2f31fa538671e1d62f96ee82b051ce4). Jobs: build: success.
- Homepage: unchanged. The head build (H 0e98c047fe5d5cb7aefa00db7c819bccf8308800) matches the merge-base 66d0b06 build.
- Local: built the head and the merge-base (66d0b06) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `b2e6ae10c2f31fa538671e1d62f96ee82b051ce4`. Its latest review is content `b2e6ae10c2f31fa538671e1d62f96ee82b051ce4`.

Qodo's latest review lists no findings.

- No new check, so no red CI run is needed (AGENTS.md rule 8). Locally, removing the Day 12 line made `check-site.sh` fail with `hackathon page link missing: …discussions/14#discussioncomment-19820008`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 30 checks, all 200, in 4 s. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.

## Assistance and third-party material

- Claude Code (planner, executor and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=b2e6ae10c2f31fa538671e1d62f96ee82b051ce4 head=fb72749cb4038c97e71e1799f56cdc8dd4976314 homepage=0e98c047fe5d5cb7aefa00db7c819bccf8308800 qodo-open=0 -->
