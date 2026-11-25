# docs: list the Day 16 submission on the hackathon page

**PR:** [#155](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/155) · **Opened:** 2026-11-25 · **Hackathon:** [Day 16: Scan your repo with Arnica](https://github.com/orgs/qodo-hackathon/discussions/18).

## Why

_From the PR description (author-written)._

The hackathon page's "My submissions" list stopped at Day 15, although Day 16 is posted. Day 16 is "Scan your repo with Arnica": the scan of this repository, the three findings it reported, and the fix for two of them (PR #152). Readers of the list couldn't reach that submission.

## How

_From the PR description (author-written)._

- One more line in the list, in the same form as Days 1 to 15, and one more URL in the list that `scripts/check-site.sh` asserts on the built page (AGENTS.md rule 3).
- `scripts/check-links.sh` needs no change to its code. The link is a discussion comment, so it is checked twice (the page link, and an API lookup that the comment exists), which takes the page from 38 jobs to 40: 24 links and 16 lookups. At the batch cap of 20 that is exactly two batches, 264 s in the worst case, inside CI's 5-minute step timeout.
- The script's header comment is the worked example a maintainer uses to decide when the cap must change, so its numbers are updated to the page as it is now.

## What

_From the PR description (author-written)._

- `docs/qodo-software-factory-hackathon.md`: Day 16 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 24 links and 16 lookups (40 jobs).

## Evidence

- Ran in CI: [run 45610470171](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45610470171) on 1179cb9 (content 6c92ba8659023400e125cfc6e9c02724b1511e1d). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 84bfd26 build.
- Local: built the head and the merge-base (84bfd26) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `6c92ba8659023400e125cfc6e9c02724b1511e1d`. Its latest review is content `6c92ba8659023400e125cfc6e9c02724b1511e1d`.

Qodo's latest review lists no findings.

_From the PR description (author-written)._

None yet.

## Assistance and third-party material

_From the PR description (author-written)._

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Limitations

_From the PR description (author-written)._

- Red CI run (AGENTS.md rule 8): [run 45584568265](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45584568265) on the deliberately broken revision fd96c1c (this PR without the Day 16 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/18#discussioncomment-19884457`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 40 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The two-batch budget is now full (40 jobs at a cap of 20). The Day 17 link starts a third batch, so the cap or the timeout must change before it is added.

## Discussion post

For the owner to post in the day's thread. The Delivery doc workflow never posts to the hackathon discussions.

````markdown
## Challenge

[Day 16: Scan your repo with Arnica](https://github.com/orgs/qodo-hackathon/discussions/18).

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/155 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-25-hackathon-day-16.md))

## What I completed

The hackathon page's "My submissions" list stopped at Day 15, although Day 16 is posted. Day 16 is "Scan your repo with Arnica": the scan of this repository, the three findings it reported, and the fix for two of them (PR #152). Readers of the list couldn't reach that submission.

- `docs/qodo-software-factory-hackathon.md`: Day 16 in "My submissions", linking the posted comment.
- `scripts/check-site.sh`: asserts the new link on the built page.
- `scripts/check-links.sh`: comment only. The budget comment now says 24 links and 16 lookups (40 jobs).

## Evidence

- Ran in CI: [run 45610470171](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45610470171) on 1179cb9 (content 6c92ba8659023400e125cfc6e9c02724b1511e1d). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base 84bfd26 build.
- Local: built the head and the merge-base (84bfd26) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `6c92ba8659023400e125cfc6e9c02724b1511e1d`. Its latest review is content `6c92ba8659023400e125cfc6e9c02724b1511e1d`.

Qodo's latest review lists no findings.

- Red CI run (AGENTS.md rule 8): [run 45584568265](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45584568265) on the deliberately broken revision fd96c1c (this PR without the Day 16 line on the page) failed at "Check site": `hackathon page link missing: https://github.com/qodo-hackathon/software-factory-hackathon/discussions/18#discussioncomment-19884457`.
- `check-links.sh` is a non-blocking CI step that needs the network. Locally it ran all 40 checks, all 200. The 264 s figure is the worst case if every request uses its full retry budget, which CI can't reproduce on demand.
- The two-batch budget is now full (40 jobs at a cap of 20). The Day 17 link starts a third batch, so the cap or the timeout must change before it is added.

## Assistance and third-party material

- Claude Code (executor and git-ops subagents).
- No third-party code.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=6c92ba8659023400e125cfc6e9c02724b1511e1d head=1179cb94d7ce4a078efbc990a44c62c7ac7c0ed3 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
