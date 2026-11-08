#!/usr/bin/env bash
# Screenshots a site's homepage at 1280 px with Playwright in Docker. Unlike
# build-site.sh this needs network access: the browser loads BASE_URL (default:
# the live site). The image pin is tracked by a regex in renovate.json; keep the
# image="...:vX.Y.Z-noble@sha256:..." line on one line.
#
# Usage: scripts/snapshot-site.sh [BASE_URL] [OUT_DIR]
# The screenshot is taken by the Playwright library, which requires Playwright's
# own response for the page to be 2xx before it captures, so the screenshot is
# always of the response that was checked. A non-2xx response (404 included)
# fails the run and leaves no PNG. The Playwright npm package is installed in the
# container by exact version, with --ignore-scripts. Unlike the image, that
# tarball is not pinned by digest.
set -euo pipefail

base="${1:-https://lioramilbaum.com}"
base="${base%/}"
out="${2:-_snapshots}"

image="mcr.microsoft.com/playwright:v1.65.0-noble@sha256:6e3fb709361521eb27161606e6da6d2674e5e89fa16516cb37d6fdd91372273d"
version=${image#*:v}
version=${version%%-*}

command -v docker >/dev/null 2>&1 || { echo "error: docker not found; install Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: cannot connect to the Docker daemon; is Docker running?" >&2; exit 1; }

mkdir -p "$out"
out_abs=$(cd "$out" && pwd)
rm -f "$out_abs"/*.png
# A run that fails at any point leaves no PNG behind, so a partial result can never
# be mistaken for a complete one.
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then rm -f "$out_abs"/*.png; fi
  exit "$rc"
}
trap cleanup EXIT

# Node program run in the container. It uses the Playwright library that matches
# the image, so it can read the response for the page it screenshots.
read -r -d '' shot_js <<'JS' || true
const { chromium } = require('playwright');

// argv: BASE_URL.
(async () => {
  const [base] = process.argv.slice(1);
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      deviceScaleFactor: 1,
      colorScheme: 'light',
    });
    try {
      const page = await context.newPage();
      const resp = await page.goto(`${base}/`, { waitUntil: 'load' });
      if (!resp) throw new Error(`no response for ${base}/`);
      if (!resp.ok()) throw new Error(`${base}/ returned HTTP ${resp.status()} to the browser`);
      await page.screenshot({ path: '/out/desktop.png', fullPage: true });
    } finally {
      await context.close();
    }
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error(`error: ${err.message}`);
  process.exit(1);
});
JS

docker run --rm --init --ipc=host --tmpfs /tmp:rw,exec,size=1g --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/.npm \
  -e npm_config_update_notifier=false \
  -e npm_config_loglevel=error \
  --add-host=host.docker.internal:host-gateway \
  -v "$out_abs":/out \
  "$image" \
  bash -c 'set -euo pipefail; v=$1; base=$2; js=$3; npm install --no-save --no-audit --no-fund --ignore-scripts --prefix /tmp/pw "playwright@$v" >/dev/null; NODE_PATH=/tmp/pw/node_modules node -e "$js" "$base"' _ "$version" "$base" "$shot_js"

# Fail if the PNG is missing, is not a PNG, or is not 1280 px wide.
f="$out_abs/desktop.png"
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
if [[ "$w" != 1280 ]]; then
  echo "error: $f is ${w}px wide, expected 1280px" >&2
  exit 1
fi
echo "$f (${w}px)"
