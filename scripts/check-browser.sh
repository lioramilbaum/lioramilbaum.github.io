#!/usr/bin/env bash
# Browser check of the hackathon page (AGENTS.md rule 8): JavaScript off, no off-site
# requests, one LinkedIn share link with the exact href and text, its contrast in
# light and dark mode, and the computed styles of the share block. Playwright runs in
# the image pinned in snapshot-site.sh. Its npm package comes from
# scripts/check-browser/package-lock.json (npm ci, so the tarballs are pinned by
# lockfile integrity), and the lockfile's version must match the image's. The site is
# served from inside the container on 127.0.0.1, so this works on native Linux Docker,
# where the host-gateway path that snapshot-site.sh uses does not. Needs Docker and
# network (npm). Build the site first.
#
# Usage: scripts/check-browser.sh [SITE]   (default: _site)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
site="${1:-_site}"

# Setup errors are annotated on this script.
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=scripts/check-browser.sh::$1"
  else
    echo "error: $1" >&2
  fi
  exit 1
}

test -f "$site/docs/qodo-software-factory-hackathon/index.html" \
  || fail "hackathon page not built under $site; run scripts/build-site.sh first"
site_abs=$(cd "$site" && pwd)

image=$(sed -nE 's/^image="(mcr\.microsoft\.com\/playwright:[^"]+)"$/\1/p' "$root/scripts/snapshot-site.sh")
[[ -n "$image" ]] || fail "could not read the Playwright image from scripts/snapshot-site.sh"
version=${image#*:v}
version=${version%%-*}

pw_abs="$root/scripts/check-browser"
test -f "$pw_abs/package.json" && test -f "$pw_abs/package-lock.json" \
  || fail "scripts/check-browser/ must hold package.json and package-lock.json"

command -v docker >/dev/null 2>&1 || fail "docker not found; install Docker"
docker info >/dev/null 2>&1 || fail "cannot connect to the Docker daemon; is Docker running?"

# Node program run in the container. It uses the Playwright library that matches
# the image. GITHUB_ACTIONS (empty when unset) switches output to annotations.
read -r -d '' check_js <<'JS' || true
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

// Files problems are reported on, as annotations. Paths are relative to the repo root.
const pageFile = 'docs/qodo-software-factory-hackathon.md';
const layoutFile = '_layouts/docs.html';
const scriptFile = 'scripts/check-browser.sh';

// The built site, mounted read-only at /site. Nothing outside it is served.
const root = '/site';
const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
};
const pagePath = '/docs/qodo-software-factory-hackathon/';
const shareHref = 'https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Flioramilbaum.com%2Fdocs%2Fqodo-software-factory-hackathon%2F';
const ci = !!process.env.GITHUB_ACTIONS;
const problems = [];
const problem = (msg, file) => problems.push({ msg, file });
const need = (ok, msg, file = layoutFile) => {
  if (!ok) problem(msg, file);
};

const server = http.createServer((req, res) => {
  let file = null;
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    file = path.normalize(path.join(root, pathname));
  } catch (err) {
    file = null;
  }
  if (!file || (file !== root && !file.startsWith(root + path.sep))) {
    res.writeHead(404).end();
    return;
  }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) {
    file = path.join(file, 'index.html');
  }
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
});

// A fresh context with JavaScript off. Any request to another origin is aborted.
async function withPage(browser, origin, colorScheme, fn) {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    viewport: { width: 1280, height: 720 },
    colorScheme,
  });
  try {
    await context.route('**/*', (route) => {
      const target = route.request().url();
      if (new URL(target).origin === origin) return route.continue();
      problem(`off-site request: ${target}`, pageFile);
      return route.abort();
    });
    await fn(await context.newPage());
  } finally {
    await context.close();
  }
}

async function pageChecks(browser, origin) {
  await withPage(browser, origin, 'light', async (page) => {
    const resp = await page.goto(origin + pagePath, { waitUntil: 'load' });
    if (!resp) problem(`did not load: no response for ${pagePath}`, pageFile);
    else if (!resp.ok()) problem(`did not load: HTTP ${resp.status()}`, pageFile);

    if ((await page.locator('script').count()) !== 0) problem('hackathon page has a <script>', pageFile);

    const share = page.locator('a[href*="share-offsite"]');
    const shares = await share.count();
    if (shares !== 1) {
      problem(`share link missing: expected one a[href*="share-offsite"], found ${shares}`, layoutFile);
      return;
    }
    const href = await share.getAttribute('href');
    if (href !== shareHref) problem(`share href is not ${shareHref} (got ${href})`, layoutFile);
    if (!(await share.isVisible())) problem('share link is not visible', layoutFile);
    const text = (await share.innerText()).trim();
    if (text !== 'Share on LinkedIn') problem(`share link text is "${text}", not "Share on LinkedIn"`, layoutFile);
  });
}

