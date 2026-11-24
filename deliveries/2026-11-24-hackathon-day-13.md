# docs: list the Day 13 submission on the hackathon page

**PR:** [#140](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/140) · **Opened:** 2026-11-24 · **Hackathon:** [Day 13: Teach your factory a new skill](https://github.com/orgs/qodo-hackathon/discussions/15).

## Why

_From the PR description (author-written)._

The hackathon page's "My submissions" list stopped at Day 12, although Day 13 is posted. Readers of the page couldn't reach the Day 13 submission, where a fresh Claude Code session ran the new `update-linkedin-followers` skill on a real update and showed five gaps in it.

## How

_From the PR description (author-written)._

- One more line in the list, in the same form as Days 1 to 12, and one more URL in the list that `scripts/check-site.sh` asserts on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh` needs no change to its code. The link is a discussion comment, so it is checked twice (the page link, and an API lookup that the comment exists), which takes the page from 30 jobs to 32: 19 links and 13 lookups. At the batch cap of 18 that is still two batches, 264 s in the worst case, inside CI's 5-minute step timeout.
- The script's header comment is the worked example a maintainer uses to decide when the cap must change, so its numbers are updated to the page as it is now.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: Day 13 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 19 links and 13 lookups (32 jobs).

## Evidence

- Ran in CI: [run 45422460169](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45422460169) on 34deeae (content 838845e824907c722861e92bb0a4e05b1a10702b). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base d20d9a8 build.
- Local: built the head and the merge-base (d20d9a8) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`, `3410593fa9c169e38afdca32a587424644970d80`, `838845e824907c722861e92bb0a4e05b1a10702b`. Its latest review is content `838845e824907c722861e92bb0a4e05b1a10702b`.

- Link-check budget comment still says Day 13 is future (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`.
- Day 13 link adds no new check for the rule (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`, `3410593fa9c169e38afdca32a587424644970d80`, `838845e824907c722861e92bb0a4e05b1a10702b`.

Open findings in Qodo's latest review: 0.

_From the PR description (author-written)._

Qodo's first review (of `cf5eea9`) raised two informational findings. Both were fixed, and none was dismissed.

- "Link-check budget comment still says Day 13 is future": the header comment in `scripts/check-links.sh` now gives the current counts.
- "Day 13 link adds no new check for the rule": the first version of this description said no red CI run was needed. The red run above was added.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (executor and git-ops subagents).
- Qodo's review found the stale budget comment and asked for the red CI run.
- No third-party code.

## Limitations

_From the PR description (author-written)._

- Red CI run (AGENTS.md rule 8): [run 45422142482](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45422142482) on the deliberately broken revision a89ee50 (this PR without the Day 13 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/15#discussioncomment-19859543`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 32 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 13: Teach your factory a new skill](https://github.com/orgs/qodo-hackathon/discussions/15).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/140 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-24-hackathon-day-13.md))

## What I completed

The hackathon page's "My submissions" list stopped at Day 12, although Day 13 is posted. Readers of the page couldn't reach the Day 13 submission, where a fresh Claude Code session ran the new `update-linkedin-followers` skill on a real update and showed five gaps in it.

- `docs/qodo-software-factory-hackathon.md`: Day 13 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 19 links and 13 lookups (32 jobs).

## Evidence

- Ran in CI: [run 45422460169](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45422460169) on 34deeae (content 838845e824907c722861e92bb0a4e05b1a10702b). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base d20d9a8 build.
- Local: built the head and the merge-base (d20d9a8) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`, `3410593fa9c169e38afdca32a587424644970d80`, `838845e824907c722861e92bb0a4e05b1a10702b`. Its latest review is content `838845e824907c722861e92bb0a4e05b1a10702b`.

- Link-check budget comment still says Day 13 is future (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`.
- Day 13 link adds no new check for the rule (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `5eeeb5aaa65640a80874c9317c97a4644c6bc1e5`, `3410593fa9c169e38afdca32a587424644970d80`, `838845e824907c722861e92bb0a4e05b1a10702b`.

Open findings in Qodo's latest review: 0.

- Red CI run (AGENTS.md rule 8): [run 45422142482](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45422142482) on the deliberately broken revision a89ee50 (this PR without the Day 13 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/15#discussioncomment-19859543`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 32 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.

## Assistance and third-party material

- Claude Code (executor and git-ops subagents).
- Qodo's review found the stale budget comment and asked for the red CI run.
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=838845e824907c722861e92bb0a4e05b1a10702b head=34deeaeb31080263b65ea191e7f17db61775cbe3 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
