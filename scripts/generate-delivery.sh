#!/usr/bin/env bash
# AGENTS.md rule 6: writes a PR's delivery doc, deliveries/<PR open date>-<branch
# slug>.md, from deliveries/TEMPLATE.md. Every section comes from the PR
# description, CI runs, the builds, or Qodo's review comment. Nothing is written
# by hand. The delivery-doc skill runs this and amends the doc into the PR commit.
#
# Usage: scripts/generate-delivery.sh --pr N [--check]
#   --check  writes nothing; exits 1 and prints a diff if the doc would change.
#
# Test hooks: BUILD_SITE (default scripts/build-site.sh, run in each worktree),
# SNAPSHOT (default scripts/snapshot-site.sh), AWK. gh is found on PATH.
#
# Choices that keep a re-run after an amend identical:
# - CI evidence cites the earliest successful Check site run whose head has
#   the same content digest, not the run for one SHA. An amend that only adds
#   the doc keeps the digest, so the evidence does not move.
# - Qodo's reviewed commits are listed by content digest, not SHA.
# - The doc names no head SHA, so an amend does not change its text.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
template=deliveries/TEMPLATE.md
repo=lioramilbaum/lioramilbaum.github.io
pr=""
check=0
usage() {
  echo "usage: scripts/generate-delivery.sh --pr N [--check]" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr=${2:-}; shift ;;
    --check) check=1 ;;
    *) usage ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

awk=${AWK:-awk}
die() { echo "error: $*" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/generate-delivery.XXXXXX")
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  for wt in head base; do
    if [[ -d "$tmp/$wt" ]]; then git -C "$root" worktree remove --force "$tmp/$wt" >/dev/null 2>&1 || true; fi
  done
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# section FILE NAME: prints the trimmed body of the first "## NAME" section of
# FILE. Exits 1 if there is no such section. Headings inside code fences are
# not special-cased, so a PR description should not use "## " inside a fence.
section() {
  # shellcheck disable=SC2016 # awk program, not the shell
  "$awk" -v name="$2" '
    { sub(/\r$/, "") }
    /^## / {
      h = $0
      sub(/[ \t]+$/, "", h)
      on = (!found && h == "## " name)
      if (on) found = 1
      next
    }
    on { body[++n] = $0 }
    END {
      s = 1; e = n
      while (s <= e && body[s] ~ /^[ \t]*$/) s++
      while (e >= s && body[e] ~ /^[ \t]*$/) e--
      for (i = s; i <= e; i++) print body[i]
      exit (found ? 0 : 1)
    }' "$1"
}

# strip_trailer FILE: removes the "Generated with Claude Code" line that ends a PR
# description, with the blank lines around it. Only the last line is considered,
# so a copy of that line in the middle of the text stays. CR line endings are
# normalised.
strip_trailer() {
  # shellcheck disable=SC2016 # awk program, not the shell
  "$awk" '
    { sub(/\r$/, ""); l[++n] = $0 }
    END {
      while (n > 0 && l[n] ~ /^[ \t]*$/) n--
      if (n > 0 && l[n] ~ /Generated with \[Claude Code\]\(https:[^)]*\)[ \t]*$/) {
        s = l[n]
        sub(/Generated with.*/, "", s)
        if (length(s) <= 5) n--
      }
      while (n > 0 && l[n] ~ /^[ \t]*$/) n--
      for (i = 1; i <= n; i++) print l[i]
    }' "$1" > "$1.new" && mv "$1.new" "$1"
}

# labelled FILE: marks author-written text so readers know whose words these are.
labelled() {
  printf '_From the PR description (author-written)._\n\n'
  cat "$1"
}

pr_field() { gh pr view "$pr" --repo "$repo" --json "$1" --jq ".$1"; }

title=$(pr_field title)
created=$(pr_field createdAt)
ref=$(pr_field headRefName)
head_sha=$(pr_field headRefOid)
base_sha=$(pr_field baseRefOid)
pr_url=$(pr_field url)
pr_field body > "$tmp/pr-body.md"
strip_trailer "$tmp/pr-body.md"

