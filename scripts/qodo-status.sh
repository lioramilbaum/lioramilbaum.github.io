#!/usr/bin/env bash
# AGENTS.md rule 9: reports whether Qodo's latest review of a PR names the PR head, whether it
# has settled, and how many findings it lists. The delivery-doc skill polls it instead of
# reading Qodo's comment by hand, and scripts/qodo-gate.sh turns its output into a commit
# status. gh only reads; --fetch adds git objects to this clone and nothing else.
#
# Usage: scripts/qodo-status.sh --pr N [--quiet-minutes M] [--fetch REMOTE]
#   --quiet-minutes M  the review comment must be unedited for M minutes (default 5, the
#                      skill's quiet period: Qodo often posts a review in two passes).
#   --fetch REMOTE     a commit this clone lacks is fetched by SHA from REMOTE (git fetch
#                      --depth=1). Without it, a missing commit is an error (exit 1), except
#                      that a reviewed commit a fetch cannot get counts as other content.
#
# Output: key: value lines, then "status:". The exit code is the status:
#   0 settled     the review names the head (same commit or same content) and is quiet
#   2 waiting     it names the head, but its comment changed less than M minutes ago
#   3 stale       the latest review is of other content
#   4 no-review   there is no Qodo review comment, or it names no commit
#   1 error       usage errors, gh failures, or the head, or a commit the review names, that
#                 is not in this clone and could not be fetched (its content cannot be
#                 compared with the head's)
#
# open: how many findings Qodo's latest review lists, read by scripts/qodo-review.awk (the
# layout parser, AGENTS.md rule 9): a number, 0 when the review is clear, unknown when its
# layout is one the parser does not know, none when there is no review.
#
# The review is the latest comment by qodo-code-review or qodo-code-review[bot] (exact logins),
# whose body contains "Code Review by Qodo". It names the commit it reviewed in its marker
# (<!-- .../commit/<sha> -->). The same commit as the head: matches-head yes.
# Otherwise the two commits' content digests are compared (scripts/check-delivery.sh
# --digest, which leaves out the delivery doc), so an amend that only adds the doc still
# matches: matches-head digest. The quiet time runs from the comment's lastEditedAt, or
# its createdAt if it was never edited.
#
# Test hooks: QODO_STATUS_NOW (ISO UTC, YYYY-MM-DDTHH:MM:SSZ) replaces the clock. gh is
# found on PATH.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
repo=lioramilbaum/lioramilbaum.github.io
awk=${AWK:-awk}
pr=""
quiet_minutes=5
fetch=""
usage() {
  echo "usage: scripts/qodo-status.sh --pr N [--quiet-minutes M] [--fetch REMOTE]" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage; pr=$2; shift ;;
    --quiet-minutes) [ $# -ge 2 ] || usage; quiet_minutes=$2; shift ;;
    --fetch) [ $# -ge 2 ] && [ -n "$2" ] || usage; fetch=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ && "$quiet_minutes" =~ ^[0-9]+$ ]] || usage

die() { echo "error: $*" >&2; exit 1; }

# epoch_of ISO: sets EPOCH to the seconds since 1970-01-01T00:00:00Z. The calendar sum is
# done here, so GNU and BSD date need not agree.
EPOCH=0
epoch_of() {
  [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] \
    || die "not an ISO time (YYYY-MM-DDTHH:MM:SSZ): $1"
  local y=$((10#${BASH_REMATCH[1]})) mo=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local h=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) s=$((10#${BASH_REMATCH[6]}))
  # Days from civil (Howard Hinnant's algorithm): the year starts in March, so January and
  # February belong to the year before.
  y=$((y - (mo <= 2)))
  local era=$((y / 400)) yoe=$((y % 400)) doy doe
  doy=$(((153 * ((mo + 9) % 12) + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  EPOCH=$(((era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s))
}

now=${QODO_STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
epoch_of "$now"
now_epoch=$EPOCH

pr_field() { gh pr view "$pr" --repo "$repo" --json "$1" --jq ".$1" || die "could not read PR $pr with gh"; }
head_sha=$(pr_field headRefOid)
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || die "PR $pr head is not a commit SHA: $head_sha"
created=$(pr_field createdAt)
ref=$(pr_field headRefName)

# The doc the generator names: the PR open date (UTC) and the branch without its type prefix.
doc="deliveries/${created%%T*}-${ref#*/}.md"

# Comments are read as the generator reads them: paged, one scalar line per record, with
# "|" as the separator (a non-whitespace IFS keeps empty fields).
# shellcheck disable=SC2016 # GraphQL variables, not the shell
comments_query='query($owner: String!, $name: String!, $n: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { url createdAt lastEditedAt body author { login } }
      }
    }
  }
}'
# The author allowlist must match generate-delivery.sh's comments_jq: a lookalike login such
# as qodo-code-review-fake is not Qodo's review (test qs20).
# shellcheck disable=SC2016 # jq program, not the shell
comments_jq='.data.repository.pullRequest.comments as $c
  | "PAGE|\($c.pageInfo.hasNextPage)|\($c.pageInfo.endCursor // "")",
    ($c.nodes[]
      | select((.author.login == "qodo-code-review" or .author.login == "qodo-code-review[bot]") and (.body | contains("Code Review by Qodo")))
      | "QCOMMENT|\(.url)|\(.createdAt)|\(.lastEditedAt // "")|\((.body | match("/commit/([0-9a-f]{40}) -->") | .captures[0].string) // "")|\(.body | @base64)")'

# The body is base64, so no text in it can read as a field (qodo-review.awk parses it).
qodo_url=""; qodo_at=""; qodo_edited=""; qodo_sha=""; qodo_body64=""
after=""; has=true
while [[ "$has" == true ]]; do
  after_args=()
  if [[ -n "$after" ]]; then after_args=(-f after="$after"); fi
  page=$(gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -F n="$pr" \
    ${after_args[@]+"${after_args[@]}"} -f query="$comments_query" --jq "$comments_jq") \
    || die "could not read Qodo's review comments on PR $pr with gh"
  has=false; cursor=""
  while IFS='|' read -r rec a b c d e; do
    case "$rec" in
      PAGE) has=$a; cursor=$b ;;
      QCOMMENT)
        # The latest one counts. The times are ISO UTC, so they sort as strings. On an exact
        # tie the comment listed later wins (test qs15).
        if [[ -z "$qodo_at" || ! "$b" < "$qodo_at" ]]; then
          qodo_url=$a; qodo_at=$b; qodo_edited=$c; qodo_sha=$d; qodo_body64=$e
        fi
        ;;
    esac
  done <<< "$page"
  after=$cursor
done

# have_commit SHA: the commit is in this clone.
have_commit() { git cat-file -e "$1^{commit}" 2>/dev/null; }
# Callers pass only validated 40-hex SHAs: the head check and the marker regex.
# fetch_commit SHA: with --fetch, fetches the commit by SHA from the remote (one commit, no
# history) and reports whether it is then in this clone. Without --fetch it fails.
fetch_commit() {
  [[ -n "$fetch" ]] || return 1
  git fetch --no-tags --quiet --depth=1 -- "$fetch" "$1" 2>/dev/null || true
  have_commit "$1"
}
digest_of() { bash "$root/scripts/check-delivery.sh" --digest "$1" "$doc"; }

open=none
if [[ -z "$qodo_at" ]]; then
  review=none; reviewed=none; matches=no; last=none; quiet_line="no (no review)"; status=no-review
else
  review=$qodo_url
  last=${qodo_edited:-$qodo_at}
  epoch_of "$last"
  age=$((now_epoch - EPOCH))
  need=$((10#$quiet_minutes * 60))
  quiet=no
  if (( age >= need )); then quiet=yes; fi
  # A change time ahead of the clock (skew) is shown as 0s; the comparison above keeps the sign.
  shown_age=$age
  if (( shown_age < 0 )); then shown_age=0; fi
  quiet_line="$quiet (${shown_age}s since last change, need ${need}s)"

  # The findings the review lists: one review, so qodo-review.awk's version is 1. Distinct keys
  # count once; a clear review with no finding counts 0; a layout the parser does not know is
  # unknown (AGENTS.md rule 9).
  qbody=$(mktemp "${TMPDIR:-/tmp}/qodo-status.XXXXXX")
  trap 'rm -f "$qbody"' EXIT
  printf '%s' "$qodo_body64" | base64 --decode > "$qbody"
  # shellcheck disable=SC2016 # awk program, not the shell
  open=$("$awk" -v vnum=1 -f "$root/scripts/qodo-review.awk" "$qbody" \
    | "$awk" -F'\t' '
        $1 == "F" && !($4 in seen) { seen[$4] = 1; n++ }
        $1 == "C" { cl = 1 }
        END { if (n > 0) print n; else if (cl) print 0; else print "unknown" }')

  reviewed=none; matches=no; status=no-review
  if [[ -n "$qodo_sha" ]]; then
    reviewed=$qodo_sha
    if [[ "$reviewed" == "$head_sha" ]]; then
      matches=yes
    else
      have_commit "$head_sha" || fetch_commit "$head_sha" \
        || die "commit $head_sha is not in this clone; fetch it and run again"
      if have_commit "$reviewed" || fetch_commit "$reviewed"; then
        reviewed_digest=$(digest_of "$reviewed") || die "could not compute the content digest of $reviewed"
        head_digest=$(digest_of "$head_sha") || die "could not compute the content digest of $head_sha"
        [[ -n "$reviewed_digest" && -n "$head_digest" ]] || die "the content digest of $reviewed or $head_sha is empty"
        if [[ "$reviewed_digest" == "$head_digest" ]]; then matches=digest; fi
      elif [[ -n "$fetch" ]]; then
        echo "note: the reviewed commit $reviewed could not be fetched from $fetch; it counts as other content" >&2
      else
        die "commit $reviewed is not in this clone; fetch it and run again"
      fi
    fi
    case "$matches:$quiet" in
      no:*) status=stale ;;
      *:yes) status=settled ;;
      *) status=waiting ;;
    esac
  fi
fi

printf 'head: %s\n' "$head_sha"
printf 'review: %s\n' "$review"
printf 'reviewed: %s\n' "$reviewed"
printf 'matches-head: %s\n' "$matches"
printf 'last-change: %s\n' "$last"
printf 'quiet: %s\n' "$quiet_line"
printf 'open: %s\n' "$open"
printf 'status: %s\n' "$status"
case "$status" in
  settled) exit 0 ;;
  waiting) exit 2 ;;
  stale) exit 3 ;;
  no-review) exit 4 ;;
esac
