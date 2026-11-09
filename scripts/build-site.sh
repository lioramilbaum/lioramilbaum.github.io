#!/usr/bin/env bash
# Docker only; no GitHub token or network needed. The image tag mirrors the
# jekyll-build-pages action pinned in CI, and the image is amd64-only. --user
# keeps _site owned by the caller.
#
# Usage: scripts/build-site.sh [SITE_DIR]
# SITE_DIR (default: this checkout) is built into its own _site. The image tag is read from this
# script's checkout, so the agent runner (scripts/agent-run.sh) builds a PR's clone with main's copy.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
cd "${1:-$here}"

command -v docker >/dev/null 2>&1 || { echo "error: docker not found; install Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: cannot connect to the Docker daemon; is Docker running?" >&2; exit 1; }

version=$(sed -nE 's|.*actions/jekyll-build-pages@[0-9a-f]{40} # (v[0-9]+\.[0-9]+\.[0-9]+).*|\1|p' "$here/.github/workflows/check-site.yml" | head -n1)
if [[ -z "$version" ]]; then
  echo "error: could not read jekyll-build-pages version from .github/workflows/check-site.yml" >&2
  exit 1
fi

rm -rf _site || { echo "error: could not remove _site (left by an earlier root-owned build?); run: sudo rm -rf _site" >&2; exit 1; }

docker run --rm --platform linux/amd64 --network none --user "$(id -u):$(id -g)" \
  -v "$PWD":/github/workspace \
  -e GITHUB_WORKSPACE=/github/workspace \
  -e INPUT_SOURCE=. \
  -e INPUT_DESTINATION=_site \
  -e INPUT_VERBOSE=false \
  -e INPUT_FUTURE=false \
  "ghcr.io/actions/jekyll-build-pages:$version"