# Doc name: the PR open date (UTC, as GitHub reports it) and the branch name
# without its type prefix (everything up to the first "/").
[[ "$created" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T ]] || die "PR $pr has no usable createdAt ($created)"
date=${BASH_REMATCH[1]}
case "$ref" in
  */*) slug=${ref#*/} ;;
  *) slug=$ref ;;
esac
name="deliveries/$date-$slug.md"
[[ "$name" =~ ^deliveries/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] \
  || die "doc name '$name' from branch '$ref' does not match deliveries/<YYYY-MM-DD>-<slug>.md"
stem=${name##*/}
stem=${stem%.md}
doc="$root/$name"
png_dir="$root/deliveries/$stem"

# Required PR description sections, copied verbatim (AGENTS.md rule 6), each
# labelled as the author's words in its part.
mkdir -p "$tmp/parts"
require() {  # require KEY "Heading"
  if ! section "$tmp/pr-body.md" "$2" > "$tmp/sec-$1.md"; then
    die "the PR description has no '## $2' section; add it (see .github/pull_request_template.md) and run this again"
  fi
  [[ -s "$tmp/sec-$1.md" ]] || die "the '## $2' section of the PR description is empty"
  labelled "$tmp/sec-$1.md" > "$tmp/parts/$1"
}
require why Why
require how How
require what What
require assistance "Assistance and third-party material"
require limitations Limitations

git cat-file -e "$head_sha^{commit}" 2>/dev/null \
  || die "PR head $head_sha is not in this clone; fetch the PR branch and run this again"
git cat-file -e "$base_sha^{commit}" 2>/dev/null \
  || die "base $base_sha is not in this clone; run: git fetch upstream"
mb=$(git merge-base "$base_sha" "$head_sha") || die "no merge-base for $base_sha and $head_sha"
if git cat-file -e "$mb:$name" 2>/dev/null; then
  die "$name already exists on the base branch; the delivery doc name must be new"
fi
base7=${mb:0:7}

D=$(bash "$root/scripts/check-delivery.sh" --digest "$head_sha" "$name")

# Builds: the head, and the merge-base in its own worktree (its own build script).
git worktree add --detach "$tmp/head" "$head_sha" >/dev/null 2>&1 || die "could not check out $head_sha"
git worktree add --detach "$tmp/base" "$mb" >/dev/null 2>&1 || die "could not check out $mb"
( cd "$tmp/head" && ${BUILD_SITE:-scripts/build-site.sh} ) >&2 || die "building the head failed"
( cd "$tmp/base" && ${BUILD_SITE:-scripts/build-site.sh} ) >&2 || die "building the merge-base failed"

# site_hash SITE: the hash of SITE's homepage manifest (AGENTS.md rule 7). It covers
# index.html and each local file it loads: src="/..." and <link ... href="/...">.
# <a href> links are not files.
site_hash() {
  local site=$1 index="$1/index.html" paths path manifest
  [[ -f "$index" ]] || die "$index is missing; the build did not produce a homepage"
  # shellcheck disable=SC2016 # awk program, not the shell
  paths=$({ grep -oE ' src="/[^"]*"' "$index" || true
            grep -E '<link[^>]*>' "$index" | grep -oE ' href="/[^"]*"' || true
          } | "$awk" -F'"' '{ p = $2; sub(/[?#].*/, "", p); if (substr(p, 1, 2) != "//" && p != "/") print p }' \
            | LC_ALL=C sort -u)
  manifest=$(printf 'index.html %s\n' "$(git hash-object "$index")")
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -f "$site/${path#/}" ]] || die "$index loads $path but $site/${path#/} is missing"
    manifest="$manifest"$'\n'"$path $(git hash-object "$site/${path#/}")"
  done <<< "$paths"
  printf '%s\n' "$manifest" | LC_ALL=C sort | git hash-object --stdin
}
H=$(site_hash "$tmp/head/_site")
base_H=$(site_hash "$tmp/base/_site")
changed=yes
if [[ "$H" == "$base_H" ]]; then changed=no; fi

# Screenshots: the homepage hash recorded in the existing doc, if any. Both the
# current and the earlier metadata line carry homepage=H.
rec_H=""
if [[ -f "$doc" ]]; then
  rec_H=$(sed -nE 's/^<!-- delivery: .* homepage=([0-9a-f]+) .*/\1/p' "$doc" | tail -n1)
fi
need_snap=0
if [[ "$changed" == yes ]]; then
  if [[ "$rec_H" != "$H" || ! -f "$png_dir/desktop.png" ]]; then
    need_snap=1
  fi
fi

SERVED_PORT=""
serve_head() {
  local port
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()') \
    || die "could not pick a free port"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp/head/_site" >"$tmp/http.log" 2>&1 &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
      SERVED_PORT=$port
      return 0
    fi
    sleep 1
  done
  die "could not serve the head build for screenshots (see $tmp/http.log)"
}

capture() {
  serve_head
  mkdir -p "$png_dir"
  ${SNAPSHOT:-$root/scripts/snapshot-site.sh} "http://host.docker.internal:$SERVED_PORT" "$png_dir" \
    || die "screenshots of the head build failed"
  kill "$server_pid" 2>/dev/null || true
  server_pid=""
  local size
  size=$(wc -c < "$png_dir/desktop.png" | tr -d ' ')
  if (( size > 512000 )); then
    die "$png_dir/desktop.png is $size bytes; the limit is 500 KB (512000 bytes)"
  fi
}

# CI evidence: the earliest completed Check site run on this branch whose head has
# content digest D and whose jobs all passed except delivery-doc. delivery-doc is left
# out: it fails while a doc from earlier content is in the tree, so requiring it would
# deadlock.
runs=$(gh run list --repo "$repo" --branch "$ref" --workflow "Check site" --limit 100 \
  --json databaseId,headSha,status,url,createdAt,event \
  --jq '.[] | select(.event == "pull_request" and .status == "completed") | [.databaseId, .headSha, .url, .createdAt] | join("\t")') \
  || die "could not list Check site runs"
run_id=""; run_sha=""; run_url=""; run_at=""; run_jobs=""
while IFS=$'\t' read -r id sha url at; do
  [[ -n "$id" ]] || continue
  git cat-file -e "$sha^{commit}" 2>/dev/null || continue
  [[ "$(bash "$root/scripts/check-delivery.sh" --digest "$sha" "$name")" == "$D" ]] || continue
  if [[ -n "$run_at" && ! "$at" < "$run_at" ]]; then continue; fi
  jobs_list=$(gh run view "$id" --repo "$repo" --json jobs --jq '.jobs | sort_by(.name) | .[] | [.name, .conclusion] | join("\t")') \
    || die "could not read the jobs of run $id"
  passed=1; counted=0; summary=""
  while IFS=$'\t' read -r jname jconc; do
    [[ -n "$jname" ]] || continue
    [[ "$jname" == delivery-doc ]] && continue
    summary="${summary}${summary:+; }$jname: $jconc"
    counted=$((counted + 1))
    [[ "$jconc" == success ]] || passed=0
  done <<< "$jobs_list"
  if [[ $passed -eq 1 && $counted -gt 0 ]]; then
    run_id=$id; run_sha=$sha; run_url=$url; run_at=$at; run_jobs=$summary
  fi
done <<< "$runs"
[[ -n "$run_id" ]] || die "no completed Check site run for content $D with every job except delivery-doc passing; wait for CI on the head and run this again"

{
  printf -- '- Ran in CI: [run %s](%s) on %s (content %s). Jobs: %s.\n' \
    "$run_id" "$run_url" "${run_sha:0:7}" "$D" "$run_jobs"
  if [[ "$changed" == yes ]]; then
    printf -- '- Homepage: changed. The head build (H %s) differs from the merge-base %s build. Screenshot below.\n' "$H" "$base7"
  else
    printf -- '- Homepage: unchanged. The head build (H %s) matches the merge-base %s build.\n' "$H" "$base7"
  fi
  printf -- '- Local: built the head and the merge-base (%s) with scripts/build-site.sh, and compared their homepages.\n' \
    "$base7"
} > "$tmp/parts/evidence"

if [[ "$changed" == yes ]]; then
  printf '![Homepage on desktop](%s/desktop.png)\n' "$stem" > "$tmp/parts/screenshot"
else
  printf 'No visible change on the homepage.\n' > "$tmp/parts/screenshot"
fi

# Qodo: the marked comment and every earlier body of it. Each edit's diff is the body
# as of that edit; the current body is the last one.
#
# Comment and edit text is PR-controlled, so it never shares a stream with structure.
# The list queries return only scalars (ids, times, cursors, flags), each checked
# against a strict pattern before use. Each edit's text is base64-encoded: base64 has
# no tab or newline, so no text can be read as a control line. Every GraphQL value
# goes through -f (a raw string), never -F, because -F reads an "@file" value from disk.
qodo_versions="$tmp/qodo-versions"
mkdir -p "$qodo_versions"
# shellcheck disable=SC2016 # GraphQL variables, not the shell
comments_query='query($owner: String!, $name: String!, $n: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id createdAt body author { login } }
      }
    }
  }
}'
# shellcheck disable=SC2016 # jq program, not the shell
comments_jq='.data.repository.pullRequest.comments as $c
  | "PAGE\t\($c.pageInfo.hasNextPage)\t\($c.pageInfo.endCursor // "")",
    ($c.nodes[]
      | select((.author.login == "qodo-code-review" or .author.login == "qodo-code-review[bot]") and (.body | contains("Code Review by Qodo")))
      | "QCOMMENT\t\(.id)\t\(.createdAt)\t\(.body | @base64)")'
