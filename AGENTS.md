# lioramilbaum.com — Agent Guide

Personal portfolio site for Liora Milbaum, hosted at [lioramilbaum.com](https://lioramilbaum.com) via GitHub Pages. Built with plain Jekyll using the `jekyll-build-pages` action (see `.github/workflows/check-site.yml` for the pinned version).

- `README.md` is the homepage (`permalink: /`, `layout: home`).
- `docs/edge-appliance/glossary.md` is the living reference for the Edge Appliance architecture article series.
- Deploys happen automatically when `main` changes on `lioramilbaum/lioramilbaum.github.io`.
- PRs go from the `lmilbaum` fork to `lioramilbaum/lioramilbaum.github.io`.

## Setup

The site build (`scripts/build-site.sh`) requires Docker only. No GitHub token or network access is needed for it: the build runs with `--network none`, and `_config.yml` pins `url` and `baseurl` so jekyll-github-metadata never calls the GitHub API. The build image is amd64-only (it runs under emulation on Apple Silicon). Screenshots (`scripts/snapshot-site.sh`) are the exception: they need Docker and network access. The delivery-doc skill (`scripts/generate-delivery.sh`) needs an authenticated `gh`, `python3` (it serves the head build on 127.0.0.1 for the screenshots), `curl`, and Docker; `scripts/test-delivery.sh` also needs `jq`. The screenshot step is verified on Docker Desktop (macOS); on native Linux Docker, the preview server bound to 127.0.0.1 is not reachable through host-gateway, and that path is not supported.

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

Every `uses:` must be a 40-character SHA with a `# vX.Y.Z` comment. `scripts/build-site.sh` parses that comment to find the image tag — keep its format (`# vX.Y.Z`). The Playwright image in `scripts/snapshot-site.sh` is tracked by the regex in `renovate.json`; keep its `image="…:vX.Y.Z-noble@sha256:…"` form. Runners must be `ubuntu-26.04`, never `-latest`. Permissions stay least-privilege. Do not bump pins by hand; Renovate groups and automerges them after CI passes.

*Why:* A site about supply-chain integrity should practice what it describes. Pinning by SHA prevents silent tag moves.

### 6. Every PR that changes the website includes a delivery doc

**Where:** `deliveries/`, `scripts/generate-delivery.sh`, `scripts/check-delivery.sh`, `.github/pull_request_template.md`, the `delivery-doc` job in `.github/workflows/check-site.yml`, `.claude/skills/delivery-doc/SKILL.md`

A PR has a delivery doc only if it changes the website, meaning its built site differs from its merge-base's. Any other PR has no doc and skips the delivery-doc skill. A PR that changes the website adds one `deliveries/<YYYY-MM-DD>-<slug>.md`: the date the PR opens, and the branch name without its type prefix (`feat/site-snapshots` → `2026-11-05-site-snapshots.md`). The delivery-doc skill generates it locally with `scripts/generate-delivery.sh`, from `deliveries/TEMPLATE.md`. The Why, How, What, Assistance and third-party material, and Limitations sections are copied verbatim from the PR description (`.github/pull_request_template.md`). Evidence comes from the CI run, the two homepage builds, and Qodo's review comment with its edit history, so findings Qodo clears later are still recorded. Nothing is written by hand. The skill amends the doc into the PR's single commit and force-pushes.

CI runs `scripts/check-delivery.sh` on the PR's own doc. It asks two questions. Does the doc exist? If not, CI posts a warning and stays green; CI does not compare the builds, so the warning also appears on a PR that does not change the website, where it can be ignored. Was it generated for this exact code, the head's content digest (the tree without the doc and its screenshot)? If not, CI is red. CI does not check the doc's sections, the homepage, the screenshot, or the Qodo and CI-run evidence: those are only as current as the last skill run. The check is advisory, not a ruleset. Renovate PRs are exempt. The process ends 2026-12-12 23:00 UTC (end of Dec 12 CET); after that, the check passes without reading the doc. Existing docs are never changed.

*Why:* Each PR that changes the website is a delivery in the Qodo Software Factory hackathon, and the doc is the evidence posted to the daily discussion. Hand-written evidence drifted from the commits it described. Generated evidence is keyed to content digests, so CI can check it.

### 7. Homepage screenshots are committed beside the doc; the screenshots branch is frozen

**Where:** `scripts/snapshot-site.sh`, `scripts/generate-delivery.sh`, `deliveries/<stem>/`, the `screenshots` branch

There are no post-merge snapshots: the deploy workflow captures nothing. A PR's homepage screenshot is taken with `scripts/snapshot-site.sh` (Playwright in a digest-pinned Docker image) only when the PR head's homepage build differs from its merge-base build; the generator compares them. It is committed as `deliveries/<stem>/desktop.png` (1280 px), beside the doc, at most 500 KB. The generator enforces this; CI does not. If the homepage did not change, there is no PNG. A PR that does not change the website has no doc (rule 6), so it has no PNG either. Never delete, modify or push to the `screenshots` branch. PR homepage screenshots stop with the rest of the process at 2026-12-12 23:00 UTC (rule 6).

*Why:* The raw URL of the November 4 baseline (`2026-11-04/desktop.png`) is embedded publicly, so moving or overwriting that branch breaks it. Committed PNGs travel with the PR and need no artifact expiry.

## Workflow

Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`. One commit per PR.

After CI and Qodo have reviewed a PR that changes the website, run the delivery-doc skill (`.claude/skills/delivery-doc/SKILL.md`). It generates the doc and amends the single commit. Qodo re-reviews each force-pushed commit, usually within a minute; the doc's digest check confirms the review matches the head. Mark a draft ready first: Qodo does not review drafts.
