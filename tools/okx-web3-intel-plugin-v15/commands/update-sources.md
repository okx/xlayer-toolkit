---
description: Update the Web3 Twitter/X source list
allowed-tools: Read, Write, Edit, WebSearch, WebFetch, Glob, Grep
---

Trigger the `web3-sources` skill to update the Web3 information source list.

Use `Skill("web3-sources")` to execute. The skill will:

1. Load the current 142+ source list from references/sources.md
2. Search for new Web3 projects, KOLs, and accounts relevant to OKX business lines
3. Verify each new handle exists and is active
4. Update the list with additions, removals, and handle changes
5. Output a change summary

If the user specifies a focus area (e.g., "add more PayFi accounts"), prioritize that category during the update.
