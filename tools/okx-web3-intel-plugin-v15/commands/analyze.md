---
description: Analyze a crypto event's impact on OKX business
allowed-tools: Read, Write, WebSearch, WebFetch, Glob, Grep
argument-hint: [news or event description]
---

Trigger the `okx-impact-analyst` skill to analyze the strategic impact of the provided event on OKX's four business lines (XLayer, OKX Wallet, OKX DEX, OKX DeFi).

Use `Skill("okx-impact-analyst")` and provide `$ARGUMENTS` as the event/news to analyze.

The skill will output:
- Concept definition (what happened)
- Engineering essence (technical details)
- Strategic assessment (what's their play)
- BPM discussion points (specific decision items for OKX)
