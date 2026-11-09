# lioramilbaum.com — Agent Guide

Personal portfolio site for Liora Milbaum, hosted at [lioramilbaum.com](https://lioramilbaum.com) via GitHub Pages. Built with plain Jekyll using the `jekyll-build-pages` action (see `.github/workflows/check-site.yml` for the pinned version).

- `README.md` is the homepage (`permalink: /`, `layout: home`).
- `docs/edge-appliance/glossary.md` is the living reference for the Edge Appliance architecture article series.
- Deploys happen automatically when `main` changes on `lioramilbaum/lioramilbaum.github.io`.
- PRs go from the `lmilbaum` fork to `lioramilbaum/lioramilbaum.github.io`.

## Setup

The site build (`scripts/build-site.sh`) requires Docker only. No GitHub token or network access is needed for it: the build runs with `--network none`, and `_config.yml` pins `url` and `baseurl` so jekyll-github-metadata never calls the GitHub API. The build image is amd64-only (it runs under emulation on Apple Silicon). Screenshots (`scripts/snapshot-site.sh`) are the exception: they need Docker and network access. `scripts/check-workflows.sh` needs Docker only (`--network none`). `scripts/check-browser.sh` needs Docker and network (`npm ci` installs Playwright in the container from `scripts/check-browser/package-lock.json`, which pins the npm tarballs by integrity; its version must match the image's). It serves the site inside the container, so unlike the screenshot step it also works on native Linux Docker. `scripts/check-links.sh` needs network. The delivery-doc skill (`scripts/generate-delivery.sh`) needs an authenticated `gh`, `python3` (it serves the head build on 127.0.0.1 for the screenshots), `curl`, Docker, and an `upstream` remote for lioramilbaum/lioramilbaum.github.io (it fetches a CI run's commit the clone lacks; `--fetch REMOTE` overrides); `scripts/test-delivery.sh` also needs `jq`. `scripts/qodo-status.sh` needs an authenticated `gh` too. `scripts/qodo-gate.sh` posts a commit status (a token with statuses write). It runs in CI from main; to re-run it, dispatch the workflow. The screenshot step is verified on Docker Desktop (macOS); on native Linux Docker, the preview server bound to 127.0.0.1 is not reachable through host-gateway, and that path is not supported.

The agent run (`.github/workflows/agent-run.yml` and `scripts/agent-run.sh`) takes an issue the owner labels `ready-for-agent`, makes the change on a `fix/issue-N` or `feat/issue-N` branch in the owner's fork, opens the PR with the issue's acceptance criteria, and works through Qodo's findings for up to three rounds. The runner needs `jq`, `gh`, `git` and a running Docker daemon, and stops before any step if one is missing. The model is Claude Code, pinned in `scripts/agent/package-lock.json`; the workflow's `npm ci` installs its Linux build, under Node 24 (`node-version` in `agent-run.yml`, which the claude-code engines need at 22 or later). Renovate moves `node-version` as it moves a `uses:` pin (it extracts the value from `actions/setup-node`, so it is in the GitHub Actions group: minor, patch and digest updates automerge, and a major update waits for the owner). `scripts/check-workflows.sh` requires it to be an explicit integer major version of 22 or later, so `lts/*`, a range and a full version fail the check. The check also pins the job's `if:` as one exact string (the owner's five `&&` terms, in order) and its steps as an exact ordered list (checkout, setup-node, the jq install, `npm ci --prefix scripts/agent` and the agent run), each with its exact keys, so a step that is added or moved, or that has a key the list lacks, fails the check. The job's timeout is 180 minutes, for three Qodo rounds of up to 20 minutes each plus the checks, the model's calls and the wait for CI on the PR head (up to 20 minutes). Three Actions secrets are needed: `CLAUDE_CODE_OAUTH_TOKEN` (the model), `AGENT_FORK_TOKEN` (a fine-grained token on `lmilbaum/lioramilbaum.github.io` with contents read and write, which pushes the branch) and `AGENT_PR_TOKEN` (on `lioramilbaum/lioramilbaum.github.io` with pull requests and issues read and write, contents read, and checks and commit statuses read, which opens the PR, sets the labels and reads the PR head's CI).

What is enforced:

- **Trigger.** The workflow runs only for the owner's `ready-for-agent` label on the owner's own issue, never on a pull request, and it runs main's copy of the runner and scripts. The three secrets are set on the one step that runs the runner, and `scripts/check-workflows.sh` fails if `secrets.` appears anywhere else in the file.
- **Tokens.** The three tokens are in the runner's process environment only, which runs git and gh. The runner replaces exact matches of the three values with `[redacted]` in every text it posts or logs (stop comments, verdicts, the PR body, the Actions log), and it refuses a commit whose diff contains one.
- **The model's environment.** Claude Code runs with `env -i`: `PATH`, a throwaway `HOME` (a fresh directory in the run's work directory, not the runner's `HOME`) and `CLAUDE_CODE_OAUTH_TOKEN`, nothing else.
- **The model's tools.** Claude Code runs with `--restricted`: no Bash and no WebFetch, the project and user settings ignored, and the file tools confined to the clone and the run's output directory. `--tools` and `--allowedTools` name Read, Edit, Write, Glob and Grep, and `--disallowedTools` denies Read of `/proc`, `/etc`, the runner's private directory and its own dotfiles (`.config`, `.docker`, `.ssh` and `.gitconfig` under its home directory), and Edit of `.git`, `.claude`, `.mcp.json`, `.github`, `CNAME`, `deliveries`, `scripts/agent-run.sh`, `scripts/agent/` and `scripts/build-site.sh`. A Read deny blocks every file under its path and overrides `--add-dir`, so the runner stops before the model if the clone or the run's output directory lies under one of those Read paths. `--permission-prompts none` denies anything that would prompt. Claude Code checks these rules when it starts: its Read rules cover Glob and Grep, and its Edit rules cover Write.
- **The runner's private directory.** A 0700 directory in the run's work directory, outside the file tools' reach, holds the askpass script (which gives git the fork token), the prompt, a copy of Claude Code, and a checkout of main that supplies the scripts the runner runs: `build-site.sh`, `check-site.sh`, `qodo-status.sh` (which runs `check-delivery.sh` and reads `qodo-review.awk`) and `snapshot-site.sh`. The runner checks the checksums of the askpass script, the prompt, every file under main's `scripts/` (recursively, so a file added, removed or renamed there changes them too), and `.git/config`, before each use, and stops if one changed.
- **Git.** Every git command runs with no global or system config (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`), with hooks and fsmonitor off. `gh` runs from the work directory, which is not a repository.
- **Guards.** The runner refuses to call the model, or to commit, when the change touches a guarded path (`.github/`, `.claude/`, `.mcp.json`, the runner, `scripts/agent/`, `scripts/build-site.sh`, `deliveries/`, `CNAME`). A rename or move out of a guarded path counts as touching it.
- **Checks.** Main's `scripts/build-site.sh` builds the clone in a container with `--network none`. Then two copies of `scripts/check-site.sh` check the built `_site`, each in its own container with `--network none`, no environment, and the clone mounted read-only at `/clone`: the clone's copy, which the model may change, and main's copy, mounted read-only from the private directory. Both must pass, and the log names the copy that fails.
- **CI on the head.** After Qodo's review is clear, the run waits for the PR head's checks, as `gh pr checks` reports them. A check that failed or was cancelled stops the run at the `ci` stage, naming it. The run stops too if a check is still running after 20 minutes, or none is reported. `qodo-findings` is not waited on: it is Qodo's own gate (rule 9).
- **Qodo rounds.** Each round has the model fix the findings or give a verdict on each one, then pushes an amended commit. Every stop in a Qodo round posts the model's verdicts on the PR first: a round in which the model changes nothing (for example, verdicts that are all false positives), a round whose checks still fail after the fixes, and three rounds that leave findings open. If the verdicts comment cannot be posted, the verdicts go to the run log (the Actions log, redacted) and the stop comment says so. Each stops the run as `agent-stuck`. The owner dismisses those findings in Qodo (rule 9).
- **Backstop.** The token scopes limit the damage: the fork token writes only to the fork, and the PR token writes only issues and pull requests upstream.

The residual risks are not closed:

1. Claude Code's permission rules are the barrier between the model and the runner's process environment, not an OS boundary, and the runner adds no sandbox beyond them. How a rule matches a path (symlinks and path spelling included) is Claude Code's, and the runner cannot check it per call. The version is pinned and the rules are validated when it starts.
2. The model holds its OAuth token and has network access for the API. A model that read the token and sent it out would leak it. The token is refused in a commit and redacted from posted text, but nothing stops the network call.
3. The build writes the clone read-write, and the model writes it too. A guarded path changed by either is caught before the next model call and before the commit, not prevented.
4. The change itself is written by the model. CI, Qodo and the owner review it, and the owner merges.
5. No model call runs in CI, so the permission rules' run-time behaviour is not tested. CI tests their exact text, the runner's refusal of changes, and the checksum and redaction paths; the first real run is the check on the rules.
6. The runner acts on the Qodo review that `scripts/qodo-status.sh` reports as settled for the head. A finding Qodo adds to that head after the read is not seen by the run, and the PR is commented as ready from the earlier read. The `qodo-findings` status (rule 9) re-reads Qodo on every Qodo edit, and is the check for that.
7. `.github/` is guarded, so the agent cannot change a workflow. A ticket that needs workflow wiring, including the CI wiring that rule 8 requires for a new test in `check-site.yml`, cannot be finished by the run: the change is refused and the run ends `agent-stuck`, and the owner makes that change.
8. Redaction replaces exact matches of the three values. A model that writes its token encoded (base64, or split across lines) is not redacted, and the commit's token scan has the same limit. The second residual risk is the backstop for that.
9. The model may edit the clone's `scripts/check-site.sh`, and main's copy runs on the same built site, so a clone copy rewritten to pass does not pass a change that main's copy rejects. The cost: a ticket that legitimately changes an existing assertion fails main's copy, and the run ends `agent-stuck` at the checks stage for the owner to make that change. A new assertion a ticket adds is checked by the clone's copy only, until it is on main, so the model could weaken it there; the Qodo review and the owner's review are the check for that.

The four labels must exist in the repo: `ready-for-agent` starts a run, and the run removes it when it starts and when it stops; `agent-working` marks a run in progress; `agent-stuck` marks a run that stopped, and its comment names the stage; `agent-done` marks a PR that is ready for the owner: no open Qodo finding, and every check on the head has passed or been skipped (`qodo-findings` aside). A run whose CI check failed stops as `agent-stuck` at the `ci` stage, naming the check. A run never merges, never adds `ready-for-agent`, never dismisses or marks a Qodo finding, and never generates the delivery doc: the owner runs the delivery-doc skill.

Runs queue on the `agent-run` concurrency group, one at a time, and GitHub keeps only the newest pending run (cancel-in-progress is false, so the active run is not cancelled). Labelling several issues while a run is active therefore silently drops the older pending runs. A dropped run never started, so its issue keeps `ready-for-agent` and nothing posts that it was dropped. Relabel the issue (remove and re-add `ready-for-agent`) to retry.

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

# Parse the workflow files, check the yearly deploy schedule, and check qodo-findings.yml's triggers and permissions (Docker, no network)
scripts/check-workflows.sh

# Browser check of the hackathon page: JavaScript off, light and dark contrast (Docker and network; build first)
scripts/check-browser.sh

# Offline tests for the delivery-doc generator and the check (needs jq)
bash scripts/test-delivery.sh

# Offline tests for the agent runner and build-site.sh's directory argument (no Docker, no network: stubs stand in for docker, gh, claude, the checks and qodo-status.sh)
bash scripts/test-agent.sh

# Docker test: the snapshot script rejects a page that only the browser sees as 404
bash scripts/test-delivery.sh --snapshot

# Check a merged PR's delivery doc is current (run on the docs branch, after the PR merges; rule 6)
scripts/generate-delivery.sh --pr 21 --check

# Is Qodo done reviewing the PR head, and how many findings does it list (`open:`)? (exit 0 settled, 2 waiting, 3 stale, 4 no review)
scripts/qodo-status.sh --pr 46

# Post the qodo-findings status on PR 46 now (maintainers; posts a commit status)
gh workflow run "Qodo findings" --repo lioramilbaum/lioramilbaum.github.io -f pr=46

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

Every `uses:` must be a 40-character SHA with a `# vX.Y.Z` comment. `scripts/build-site.sh` parses that comment to find the image tag — keep its format (`# vX.Y.Z`). The Playwright image in `scripts/snapshot-site.sh` is tracked by the regex in `renovate.json`; keep its `image="…:vX.Y.Z-noble@sha256:…"` form. `scripts/check-browser.sh` reads the image from that line; never copy the pin. `scripts/check-browser/package.json` and its `package-lock.json` pin Playwright's npm package to the same version as that image; the lockfile pins the tarballs by integrity. Renovate moves the image and the npm package together in one PR (the `Playwright` group), and `scripts/check-browser.sh` fails if the versions differ. If a Renovate PR fails check-browser.sh's version check, one side (the image or the npm package) isn't published yet; the next run picks it up. `scripts/snapshot-site.sh` still installs its package by version only. Runners must be `ubuntu-26.04`, never `-latest`. Permissions stay least-privilege. Only `qodo-findings.yml` may request `statuses: write` or use `pull_request_target`. It checks out main only, with `persist-credentials: false`, uses no action but checkout, and passes every expression to `run:` through `env:`. `scripts/check-workflows.sh` asserts this, and pins `agent-run.yml`'s trigger, guard (exactly the owner's `&&` terms, in order), step list (exactly the five steps, in order, with their keys and run text), permissions, timeout, Node version (an integer major of 22 or later) and the place of its secrets (Setup). Do not bump pins by hand; Renovate groups and automerges them after CI passes.

*Why:* A site about supply-chain integrity should practice what it describes. Pinning by SHA prevents silent tag moves.

### 6. Every merged PR gets a delivery doc, in a docs PR after it merges

**Where:** `deliveries/`, `scripts/generate-delivery.sh`, `scripts/check-delivery.sh`, `.github/pull_request_template.md`, the `delivery-doc` job in `.github/workflows/check-site.yml`, `.claude/skills/delivery-doc/SKILL.md`

A PR merges with no delivery doc. After it merges, the delivery-doc skill generates its doc, `deliveries/<YYYY-MM-DD>-<slug>.md`, from the merged PR, and adds it in a separate docs PR. The name is the date the PR opened and the branch name without its type prefix (`feat/site-snapshots` → `2026-11-05-site-snapshots.md`). `scripts/generate-delivery.sh` generates it locally from `deliveries/TEMPLATE.md`, and refuses a PR that has not merged. The Why, How, What, Assistance and third-party material, and Limitations sections are copied verbatim from the PR description (`.github/pull_request_template.md`). Evidence records the final state: the merged head (`head=` in the doc's metadata line), the latest Check site run that passed on its content before the merge, the two homepage builds, and Qodo's final review comment with its edit history, so findings Qodo cleared are still recorded. Nothing is written by hand. One docs PR may carry several docs. A docs PR is one that changes only files under `deliveries/`; it needs no delivery doc of its own.

CI runs `scripts/check-delivery.sh`. A PR that changes any file outside `deliveries/` needs no doc, and the check passes. On a docs PR it checks each doc the PR adds or changes. Does its metadata name the merged head? Was it generated for that head's content digest (the tree without the doc and its screenshot)? If not, CI is red. CI's clone is shallow, so the check fetches the head from origin; a head that cannot be fetched is red. The doc's `qodo-open` is evidence of Qodo's final review, not a gate (rule 9): a value other than 0 is a warning. CI does not check the doc's sections, the homepage, the screenshot, or the CI-run evidence, it does not re-read Qodo, and it does not check that the head is the merged head of the PR the doc names: the generator reads that from GitHub. The check is advisory, not a ruleset. Renovate PRs are exempt. The process ends 2026-12-12 23:00 UTC (end of Dec 12 CET); after that, the check passes without reading a doc. Existing docs are never changed.

*Why:* Each PR is a delivery in the Qodo Software Factory hackathon, and the doc is the evidence posted to the daily discussion. Hand-written evidence drifted from the commits it described. Generated evidence is keyed to content digests, so CI can check it. Until issue #48 the doc rode in the PR's own commit, so Qodo reviewed the doc itself, each regeneration was a push that triggered a re-review and made the doc stale again (#34 needed three, #46 more), and a restored SHA got no re-review. #35 merged without its doc and #36 added it after the merge, which worked: the generator reads everything from the PR.

### 7. Homepage screenshots are committed beside the doc; the screenshots branch is frozen

**Where:** `scripts/snapshot-site.sh`, `scripts/generate-delivery.sh`, `deliveries/<stem>/`, the `screenshots` branch

There are no post-merge snapshots: the deploy workflow captures nothing. A PR's homepage screenshot is taken with `scripts/snapshot-site.sh` (Playwright in a digest-pinned Docker image) only when the PR head's homepage build differs from its merge-base build; the generator compares them. Both commits stay in main's history after the merge, so the comparison runs on the merged PR. It is committed as `deliveries/<stem>/desktop.png` (1280 px), beside the doc, at most 500 KB. The generator enforces this; CI does not. If the homepage did not change, there is no PNG. Never delete, modify or push to the `screenshots` branch. PR homepage screenshots stop with the rest of the process at 2026-12-12 23:00 UTC (rule 6).

*Why:* The raw URL of the November 4 baseline (`2026-11-04/desktop.png`) is embedded publicly, so moving or overwriting that branch breaks it. Committed PNGs travel with the PR and need no artifact expiry.

### 8. Every line a PR adds or changes is tested in CI

**Where:** the code a PR adds or changes (`scripts/` except `check-*.sh` and `test-*.sh`, `.github/workflows/`, `_layouts/`, `_config.yml`) and the Limitations section of the PR description

CI must exercise every line of code the PR adds or changes. Code already on `main` is covered when a PR changes it, not before. Test code is exempt: checks and tests (`scripts/check-*.sh`, `scripts/test-*.sh` and the `check-site.yml` steps that run them; other workflow changes are other code) must run in CI, but don't need tests of their own; a new check must still be run by CI against a failing input at least once (push a deliberately broken revision, let CI go red, and link that run in the PR description). Every other file under `scripts/` (`build-site.sh`, `snapshot-site.sh`, `generate-delivery.sh`, `agent-run.sh`, which `scripts/test-agent.sh` tests) is other code and needs tests. For `_layouts/` and `_config.yml`, a `check-site.sh` assertion on the built `_site` output that fails without the change counts as exercising it.

- Every new branch or failure path in other code has a CI test that fails without it: a case in a `scripts/test-*.sh` run by `.github/workflows/check-site.yml`, or an assertion in `scripts/check-site.sh`. Wire each new test into CI in the same PR.
- Nothing is verified only by hand. One-off mutation runs on a local machine, scripts documented as "run by hand", and manual browser checks don't count as tests. The red CI run a new check needs (above) is a CI run, not a by-hand check.
- Anything that truly can't run in CI is named in the PR's Limitations section, with the reason (for example, LinkedIn's share dialog needs a signed-in account).

*Why:* PR #34 (issue #27) first relied on one-off mutation runs, a by-hand link check and a manual browser check, so the owner required CI coverage for every line. The rule covers only new and changed lines, so code already on `main` whose real-world behaviour CI can't reproduce, such as the real GitHub responses behind `scripts/generate-delivery.sh`'s `gh` calls, doesn't break it. Test code is exempt so that tests don't need tests of their own; running in CI is what keeps it honest.

### 9. Every Qodo finding is fixed or dismissed before the PR merges

**Where:** Qodo's "Code Review by Qodo" comment on each PR, the `## Qodo notes` section of the PR description, `.claude/skills/delivery-doc/SKILL.md`, `scripts/generate-delivery.sh`, `scripts/check-delivery.sh`, `scripts/qodo-status.sh`, `scripts/qodo-review.awk`, `scripts/qodo-gate.sh`, `.github/workflows/qodo-findings.yml`, and the ruleset on main

A PR is ready to merge only when Qodo's latest review of its head lists no open findings. `scripts/qodo-status.sh --pr N` reports whether Qodo's latest review names the head (or the same content) and has been quiet for 5 minutes; the delivery-doc skill uses it to wait. Qodo is configured in its own dashboard (app.qodo.ai), including the review rules imported from this file and those added by hand. The repo has no Qodo config file. If one is ever added, it goes in `_config.yml`'s `exclude:` block (rule 4). A finding is open while Qodo's managed tools (`get-pr-review-findings`) report it as pending, partial_implementation, not_implemented or focus_areas_edited; closed findings disappear from Qodo's comment. The owner merges; the agent never does, and never reports a PR as ready while a finding is open. Close each finding in one of two ways:

- **Fix it.** Push the fix and wait for Qodo's re-review. If Qodo still lists the finding once the fix is on the PR head, mark it implemented (`pr-review-mark-implemented`). Never mark a finding implemented before its fix is pushed.
- **Dismiss it** (`pr-review-dismiss`) with a reason (false_positive, intentional, deferred or rejected) and an explanation that cites evidence: the code at the head, a command and its output, or the revision the finding was raised against. The agent may dismiss a false_positive on its own. Intentional, deferred and rejected need the owner's approval, as does dismissing any High finding. Record each dismissal and its reason in the PR description's `## Qodo notes` section, so the delivery doc carries it.

The `qodo-findings` commit status enforces this on every PR, with no end date. `.github/workflows/qodo-findings.yml` runs `scripts/qodo-gate.sh` from main when a PR head changes and when a comment on the PR changes, which covers Qodo's re-reviews and every finding closed in Qodo. The status is success when Qodo's latest review names the head (or the same content), has been quiet for 5 minutes and lists no open findings. It is failure while the review lists any, or lists none in a layout `scripts/qodo-review.awk` does not know. It is pending while Qodo has not reviewed the head, or the PR is a draft. It is error when the gate could not read the PR or Qodo's review; re-run it by dispatching the Qodo findings workflow (see Verify). After a force-push, the reviewed commit may no longer be fetchable (the old head is pruned from the clone and from the remote), so the status is pending (stale) until Qodo re-reviews the new head. That fails closed and heals itself. Renovate PRs get success (exempt), so automerge isn't blocked. A ruleset on main requires the status from GitHub Actions (integration 15368), with no bypass. The ruleset is not created yet; the owner creates it after this PR merges, in this order:

1. Create it from the JSON below with `"enforcement": "evaluate"`. Evaluate mode reports what the rule would block without blocking anything.
2. Confirm on a real PR that the `qodo-findings` status satisfies the rule: rule insights show it passing, with the source pinned to GitHub Actions (integration 15368). If the status is posted with GITHUB_TOKEN and the pin does not match it, drop `integration_id` from the JSON rather than block every PR.
3. Only then change `"enforcement"` to `"active"`, which blocks merges that lack the status.

The JSON for step 1; step 3 changes only its `enforcement`:

```json
{
  "name": "qodo-findings",
  "target": "branch",
  "enforcement": "evaluate",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [{ "context": "qodo-findings", "integration_id": 15368 }]
      }
    }
  ]
}
```

The `qodo-findings` status is the merge gate. The delivery doc is generated after the merge (rule 6), so it records Qodo's final review: the generator records how many findings Qodo's latest review of the merged head's content lists (`qodo-open=` in the doc's metadata line), and lists the findings Qodo cleared. On the docs PR, CI's delivery-doc job warns, but stays green, when it is not 0. `qodo-open=unknown` means Qodo's final review has no finding the generator can parse, and not every group says it is clear: the agent reports it to the owner, who decides whether `scripts/qodo-review.awk` needs a change. If three re-reviews in a row each add a new finding, the agent stops and hands the open list to the owner. Renovate PRs are exempt: Qodo does not review them, and they automerge after CI passes (rule 5). The delivery-doc job ends with the delivery window (rule 6); the `qodo-findings` status does not.

*Why:* On PR #34 (issue #27), Qodo added findings on almost every re-review. The final delivery doc listed three as open; they were closed (two dismissed, one marked implemented) at 06:47Z on 2026-11-08, after the doc was generated and a minute before the merge, so the merged doc still shows them open. The owner then required every finding to be closed before merge, and triage to come before the doc.

### 10. Every issue has acceptance criteria before work starts; its PR carries them

**Where:** issues on `lioramilbaum/lioramilbaum.github.io`, `.github/ISSUE_TEMPLATE/change.md`, the `## Acceptance criteria` section of the PR description (`.github/pull_request_template.md`)

- No work starts on an issue (no plan, branch or code) until the issue has an `## Acceptance criteria` section: a checklist in which every item is checkable, an observable result or a test that passes or fails.
- An agent picking up an issue reads it first (`gh issue view N -R lioramilbaum/lioramilbaum.github.io`). If it has no such section, or a criterion can't be checked, the agent may propose draft criteria, but it waits until the owner approves them and they are in the issue. It never treats its own draft as approved. A list under another heading (such as `## Done when`) counts once the owner renames it.
- The PR that closes the issue copies the checklist, and only the checklist, into its `## Acceptance criteria` section next to `Closes #N`, so the reviewer sees the request beside the change. A PR with no linked issue writes `No linked issue.` there.
- Renovate's Dependency Dashboard and Renovate PRs are exempt. CI does not check this; the delivery doc does not copy the section.

*Why:* The Qodo Software Factory hackathon's Day 3 challenge asks every PR description to carry the ticket link and its acceptance criteria. PRs #25 (issue #24) and #34 (issue #27) linked their issues but not the criteria; Qodo found its requirement gaps only by reading the linked issues.

## Workflow

Before starting an issue, read it and confirm it has acceptance criteria (rule 10).

Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`. One commit per PR.

After CI and Qodo have reviewed a PR, clear Qodo's findings (rule 9). Mark a draft ready first: Qodo does not review drafts. A PR is ready to merge when the `qodo-findings` status on its head is success. After it merges, run the delivery-doc skill (`.claude/skills/delivery-doc/SKILL.md`) on it: it generates the doc from the merged PR and adds it in a docs PR (rule 6).
