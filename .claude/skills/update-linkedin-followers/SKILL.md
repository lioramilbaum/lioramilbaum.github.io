---
name: update-linkedin-followers
description: Updates the homepage's LinkedIn followers line (_data/linkedin.yml) from a count the owner gives, setting the as-of date to the day of the update (or a date the owner names), then builds the site, runs the checks, confirms the rendered line matches the input exactly, proves the check still fails on an invalid value, and opens a PR from a branch off upstream main when all of that passes. Use when the owner gives a new LinkedIn followers count, or asks to update or refresh the followers count on lioramilbaum.com.
---

# Update the LinkedIn followers count

The homepage shows one line under the social links, `N LinkedIn followers · as of <date>`, built from `_data/linkedin.yml` (AGENTS.md rule 3). This skill changes the two values in that file, proves the result, and on a clean run opens a PR for it (step 7). The branch is made from `upstream/main` before any edit, so the build and checks test the tree the PR will contain. Run every command from the repository root. The checks need Docker (the build image is amd64-only; on Apple Silicon it runs under emulation) and python3. Network is needed for step 2 (the fetch and `ls-remote`) and step 7 (the push and `gh`); step 7 also needs git with the `origin` (the fork) and `upstream` remotes and an authenticated `gh`.

## Inputs

- **count**: the number of LinkedIn followers, from the owner.
- **as_of**: `YYYY-MM-DD`, set by the skill to today's local date (`date +%F`), unless the owner names a date in the invocation or conversation; an owner-named date is used instead and goes through the same validation.

The count comes from the owner, with the invocation (`/update-linkedin-followers 29800`) or in the conversation. Never look it up: no source the agent is permitted to read gives the count (LinkedIn needs a signed-in account). Never guess, round or keep the current value.

## Format rules (from the comments in `_data/linkedin.yml`)

- `followers` is a whole number of at least 1 in plain decimal digits with no leading zero: `^[1-9][0-9]*$`. No comma, space, decimal point, sign, `_`, suffix (`K`), hex or octal form.
- It stays `followers: <count>` at the start of its own line, with no trailing comment. This skill writes it unquoted.
- `as_of` is `YYYY-MM-DD` (`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`) and a real date (`2026-13-45` and `2026-02-30` are not).
- The file is read as Liquid too: nothing in it may contain `{{`, `}}`, `{%` or `%}`.
- An invalid value hides the line on the homepage and fails CI.

## Stop conditions

Stop, tell the owner what you saw, and wait. Do not work around any of these.

1. No count: ask the owner for it.
2. A value breaks a format rule: name the rule and ask for a corrected value. If the count is in a human format (`29,800`, `29.8K`), ask the owner to confirm the plain digits (`29800`); do not convert it yourself.
3. `git status --porcelain` prints any line (any path, tracked or untracked) before you start: ask whether to keep or discard those changes. Step 2 repeats the check after the switch; the pre-start check should make a line there unreachable, but a line there is the same stop.
4. A build or check fails, or exits with a code other than the one its step names.
5. The rendered line is missing, appears more than once, or differs from the expected line by any character.
6. The broken-value step does not behave as described, or the real `_data/linkedin.yml` changed during it.
7. The diff in step 2 is empty: the count and date already match the file. Report it, edit nothing more, and open no PR.
8. The diff in step 2 changes a line other than `followers:` or `as_of:`.
9. Branching cannot start: the starting HEAD is detached, a remote is missing, `origin` does not have exactly one push URL, or that URL is not the lmilbaum fork, or `upstream` is not lioramilbaum/lioramilbaum.github.io, the fetch or the switch fails, or `chore/linkedin-followers-<COUNT>` already exists locally or on origin (if it exists, ask the owner whether to reuse or delete that earlier branch; do not delete it).
10. A command in step 7 fails.

After a stop, report it, and clean up as this paragraph says. Nothing is committed, pushed or opened before step 7. A stop before step 2 changes nothing. Stops 7 and 8 undo step 2 here, since the branch was never pushed:

```bash
git restore -- _data/linkedin.yml && git switch "$(cat "<WORK>/start-branch.txt")" && git branch -D "chore/linkedin-followers-<COUNT>"; echo "exit=$?"; git status --porcelain; git branch --show-current
```

Expect `exit=0`, no status line, and the starting branch. Stops 3 to 6, when they fire after the switch, leave the branch and the edit for the owner to inspect. The report names the new branch and the starting branch, and gives that same command as the way to discard the branch. Stop 9 changes nothing this run did not create. A stop in step 7 leaves what step 7 has already done (the commit, the push, the PR), and the report names it. Never edit `_layouts/home.html`, `scripts/check-site.sh`, `scripts/test-site.sh`, or any file other than `_data/linkedin.yml`, to make a check pass. A failing check is the owner's to decide.

