# feat: add the story workflow

**PR:** [#163](https://github.com/lioramilbaum/lioramilbaum.github.io/pull/163) · **Opened:** 2026-11-25

## Why

_From the PR description (author-written)._

Work in this repo starts as a request in a conversation, and until now its intent was written down by hand, if at all, before an issue existed. A "story" is a piece of work run with a Claude Code workflow, and its first steps should be the same every time: state what the request asks for, and record it somewhere that outlasts the session. This PR adds those first steps as a saved workflow.

## How

_From the PR description (author-written)._

`/story <request>` runs `.claude/workflows/story.js`, a script for Claude Code's Workflow tool. The script fixes the order of the steps and checks every result; three subagents do the reading and the `gh` calls.

1. **Extract intent.** An agent returns a title and four fields: the goal, why it matters, what is in scope and what is out of scope. It uses only what the request says, and writes `Not stated in the request.` where the request gives no reason or no exclusions. A request that states no outcome stops the run.
2. **File issue.** The script writes the issue body from those fields. The agent copies it into a file and runs one `gh issue create`, assigned to the owner, with no labels. Before filing, it looks for the request's marker in the 200 newest issues and stops if it finds it.
3. **Verify issue.** A separate agent, which is not told the title, the body or the assignee, reads the issue back. The script compares the title, body, state, labels and assignee, and requires that exactly one issue carries the marker.

Every failure, including an agent call that stalls or never returns a valid result, stops the run with an error that says whether an issue may exist (AGENTS.md rule 11).

## What

_From the PR description (author-written)._

- `.claude/workflows/story.js`: the workflow. It returns `{ intent, issue }`, where `issue` holds the number, URL and title.
- The extraction agent runs on the `sonnet` model alias, and the filing and Verify agents on `haiku`, by the owner's choice (Sonnet 5.5 and Haiku 5.5 on the Anthropic API today).
- The filed issue has four sections (Goal, Why it matters, In scope, Out of scope) and ends with a hidden comment, `<!-- story-request: <16 hex digits> -->`: a fingerprint of the request, used to refuse a duplicate.
- The issue has no `## Acceptance criteria` section and no labels, by the owner's decision, so no work starts on it until the owner adds the criteria (rule 10). It never gets `ready-for-agent`.
- `_config.yml` is unchanged: `.claude/` is already excluded from the site, and `scripts/check-site.sh` fails if it is published.

## Evidence

- Ran in CI: [run 45710879035](https://github.com/lioramilbaum/lioramilbaum.github.io/actions/runs/45710879035) on b293e08 (content 81324793477832fe7915de9c24847ddca78b80c2). Jobs: build: success.
- Homepage: unchanged. The head build (H 23e8c9dd1c25a354dbf649dc95b5f75dadb13804) matches the merge-base b2d9651 build.
- Local: built the head and the merge-base (b2d9651) with scripts/build-site.sh, and compared their homepages.

## Screenshot or demo

No visible change on the homepage.

## What I learned from the Qodo review

Qodo reviewed these contents (by content digest): `590f2501a003dbe1e4d242bc28bbfc9cbad10e6c`, `3aac314dd5bf49581b94398e8cae6c1b5f9609bd`, `1948ed8ab465cfd10a63e21df78bd2ac80c32527`, `81324793477832fe7915de9c24847ddca78b80c2`. Its latest review is content `81324793477832fe7915de9c24847ddca78b80c2`.

- A failed verification hides the issue URL (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `590f2501a003dbe1e4d242bc28bbfc9cbad10e6c`.
- Altered issue formatting passes verification (Medium, 🐞 Bug). No longer listed by Qodo. Reviewed in content `590f2501a003dbe1e4d242bc28bbfc9cbad10e6c`.
- Phase summary omits the state and URL checks (Low, 🐞 Bug). No longer listed by Qodo. Reviewed in content `1948ed8ab465cfd10a63e21df78bd2ac80c32527`, `81324793477832fe7915de9c24847ddca78b80c2`.

Open findings in Qodo's latest review: 0.

The PR description has no `## Qodo notes` section.

## Assistance and third-party material

_From the PR description (author-written)._

Written with Claude Code (Claude Fable 5.2, then Claude Opus 5.5) under the owner's direction. A planner agent drafted the script, an executor agent wrote it, and a reviewer agent reviewed it in five rounds (9, 9, 4, 2 and 0 findings), and again after each later change (0 findings); the owner chose which findings to fix. Qodo's review of the first head raised two findings, both fixed in the current head: the read-back compared the issue body without its line breaks, and a failed agent call ended the run without naming the issue that had been filed. The script format follows the Claude Code documentation at https://code.claude.com/docs/en/workflows. No third-party code is included.

## Limitations

_From the PR description (author-written)._

- CI does not run or parse the script. AGENTS.md rule 8 covers `scripts/`, `.github/workflows/`, `_layouts/` and `_config.yml`, not `.claude/`. The script was checked with an offline harness kept outside the repo, which runs it with stubbed agents and checks the result and each failure path by its error message.
- The workflow has not been run for real: a run files a real issue, and the owner chose offline checks only. The first `/story` run is the first test of how the agents follow their prompts, of the `gh` commands against GitHub, and of whether the agents need permission prompts for `gh` and for their temporary files.
- The agents are limited by their prompts only; no tool restriction is applied. A filing agent that ignored its prompt (another repository, a different body) would not be caught by the script.
- The filing agent, on the smaller Haiku model, is told to write the title and body files with the Write tool and never through the shell. If it used the shell anyway, a `$` or a backquote in that text would be expanded before the Verify step could catch the result.
- The Verify step reads the issue through an agent on the smaller Haiku model. If that agent miscopies the title or the body, a correct issue fails the check; the error names the issue's URL. A miscopy cannot make a wrong issue pass.
- The duplicate check reads the 200 newest issues, so an older duplicate is not found. The same request text cannot be filed twice, even after its issue is closed; change the text to file it again.
- The documentation does not fix whether `/story <text>` passes the text as a string or as an object, so the script accepts a string, or an object with a `request` string.
- The model names are aliases, so each follows its family's current version. The documentation confirms only the alias form for a model a workflow script names; a pinned model ID was not tried.
- A stalled agent is reported with the issue's state only if the runtime rejects the script's `agent()` call. If the runtime ends the run itself, its own error is shown instead.

## Discussion post

This PR has no `## Hackathon` section, so there is no discussion post.
<!-- delivery: content=81324793477832fe7915de9c24847ddca78b80c2 head=b293e0809efbf289056d9407745dc11ecce9b818 homepage=23e8c9dd1c25a354dbf649dc95b5f75dadb13804 qodo-open=0 -->
