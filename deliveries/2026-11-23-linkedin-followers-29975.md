# chore: update the LinkedIn followers count to 29,975

**PR:** [#132](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/132) · **Opened:** 2026-11-23

## Why

_From the PR description (author-written)._

The homepage's LinkedIn followers line was last updated earlier on Nov 23, 2026 (29,973, #131). The owner gave the current count, 29,975, on Nov 23, 2026.

## How

_From the PR description (author-written)._

Ran the `update-linkedin-followers` skill with the owner's count. It validated the count and date, edited `_data/linkedin.yml`, built the site with `scripts/build-site.sh`, ran `scripts/check-site.sh` and `scripts/test-site.sh`, compared the rendered line with the expected text byte for byte, and built a throwaway copy with `followers: 012` to confirm the check still fails on an invalid value.

## What

_From the PR description (author-written)._

- `_data/linkedin.yml`: `followers: 29975` (`as_of` stays `2026-11-23`, already today's date). The homepage line now reads `29,975 LinkedIn followers · as of Nov 23, 2026`.

Local results: build exit 0; `check-site.sh` exit 0 (`Homepage checks passed`); `test-site.sh` exit 0 (`All LinkedIn followers cases passed`); rendered line matches the expected text (1 occurrence); the `followers: 012` copy built (exit 0), failed `check-site.sh` (exit 1, `error: LinkedIn followers line missing from the homepage …`) and hid the line.

## Evidence

- Ran in CI: [run 45146544011](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45146544011) on c554f18 (content 4e512511b82e916706121a4ebc2d3d1c0e72706f). Jobs: build: success.
- Homepage: changed. The head build (H 1626e572e3a4a4b4150af73411b91fb4124d8533) differs from the merge-base 2c70a89 build. Screenshot below.
- Local: built the head and the merge-base (2c70a89) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

![Homepage on desktop](2026-11-23-linkedin-followers-29975/desktop.png)

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `4e512511b82e916706121a4ebc2d3d1c0e72706f`. Its latest review is content `4e512511b82e916706121a4ebc2d3d1c0e72706f`.

Qodo's latest review lists no findings.

The PR description has no `## Qodo notes` section.

## Assistance and third-party material

_From the PR description (author-written)._

Claude Code (Claude Opus 5.5) ran the skill and opened this PR. The follower count came from the owner. No third-party material.

## Limitations

_From the PR description (author-written)._

The count itself can't be checked in CI: reading it from LinkedIn needs a signed-in account. CI checks its format and the rendered line. This PR adds no code.

## Discussion post

This PR has no `## Hackathon` section, so there is no discussion post.
<!-- delivery: content=4e512511b82e916706121a4ebc2d3d1c0e72706f head=c554f18d65bc6c9deb5d0dc58257300502a23322 homepage=1626e572e3a4a4b4150af73411b91fb4124d8533 qodo-open=0 -->
