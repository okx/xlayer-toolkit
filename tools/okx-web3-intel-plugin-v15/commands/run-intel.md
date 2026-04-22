---
description: Run the Web3 intel pipeline and push to Lark
allowed-tools: Read, Write, Edit, Bash, WebSearch, WebFetch, Glob, Grep
---

Trigger the `insight-decision-flow` skill to run the full Web3 intelligence pipeline:

1. Load dedup history
2. Collect from 142+ Web3 Twitter/X sources
3. Filter through the 8+8 signal matrix
4. Deduplicate against sent history
5. Deep strategic analysis on top signal
6. Push intel briefing to Lark (blue card)
7. Update dedup history

Use `Skill("insight-decision-flow")` to execute. Do not inline the logic — the skill has the complete methodology.

If the user provides additional context (e.g., "focus on L2 news today"), pass that context to the skill as guidance for Step 3 filtering priority.
