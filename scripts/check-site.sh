#!/usr/bin/env bash
set -euo pipefail

site="${1:-_site}"

page="$site/index.html"
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=${2:-README.md}::$1"
  else
    echo "error: $1" >&2
  fi
  exit 1
}

test -f "$page" || fail "homepage was not built at $page"

for heading in "Platform Engineering" "DevOps" "AI" "Open Source"; do
  grep -Eq "<h2[^>]*>${heading}</h2>" "$page" \
    || fail "missing topic section: ## ${heading}"
done

if grep -Eq '<h2[^>]*>Documentation</h2>' "$page"; then
  fail "legacy '## Documentation' section should be replaced by topic sections"
fi

section() { sed -n "/<h2[^>]*>$1<\/h2>/,/<h2/p" "$page"; }

section "Platform Engineering" | grep -q 'href="/docs/edge-appliance/glossary.html"' \
  || fail "Edge Appliance glossary link missing from Platform Engineering"
test -f "$site/docs/edge-appliance/glossary.html" \
  || fail "glossary page was not built"

section "AI" | grep -q 'href="https://github.com/lioramilbaum/projectmesh"' \
  || fail "projectmesh link missing from AI"

if grep -Eq 'href="[^"]*\.md"' "$page"; then
  fail "unrewritten .md link on homepage (jekyll-relative-links)"
fi

test -f "$site/favicon.ico" || fail "favicon.ico was not built"
test -f "$site/assets/images/favicon.svg" || fail "favicon.svg was not built"
test -f "$site/assets/images/apple-touch-icon.png" || fail "apple-touch-icon.png was not built"
for p in "$page" "$site/docs/edge-appliance/glossary.html"; do
  grep -q 'rel="icon"' "$p" || fail "favicon link missing from $p"
done

for repo_only in CNAME scripts deliveries AGENTS.md AGENTS.html; do
  test ! -e "$site/$repo_only" || fail "repo-only path published: $repo_only" _config.yml
done

echo "Homepage checks passed"
