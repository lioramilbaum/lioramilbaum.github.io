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

grep -Eq '<h2[^>]*>News</h2>' "$page" || fail "missing section: ## News"
# Everything above the Platform Engineering heading must hold the News heading.
sed '/<h2[^>]*>Platform Engineering<\/h2>/,$d' "$page" | grep -Eq '<h2[^>]*>News</h2>' \
  || fail "## News must come before ## Platform Engineering"

section "News" | grep -Eq '<ul[^>]* class="news"' \
  || fail "News list lacks the news class ({: .news})"
# The date line's colours, light and dark, as the tagline's (the layout's style block).
styles=$(tr '\n' ' ' < "$page")
grep -Eq '\.news[^{}]*\{[^}]*color: #666;' <<<"$styles" \
  || fail "no .news rule with color #666 in the homepage styles" _layouts/home.html
grep -Eq '@media \(prefers-color-scheme: dark\)[[:space:]]*\{[[:space:]]*\.news[^{}]*\{[^}]*color: #999;' <<<"$styles" \
  || fail "no dark-mode .news rule with color #999 in the homepage styles" _layouts/home.html

advantech='https://www.advantech.com/hi-in/resources/industry-focus/deploying-edge-ai-across-heterogeneous-hardware-from-compatibility-to-controlled-composition'
section "News" | grep -Fq "href=\"$advantech\"" \
  || fail "Advantech article link missing from News"
section "News" | grep -Fq 'Nov 10, 2026 · Advantech' \
  || fail "Advantech article's date and publisher line (Nov 10, 2026 · Advantech) missing from News"

entries=$(section "News" | sed -n '/<ul[^>]* class="news"/,/<\/ul>/p' | grep -oE '<li[ >]' | wc -l || true)
(( entries >= 1 )) || fail "News list has no entries"
(( entries <= 5 )) || fail "News list has $entries entries; the cap is 5"

# One identity: the tagline is a single line, not a list of roles, and the
# positioning line sits above News.
grep -Eq '<p class="tagline">[^|<]+</p>' "$page" \
  || fail "tagline is empty or a '|' list of roles; keep one identity"
sed '/<h2[^>]*>News<\/h2>/,$d' "$page" | grep -Fq '<strong>Practical platforms. Open collaboration.</strong>' \
  || fail "positioning line (Practical platforms. Open collaboration.) missing above ## News"
grep -Fq '<meta name="viewport" content="width=device-width, initial-scale=1">' "$page" \
  || fail "viewport meta tag missing from the homepage" _layouts/home.html

# Featured work and the next steps come after News and before the topic sections.
# kramdown renders the apostrophe in "Let's" as a typographic quote, so match any.
together_h='Let[^<]*s work together'
order=$(grep -oE "<h2[^>]*>(News|Featured work|${together_h}|Platform Engineering)</h2>" "$page" \
  | sed -E 's/<[^>]*>//g; s/^Let.*/Together/' | tr '\n' '|' || true)
[[ "$order" == "News|Featured work|Together|Platform Engineering|" ]] \
  || fail "sections must run News, Featured work, Let's work together, Platform Engineering (got: ${order})"

featured=$(section "Featured work")
grep -Eq '<ul[^>]* class="news"' <<<"$featured" \
  || fail "Featured work list lacks the news class ({: .news}) for its label lines"
# Check each item on its own, so a duplicate in one item cannot hide a gap in another.
rest=$(sed -n '/<ul[^>]* class="news"/,/<\/ul>/p' <<<"$featured" | tr '\n' ' ')
items=()
while [[ "$rest" == *"<li"* ]]; do
  rest=${rest#*<li}
  items+=("${rest%%</li>*}")
done
(( ${#items[@]} == 3 )) || fail "Featured work has ${#items[@]} items; it needs 3"
# Completed work says so; ongoing work is labelled ongoing.
labels=('Article · Published Nov 10, 2026' 'Project · Ongoing' 'Experiment · Ongoing')
hrefs=("$advantech" https://github.com/lioramilbaum/projectmesh /docs/qodo-software-factory-hackathon/)
for i in 0 1 2; do
  item=${items[i]} label=${labels[i]}
  grep -Fq "<p>$label" <<<"$item" \
    || fail "Featured work item $((i + 1)) lacks its label line: $label"
  grep -Fq "href=\"${hrefs[i]}\"" <<<"$item" \
    || fail "Featured work item $((i + 1)) ($label) lacks its link: ${hrefs[i]}"
  for part in 'Problem:' 'My contribution:' 'Outcome( so far)?:'; do
    n=$(grep -oE "<strong>$part</strong>" <<<"$item" | wc -l || true)
    (( n == 1 )) || fail "Featured work item $((i + 1)) ($label) has $n '${part%%(*}' paragraphs; it needs one"
  done
done

together=$(section "$together_h")
for path in \
  'Employers:</strong>[^<]*<a href="https://linkedin\.com/in/lmilbaum">' \
  'Clients:</strong>[^<]*<a href="https://linkedin\.com/in/lmilbaum">' \
  'Collaborators:</strong>.*href="https://github\.com/lmilbaum"' \
  'Collaborators:</strong>.*href="https://github\.com/lioramilbaum/lioramilbaum\.github\.io/issues"'; do
  grep -Eq "<li><strong>$path" <<<"$together" \
    || fail "Let's work together lacks a next step: ${path%%:*} (${path#*href=})"
done

# No placeholder sections: every topic section holds at least one link.
if grep -Eqi 'coming soon' "$page"; then
  fail "placeholder 'Coming soon' text on the homepage"
fi
for heading in "Platform Engineering" "DevOps" "AI" "Open Source"; do
  section "$heading" | grep -q '<a href=' || fail "## ${heading} has no link; no empty sections"
done
# The #rules anchor keeps the href from ending in .md, which the check below rejects.
section "DevOps" | grep -Fq 'href="https://github.com/lioramilbaum/lioramilbaum.github.io/blob/main/AGENTS.md#rules"' \
  || fail "AGENTS.md link missing from DevOps"
section "Open Source" | grep -Fq 'href="https://github.com/lioramilbaum/lioramilbaum.github.io"' \
  || fail "site repository link missing from Open Source"

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
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/5#discussioncomment-19469556 \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/6#discussioncomment-19501367 \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/7#discussioncomment-19599476 \
  https://github.com/qodo-hackathon/software-factory-hackathon/discussions/8#discussioncomment-19607588 \
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