// Parses a computed colour such as rgb(0, 0, 0) or rgba(0, 0, 0, 0.5).
const parse = (s) => {
  const m = /^rgba?\((.*)\)$/.exec(s.trim());
  if (!m) throw new Error(`cannot parse colour: ${s}`);
  const v = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
  return { r: v[0], g: v[1], b: v[2], a: v.length > 3 ? v[3] : 1 };
};

// WCAG relative luminance and contrast ratio.
const luminance = (c) => {
  const lin = (v) => {
    const x = v / 255;
    return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
};

async function contrastCheck(browser, origin, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + pagePath, { waitUntil: 'load' });
    const share = page.locator('a[href*="share-offsite"]');
    if ((await share.count()) !== 1) return;  // pageChecks reports the missing link
    const styles = await share.evaluate((el) => {
      const backgrounds = [];
      for (let n = el; n; n = n.parentElement) backgrounds.push(getComputedStyle(n).backgroundColor);
      return { color: getComputedStyle(el).color, backgrounds };
    });

    const fg = parse(styles.color);
    let translucent = fg.a > 0 && fg.a < 1;
    // The first opaque background, nearest first. Transparent layers are skipped.
    // No opaque one means the page is white.
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    for (const s of styles.backgrounds) {
      const c = parse(s);
      if (c.a === 0) continue;
      if (c.a < 1) {
        translucent = true;
        continue;
      }
      bg = c;
      break;
    }
    if (translucent) {
      problem(`cannot check contrast: translucent colour in ${scheme} mode`, layoutFile);
      return;
    }

    const hi = Math.max(luminance(fg), luminance(bg));
    const lo = Math.min(luminance(fg), luminance(bg));
    const ratio = (hi + 0.05) / (lo + 0.05);
    if (ratio < 4.5) {
      problem(`share link contrast below 4.5:1 in ${scheme} mode: ${ratio.toFixed(2)} (${styles.color} on rgb(${bg.r}, ${bg.g}, ${bg.b}))`, layoutFile);
    }
  });
}