# shellcheck disable=SC2016 # GraphQL variables, not the shell
edits_query='query($id: ID!, $after: String) {
  node(id: $id) {
    ... on IssueComment {
      userContentEdits(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { editedAt diff } }
    }
  }
}'
# shellcheck disable=SC2016 # jq program, not the shell
edits_jq='.data.node.userContentEdits as $e
  | "PAGE\t\($e.pageInfo.hasNextPage)\t\($e.pageInfo.endCursor // "")",
    ($e.nodes[] | "EDIT\t\(.editedAt)\t\((.diff // "") | @base64)")'

# valid_token VALUE: the comment id is base64-like (GitHub node id); anything else is
# refused before gh is called with it.
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_=+/-]+$ ]] || die "Qodo returned a value that is not an id; refusing it"; }

# Phase A: the list of comments. Each comment's body arrives base64-encoded, so it
# cannot be read as a control line. The Qodo comment is the one with the latest createdAt.
qcomments=0; chosen_id=""; chosen_at=""; chosen_body=""
after=""; has=true; page=0
while [[ "$has" == true ]]; do
  page=$((page + 1))
  (( page <= 100 )) || die "Qodo's comments run past 100 pages; refusing to guess"
  after_args=()
  if [[ -n "$after" ]]; then after_args=(-f after="$after"); fi
  gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -F n="$pr" ${after_args[@]+"${after_args[@]}"} \
    -f query="$comments_query" --jq "$comments_jq" > "$tmp/qodo-page.txt" \
    || die "could not read Qodo's review comments (page $page)"
  has=false; cursor=""
  while IFS=$'\t' read -r rec a b c; do
    case "$rec" in
      PAGE) has=$a; cursor=$b ;;
      QCOMMENT)
        qcomments=$((qcomments + 1))
        if [[ -z "$chosen_at" || ! "$b" < "$chosen_at" ]]; then chosen_id=$a; chosen_at=$b; chosen_body=$c; fi
        ;;
    esac
  done < "$tmp/qodo-page.txt"
  if [[ "$has" == true ]]; then after=$cursor; fi
