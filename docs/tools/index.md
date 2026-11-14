---
layout: docs
title: Tools I Investigate
description: "Hands-on notes on the tools I investigate: what each one addresses, what I tried, what I found, and how far each investigation has got."
image: /assets/images/profile.jpg
permalink: /docs/tools/
---

# Tools I Investigate

Hands-on notes on tools I'm investigating: the problem each one addresses, the scenario I tried it on, and what I found. Investigating a tool is not an endorsement.

## How to read an entry

- **Status:** *Exploring* means preliminary impressions, from the documentation and first tries. *Evaluated* means findings from a scenario I tested hands-on.
- **Last updated:** when I last changed the entry.
- Each entry names the tool and links its official site, says what problem it addresses and why I'm investigating it, describes the use case I explored, and lists findings, strengths, limitations and trade-offs, with examples, code or supporting links where I have them.

## Investigations

{% assign tools = site.pages | where_exp: "p", "p.tool_status != nil" | sort: "last_updated" | reverse %}
{% if tools.size == 0 %}
No investigation is published here yet.
{% else %}
{% for tool in tools %}
{% if tool.tool_status == "evaluated" %}{% assign label = "Evaluated: tested findings" %}{% elsif tool.tool_status == "exploring" %}{% assign label = "Exploring: preliminary impressions" %}{% else %}{% assign label = "Status unknown" %}{% endif %}
- [{{ tool.title }}]({{ tool.url | relative_url }})

  {{ label }} · Last updated {{ tool.last_updated | date: "%b %-d, %Y" }}

  {{ tool.summary }}
{% endfor %}
{% endif %}
