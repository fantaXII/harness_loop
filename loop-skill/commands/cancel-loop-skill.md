---
description: "Cancel the active loop-skill loop"
allowed-tools: ["Bash(test:*)", "Bash(rm:*)", "Bash(echo:*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Loop Skill

```!
if [[ -f ".claude/loop-skill.local.md" ]]; then
  rm ".claude/loop-skill.local.md"
  echo "✅ Loop cancelled. The Stop hook will now allow the session to end normally."
  echo "   Note: the state_dir (if a pipeline created one) is NOT deleted — clean it up manually if needed."
else
  echo "ℹ️  No active loop-skill loop found in this project."
fi
```
