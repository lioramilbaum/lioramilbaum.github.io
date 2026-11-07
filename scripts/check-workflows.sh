#!/usr/bin/env bash
# Parses the workflow files and checks the yearly deploy schedule. Docker only, no
# network: the Ruby runs in the jekyll-build-pages image that the build step pulls,
# so it uses the same YAML library CI does. The image is amd64-only. --user keeps
# the container from writing as root; the workflows mount is read-only.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

command -v docker >/dev/null 2>&1 || { echo "error: docker not found; install Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: cannot connect to the Docker daemon; is Docker running?" >&2; exit 1; }

version=$(sed -nE 's|.*actions/jekyll-build-pages@[0-9a-f]{40} # (v[0-9]+\.[0-9]+\.[0-9]+).*|\1|p' "$root/.github/workflows/check-site.yml" | head -n1)
if [[ -z "$version" ]]; then
  echo "error: could not read jekyll-build-pages version from .github/workflows/check-site.yml" >&2
  exit 1
fi

# Ruby program run in the container. Psych reads the bare key on: as true, so both
# spellings are accepted. on: may be an event name, a list or a mapping, as GitHub
# allows; deploy-pages.yml needs a mapping for its schedule and push keys. YAML
# anchors and aliases are allowed, as in GitHub Actions.
read -r -d '' check_rb <<'RUBY' || true
require "yaml"

# Reports "FILE: reason" per problem; GITHUB_ACTIONS switches to annotations.
ci = !ENV["GITHUB_ACTIONS"].to_s.empty?
problems = 0
report = lambda do |name, reason|
  problems += 1
  if ci
    puts "::error file=.github/workflows/#{name}::#{reason}"
  else
    warn "error: #{name}: #{reason}"
  end
end

files = (Dir.glob("/w/*.yml") + Dir.glob("/w/*.yaml")).sort
abort "error: no workflow files found" if files.empty?

files.each do |path|
  name = File.basename(path)
  begin
    w = YAML.load_file(path, aliases: true)
  rescue Psych::Exception => e
    report.call(name, "does not parse (#{e.class})")
    next
  end
  on = w.is_a?(Hash) ? (w.key?(true) ? w[true] : w["on"]) : nil
  unless [Hash, Array, String].any? { |t| on.is_a?(t) } && w["jobs"].is_a?(Hash)
    report.call(name, "no on: trigger or no jobs: mapping")
    next
  end
  next unless name == "deploy-pages.yml"
  unless on.is_a?(Hash)
    report.call(name, "on: is not a mapping")
    next
  end

  schedule = Array(on["schedule"]).map { |s| s.is_a?(Hash) ? s["cron"] : nil }
  report.call(name, "schedule is not exactly cron '17 0 1 1 *'") unless schedule == ["17 0 1 1 *"]
  push = on["push"]
  report.call(name, "push trigger is not main") unless push.is_a?(Hash) && push["branches"] == ["main"]
  report.call(name, "no workflow_dispatch fallback") unless on.key?("workflow_dispatch")
end

exit 1 if problems.positive?
RUBY

docker run --rm --platform linux/amd64 --network none --user "$(id -u):$(id -g)" \
  --entrypoint ruby \
  -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
  -v "$root/.github/workflows:/w:ro" \
  "ghcr.io/actions/jekyll-build-pages:$version" \
  -ryaml -e "$check_rb"

echo "Workflow checks passed"