## Steps

Make a fresh work directory outside the repository for the evidence, once per run: `mktemp -d "<SCRATCHPAD>/linkedin.XXXXXX"` when the session's scratchpad path matches `^/[A-Za-z0-9._/-]+$` (no spaces, quotes or other shell characters), else plain `mktemp -d`. The printed path must match `^/[A-Za-z0-9._/-]+$`, or stop and report it. A fresh directory means the files in step 1 do not exist yet, so the Write tool can create them; never reuse a work directory from an earlier run. Write the printed path in place of `<WORK>` in every command, always inside the double quotes shown (shell variables do not carry between commands). Never put the owner's raw input into a command: step 1 hands it over in files and checks it first. `<COUNT>` and `<AS_OF>` are the `count=` and `as_of=` values in `<WORK>/checked.txt`, which step 1's check writes and prints only after it exits 0; only then do they go into a command.

### 1. Check the inputs, before editing anything

Use the Write tool (not the shell) to write the owner's count, exactly as given, to `<WORK>/count.txt`. Never write `count.txt`, or an owner-named `as_of.txt`, with the shell. If the owner named a date, write it the same way to `<WORK>/as_of.txt`. Otherwise:

```bash
date +%F > "<WORK>/as_of.txt"; cat "<WORK>/as_of.txt"
```

That `date` command is the only shell write to `as_of.txt`, and it writes only today's date.

The check below reads both files.

```bash
python3 -c 'import datetime, pathlib, re, sys
w = pathlib.Path(sys.argv[1])
def read(n):
    try: return (w / n).read_text(encoding="utf-8").rstrip("\n")
    except OSError as e: sys.exit("cannot read " + n + ": " + str(e))
c, a = read("count.txt"), read("as_of.txt")
if not re.fullmatch(r"[1-9][0-9]*", c): sys.exit("invalid count: " + repr(c))
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", a): sys.exit("invalid as_of: " + repr(a))
try: d = datetime.date.fromisoformat(a)
except ValueError: sys.exit("invalid as_of: " + repr(a) + " is not a real date")
m = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")[d.month - 1]
sys.stdout.buffer.write((f"{int(c):,} LinkedIn followers · as of {m} {d.day}, {d.year}\n").encode("utf-8"))
(w / "checked.txt").write_text("count=" + c + "\nas_of=" + a + "\n", encoding="utf-8")' "<WORK>" > "<WORK>/expected.txt"; echo "exit=$?"; cat "<WORK>/expected.txt"; cat "<WORK>/checked.txt"
```