// Computed styles of the share block in _layouts/docs.html. Every declaration in the
// block is checked through its computed value, so a removed or changed rule fails.
async function shareStyleChecks(browser, origin, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + pagePath, { waitUntil: 'load' });
    const share = page.locator('a[href*="share-offsite"]');
    if ((await share.count()) !== 1) return;  // pageChecks reports the missing link
    const para = page.locator('p.share');
    const svg = share.locator('svg');
    const computed = (loc, names) => loc.evaluate((el, props) => {
      const cs = getComputedStyle(el);
      return Object.fromEntries(props.map((p) => [p, cs[p]]));
    }, names);
    const expected = scheme === 'dark' ? 'rgb(88, 166, 255)' : 'rgb(3, 102, 214)';

    const a = await computed(share, [
      'display', 'alignItems', 'columnGap', 'rowGap', 'paddingTop', 'paddingLeft',
      'borderTopWidth', 'borderTopStyle', 'borderTopColor', 'borderTopLeftRadius',
      'fontWeight', 'textDecorationLine', 'color',
    ]);
    need(a.display === 'inline-flex', `share link display is "${a.display}", not inline-flex (.share a)`);
    need(a.alignItems === 'center', `share link align-items is "${a.alignItems}", not center (.share a)`);
    need(parseFloat(a.columnGap) > 0, `share link column-gap is "${a.columnGap}", not above 0 (.share a gap)`);
    need(parseFloat(a.rowGap) > 0, `share link row-gap is "${a.rowGap}", not above 0 (.share a gap)`);
    need(parseFloat(a.paddingTop) > 0, `share link padding-top is "${a.paddingTop}", not above 0 (.share a padding)`);
    need(parseFloat(a.paddingLeft) > 0, `share link padding-left is "${a.paddingLeft}", not above 0 (.share a padding)`);
    need(parseFloat(a.borderTopWidth) > 0 && a.borderTopStyle === 'solid',
      `share link border is ${a.borderTopWidth} ${a.borderTopStyle}, not a solid border above 0 (.share a border)`);
    need(a.borderTopColor === a.color,
      `share link border colour is ${a.borderTopColor}, not the link colour ${a.color} (.share a border currentColor)`);
    need(parseFloat(a.borderTopLeftRadius) > 0, `share link border-radius is "${a.borderTopLeftRadius}", not above 0 (.share a)`);
    need(parseInt(a.fontWeight, 10) >= 600, `share link font-weight is "${a.fontWeight}", not at least 600 (.share a)`);
    need(a.color === expected, `share link colour is ${a.color} in ${scheme} mode, not ${expected} (.share a)`);
    need(a.textDecorationLine === 'none',
      `share link text-decoration-line at rest is "${a.textDecorationLine}", not none (.share a)`);

    if ((await para.count()) !== 1) {
      problem('share paragraph p.share is missing', layoutFile);
    } else {
      const p = await computed(para, ['marginTop']);
      need(parseFloat(p.marginTop) > 0, `share paragraph margin-top is "${p.marginTop}", not above 0 (.share)`);
    }

    if ((await svg.count()) !== 1) {
      problem('share icon svg is missing', layoutFile);
    } else {
      const box = await svg.boundingBox();
      const size = box ? `${box.width}x${box.height}` : 'no box';
      need(!!box && box.width > 0 && box.height > 0 && box.width <= 24 && box.height <= 24,
        `share icon is ${size} CSS px, not above 0 and at most 24x24 (.share svg)`);
      const s = await computed(svg, ['fill']);
      need(s.fill === a.color, `share icon fill is ${s.fill}, not the link colour ${a.color} (.share svg currentColor)`);
    }

    // Hover: .share a:hover underlines the link.
    await share.hover();
    const hover = await computed(share, ['textDecorationLine']);
    need(hover.textDecorationLine === 'underline',
      `share link text-decoration-line on hover is "${hover.textDecorationLine}", not underline (.share a:hover)`);
    await page.mouse.move(0, 0);

    // Keyboard focus: Tab from the top of the page, through the body's links, until the
    // share link has focus. Tab focus is what :focus-visible is for; locator.focus() also
    // matched it in a probe on Chromium, so this is the stricter of the two.
    let focused = false;
    for (let i = 0; i < 50 && !focused; i++) {
      await page.keyboard.press('Tab');
      focused = await share.evaluate((el) => el === document.activeElement);
    }
    if (!focused) {
      problem('share link cannot be reached with Tab', layoutFile);
    } else {
      need(await share.evaluate((el) => el.matches(':focus-visible')),
        'share link is focused but :focus-visible does not match (.share a:focus-visible)');
      const focus = await computed(share, ['textDecorationLine']);
      need(focus.textDecorationLine === 'underline',
        `share link text-decoration-line on keyboard focus is "${focus.textDecorationLine}", not underline (.share a:focus-visible)`);
    }
  });
}

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  try {
    await pageChecks(browser, origin);
    await contrastCheck(browser, origin, 'light');
    await contrastCheck(browser, origin, 'dark');
    await shareStyleChecks(browser, origin, 'light');
    await shareStyleChecks(browser, origin, 'dark');
  } finally {
    await browser.close();
    server.close();
  }

  const seen = new Map();
  for (const p of problems) seen.set(`${p.file}|${p.msg}`, p);
  for (const { msg, file } of seen.values()) {
    if (ci) console.log(`::error file=${file}::${msg}`);
    else console.error(`error: ${msg}`);
  }
  if (seen.size) process.exitCode = 1;
  else console.log('ok docs/qodo-software-factory-hackathon/');
})().catch((err) => {
  if (ci) console.log(`::error file=${scriptFile}::${err.message}`);
  else console.error(`error: ${err.message}`);
  process.exitCode = 1;
});
JS

# Node program run in the container before npm ci. The image tag, package.json, and the
# lockfile's playwright and playwright-core must name the same version. argv: the image's version.
read -r -d '' lock_js <<'JS' || true
const fs = require('fs');
const want = process.argv[1];
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const pinned = pkg.dependencies && pkg.dependencies.playwright;
const locked = lock.packages && lock.packages['node_modules/playwright'] && lock.packages['node_modules/playwright'].version;
const lockedCore = lock.packages && lock.packages['node_modules/playwright-core'] && lock.packages['node_modules/playwright-core'].version;
const bad = [];
if (pinned !== want) bad.push(`scripts/check-browser/package.json pins playwright ${pinned}`);
if (locked !== want) bad.push(`package-lock.json pins playwright ${locked}`);
if (lockedCore !== want) bad.push(`package-lock.json pins playwright-core ${lockedCore}`);
if (bad.length) {
  const msg = `Playwright version mismatch: the image is v${want}, but ${bad.join(', and ')}. Set all of them to ${want}.`;
  if (process.env.GITHUB_ACTIONS) console.log(`::error file=scripts/check-browser.sh::${msg}`);
  else console.error(`error: ${msg}`);
  process.exit(1);
}
JS

docker run --rm --init --ipc=host --tmpfs /tmp:rw,exec,size=1g --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/.npm \
  -e npm_config_update_notifier=false \
  -e npm_config_loglevel=error \
  -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
  -v "$site_abs":/site:ro \
  -v "$pw_abs":/pw:ro \
  "$image" \
  bash -c 'set -euo pipefail; v=$1; js=$2; lock_js=$3; mkdir /tmp/pw; cp /pw/package.json /pw/package-lock.json /tmp/pw/; cd /tmp/pw; node -e "$lock_js" "$v"; npm ci --ignore-scripts --no-audit --no-fund; NODE_PATH=/tmp/pw/node_modules node -e "$js"' _ "$version" "$check_js" "$lock_js"