done

# Phase B: the chosen comment's body is the current version (last in order). Its edits
# come before it: each is written to $qodo_versions, named by its time so a sort gives
# chronological order.
if (( qcomments > 0 )); then
  valid_token "$chosen_id"
  printf '%s' "$chosen_body" | base64 --decode > "$qodo_versions/~body" \
    || die "could not decode Qodo's current review body"
  e_after=""; e_has=true; e_page=0
  while [[ "$e_has" == true ]]; do
    e_page=$((e_page + 1))
    (( e_page <= 100 )) || die "Qodo's edit history runs past 100 pages; refusing to guess"
    e_args=()
    if [[ -n "$e_after" ]]; then e_args=(-f after="$e_after"); fi
    gh api graphql -f id="$chosen_id" ${e_args[@]+"${e_args[@]}"} -f query="$edits_query" --jq "$edits_jq" \
      > "$tmp/qodo-edits.txt" || die "could not read Qodo's edit history (page $e_page)"
    e_has=false; e_after=""; nedit=0
    while IFS=$'\t' read -r rec a b; do
      case "$rec" in
        PAGE) e_has=$a; e_after=$b ;;
        EDIT)
          [[ "$a" =~ ^[0-9TZ:.+-]+$ ]] || die "Qodo returned an unexpected edit time"
          nedit=$((nedit + 1))
          printf '%s' "$b" | base64 --decode > "$qodo_versions/$a.$e_page.$(printf '%04d' "$nedit")" \
            || die "Qodo's edit history did not decode"
          ;;
      esac
    done < "$tmp/qodo-edits.txt"
  done
