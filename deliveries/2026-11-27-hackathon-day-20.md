# docs: list the Day 20 submission on the hackathon page

**PR:** [#203](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/203) · **Opened:** 2026-11-27 · **Hackathon:** [Day 20: Monitor your factory's output](https://github.com/orgs/qodo-hackathon/discussions/22), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/22#discussioncomment-19955747

## Why

_From the PR description (author-written)._

Day 20 of the hackathon ("Monitor your factory's output") was posted on 2026-11-27 and is not listed on the hackathon page. The submission added a Better Stack keyword monitor on the live Edge Appliance glossary: it checks one term anchor every 3 minutes, with a passing check and a real failure email from a temporary monitor.

## How

_From the PR description (author-written)._

The same shape as the Day 19 link: one list entry, one asserted URL, and the job counts in the link checker's budget comment.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: add the Day 20 link.
- `scripts/check-site.sh`: assert that link.
- `scripts/check-links.sh`: update the budget comment to 28 links and 20 lookups (48 jobs); the cap stays 25.

## Evidence

- Ran in CI: [run 46033712112](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/46033712112) on 2014430 (content 6dbadf1a10649d64da641d279604ff985124d018). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 99181d8 build.
- Local: built the head and the merge-base (99181d8) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `6dbadf1a10649d64da641d279604ff985124d018`. Its latest review is content `6dbadf1a10649d64da641d279604ff985124d018`.

- Day 22 submission will push link check past its timeout (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6dbadf1a10649d64da641d279604ff985124d018`.

Open findings in Qodo's latest review: 0.

_From the PR description (author-written)._

- "Day 22 submission will push link check past its timeout" (informational): dismissed as deferred, approved by the owner, tracked in #204. At head 2014430 the page has 48 link-check jobs (264 s of 300 s) and the cap of 25 covers the Day 21 link; only the Day 22 link does not fit, and this PR adds Day 20 only.

## Assistance and third-party material

_From the PR description (author-written)._

Claude Code (planner, executor, reviewer and git subagents) planned, made, reviewed and published the change. No third-party code or material.

## Limitations

_From the PR description (author-written)._

- Red run for the new assertion: [Check site on f998137](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/46033595410) failed with `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/22#discussioncomment-19955747`, because that revision lacked the page line.
- CI does not reproduce the link checker's worst-case 264 s timing in the budget comment.
- The cap of 25 covers the Day 21 link; the Day 22 link needs the cap or the step timeout changed first.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 20: Monitor your factory's output](https://github.com/orgs/qodo-hackathon/discussions/22), reply: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/22#discussioncomment-19955747

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/203 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-27-hackathon-day-20.md))

## What I completed

Day 20 of the hackathon ("Monitor your factory's output") was posted on 2026-11-27 and is not listed on the hackathon page. The submission added a Better Stack keyword monitor on the live Edge Appliance glossary: it checks one term anchor every 3 minutes, with a passing check and a real failure email from a temporary monitor.

- `docs/qodo-software-factory-hackathon.md`: add the Day 20 link.
- `scripts/check-site.sh`: assert that link.
- `scripts/check-links.sh`: update the budget comment to 28 links and 20 lookups (48 jobs); the cap stays 25.

## Evidence

- Ran in CI: [run 46033712112](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/46033712112) on 2014430 (content 6dbadf1a10649d64da641d279604ff985124d018). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 99181d8 build.
- Local: built the head and the merge-base (99181d8) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `6dbadf1a10649d64da641d279604ff985124d018`. Its latest review is content `6dbadf1a10649d64da641d279604ff985124d018`.

- Day 22 submission will push link check past its timeout (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `6dbadf1a10649d64da641d279604ff985124d018`.

Open findings in Qodo's latest review: 0.

- Red run for the new assertion: [Check site on f998137](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/46033595410) failed with `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/22#discussioncomment-19955747`, because that revision lacked the page line.
- CI does not reproduce the link checker's worst-case 264 s timing in the budget comment.
- The cap of 25 covers the Day 21 link; the Day 22 link needs the cap or the step timeout changed first.

## Assistance and third-party material

Claude Code (planner, executor, reviewer and git subagents) planned, made, reviewed and published the change. No third-party code or material.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=6dbadf1a10649d64da641d279604ff985124d018 head=20144306b6c9107c08c1b20d9cce2bf2cb680cf1 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
