#!/bin/bash
# Loop Skill Setup Script
# Creates the state file + state_dir for an in-session self-referential loop.
# This script is domain-agnostic: it never inspects or assumes the structure
# of anything inside state_dir, and it does not care what --pipeline's
# prompt.md contains. The only "config" it reads besides CLI args is
# .claude/loop-skill.config, and only for two known keys (§3.7).

set -euo pipefail

STATE_FILE=".claude/loop-skill.local.md"
CONFIG_FILE=".claude/loop-skill.config"
DEFAULT_MAX_ITERATIONS=50

PROMPT_PARTS=()
MAX_ITERATIONS=""
PIPELINE_NAME=""
STATE_DIR_OVERRIDE=""
CLI_MAX_ITERATIONS_SET=false
CLI_PIPELINE_SET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Loop Skill - Generic self-referential development loop

USAGE:
  /loop-skill [PROMPT...] [OPTIONS]
  /loop-skill --pipeline <name> [OPTIONS]

OPTIONS:
  --max-iterations <n>   Maximum iterations before auto-stop (default: 50, 0 = unlimited)
  --pipeline <name>       Load pipelines/<name>/prompt.md as the loop body
                          (value = folder name under pipelines/, e.g. "l1-log-analysis")
  --state-dir <path>       Override the default state_dir location
  -h, --help              Show this help message

DEFAULTS FILE (optional, §3.7):
  .claude/loop-skill.config (dotenv format) can set LOOP_SKILL_PIPELINE and/or
  LOOP_SKILL_MAX_ITERATIONS as project-level defaults. Precedence:
  CLI args > .claude/loop-skill.config > built-in default (max-iterations=50).

STOPPING:
  The loop stops when --max-iterations is reached, OR when the pipeline writes
  {"status": "complete"} (or {"status": "failed", "reason": "..."}) to
  <state_dir>/status.json (§3.6.1).
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: --max-iterations must be a non-negative integer, got: ${2:-<missing>}" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"; CLI_MAX_ITERATIONS_SET=true; shift 2 ;;
    --pipeline)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --pipeline requires a name argument" >&2
        exit 1
      fi
      PIPELINE_NAME="$2"; CLI_PIPELINE_SET=true; shift 2 ;;
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

# §3.7 config defaults — CLI args always win; the config file is consulted
# only for values the CLI did not set. The core knows exactly these two keys
# and nothing else about the file's contents.
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_PIPELINE=$(grep -E '^LOOP_SKILL_PIPELINE=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- || true)
  CONFIG_MAX_ITERATIONS=$(grep -E '^LOOP_SKILL_MAX_ITERATIONS=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- || true)

  if [[ "$CLI_PIPELINE_SET" == "false" ]] && [[ -n "${CONFIG_PIPELINE:-}" ]]; then
    PIPELINE_NAME="$CONFIG_PIPELINE"
  fi
  if [[ "$CLI_MAX_ITERATIONS_SET" == "false" ]] && [[ -n "${CONFIG_MAX_ITERATIONS:-}" ]]; then
    if [[ "$CONFIG_MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
      MAX_ITERATIONS="$CONFIG_MAX_ITERATIONS"
    else
      echo "⚠️  Loop skill: ignoring invalid LOOP_SKILL_MAX_ITERATIONS in $CONFIG_FILE (not a non-negative integer): $CONFIG_MAX_ITERATIONS" >&2
    fi
  fi
fi

MAX_ITERATIONS="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"

# [CR-4] Active loop guard — never silently clobber an in-flight loop.
if [[ -f "$STATE_FILE" ]]; then
  CURRENT_ITER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//')
  echo "❌ Error: 이미 활성 loop가 있습니다 (iteration ${CURRENT_ITER:-?})" >&2
  echo "   중지하려면 /cancel-loop-skill을 실행하거나 status.json 완료 신호/max-iterations 도달을 기다리세요." >&2
  exit 1
fi

# Resolve the prompt body: --pipeline takes precedence over inline PROMPT.
# The core does NOT interpret pipeline prompt.md content — it is read and
# copied verbatim. PIPELINE_NAME must match a folder name under pipelines/.
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
    echo "     /loop-skill --pipeline l1-log-analysis" >&2
    exit 1
  fi
fi

# Resolve state_dir — a bare empty directory the core will never touch again,
# except to read <state_dir>/status.json for the completion signal (§3.6.1).
RUN_ID="loop-$(date -u +%Y%m%d-%H%M%S)"
STATE_DIR="${STATE_DIR_OVERRIDE:-.claude/loop-skill/${RUN_ID}}"
mkdir -p "$STATE_DIR"

mkdir -p .claude

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

The Stop hook is now active. To cancel: /cancel-loop-skill
EOF

if [[ -n "$PROMPT" ]]; then
  echo ""
  echo "$PROMPT"
fi

echo ""
echo "To end this loop, write EXACTLY this JSON to ${STATE_DIR}/status.json using the Write tool:"
echo '  {"status": "complete"}'
echo "If the task genuinely cannot be completed, write instead:"
echo '  {"status": "failed", "reason": "<short reason>"}'
echo "Only write this when the condition is truly met — do not write it prematurely to escape the loop."
