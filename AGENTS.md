# lioramilbaum.com — Agent Guide

Personal portfolio site for Liora Milbaum, hosted at [lioramilbaum.com](https://lioramilbaum.com) via GitHub Pages. Built with plain Jekyll using the `jekyll-build-pages` action (see `.github/workflows/check-site.yml` for the pinned version).

- `README.md` is the homepage (`permalink: /`, `layout: home`).
- `docs/edge-appliance/glossary.md` is the living reference for the Edge Appliance architecture article series.
- Deploys happen automatically when `main` changes on `lioramilbaum/lioramilbaum.github.io`.
- PRs go from the `lmilbaum` fork to `lioramilbaum/lioramilbaum.github.io`.

## Setup

The site build (`scripts/build-site.sh`) requires Docker only. No GitHub token or network access is needed for it: the build runs with `--network none`, and `_config.yml` pins `url` and `baseurl` so jekyll-github-metadata never calls the GitHub API. The build image is amd64-only (it runs under emulation on Apple Silicon). Screenshots (`scripts/snapshot-site.sh`) are the exception: they need Docker and network access.

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

# Download a deploy's snapshots (for a PR, use -n site-preview-<sha7> instead)
gh run download <run-id> -R lioramilbaum/lioramilbaum.github.io -n site-snapshots-<sha7> -D _snapshots

# Check this branch has a delivery doc (rule 6; commit it first)
bash scripts/check-delivery.sh upstream/main HEAD

# Regression tests for the delivery check (fence rules, sections, names, CRLF)
bash scripts/test-check-delivery.sh

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

### 6. Every PR includes a delivery doc

**Where:** `deliveries/`, `scripts/check-delivery.sh`, the `delivery-doc` job in `.github/workflows/check-site.yml`

Every PR adds or updates one `deliveries/<YYYY-MM-DD>-<slug>.md`, copied from `deliveries/TEMPLATE.md`: the date the PR opens, and the branch name without its type prefix (`feat/site-snapshots` → `2026-11-05-site-snapshots.md`). Write it for hackathon readers and other builders, not for agents. Fill "What I learned from the Qodo review" only from real `qodo-code-review[bot]` output; until Qodo has reviewed the PR (Qodo has only reviewed PRs after they leave draft), keep the `TODO(qodo)` marker, which CI flags as a warning. Copy findings into the doc before fixing them: Qodo rewrites its comment to "no open findings" once they are resolved. Never post to the hackathon discussions; the owner does. Renovate PRs are exempt.

*Why:* Each PR is a delivery in the Qodo Software Factory hackathon, and the doc is the evidence posted to the daily discussion. CI fails a PR without one.

### 7. Snapshots are artifacts; the screenshots branch is frozen

**Where:** `.github/workflows/deploy-pages.yml` (`snapshot` job), `.github/workflows/check-site.yml`, the `screenshots` branch

After each deploy, the `snapshot` job uploads desktop and phone PNGs of the live homepage as the `site-snapshots-<sha7>` artifact (kept 90 days). Every PR uploads `site-preview-<sha7>` from the built `_site` (kept 14 days). Nothing is committed to git. Never delete, modify or push to the `screenshots` branch.

The snapshot job runs inside the deploy workflow's `pages` concurrency group, so the next deploy waits for it. This takes up to its 15-minute timeout, usually 1–3 minutes, and this is intentional so that a normal capture matches its commit. A re-run of an older run is guarded by the newest-deployment skip checks, not by the group. The job is `continue-on-error`, so a failed snapshot leaves the deploy run green and shows only as a failed job or annotation.

*Why:* `screenshots` is a frozen baseline whose raw URL (`2026-11-04/desktop.png`) is embedded publicly; changing it breaks that link.

## Workflow

Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`. One commit per PR.

After Qodo reviews a PR: record its findings in the delivery doc, fix the confirmed ones, replace `TODO(qodo)`, amend the single commit, and force-push with `--force-with-lease`. Qodo has re-reviewed each force-pushed commit so far (usually within a minute); check the commit marker in its comment to confirm which commit it reviewed.