fi

qodo_body="$tmp/qodo-body.md"
if (( qcomments == 0 )); then
  echo 'Qodo has not reviewed this PR yet: there is no "Code Review by Qodo" comment.' > "$qodo_body"
else
  # Stage 1: one V line per version (its marked commit), one F line per finding.
  # Each version is parsed on its own, so no text can open a new version.
  parsed="$tmp/qodo-parsed.txt"
  : > "$parsed"
  vn=0
  # shellcheck disable=SC2012 # version file names are generated above (no spaces)
  while IFS= read -r f; do
    vn=$((vn + 1))
    # shellcheck disable=SC2016 # awk program, not the shell
    "$awk" -v vnum="$vn" '
      function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
      {
        if (sha == "" && substr($0, 1, 5) == "<!-- " && (i = index($0, "/commit/")) > 0) {
          s = substr($0, i + 8, 40)
          if (length(s) == 40 && s ~ /^[0-9a-f]+$/) sha = s
        }
        if ((i = index($0, "<strong>View ")) > 0) {
          s = substr($0, i + 13)
          sub(/[ <].*$/, "", s)
          sev = s
          next
        }
        if ($0 ~ /<summary>[ \t]*[0-9]+\.[ \t]/) {
          n++; last = n
          s = $0
          sub(/^.*<summary>[ \t]*[0-9]+\.[ \t]/, "", s)
          sub(/<\/summary>.*$/, "", s)
          k = index(s, "<code>")
          t = (k > 0) ? substr(s, 1, k - 1) : s
          codes = (k > 0) ? substr(s, k) : ""
          kind = ""
          while ((k = index(codes, "<code>")) > 0) {
            codes = substr(codes, k + 6)
            e = index(codes, "</code>")
            c = (e > 0) ? substr(codes, 1, e - 1) : codes
            if (kind == "" && index(c, "New") == 0) kind = c
            codes = (e > 0) ? substr(codes, e + 7) : ""
          }
          gsub(/\t/, " ", t); gsub(/\t/, " ", kind)
          ft[n] = trim(t); fk[n] = trim(kind); fu[n] = ""; fsev[n] = sev
          next
        }
        if (last > 0 && fu[last] == "" && (i = index($0, "/findings/")) > 0) fu[last] = substr($0, i + 10, 36)
      }
      END {
        print "V\t" vnum "\t" sha
        for (j = 1; j <= n; j++) {
          key = fu[j]
          if (key == "") key = "title:" ft[j]
          print "F\t" vnum "\t" fsev[j] "\t" key "\t" fk[j] "\t" ft[j]
        }
      }' "$qodo_versions/$f" >> "$parsed"
  done <<< "$(ls -A "$qodo_versions" | LC_ALL=C sort)"

  # Stage 2: each version's marked commit becomes its content digest.
  ready="$tmp/qodo-ready.txt"
  {
    while IFS=$'\t' read -r _ vnum sha; do
      digest=unknown
      if [[ -n "$sha" ]] && git cat-file -e "$sha^{commit}" 2>/dev/null; then
        digest=$(bash "$root/scripts/check-delivery.sh" --digest "$sha" "$name")
      fi
      printf 'V\t%s\t%s\n' "$vnum" "$digest"
    done < <(grep '^V' "$parsed")
    grep '^F' "$parsed" || true
  } > "$ready"

  # Stage 3: the findings, with the state of each in Qodo's latest review.
  # shellcheck disable=SC2016 # awk program, not the shell
  "$awk" -F'\t' '
    function code(s) { return "`" s "`" }
    $1 == "V" { nv = $2 + 0; vd[nv] = $3; next }
    $1 == "F" {
      key = $4
      if (!(key in ft)) { order[++no] = key; ft[key] = $6; fsev[key] = $3; fkind[key] = $5 }
      lastv[key] = $2 + 0
      d = vd[$2 + 0]
      if (index(ds[key], "|" d "|") == 0) {
        ds[key] = ds[key] "|" d "|"
        dl[key] = dl[key] (dl[key] == "" ? "" : ", ") code(d)
      }
      next
    }
    END {
      list = ""
      for (i = 1; i <= nv; i++) {
        if (index(all, "|" vd[i] "|") == 0) {
          all = all "|" vd[i] "|"
          list = list (list == "" ? "" : ", ") code(vd[i])
        }
      }
      printf "Qodo reviewed these contents (by content digest): %s. Its latest review is content %s.\n\n", list, code(vd[nv])
      if (no == 0) { print "Qodo\047s latest review lists no findings."; exit }
      for (k = 1; k <= no; k++) {
        key = order[k]
        detail = ""
        if (fsev[key] != "") detail = toupper(substr(fsev[key], 1, 1)) substr(fsev[key], 2)
        if (fkind[key] != "") detail = (detail == "" ? "" : detail ", ") fkind[key]
        status = (lastv[key] == nv) ? "Open in Qodo\047s latest review." : "No longer listed by Qodo."
        printf "- %s%s. %s Reviewed in content %s.\n", ft[key], (detail == "" ? "" : " (" detail ")"), status, dl[key]
      }
    }' "$ready" > "$qodo_body"
