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

section "AI" | grep -q 'href="/docs/qodo-software-factory-hackathon/"' \
  || fail "Qodo hackathon page link missing from AI"

if grep -Eq 'href="[^"]*\.md"' "$page"; then
  fail "unrewritten .md link on homepage (jekyll-relative-links)"
fi

hackathon="$site/docs/qodo-software-factory-hackathon/index.html"
hackathon_md=docs/qodo-software-factory-hackathon.md
test -f "$hackathon" || fail "hackathon page was not built" "$hackathon_md"

for u in \
  https://www.qodo.ai \
  https://hackathon.qodo.ai/ \
  https://hackathon.qodo.ai/challenges/ \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/2#discussioncomment-19397091 \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/4#discussioncomment-19456803 \
  https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/AGENTS.md \
  https://github.com/lioramilbaum/lioramilbaum.github.io/tree/main/deliveries; do
  grep -Fq "href=\"$u\"" "$hackathon" || fail "hackathon page link missing: $u" "$hackathon_md"
done

# Relative hrefs only: absolute URLs such as the AGENTS.md link end in .md too.
if grep -Eq 'href="[^":]*\.md"' "$hackathon"; then
  fail "unrewritten .md link on hackathon page (jekyll-relative-links)" "$hackathon_md"
fi

grep -Eq '<meta property="og:title" content="[^"]*[Hh]ackathon[^"]*">' "$hackathon" \
  || fail "hackathon og:title missing" "$hackathon_md"
grep -Eq '<meta property="og:description" content="[^"]*[Hh]ackathon[^"]*">' "$hackathon" \
  || fail "hackathon og:description missing" "$hackathon_md"
grep -Fq '<meta property="og:image" content="https://lioramilbaum.com/assets/images/profile.jpg">' "$hackathon" \
  || fail "hackathon og:image missing" "$hackathon_md"

share='https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Flioramilbaum.com%2Fdocs%2Fqodo-software-factory-hackathon%2F'
# Assumes the anchor sits on one line, which _layouts/docs.html keeps on purpose.
share_anchor=$(grep -o '<a [^>]*share-offsite[^>]*>.*</a>' "$hackathon" || true)
if [[ -z "$share_anchor" ]]; then
  fail "LinkedIn share link missing or mis-encoded" "$hackathon_md"
fi
share_tag="${share_anchor%%>*}>"
share_text="${share_anchor#*>}"
share_text="${share_text%%</a>*}"
# Drop the icon's <svg>...</svg> so a <title> inside it cannot satisfy the text check.
share_text="${share_text%%<svg*}${share_text#*</svg>}"
grep -Fq "href=\"$share\"" <<<"$share_tag" || fail "LinkedIn share link missing or mis-encoded" "$hackathon_md"
for attr in 'target="_blank"' 'rel="noopener noreferrer"' 'aria-label="Share on LinkedIn'; do
  grep -Fq "$attr" <<<"$share_tag" || fail "LinkedIn share link lacks $attr" "$hackathon_md"
done
[[ "$share_text" == *"Share on LinkedIn"* ]] \
  || fail "LinkedIn share link has no visible 'Share on LinkedIn' text" "$hackathon_md"

if grep -Eq 'share-offsite|\.share[ {]' "$site/docs/edge-appliance/glossary.html"; then
  fail "share button rendered on a page that did not opt in" _layouts/docs.html
fi

if grep -qi '<script' "$hackathon"; then
  fail "script on hackathon page" "$hackathon_md"
fi
if grep -Eqi '<link[^>]*stylesheet' "$hackathon"; then
  fail "external stylesheet on hackathon page" "$hackathon_md"
fi
if grep -Eqi '@import|@font-face|fonts\.googleapis\.com|fonts\.gstatic\.com|use\.typekit\.net' "$hackathon"; then
  fail "external font or stylesheet import on hackathon page" "$hackathon_md"
fi

test -f "$site/favicon.ico" || fail "favicon.ico was not built"
test -f "$site/assets/images/favicon.svg" || fail "favicon.svg was not built"
test -f "$site/assets/images/apple-touch-icon.png" || fail "apple-touch-icon.png was not built"
for p in "$page" "$site/docs/edge-appliance/glossary.html" "$hackathon"; do
  grep -q 'rel="icon"' "$p" || fail "favicon link missing from $p"
done

# The footer year is site.time, read when the build starts. Take the expected year
# from the build output, not the clock: the homepage's mtime is when the build
# wrote it (rendered pages are written fresh; static files keep their source
# mtime). A build that starts just before a New Year writes after it, so in the
# first five minutes of January 1 the year before passes too.
stamp=$(date -u -r "$page" '+%Y %m%d%H%M') || fail "cannot read the build time of $page"
built_year=${stamp% *}
years=" $built_year "
# MMDDHHMM up to 01010004 is Jan 1 00:00-00:04 UTC. 10# forces base 10: the leading
# zero would otherwise make the number octal.
(( 10#${stamp#* } > 1010004 )) || years+="$((built_year - 1)) "
year=$(sed -nE 's/.*<footer>&copy; ([0-9]{4}) Liora Milbaum<\/footer>.*/\1/p' "$page")
[[ -n "$year" && "$years" == *" $year "* ]] \
  || fail "footer year '${year}' is not the build year ($built_year) in index.html" _layouts/home.html
for p in "$page" "$site/docs/edge-appliance/glossary.html" "$hackathon"; do
  layout=_layouts/docs.html; [[ "$p" == "$page" ]] && layout=_layouts/home.html
  grep -Fq "<footer>&copy; $year Liora Milbaum</footer>" "$p" \
    || fail "footer year is not the build year ($year) in ${p#"$site"/}" "$layout"
done

# Every og:image on every built page must be an absolute site URL to a built file.
while IFS= read -r -d '' html; do
  layout=_layouts/docs.html
  [[ "${html#"$site"/}" == index.html ]] && layout=_layouts/home.html
  total=$(grep -o 'property="og:image"' "$html" | wc -l || true)
  exact=$(grep -oE '<meta property="og:image" content="[^"]*">' "$html" | wc -l || true)
  if (( total != exact )); then
    fail "malformed og:image in ${html#"$site"/}" "$layout"
  fi
  while IFS= read -r image; do
    case "$image" in
      https://lioramilbaum.com/?*) ;;
      *) fail "og:image is not an absolute site URL in ${html#"$site"/}: '$image'" "$layout" ;;
    esac
    path=${image#https://lioramilbaum.com/}
    path=${path%%[?#]*}
    test -f "$site/$path" || fail "og:image target not built: $image" "$layout"
  done < <(grep -oE '<meta property="og:image" content="[^"]*">' "$html" | sed -E 's/.*content="([^"]*)">/\1/')
done < <(find "$site" -name '*.html' -print0)

for repo_only in CNAME scripts deliveries .claude .github AGENTS.md AGENTS.html; do
  test ! -e "$site/$repo_only" || fail "repo-only path published: $repo_only" _config.yml
done

echo "Homepage checks passed"