`exit=0`, then one line, the expected text, then the two checked values, `count=` and `as_of=`, on their own lines. The expected text is the count grouped in threes with commas and the date as `Mon D, YYYY`, with an English three-letter month (the layout's `%b %-d, %Y` gives the same in the built site, whatever the locale) (`29800`, `2026-11-23` gives `29,800 LinkedIn followers · as of Nov 23, 2026`). The output is UTF-8 whatever the locale. Any other exit is stop condition 2. A missing or unreadable file is a non-zero exit too (stop condition 2). Also check stop condition 3: `git status --porcelain` (expect no output).

### 2. Branch, then edit the file

Record the starting branch, before anything else changes:

```bash
git branch --show-current > "<WORK>/start-branch.txt"; cat "<WORK>/start-branch.txt"
```

An empty result (detached HEAD) is stop condition 9. Then check the remotes and the new branch name. The remotes are normalised to `OWNER/REPO` (SSH and HTTPS forms, with or without `.git`). `origin` must have exactly one push URL, because `git push` sends to every push URL, and it must be the lmilbaum fork. `upstream` must be lioramilbaum/lioramilbaum.github.io. The probe prints each of `origin`'s push URLs on its own `origin=` line, so a second one shows:

```bash
o=$(git remote get-url --push --all origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##'); printf '%s\n' "$o" | sed 's/^/origin=/'; n=$(printf '%s\n' "$o" | grep -c .); echo "origin-count=$n"; u=$(git remote get-url upstream 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##'); echo "upstream=$u"; [ "$n" -eq 1 ] && [ "$o" = "lmilbaum/lioramilbaum.github.io" ] && [ "$u" = "lioramilbaum/lioramilbaum.github.io" ]; echo "remotes=$?"; git show-ref --verify --quiet "refs/heads/chore/linkedin-followers-<COUNT>"; echo "local=$?"; git ls-remote --exit-code --heads origin "chore/linkedin-followers-<COUNT>"; echo "origin-branch=$?"
```

Expect `origin=lmilbaum/lioramilbaum.github.io` (one line), `origin-count=1`, `upstream=lioramilbaum/lioramilbaum.github.io`, `remotes=0`, `local=1` and `origin-branch=2`. Any other value, a missing remote, or a second `origin=` line (more than one push URL) is stop condition 9. Then branch from `upstream/main` and run stop condition 3's check on the new branch:

```bash
git fetch upstream main && git switch -c "chore/linkedin-followers-<COUNT>" upstream/main; echo "exit=$?"; git branch --show-current; git status --porcelain
```

Expect `exit=0`, the new branch name, and no line from `git status --porcelain`. A failed fetch or switch is stop condition 9; a status line is stop condition 3.

With the Edit tool, change only the values on the `followers:` and `as_of:` lines of `_data/linkedin.yml` to `followers: <COUNT>` and `as_of: <AS_OF>`. Keep the comment lines. Then:

```bash
git diff -- _data/linkedin.yml > "<WORK>/data.diff"; cat "<WORK>/data.diff"
```

The diff changes only the `followers:` line, the `as_of:` line, or both (`as_of` often already holds today's date, so only the `followers:` line changes). An empty diff is stop condition 7. A diff that changes any other line is stop condition 8.

### 3. Build and run the checks

```bash
scripts/build-site.sh > "<WORK>/build.log" 2>&1; echo "exit=$?"; tail -n 1 "<WORK>/build.log"
```
Expect `exit=0`. The last line of Jekyll's output is reported verbatim in the step 6 report; it is not matched.

```bash
bash scripts/check-site.sh _site > "<WORK>/check-site.log" 2>&1; echo "exit=$?"; tail -n 1 "<WORK>/check-site.log"
```
Expect `exit=0` and `Homepage checks passed`.

```bash
bash scripts/test-site.sh > "<WORK>/test-site.log" 2>&1; echo "exit=$?"; tail -n 1 "<WORK>/test-site.log"
```
Expect `exit=0` and `All LinkedIn followers cases passed`. It builds about 26 variants and takes several minutes: allow a 10-minute timeout, or run it in the background and wait for it.

### 4. Compare the rendered line with the input

```bash
grep -oE '<p class="followers"><a [^>]*>[^<]*</a></p>' _site/index.html > "<WORK>/rendered.txt"; wc -l < "<WORK>/rendered.txt"; cat "<WORK>/rendered.txt"
printf '<p class="followers"><a href="https://linkedin.com/in/lmilbaum" rel="me noopener">%s</a></p>\n' "$(cat "<WORK>/expected.txt")" | cmp - "<WORK>/rendered.txt" && echo "rendered line matches"
```

Expect `1` line and `rendered line matches`. The report (step 6) quotes, together and verbatim: the input (the count and `as_of`, with where the date came from), the expected text from `<WORK>/expected.txt`, and the rendered line from `<WORK>/rendered.txt`.

### 5. Prove the check fails on an invalid value

This builds a throwaway copy outside the repository with `followers: 012` (YAML reads it as octal 10, so the layout must hide the line). The real `_data/linkedin.yml` is not touched.

Run this block as one command, with a 10-minute timeout.

```bash
set -o pipefail
copy=$(mktemp -d "<WORK>/copy.XXXXXX") || { echo "error: mktemp failed"; exit 1; }
tar -C . --exclude=./.git --exclude=./.claude --exclude=./_site --exclude=./_snapshots -cf - . | tar -C "$copy" -xf -; echo "exit=$?"
printf 'followers: 012\nas_of: %s\n' '<AS_OF>' > "$copy/_data/linkedin.yml"
scripts/build-site.sh "$copy" > "<WORK>/broken-build.log" 2>&1; echo "exit=$?"
env -u GITHUB_ACTIONS bash scripts/check-site.sh "$copy/_site" > "<WORK>/broken-check.log" 2>&1; echo "exit=$?"; tail -n 1 "<WORK>/broken-check.log"
grep -cE 'LinkedIn followers|class="followers"' "$copy/_site/index.html" || true
git diff -- _data/linkedin.yml | cmp - "<WORK>/data.diff" && echo "real file unchanged"
rm -rf -- "$copy"; echo "removed $copy"
```

Expect, in order: `exit=0` (copy), `exit=0` (build), `exit=1` with exactly

```
error: LinkedIn followers line missing from the homepage (_data/linkedin.yml needs followers, a positive integer, and as_of, YYYY-MM-DD)
```

then `0` (the line is hidden), then `real file unchanged`, then `removed <WORK>/copy.XXXXXX` with the path `mktemp` created. Anything else is stop condition 6. The block removes only the directory `mktemp` created for it.

### 6. Compose the report

Write the report with the Write tool to `<WORK>/report.md`:
- the input: the count, and the as-of date with where it came from (today's date from `date +%F`, or the owner's);
- the expected text and the rendered line, quoted verbatim from `expected.txt` and `rendered.txt`;
- each command's exit code and the last line of its log (the logs are in `<WORK>`), the last line quoted verbatim;
- the `012` result: the last line of `<WORK>/broken-check.log`, quoted verbatim;
- `git status --short`, which should show only `_data/linkedin.yml` modified;
- the starting branch (from `<WORK>/start-branch.txt`) and the new branch.

A clean run (every step as expected, no stop) goes on to step 7 without asking the owner. A stop skips step 7 and ends the run here, as described under Stop conditions. The run ends with one final message to the owner: the report, plus the PR URL on a clean run, or the report and the stop reason after a stop.

### 7. Open the PR

Only on a clean run. Nothing is committed before this step.

Commit only the one file. Write the commit message with the Write tool to `<WORK>/commit-msg.txt`: the subject `chore: update the LinkedIn followers count to <COMMA>`, where `<COMMA>` is the count with commas (the text before ` LinkedIn followers` in `expected.txt`); a blank line; then the `Co-Authored-By:` trailer from the session's attribution instructions, copied exactly. Do not type a model name by hand.

```bash
git add -- _data/linkedin.yml; git diff --cached --name-only; git status --porcelain
```

Expect `_data/linkedin.yml` as the only name, and `M  _data/linkedin.yml` as the only status line.

```bash
git commit -F "<WORK>/commit-msg.txt"; echo "exit=$?"; git log -1 --format=%B | sed '/^$/d' | tail -n 1
```

Expect `exit=0`, and the last non-blank line must be the session's `Co-Authored-By:` trailer, exactly. If it is not, rewrite `<WORK>/commit-msg.txt` with the Write tool (the subject, a blank line, and the exact trailer), run `git commit --amend -F "<WORK>/commit-msg.txt"`, and run the check again. The branch is not pushed yet, so the amend is safe.

Push the branch. Never force-push. Step 2 verified `origin` (the fork), and this re-checks it just before the push, since the remotes could change between the steps:

```bash
[ "$(git remote get-url --push --all origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')" = "lmilbaum/lioramilbaum.github.io" ] && git push -u origin "chore/linkedin-followers-<COUNT>"; echo "exit=$?"
```

Expect `exit=0`.

Write the PR body with the Write tool to `<WORK>/pr-body.md`, built from `.github/pull_request_template.md` and modelled on PRs #131 and #132: drop the template's comment block and its `Closes #` line, and fill every section:
- `## Acceptance criteria`: `No linked issue.`
- `## Why`: the owner's new count, and the value it replaces (read from `git show upstream/main:_data/linkedin.yml`).
- `## How`: how the skill ran, with the step 6 report's verbatim lines in a code block. Replace any local path in them (the work directory, the scratchpad path) with `<WORK>`.
- `## What`: `_data/linkedin.yml`, `followers: <COUNT>` and `as_of: <AS_OF>`, and the rendered line.
- `## Assistance and third-party material`: `Claude Code ran the update-linkedin-followers skill and opened this PR. The follower count came from the owner. No third-party material.`
- `## Limitations`: the count can't be checked in CI (reading it from LinkedIn needs a signed-in account); CI checks its format and the rendered line; this PR adds no code.
- `## Hackathon` and `## Qodo notes`: `None.`
- The last line: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

Open the PR as a non-draft (no `--draft`), as #131 and #132 are. It is assigned to the owner:

```bash
gh pr create --repo lioramilbaum/lioramilbaum.github.io --base main --head "lmilbaum:chore/linkedin-followers-<COUNT>" --assignee lmilbaum --title "$(head -n 1 "<WORK>/commit-msg.txt")" --body-file "<WORK>/pr-body.md"; echo "exit=$?"
```

Expect `exit=0` and the PR URL. Then switch back to the starting branch:

```bash
git switch "$(cat "<WORK>/start-branch.txt")"; echo "exit=$?"; git branch --show-current
```

Expect `exit=0` and the starting branch. Report the PR URL to the owner. Any failing command in this step is stop condition 10: report the command and its output, and do not force-push or merge.