fi

qodo_notes="$tmp/qodo-notes.md"
if section "$tmp/pr-body.md" "Qodo notes" > "$tmp/sec-qodo-notes.md" && [[ -s "$tmp/sec-qodo-notes.md" ]]; then
  labelled "$tmp/sec-qodo-notes.md" > "$qodo_notes"
else
  # shellcheck disable=SC2016 # the backticks are Markdown
  printf 'The PR description has no `## Qodo notes` section.\n' > "$qodo_notes"
fi
{
  cat "$qodo_body"
  printf '\n'
  cat "$qodo_notes"
} > "$tmp/parts/qodo"

# Hackathon: the Day line and discussion link set the discussion post.
hack="$tmp/sec-hackathon.md"
header_extra=""
if section "$tmp/pr-body.md" "Hackathon" > "$hack" && [[ -s "$hack" ]]; then
  day_line=$(head -n1 "$hack")
  day_link=$(grep -oE 'https://github.com/orgs/qodo-hackathon/discussions/[0-9]+' "$hack" | head -n1 || true)
  [[ -n "$day_link" ]] || die "## Hackathon must link the Day N discussion (https://github.com/orgs/qodo-hackathon/discussions/<n>)"
  header_extra=" · **Hackathon:** $day_line"
  # Each heading follows one blank line; the parts before it end in a newline.
  {
    printf 'For the owner to post in the day'"'"'s thread. The skill never posts to the hackathon discussions.\n\n'
    printf '````markdown\n'
    printf '## Challenge\n\n'
    cat "$hack"
    printf '\n## Project\n\n'
    printf 'Project name: lioramilbaum.com\n'
    printf 'Repository link: https://github.com/%s\n' "$repo"
    printf 'Relevant pull request or commit: %s ([delivery notes](https://github.com/%s/blob/main/%s))\n\n' "$pr_url" "$repo" "$name"
    printf '## What I completed\n\n'
    cat "$tmp/sec-why.md"
    printf '\n'
    cat "$tmp/sec-what.md"
    printf '\n## Evidence\n\n'
    cat "$tmp/parts/evidence"
    printf '\n## What I learned / what is blocked\n\n'
    cat "$qodo_body"
    printf '\n'
    cat "$tmp/sec-limitations.md"
    printf '\n## Assistance and third-party material\n\n'
    cat "$tmp/sec-assistance.md"
    printf '\n## Optional demo\n\n'
    # The post is read on a discussion, so its image uses the raw URL on main. The doc
    # keeps the relative path.
    if [[ "$changed" == yes ]]; then
      printf '![Homepage on desktop](https://raw.githubusercontent.com/%s/main/deliveries/%s/desktop.png)\n' "$repo" "$stem"
    else
      cat "$tmp/parts/screenshot"
    fi
    printf '````\n'
  } > "$tmp/parts/discussion"
