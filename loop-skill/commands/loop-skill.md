---
description: "Start a generic self-referential loop (optionally driven by a --pipeline definition)"
argument-hint: "[PROMPT...] | --pipeline <name> [--max-iterations N] [--state-dir PATH]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-loop-skill.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Loop Skill Command

Execute the setup script to initialize the loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-loop-skill.sh" $ARGUMENTS
```

Please work on the task described above. When you try to exit, the Stop hook will feed the
SAME prompt back to you for the next iteration. You'll see your previous work in files
(including anything you wrote under the reported `state_dir`, if a pipeline is in use)
and git history — this is how continuity works without the loop core knowing anything
about what you're doing.

CRITICAL RULE: The loop only stops when you write `{"status": "complete"}` to
`<state_dir>/status.json` using the Write tool, or when max-iterations is reached. Only
write `complete` when the task is genuinely, completely done — do not write it prematurely
to escape the loop, even if you think you're stuck. If the task truly cannot be completed,
write `{"status": "failed", "reason": "<short honest reason>"}` instead — that also ends
the loop, but is reported differently so it isn't confused with genuine success.
