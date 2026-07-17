#!/bin/bash
# Loop Skill Setup Script
# Creates the state file + state_dir for an in-session self-referential loop.
# This script is domain-agnostic: it never inspects or assumes the structure
# of anything inside state_dir, and it does not care what --pipeline's
# prompt.md contains.

set -euo pipefail

STATE_FILE=".claude/loop-skill.local.md"
DEFAULT_MAX_ITERATIONS=50

PROMPT_PARTS=()
MAX_ITERATIONS=$DEFAULT_MAX_ITERATIONS
COMPLETION_PROMISE="null"
PIPELINE_NAME=""
STATE_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Loop Skill - Generic self-referential development loop

USAGE:
  /loop-skill [PROMPT...] [OPTIONS]
  /loop-skill --pipeline <name> [OPTIONS]

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: 50, 0 = unlimited)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  --pipeline <name>               Load pipelines/<name>/prompt.md as the loop body
  --state-dir <path>               Override the default state_dir location
  -h, --help                      Show this help message

STOPPING:
  Only by reaching --max-iterations or detecting --completion-promise.
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: --max-iterations must be a non-negative integer, got: ${2:-<missing>}" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"; shift 2 ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"; shift 2 ;;
    --pipeline)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --pipeline requires a name argument" >&2
        exit 1
      fi
      PIPELINE_NAME="$2"; shift 2 ;;
    --state-dir)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --state-dir requires a path argument" >&2
        exit 1
      fi
      STATE_DIR_OVERRIDE="$2"; shift 2 ;;
    *)
      PROMPT_PARTS+=("$1"); shift ;;
  esac
done

# [CR-4] Active loop guard — never silently clobber an in-flight loop.
if [[ -f "$STATE_FILE" ]]; then
  CURRENT_ITER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//')
  echo "❌ Error: 이미 활성 loop가 있습니다 (iteration ${CURRENT_ITER:-?})" >&2
  echo "   중지하려면 /cancel-loop-skill을 실행하거나 completion promise/max-iterations 도달을 기다리세요." >&2
  exit 1
fi

# Resolve the prompt body: --pipeline takes precedence over inline PROMPT.
# The core does NOT interpret pipeline prompt.md content — it is read and
# copied verbatim.
if [[ -n "$PIPELINE_NAME" ]]; then
  PIPELINE_PROMPT_FILE="${CLAUDE_PLUGIN_ROOT:-.}/pipelines/${PIPELINE_NAME}/prompt.md"
  if [[ ! -f "$PIPELINE_PROMPT_FILE" ]]; then
    echo "❌ Error: pipeline '$PIPELINE_NAME' not found (expected $PIPELINE_PROMPT_FILE)" >&2
    exit 1
  fi
  PROMPT=$(cat "$PIPELINE_PROMPT_FILE")
else
  PROMPT="${PROMPT_PARTS[*]:-}"
  if [[ -z "$PROMPT" ]]; then
    echo "❌ Error: No prompt provided and no --pipeline given" >&2
    echo "   Examples:" >&2
    echo "     /loop-skill Build a REST API for todos" >&2
    echo "     /loop-skill --pipeline l1-log-analysis --completion-promise 'DONE'" >&2
    exit 1
  fi
fi

# Resolve state_dir — a bare empty directory the core will never touch again.
RUN_ID="loop-$(date -u +%Y%m%d-%H%M%S)"
STATE_DIR="${STATE_DIR_OVERRIDE:-.claude/loop-skill/${RUN_ID}}"
mkdir -p "$STATE_DIR"

mkdir -p .claude

if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

if [[ -n "$PIPELINE_NAME" ]]; then
  PIPELINE_YAML="\"$PIPELINE_NAME\""
else
  PIPELINE_YAML="null"
fi

cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
session_id: ${CLAUDE_CODE_SESSION_ID:-}
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
state_dir: "$STATE_DIR"
pipeline: $PIPELINE_YAML
---

$PROMPT
EOF

cat <<EOF
🔄 Loop skill activated in this session!

Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)
Pipeline: $(if [[ -n "$PIPELINE_NAME" ]]; then echo "$PIPELINE_NAME"; else echo "none (plain prompt)"; fi)
State dir: $STATE_DIR
Completion promise: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "${COMPLETION_PROMISE//\"/} (ONLY output when TRUE!)"; else echo "none (runs until max-iterations)"; fi)

The Stop hook is now active. To cancel: /cancel-loop-skill
EOF

if [[ -n "$PROMPT" ]]; then
  echo ""
  echo "$PROMPT"
fi

if [[ "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "To complete this loop, output this EXACT text: <promise>$COMPLETION_PROMISE</promise>"
  echo "Only output it when the statement is completely and unequivocally TRUE."
fi
