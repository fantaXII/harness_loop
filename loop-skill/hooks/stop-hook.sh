#!/bin/bash
# Loop Skill Stop Hook
# Prevents session exit while a loop is active; feeds the SAME prompt back.
# Domain-agnostic except for one fixed contract file: <state_dir>/status.json
# (§3.6.1). This hook only READS that file to decide completion — it never
# writes it, and it never reads or writes anything else inside state_dir.

set -euo pipefail

HOOK_INPUT=$(cat)

STATE_FILE=".claude/loop-skill.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
STATE_DIR=$(echo "$FRONTMATTER" | grep '^state_dir:' | sed 's/state_dir: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation — a state file belongs to exactly one session.
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Loop skill: state file corrupted ('iteration' invalid). Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi
if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Loop skill: state file corrupted ('max_iterations' invalid). Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Loop skill: max iterations ($MAX_ITERATIONS) reached."
  rm "$STATE_FILE"
  exit 0
fi

# §3.6.1 completion signal — the ONLY file inside state_dir the core ever
# reads. Missing file, or a missing/unrecognized 'status' field, is treated
# as not-yet-complete (graceful degradation, same principle as the original
# ralph-loop's jq-failure tolerance).
if [[ -n "$STATE_DIR" ]]; then
  STATUS_FILE="${STATE_DIR}/status.json"
  if [[ -f "$STATUS_FILE" ]]; then
    set +e
    STATUS=$(jq -r '.status // empty' "$STATUS_FILE" 2>/dev/null)
    set -e
    if [[ "$STATUS" == "complete" ]]; then
      echo "✅ Loop skill: pipeline reported completion (${STATUS_FILE})"
      rm "$STATE_FILE"
      exit 0
    elif [[ "$STATUS" == "failed" ]]; then
      set +e
      REASON=$(jq -r '.reason // "no reason given"' "$STATUS_FILE" 2>/dev/null)
      set -e
      echo "🛑 Loop skill: pipeline reported failure (${STATUS_FILE}): ${REASON:-no reason given}"
      rm "$STATE_FILE"
      exit 0
    fi
  fi
fi

NEXT_ITERATION=$((ITERATION + 1))

# The prompt body (everything after the second ---) is reused AS-IS.
# This is the core principle: continuity comes from whatever the LLM wrote
# on disk (e.g. inside state_dir), NOT from the hook regenerating text.
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Loop skill: state file has no prompt body. Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

SYSTEM_MSG="🔄 Loop iteration $NEXT_ITERATION | To stop: write {\"status\":\"complete\"} to ${STATE_DIR}/status.json"

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
