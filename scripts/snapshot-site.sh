#!/usr/bin/env bash
# Screenshots a site with Playwright in Docker. Unlike build-site.sh this needs
# network access: the browser loads BASE_URL (default: the live site).
# The image pin is tracked by a regex in renovate.json; keep the
# image="...:vX.Y.Z-noble@sha256:..." line on one line.
#
# Usage: scripts/snapshot-site.sh [BASE_URL] [OUT_DIR] [QUERY]
#   QUERY is an optional query string without the leading "?" (for example
#   "snapshot=abc123-42"), appended to every captured URL to bypass CDN caches.
#   Empty by default, so local and PR usage is unchanged.
# Every URL is fetched with curl first; a non-2xx response fails the run
# instead of producing a screenshot of an error page.
set -euo pipefail

base="${1:-https://lioramilbaum.com}"
base="${base%/}"
out="${2:-_snapshots}"
query="${3:-}"
if [[ ! "$query" =~ ^[A-Za-z0-9._=-]*$ ]]; then
  echo "error: QUERY may only contain letters, digits, . _ = -" >&2
  exit 1
fi

image="mcr.microsoft.com/playwright:v1.64.1-noble@sha256:2f05f8a734509a7b3f26a912639488ee08f58a7b292d14d62271bcff9038768f"
version=${image#*:v}
version=${version%%-*}

command -v docker >/dev/null 2>&1 || { echo "error: docker not found; install Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: cannot connect to the Docker daemon; is Docker running?" >&2; exit 1; }

# name|path|width,height
specs=(
  "desktop||1280,720"
  "phone||390,844"
)

mkdir -p "$out"
out_abs=$(cd "$out" && pwd)
rm -f "$out_abs"/*.png

docker run --rm --init --ipc=host --tmpfs /tmp:rw,exec,size=1g --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/.npm \
  -e npm_config_update_notifier=false \
  -e npm_config_loglevel=error \
  --add-host=host.docker.internal:host-gateway \
  -v "$out_abs":/out \
  "$image" \
  bash -c 'set -euo pipefail; v=$1; base=$2; q=$3; shift 3; for s in "$@"; do IFS="|" read -r n p vp <<<"$s"; url="$base/$p"; if [[ -n "$q" ]]; then url="$url?$q"; fi; curl -fsSL -o /dev/null -H "Cache-Control: no-cache" "$url"; npx --yes "playwright@$v" screenshot -b chromium --full-page --color-scheme=light --viewport-size="$vp" "$url" "/out/$n.png"; done' _ "$version" "$base" "$query" "${specs[@]}"

# Fail if any expected PNG is missing or has the wrong width.
for s in "${specs[@]}"; do
  IFS="|" read -r n _ vp <<<"$s"
  want_w=${vp%,*}
  f="$out_abs/$n.png"
  if [[ ! -s "$f" ]]; then
    echo "error: $f was not written" >&2
    exit 1
  fi
  sig=$(od -An -tx1 -N8 "$f" | tr -d ' \n')
  if [[ "$sig" != "89504e470d0a1a0a" ]]; then
    echo "error: $f is not a PNG" >&2
    exit 1
  fi
  # IHDR width is a big-endian uint32 at byte offset 16 (BSD od has no --endian).
  read -r -a dims <<<"$(od -An -tu1 -j16 -N4 "$f")"
  w=$(( (dims[0] << 24) | (dims[1] << 16) | (dims[2] << 8) | dims[3] ))
  if [[ "$w" != "$want_w" ]]; then
    echo "error: $f is ${w}px wide, expected ${want_w}px" >&2
    exit 1
  fi
  echo "$f (${w}px)"
done
