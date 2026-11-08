#!/usr/bin/env bash
# Parses the workflow files, checks the yearly deploy schedule, and checks who may write
# statuses or run on pull_request_target (AGENTS.md rule 5): only qodo-findings.yml, whose
# triggers and permissions are pinned here. Docker only, no network: the Ruby runs in the
# jekyll-build-pages image that the build step pulls, so it uses the same YAML library CI
# does. The image is amd64-only. --user keeps the container from writing as root; the
# workflows mount is read-only.
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
report.call("qodo-findings.yml", "is missing; the qodo-findings status is not set") unless files.any? { |f| File.basename(f) == "qodo-findings.yml" }

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

  # qodo-findings.yml is the only workflow that may write statuses or run on
  # pull_request_target (AGENTS.md rule 5). Its triggers, permissions and steps are pinned
  # here; every other file must not request either.
  jobs = w["jobs"]
  if name == "qodo-findings.yml"
    report.call(name, "top-level permissions are not exactly contents, issues, pull-requests read and statuses write") unless w["permissions"] == { "contents" => "read", "issues" => "read", "pull-requests" => "read", "statuses" => "write" }
    report.call(name, "on: is not exactly issue_comment, pull_request_target and workflow_dispatch") unless on.is_a?(Hash) && on.keys.sort == ["issue_comment", "pull_request_target", "workflow_dispatch"]
    if on.is_a?(Hash)
      report.call(name, "issue_comment types are not created, edited, deleted") unless on["issue_comment"].is_a?(Hash) && on["issue_comment"]["types"] == ["created", "edited", "deleted"]
      prt = on["pull_request_target"].is_a?(Hash) ? on["pull_request_target"] : {}
      report.call(name, "pull_request_target branches are not main") unless prt["branches"] == ["main"]
      report.call(name, "pull_request_target types lack opened, synchronize, reopened, ready_for_review or converted_to_draft") unless (["opened", "synchronize", "reopened", "ready_for_review", "converted_to_draft"] - Array(prt["types"])).empty?
      dispatch = on["workflow_dispatch"].is_a?(Hash) ? on["workflow_dispatch"] : {}
      report.call(name, "workflow_dispatch has no pr input") unless dispatch["inputs"].is_a?(Hash) && dispatch["inputs"].key?("pr")
    end
    report.call(name, "has a workflow-level env or defaults; the gate sets its env in its one step") if w.key?("env") || w.key?("defaults")
    conc = w["concurrency"].is_a?(Hash) ? w["concurrency"] : {}
    report.call(name, "concurrency.cancel-in-progress is not true") unless conc["cancel-in-progress"] == true
    group = conc["group"].to_s
    report.call(name, "concurrency.group does not name the issue, pull request and dispatch PR numbers") unless ["github.event.issue.number", "github.event.pull_request.number", "inputs.pr"].all? { |e| group.include?(e) }
    report.call(name, "does not have exactly one job") unless jobs.size == 1
    jobs.each do |jid, job|
      next report.call(name, "job #{jid} is not a mapping") unless job.is_a?(Hash)
      report.call(name, "job #{jid} runs-on is not ubuntu-26.04") unless job["runs-on"] == "ubuntu-26.04"
      report.call(name, "job #{jid} has its own permissions") if job.key?("permissions")
      (job.keys - ["if", "runs-on", "timeout-minutes", "steps"]).each do |key|
        report.call(name, "job #{jid} has key #{key}; only if, runs-on, timeout-minutes and steps are allowed")
      end
      job_if = job["if"].to_s
      report.call(name, "job #{jid} if does not guard the repository and PR comments") unless job_if.include?("github.repository == 'lioramilbaum/lioramilbaum.github.io'") && job_if.include?("github.event.issue.pull_request")
      steps = Array(job["steps"])
      checkout = steps[0].is_a?(Hash) ? steps[0] : {}
      run_step = steps[1].is_a?(Hash) ? steps[1] : {}
      report.call(name, "job #{jid} does not have exactly two steps: checkout, then run") unless steps.size == 2 && checkout["uses"].to_s.start_with?("actions/checkout@") && run_step.key?("run") && !run_step.key?("uses")
      report.call(name, "job #{jid} run step is not the pinned qodo-gate.sh command") unless run_step["run"].to_s.strip == 'bash scripts/qodo-gate.sh --pr "$PR" --fetch origin'
      report.call(name, "job #{jid} run step env is not exactly GH_TOKEN and PR") unless run_step["env"].is_a?(Hash) && run_step["env"].keys.sort == ["GH_TOKEN", "PR"]
      Array(job["steps"]).each do |step|
        next unless step.is_a?(Hash)
        uses = step["uses"].to_s
        if step.key?("uses") && !uses.start_with?("actions/checkout@")
          report.call(name, "job #{jid} uses #{uses}; only actions/checkout is allowed")
        end
        if uses.start_with?("actions/checkout@")
          with = step["with"].is_a?(Hash) ? step["with"] : {}
          report.call(name, "job #{jid} checkout sets ref or repository") if with.key?("ref") || with.key?("repository")
          report.call(name, "job #{jid} checkout does not set persist-credentials: false") unless with["persist-credentials"] == false
        end
        report.call(name, "job #{jid} has a run: with an expression; pass it through env:") if step["run"].to_s.include?("${{")
      end
    end
  else
    # Every other workflow: no status writes (workflow or job level) and no pull_request_target.
    scopes = [w["permissions"]] + jobs.values.map { |j| j.is_a?(Hash) ? j["permissions"] : nil }
    if scopes.any? { |p| p == "write-all" || (p.is_a?(Hash) && p["statuses"] == "write") }
      report.call(name, "requests statuses: write or write-all; only qodo-findings.yml may")
    end
    triggers = on.is_a?(Hash) ? on.keys : Array(on)
    report.call(name, "runs on pull_request_target; only qodo-findings.yml may") if triggers.include?("pull_request_target")
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
