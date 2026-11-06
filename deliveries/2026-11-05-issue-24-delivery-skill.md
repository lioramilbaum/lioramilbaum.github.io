# feat: generate the delivery doc locally and snapshot the homepage only when it changes

**PR:** [#25](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/25) · **Opened:** 2026-11-05 · **Hackathon:** [Day 1: Your factory's first delivery](https://github.com/orgs/qodo-hackathon/discussions/2)

## Why

_From the PR description (author-written)._

Hand-written delivery docs drifted from the facts. Claims didn't say where a check had actually run, and Qodo findings disappeared once Qodo cleared them from its comment. Homepage screenshots were also taken after every deploy, even when nothing visible had changed, and post-merge artifacts can't be part of a PR's evidence.

I want every PR to carry its own evidence before it merges, generated from real data, with a screenshot only when the homepage changed. This is a personal site and the process ends on December 12, so the tooling has to stay small.

## How

_From the PR description (author-written)._

- A local Claude Code skill, `.claude/skills/delivery-doc`, runs `scripts/generate-delivery.sh`. Nobody writes evidence by hand.
  - It builds the PR head and its merge-base and compares their homepages (`index.html` plus the local files it loads).
  - When the homepage differs, it takes one desktop screenshot (1280 px).
  - It writes `deliveries/<date>-<slug>.md` from:
    - this PR description;
    - the Check site run;
    - Qodo's findings, including ones Qodo has since cleared.

  The skill then amends the PR's single commit and force-pushes.
- The doc records a content digest: the PR's tree without the doc and its screenshot. The doc names no head commit, so a doc-only amend changes nothing in it. Generate, amend, `--check` gives no diff.
- CI only verifies, with read-only permissions, and asks two questions:
  - Does the doc exist? If not, CI posts a warning and stays green.
  - Was it generated for this exact code? If the digest doesn't match, CI goes red.

  The check is advisory. Renovate is exempt, and the check switches off after 2026-12-12 23:00 UTC (end of December 12 CET).
- CI does not rebuild the site for this check, compare homepages or inspect screenshots. The generator does that work when it writes the doc.
- Three changes from the issue as first written:
  - #24 asked for CI to generate and commit the doc. That needed a token able to push to fork branches and a trusted workflow, so generation runs locally.
  - #24 said the check fails while the doc is missing. The doc can only be written after CI has run, so a missing doc is now a warning.
  - #24 asked for desktop and phone screenshots. There is now only desktop.
- The homepage is compared with the base build, not the live site, so the result is deterministic.
- The snapshot script fails unless the browser's own response is 2xx. This fixes Qodo's finding "Error pages can pass screenshot validation" on #21.

## What

_From the PR description (author-written)._

- New:
  - `.claude/skills/delivery-doc/SKILL.md`;
  - `.github/pull_request_template.md`;
  - `scripts/generate-delivery.sh`;
  - `scripts/test-delivery.sh`, the one test file. Its `--snapshot` mode needs Docker.
- Rewritten: `scripts/check-delivery.sh`, now under 100 lines. It also holds the content digest and the cut-off, so the generator and CI can't disagree.
- Removed: `scripts/test-check-delivery.sh`.
- `deliveries/TEMPLATE.md` keeps its sections, with placeholders the generator fills.
- `.github/workflows/check-site.yml`:
  - The `delivery-doc` job only runs the check.
  - The delivery tests run in `build`, so a failing test blocks the evidence.
  - The snapshot test runs only when `scripts/snapshot-site.sh` changes.
  - The `site-preview` upload is removed.
- `.github/workflows/deploy-pages.yml`: the post-merge `snapshot` job is removed.
- `scripts/snapshot-site.sh`:
  - takes one desktop screenshot through Playwright's API and checks the browser's response status;
  - removes partial PNGs on failure;
  - runs `npm install --ignore-scripts`.
- `AGENTS.md`: rules 6 and 7, Verify and Workflow updated. `_config.yml` and `check-site.sh` keep `.claude/` unpublished.

## Evidence

- Ran in CI: [run 42166724338](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42166724338) on 4e7e953 (content 3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf). Jobs: build: success.
- Homepage: unchanged. The head build (H 11fcbbe5c29957f489772ff32321790da0b2b5d8) matches the merge-base 720ab3c build.
- Local: built the head and the merge-base (720ab3c) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`, `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`. Its latest review is content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.

- Delivery doc cites scripts the PR lacks (📘 Rule violation). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Rule 7 omits the process end date (📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Cleared review findings disappear (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- PR code can read maintainer secrets (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Playwright pin bumps always fail CI (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Doc links the wrong hackathon day (Medium, 📘 Rule violation). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Missing delivery doc still passes CI (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- PR preview screenshots no longer produced (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Snapshot errors pass the 404 test (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Long discussions block delivery docs (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Another PR can supply the CI evidence (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- A failed screenshot leaves an empty folder (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- A stale checkout can overwrite the PR (🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Discussion posts show a broken screenshot (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Leaving the optional Hackathon heading empty stops the generator (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Older reviews lose their provenance (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Documented verify command fails when run (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Generator still writes docs after cutoff (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Nested branches cannot get delivery docs (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Snapshot test comment wrongly says no network is needed (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.

_From the PR description (author-written)._

- Fixed because of Qodo:
  - The snapshot test's server was bound to loopback, which a container can't reach on native Linux. This failed CI, and Qodo named the cause.
  - The 404 test could pass for the wrong reason.
  - Rule 7 had no end date.
  - The skill could overwrite the PR from a stale checkout.
  - Discussion posts would show a broken screenshot.
  - An empty `## Hackathon` heading, which the PR template ships, stopped the generator.
- "Delivery doc cites scripts the PR lacks" and "Doc links the wrong hackathon day" described an earlier generated doc. Regenerating it fixed them.
- Dismissed in Qodo, with reasons:
  - "Cleared review findings disappear" does not hold on real data. On #21, the comment's edit history holds complete earlier reviews, including a finding Qodo later cleared.
  - "Missing delivery doc still passes CI" is my decision; see Limitations.
  - "PR code can read maintainer secrets": the skill only runs on PRs from my own fork.
  - "Long discussions block delivery docs", "Another PR can supply the CI evidence" and "A failed screenshot leaves an empty folder" are unlikely edge cases, and the process ends on December 12.
  - "Older reviews lose their provenance": the doc says `unknown` rather than guessing.
  - "Documented verify command fails when run": 21 is only an example number.
  - "Generator still writes docs after cutoff": the skill stops at the cut-off, and CI ignores docs after it.
  - "Nested branches cannot get delivery docs": branches here have one segment after the prefix, and the generator stops with a clear error.
  - "Snapshot test comment wrongly says no network is needed": real, but only a comment. It's deferred to the next PR that touches the file.

## Assistance and third-party material

_From the PR description (author-written)._

Built with Claude Code agents running Anthropic Claude models: a planner, an executor and reviewers. I chose the design and approved each change. Screenshots use Playwright (Apache-2.0) from Microsoft's `mcr.microsoft.com/playwright` image; workflows use GitHub's official actions.

## Limitations

_From the PR description (author-written)._

- CI checks only that the doc exists and matches the content digest. It doesn't check the doc's sections, the homepage claim, the screenshot, or the CI-run and Qodo evidence. Those are only as current as the last skill run.
- A missing doc is only a warning, and `main` has no ruleset requiring the check. A PR can merge without a doc.
- The digest leaves out the doc, so CI can't see a hand edit to a generated doc. `--check` finds it locally.
- Only the desktop layout is captured. A phone-only layout problem won't show.
- The screenshot step in the skill is verified on Docker Desktop for macOS. On native Linux Docker, the preview server bound to 127.0.0.1 isn't reachable from the container.
- `scripts/test-delivery.sh` reports every failed assertion, but an unexpected command error stops the run early. The run still goes red.
- This PR's own delivery doc is added by running the new skill after CI and Qodo have reviewed it.

## Discussion post

For the owner to post in the day's thread. The skill never posts to the hackathon discussions.

````markdown
## Challenge

[Day 1: Your factory's first delivery](https://github.com/orgs/qodo-hackathon/discussions/2)

## Project

Project name: lioramilbaum.com
Repository link: https://github.com/lioramilbaum/lioramilbaum.github.io
Relevant pull request or commit: https://github.com/lioramilbaum/lioramilbaum.github.io/pull/25 ([delivery notes](https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/deliveries/2026-11-05-issue-24-delivery-skill.md))

## What I completed

Hand-written delivery docs drifted from the facts. Claims didn't say where a check had actually run, and Qodo findings disappeared once Qodo cleared them from its comment. Homepage screenshots were also taken after every deploy, even when nothing visible had changed, and post-merge artifacts can't be part of a PR's evidence.

I want every PR to carry its own evidence before it merges, generated from real data, with a screenshot only when the homepage changed. This is a personal site and the process ends on December 12, so the tooling has to stay small.

- New:
  - `.claude/skills/delivery-doc/SKILL.md`;
  - `.github/pull_request_template.md`;
  - `scripts/generate-delivery.sh`;
  - `scripts/test-delivery.sh`, the one test file. Its `--snapshot` mode needs Docker.
- Rewritten: `scripts/check-delivery.sh`, now under 100 lines. It also holds the content digest and the cut-off, so the generator and CI can't disagree.
- Removed: `scripts/test-check-delivery.sh`.
- `deliveries/TEMPLATE.md` keeps its sections, with placeholders the generator fills.
- `.github/workflows/check-site.yml`:
  - The `delivery-doc` job only runs the check.
  - The delivery tests run in `build`, so a failing test blocks the evidence.
  - The snapshot test runs only when `scripts/snapshot-site.sh` changes.
  - The `site-preview` upload is removed.
- `.github/workflows/deploy-pages.yml`: the post-merge `snapshot` job is removed.
- `scripts/snapshot-site.sh`:
  - takes one desktop screenshot through Playwright's API and checks the browser's response status;
  - removes partial PNGs on failure;
  - runs `npm install --ignore-scripts`.
- `AGENTS.md`: rules 6 and 7, Verify and Workflow updated. `_config.yml` and `check-site.sh` keep `.claude/` unpublished.

## Evidence

- Ran in CI: [run 42166724338](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42166724338) on 4e7e953 (content 3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf). Jobs: build: success.
- Homepage: unchanged. The head build (H 11fcbbe5c29957f489772ff32321790da0b2b5d8) matches the merge-base 720ab3c build.
- Local: built the head and the merge-base (720ab3c) with scripts/build-site.sh, and compared their homepages.

## What I learned / what is blocked

Qodo reviewed these contents (by content digest): `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`, `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`. Its latest review is content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.

- Delivery doc cites scripts the PR lacks (📘 Rule violation). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Rule 7 omits the process end date (📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Cleared review findings disappear (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- PR code can read maintainer secrets (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Playwright pin bumps always fail CI (🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Doc links the wrong hackathon day (Medium, 📘 Rule violation). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Missing delivery doc still passes CI (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- PR preview screenshots no longer produced (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Snapshot errors pass the 404 test (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`.
- Long discussions block delivery docs (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Another PR can supply the CI evidence (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- A failed screenshot leaves an empty folder (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `35e4b774c5b83193a3b33962612127b1fdb07f90`, `25f9a1481773946add26e6567993fbfeb1db7c56`.
- A stale checkout can overwrite the PR (🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Discussion posts show a broken screenshot (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Leaving the optional Hackathon heading empty stops the generator (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `25f9a1481773946add26e6567993fbfeb1db7c56`.
- Older reviews lose their provenance (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Documented verify command fails when run (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Generator still writes docs after cutoff (Medium, 📎 Requirement gap). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Nested branches cannot get delivery docs (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.
- Snapshot test comment wrongly says no network is needed (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf`.

- CI checks only that the doc exists and matches the content digest. It doesn't check the doc's sections, the homepage claim, the screenshot, or the CI-run and Qodo evidence. Those are only as current as the last skill run.
- A missing doc is only a warning, and `main` has no ruleset requiring the check. A PR can merge without a doc.
- The digest leaves out the doc, so CI can't see a hand edit to a generated doc. `--check` finds it locally.
- Only the desktop layout is captured. A phone-only layout problem won't show.
- The screenshot step in the skill is verified on Docker Desktop for macOS. On native Linux Docker, the preview server bound to 127.0.0.1 isn't reachable from the container.
- `scripts/test-delivery.sh` reports every failed assertion, but an unexpected command error stops the run early. The run still goes red.
- This PR's own delivery doc is added by running the new skill after CI and Qodo have reviewed it.

## Assistance and third-party material

Built with Claude Code agents running Anthropic Claude models: a planner, an executor and reviewers. I chose the design and approved each change. Screenshots use Playwright (Apache-2.0) from Microsoft's `mcr.microsoft.com/playwright` image; workflows use GitHub's official actions.

## Optional demo

No visible change on the homepage.
````
<!-- delivery: content=3a14a7299ff5f73e16ed5aee677c6c24e9cc3baf homepage=11fcbbe5c29957f489772ff32321790da0b2b5d8 -->
