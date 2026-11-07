# docs: add the missing delivery doc for PR #35

**PR:** [#36](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/36) · **Opened:** 2026-11-07

## Why

_From the PR description (author-written)._

PR #35 (AGENTS.md rule 8) merged before its delivery doc was generated. Rule 6 requires a delivery doc for every PR, and the doc is that PR's hackathon evidence, so this adds it after the fact.

## How

_From the PR description (author-written)._

- `scripts/generate-delivery.sh --pr 35` generated the doc from #35's own description, its CI run, the two homepage builds, and Qodo's review comments on #35. Nothing was written by hand.
- The generator reads everything from the PR itself, so it works after the merge. Only the delivery-doc skill's amend step can't run, because #35's commit is already on `main`.
- Rule 6 says existing docs are never changed. This doc never existed, so adding it changes nothing that was already there.

## What

_From the PR description (author-written)._

- New: `deliveries/2026-11-07-ci-tests-every-line.md` (#35's delivery doc).
- This PR's own delivery doc is added later by the delivery-doc skill, after CI and Qodo have reviewed it, in the same single commit.

## Evidence

- Ran in CI: [run 42414884477](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/42414884477) on d8e4079 (content 012633a15156188b94aacb0deaac53d836b1f2f2). Jobs: build: success.
- Homepage: unchanged. The head build (H 11fcbbe5c29957f489772ff32321790da0b2b5d8) matches the merge-base fe4e475 build.
- Local: built the head and the merge-base (fe4e475) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `012633a15156188b94aacb0deaac53d836b1f2f2`. Its latest review is content `012633a15156188b94aacb0deaac53d836b1f2f2`.

- PR lacks its own delivery evidence doc (Medium, 📘 Rule violation). No longer listed by Qodo. Reviewed in content `012633a15156188b94aacb0deaac53d836b1f2f2`.

The PR description has no `## Qodo notes` section.

## Assistance and third-party material

_From the PR description (author-written)._

Generated with the repo's delivery-doc generator, run by Claude Code agents running Anthropic Claude models. I approved the change. No third-party material.

## Limitations

_From the PR description (author-written)._

- #35's doc was generated after its merge instead of being amended into its commit, so it lands in this PR's commit, not #35's.
- This PR adds no code, so AGENTS.md rule 8 has nothing to test here. CI still builds the site and runs check-site.sh and the delivery tests.

## Discussion post

This PR has no `## Hackathon` section, so there is no discussion post.
<!-- delivery: content=012633a15156188b94aacb0deaac53d836b1f2f2 homepage=11fcbbe5c29957f489772ff32321790da0b2b5d8 -->
