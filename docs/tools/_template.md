---
# The entry template for Tools I Investigate (docs/tools/index.md). Jekyll does not
# publish files whose names start with "_", and scripts/check-site.sh checks that
# this one is not published. To add an entry, copy it to docs/tools/<tool>.md (no
# leading underscore) and fill in every field and section from your own
# investigation. The index lists every page with a tool_status, newest first.
layout: docs
title: Tool name
description: "One line: what the tool is and what I'm investigating it for."
# One or two sentences for the index.
summary: "What the tool addresses and where the investigation stands."
tool_url: https://example.com
# exploring: preliminary impressions, from the documentation and first tries.
# evaluated: findings from a scenario I tested hands-on.
tool_status: exploring
last_updated: 2026-11-14
---

# {{ page.title }}

**Official site:** [{{ page.title }}]({{ page.tool_url }})

**Status:** {% if page.tool_status == "evaluated" %}Evaluated: tested findings{% elsif page.tool_status == "exploring" %}Exploring: preliminary impressions{% endif %}

**Last updated:** {{ page.last_updated | date: "%b %-d, %Y" }}

Investigating a tool is not an endorsement.

## The problem and why I'm investigating it

## The use case I explored

## Findings

Mark each finding as a preliminary impression or a tested result.

### Strengths

### Limitations and trade-offs

## Examples and links
