# lioramilbaum.com — Agent Guide

Personal portfolio site for Liora Milbaum, hosted at [lioramilbaum.com](https://lioramilbaum.com) via GitHub Pages. Built with plain Jekyll using the `jekyll-build-pages` action (see `.github/workflows/check-site.yml` for the pinned version).

- `README.md` is the homepage (`permalink: /`, `layout: home`).
- `docs/edge-appliance/glossary.md` is the living reference for the Edge Appliance architecture article series.
- Deploys happen automatically when `main` changes on `lioramilbaum/lioramilbaum.github.io`.
- PRs go from the `lmilbaum` fork to `lioramilbaum/lioramilbaum.github.io`.

## Setup

The site build (`scripts/build-site.sh`) requires Docker only. No GitHub token or network access is needed for it: the build runs with `--network none`, and `_config.yml` pins `url` and `baseurl` so jekyll-github-metadata never calls the GitHub API. The build image is amd64-only (it runs under emulation on Apple Silicon). Screenshots (`scripts/snapshot-site.sh`) are the exception: they need Docker and network access. `scripts/check-workflows.sh` needs Docker only (`--network none`). `scripts/check-browser.sh` needs Docker and network (`npm ci` installs Playwright in the container from `scripts/check-browser/package-lock.json`, which pins the npm tarballs by integrity; its version must match the image's). It serves the site inside the container, so unlike the screenshot step it also works on native Linux Docker. `scripts/check-links.sh` needs network. The delivery-doc skill (`scripts/generate-delivery.sh`) needs an authenticated `gh`, `python3` (it serves the head build on 127.0.0.1 for the screenshots), `curl`, and Docker; `scripts/test-delivery.sh` also needs `jq`. The screenshot step is verified on Docker Desktop (macOS); on native Linux Docker, the preview server bound to 127.0.0.1 is not reachable through host-gateway, and that path is not supported.

## Verify

```bash
# Build the site locally using the same image CI uses
scripts/build-site.sh

# Run the same checks CI runs
bash scripts/check-site.sh _site

# Preview (absolute URLs such as og:image point at production — expected)
python3 -m http.server --directory _site 4000

# Screenshot the live site (Docker and network needed; writes _snapshots/)
scripts/snapshot-site.sh [URL] [DIR]

# Screenshot the local preview from the Preview step above (Docker and network needed)
scripts/snapshot-site.sh http://host.docker.internal:4000 _snapshots

# Check that the hackathon page's external links resolve (network needed; run scripts/build-site.sh first). CI runs this too, as a non-blocking step: a dead link warns.
bash scripts/check-links.sh

# Parse the workflow files and check the yearly deploy schedule (Docker, no network)
scripts/check-workflows.sh

# Browser check of the hackathon page: JavaScript off, light and dark contrast (Docker and network; build first)
scripts/check-browser.sh

# Offline tests for the delivery-doc generator and the check (needs jq)
bash scripts/test-delivery.sh

# Docker test: the snapshot script rejects a page that only the browser sees as 404
bash scripts/test-delivery.sh --snapshot

# Check the PR's delivery doc is current for its head (run on the branch, after CI and Qodo review)
scripts/generate-delivery.sh --pr 21 --check

# Read Qodo's review of a PR, including findings it has since cleared.
# Set n to the PR number (21 is an example).
gh api graphql -F n=21 -f query='query($n:Int!){repository(owner:"lioramilbaum",name:"lioramilbaum.github.io"){pullRequest(number:$n){comments(first:50){nodes{author{login} url body userContentEdits(first:20){nodes{editedAt diff}}}}}}}'
```

## Rules

### 1. The glossary is tool-agnostic and follows the articles

**Where:** `docs/edge-appliance/glossary.md`

Do not use product, vendor, or tool names (no OCM, Helm, Zarf, or similar). Add a term only once a published article uses it; remove terms that articles drop. This glossary defines an implementation-agnostic architecture.

*Why:* OCM-specific terms were reverted (3dfb73d) and unpublished terms were pruned (da95e5f) to keep the glossary aligned with the published series.

### 2. Glossary headings are public permalinks

**Where:** every `##` in `docs/edge-appliance/glossary.md`

One term per `##`. Never rename or delete a heading without the owner's explicit approval.

*Why:* kramdown derives anchor IDs from heading text (`## Software Bill of Materials (SBOM)` → `#software-bill-of-materials-sbom`). Articles deep-link to these anchors; a rename silently breaks inbound links.

### 3. The homepage structure is a CI contract

**Where:** `README.md` and `scripts/check-site.sh`

Keep the four `##` topic sections with exactly these names: **Platform Engineering**, **DevOps**, **AI**, **Open Source**. Link internal pages with relative `.md` paths (jekyll-relative-links rewrites them); a raw `.md` href fails CI. Every new homepage link needs a matching assertion in `check-site.sh` in the same PR.

*Why:* The homepage structure is asserted on every PR. Changing a section name or adding an unasserted link breaks CI.

### 4. Stay GitHub Pages-native; publish nothing by accident

**Where:** `_config.yml`, `_layouts/`, the repo root

- No Gemfile, theme gem, non-allowlisted plugins, JS frameworks, CDN fonts, or external CSS. Styles stay inline in the layouts.
- Changes to shared elements (favicon links, dark-mode palette `#1a1a1a` / `#e0e0e0` / `#58a6ff`, footer) must be applied to both `_layouts/home.html` and `_layouts/docs.html` in the same PR.
- Every repo-only file (scripts, config, CI files) must be listed in `_config.yml`'s `exclude:` block.

*Why:* Any file at the repo root is published to lioramilbaum.com unless excluded. Overriding `exclude:` also drops Jekyll's built-in default excludes — see the comment in `_config.yml`.

### 5. Pin everything; let Renovate move the pins

**Where:** `.github/workflows/*.yml`, `renovate.json`

Every `uses:` must be a 40-character SHA with a `# vX.Y.Z` comment. `scripts/build-site.sh` parses that comment to find the image tag — keep its format (`# vX.Y.Z`). The Playwright image in `scripts/snapshot-site.sh` is tracked by the regex in `renovate.json`; keep its `image="…:vX.Y.Z-noble@sha256:…"` form. `scripts/check-browser.sh` reads the image from that line; never copy the pin. `scripts/check-browser/package.json` and its `package-lock.json` pin Playwright's npm package to the same version as that image; the lockfile pins the tarballs by integrity. Renovate moves the image and the npm package together in one PR (the `Playwright` group), and `scripts/check-browser.sh` fails if the versions differ. If a Renovate PR fails check-browser.sh's version check, one side (the image or the npm package) isn't published yet; the next run picks it up. `scripts/snapshot-site.sh` still installs its package by version only. Runners must be `ubuntu-26.04`, never `-latest`. Permissions stay least-privilege. Do not bump pins by hand; Renovate groups and automerges them after CI passes.

*Why:* A site about supply-chain integrity should practice what it describes. Pinning by SHA prevents silent tag moves.

### 6. Every PR includes a delivery doc

**Where:** `deliveries/`, `scripts/generate-delivery.sh`, `scripts/check-delivery.sh`, `.github/pull_request_template.md`, the `delivery-doc` job in `.github/workflows/check-site.yml`, `.claude/skills/delivery-doc/SKILL.md`

Every PR adds one `deliveries/<YYYY-MM-DD>-<slug>.md`: the date the PR opens, and the branch name without its type prefix (`feat/site-snapshots` → `2026-11-05-site-snapshots.md`). The delivery-doc skill generates it locally with `scripts/generate-delivery.sh`, from `deliveries/TEMPLATE.md`. The Why, How, What, Assistance and third-party material, and Limitations sections are copied verbatim from the PR description (`.github/pull_request_template.md`). Evidence comes from the CI run, the two homepage builds, and Qodo's review comment with its edit history, so findings Qodo clears later are still recorded. Nothing is written by hand. The skill amends the doc into the PR's single commit and force-pushes.

CI runs `scripts/check-delivery.sh` on the PR's own doc. It asks two questions. Does the doc exist? If not, CI posts a warning and stays green. Was it generated for this exact code, the head's content digest (the tree without the doc and its screenshot)? If not, CI is red. CI does not check the doc's sections, the homepage, the screenshot, or the Qodo and CI-run evidence: those are only as current as the last skill run. The check is advisory, not a ruleset. Renovate PRs are exempt. The process ends 2026-12-12 23:00 UTC (end of Dec 12 CET); after that, the check passes without reading the doc. Existing docs are never changed.

*Why:* Each PR is a delivery in the Qodo Software Factory hackathon, and the doc is the evidence posted to the daily discussion. Hand-written evidence drifted from the commits it described. Generated evidence is keyed to content digests, so CI can check it.

### 7. Homepage screenshots are committed beside the doc; the screenshots branch is frozen

**Where:** `scripts/snapshot-site.sh`, `scripts/generate-delivery.sh`, `deliveries/<stem>/`, the `screenshots` branch

There are no post-merge snapshots: the deploy workflow captures nothing. A PR's homepage screenshot is taken with `scripts/snapshot-site.sh` (Playwright in a digest-pinned Docker image) only when the PR head's homepage build differs from its merge-base build; the generator compares them. It is committed as `deliveries/<stem>/desktop.png` (1280 px), beside the doc, at most 500 KB. The generator enforces this; CI does not. If the homepage did not change, there is no PNG. Never delete, modify or push to the `screenshots` branch. PR homepage screenshots stop with the rest of the process at 2026-12-12 23:00 UTC (rule 6).

*Why:* The raw URL of the November 4 baseline (`2026-11-04/desktop.png`) is embedded publicly, so moving or overwriting that branch breaks it. Committed PNGs travel with the PR and need no artifact expiry.

### 8. Every line a PR adds or changes is tested in CI

**Where:** the code a PR adds or changes (`scripts/` except `check-*.sh` and `test-*.sh`, `.github/workflows/`, `_layouts/`, `_config.yml`) and the Limitations section of the PR description

CI must exercise every line of code the PR adds or changes. Code already on `main` is covered when a PR changes it, not before. Test code is exempt: checks and tests (`scripts/check-*.sh`, `scripts/test-*.sh` and the `check-site.yml` steps that run them; other workflow changes are other code) must run in CI, but don't need tests of their own; a new check must still be run by CI against a failing input at least once (push a deliberately broken revision, let CI go red, and link that run in the PR description). Every other file under `scripts/` (`build-site.sh`, `snapshot-site.sh`, `generate-delivery.sh`) is other code and needs tests. For `_layouts/` and `_config.yml`, a `check-site.sh` assertion on the built `_site` output that fails without the change counts as exercising it.

- Every new branch or failure path in other code has a CI test that fails without it: a case in a `scripts/test-*.sh` run by `.github/workflows/check-site.yml`, or an assertion in `scripts/check-site.sh`. Wire each new test into CI in the same PR.
- Nothing is verified only by hand. One-off mutation runs on a local machine, scripts documented as "run by hand", and manual browser checks don't count as tests. The red CI run a new check needs (above) is a CI run, not a by-hand check.
- Anything that truly can't run in CI is named in the PR's Limitations section, with the reason (for example, LinkedIn's share dialog needs a signed-in account).

*Why:* PR #34 (issue #27) first relied on one-off mutation runs, a by-hand link check and a manual browser check, so the owner required CI coverage for every line. The rule covers only new and changed lines, so code already on `main` whose real-world behaviour CI can't reproduce, such as the real GitHub responses behind `scripts/generate-delivery.sh`'s `gh` calls, doesn't break it. Test code is exempt so that tests don't need tests of their own; running in CI is what keeps it honest.

## Workflow

Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`. One commit per PR.

After CI and Qodo have reviewed a PR, run the delivery-doc skill (`.claude/skills/delivery-doc/SKILL.md`). It generates the doc and amends the single commit. Qodo re-reviews each force-pushed commit, usually within a minute; the doc's digest check confirms the review matches the head. Mark a draft ready first: Qodo does not review drafts.