else
  # shellcheck disable=SC2016 # the backticks are Markdown
  printf 'This PR has no `## Hackathon` section, so there is no discussion post.\n' > "$tmp/parts/discussion"
fi

printf '# %s\n' "$title" > "$tmp/parts/title"
printf '**PR:** [#%s](%s) · **Opened:** %s%s\n' "$pr" "$pr_url" "$date" "$header_extra" > "$tmp/parts/header"

# Fill the template: each whole-line {{key}} is replaced by that key's part.
out="$tmp/doc.md"
# shellcheck disable=SC2016 # awk program, not the shell
"$awk" -v parts="$tmp/parts" -v keys=" title header why how what evidence screenshot qodo assistance limitations discussion " '
  {
    if (substr($0, 1, 2) == "{{" && substr($0, length($0) - 1) == "}}") {
      key = substr($0, 3, length($0) - 4)
      if (index(keys, " " key " ") == 0) {
        print "error: unknown template placeholder " $0 > "/dev/stderr"
        exit 1
      }
      f = parts "/" key
      while ((getline line < f) > 0) print line
      close(f)
      next
    }
    print
  }' "$root/$template" > "$out"
printf '<!-- delivery: content=%s homepage=%s -->\n' "$D" "$H" >> "$out"

if (( check )); then
  differs=0
  if [[ "$changed" == no && -d "$png_dir" ]]; then
    echo "would remove $png_dir (the homepage did not change)" >&2
    differs=1
  fi
  if (( need_snap )); then
    echo "would capture the homepage screenshot into $png_dir" >&2
    differs=1
  fi
  if ! cmp -s "$out" "$doc" 2>/dev/null; then
    old=$doc
    [[ -f "$doc" ]] || old=/dev/null
    diff -u "$old" "$out" >&2 || true
    differs=1
  fi
  if (( differs )); then
    echo "delivery doc $name is not current; run scripts/generate-delivery.sh --pr $pr" >&2
    exit 1
  fi
  echo "$name is current (content $D, homepage $H, changed $changed)"
  exit 0
fi

if [[ "$changed" == no ]]; then
  rm -rf "$png_dir"
elif (( need_snap )); then
  capture
fi
mkdir -p "$(dirname "$doc")"
cp "$out" "$doc"
echo "wrote $name (content $D, homepage $H, changed $changed)"
