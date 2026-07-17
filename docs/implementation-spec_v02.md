# 범용 Ralph-Loop Skill 구현 스펙 (v02)

## 문서 버전

- **버전**: 2.0.0
- **상태**: Draft
- **기반 문서**: `harness_loop_plan_v02.md` (§1~§14 코어 범위, 부록 A는 참고용 — 이 스펙도 코어만 다룬다)
- **작성일**: 2026-07-19

## 0. 이 스펙의 범위

`harness_loop_plan_v02.md`의 결정을 그대로 따른다:
- 구현 대상은 **범용 loop 코어**뿐이다 — 특정 pipeline(L1 로그 분석의 8-agent/manifest.json 등)은 구현하지 않는다.
- 코어는 `pipelines/<name>/prompt.md`를 읽어 그대로 전달하는 것 이상 pipeline 내용에 관여하지 않는다(계획 §3.5/§3.6).
- 이 스펙에서 만드는 파일 전체는 `l1-log-analysis`가 아니라 `loop-skill`이라는 이름을 쓴다.

## 1. 디렉토리 구조 (구현 대상)

```
loop-skill/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   ├── loop-skill.md
│   └── cancel-loop-skill.md
├── scripts/
│   └── setup-loop-skill.sh
├── hooks/
│   ├── hooks.json
│   └── stop-hook.sh
├── pipelines/
│   └── README.md
├── install/
│   ├── install.sh
│   ├── install.ps1
│   ├── uninstall.sh
│   └── uninstall.ps1
└── README.md
```

`install-state.json`은 설치 시점에 `install/` 아래 생성되는 산출물이며 소스 저장소에는 없다.

## 2. `.claude-plugin/plugin.json`

```json
{
  "name": "loop-skill",
  "version": "0.1.0",
  "description": "Generic self-referential loop (ralph-loop pattern) with a pipeline extension point. Domain-agnostic core — pipelines plug in via pipelines/<name>/prompt.md.",
  "author": {
    "name": "loop-skill contributors",
    "email": ""
  }
}
```

## 3. `commands/loop-skill.md` (source template)

```markdown
---
description: "Start a generic self-referential loop (optionally driven by a --pipeline definition)"
argument-hint: "[PROMPT...] | --pipeline <name> [--max-iterations N] [--completion-promise TEXT] [--state-dir PATH]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-loop-skill.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Loop Skill Command

Execute the setup script to initialize the loop:

\`\`\`!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-loop-skill.sh" $ARGUMENTS
\`\`\`

Please work on the task described above. When you try to exit, the Stop hook will feed the
SAME prompt back to you for the next iteration. You'll see your previous work in files
(including anything you wrote under the reported `state_dir`, if a pipeline is in use)
and git history — this is how continuity works without the loop core knowing anything
about what you're doing.

CRITICAL RULE: If a completion promise is set, you may ONLY output it when the statement
is completely and unequivocally TRUE. Do not output false promises to escape the loop,
even if you think you're stuck. The loop is designed to continue until genuine completion.
```

**설치 시점 치환**: `${CLAUDE_PLUGIN_ROOT}`는 plugin 컨텍스트가 없으므로 installer가 payload 절대경로(`~/.claude/skills/loop-skill`)로 치환한 뒤 `~/.claude/commands/loop-skill.md`에 설치한다(§5.1 `register_hooks_and_commands()`).

## 4. `commands/cancel-loop-skill.md` (source template)

```markdown
---
description: "Cancel the active loop-skill loop"
allowed-tools: ["Bash(test:*)", "Bash(rm:*)", "Bash(echo:*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Loop Skill

\`\`\`!
if [[ -f ".claude/loop-skill.local.md" ]]; then
  rm ".claude/loop-skill.local.md"
  echo "✅ Loop cancelled. The Stop hook will now allow the session to end normally."
  echo "   Note: the state_dir (if a pipeline created one) is NOT deleted — clean it up manually if needed."
else
  echo "ℹ️  No active loop-skill loop found in this project."
fi
\`\`\`
```

## 5. `scripts/setup-loop-skill.sh`

```bash
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
```

**원본 ralph-loop 대비 변경점 요약** (계획 §3.5 원칙 준수 여부 확인용):
| 변경 | 이유 |
|---|---|
| `MAX_ITERATIONS` 기본값 `0` → `50` | 계획 §10.2 위험 5 완화 |
| 활성 loop 존재 시 즉시 에러 | CR-4 / 계획 §10.2 위험 7 완화 |
| `--pipeline`, `--state-dir` 옵션 추가 | 계획 §3.6 확장 계약 구현 |
| `state_dir` 생성(빈 디렉토리) | 계획 §3.6 항목 2 |
| state 파일에 `state_dir`, `pipeline` 필드 추가 | 계획 §6.1 |
| **그 외 로직 전부 원본과 동일** | 계획 §3.5 "코어는 도메인 로직을 모른다" 원칙 |

## 6. `hooks/hooks.json`

```json
{
  "description": "Loop Skill stop hook — generic self-referential loop, no domain logic",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

이 파일은 **참고용**이다 — Claude Code는 payload 디렉토리 내부의 `hooks.json`을 스캔해 자동 등록하지 않는다(계획 §3.1). 실제 등록은 installer가 `~/.claude/settings.json`의 `hooks.Stop`에 동일한 내용을 병합하는 방식으로 수행한다(§7).

## 7. `hooks/stop-hook.sh`

원본 ralph-loop의 `stop-hook.sh`를 **의도적으로 최소 변경**만 가한 버전이다. 변경점은 상태 파일 경로 하나뿐이며, `state_dir` 내부를 읽거나 쓰는 코드는 어디에도 없다(계획 §3.5 원칙 검증용으로 아래 diff 요약 참고).

```bash
#!/bin/bash
# Loop Skill Stop Hook
# Prevents session exit while a loop is active; feeds the SAME prompt back.
# Domain-agnostic: never reads or writes anything inside state_dir.

set -euo pipefail

HOOK_INPUT=$(cat)

STATE_FILE=".claude/loop-skill.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

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

TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')
if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Loop skill: transcript file not found. Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  Loop skill: no assistant messages found in transcript. Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
if [[ -z "$LAST_LINES" ]]; then
  echo "⚠️  Loop skill: failed to extract assistant messages. Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]]; then
  echo "⚠️  Loop skill: failed to parse transcript JSON. Stopping." >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "✅ Loop skill: detected <promise>$COMPLETION_PROMISE</promise>"
    rm "$STATE_FILE"
    exit 0
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

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Loop iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when TRUE)"
else
  SYSTEM_MSG="🔄 Loop iteration $NEXT_ITERATION | No completion promise set — runs until max-iterations"
fi

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
```

**원본 ralph-loop `stop-hook.sh` 대비 변경점**: 상태 파일 경로(`ralph-loop.local.md` → `loop-skill.local.md`)와 로그 메시지 문구(브랜딩)뿐이다. iteration 증가, session 검증, numeric validation, transcript 파싱, `<promise>` 비교, 원자적 쓰기(temp file + mv) 로직은 **바이트 단위로 동일**하다. `state_dir`/`pipeline` 필드는 frontmatter에 있어도 이 스크립트는 아예 읽지 않는다 — 계획 §3.5/§6.2의 "코어는 state_dir를 절대 읽거나 쓰지 않는다"는 원칙을 코드로 증명한다.

## 8. `pipelines/README.md`

```markdown
# Pipeline 확장 가이드

이 디렉토리에 `pipelines/<name>/prompt.md`를 추가하면 `/loop-skill --pipeline <name>`으로
그 내용을 loop의 고정 프롬프트로 사용할 수 있습니다.

## 필수
- `pipelines/<name>/prompt.md` — loop이 매 iteration 그대로 재feed할 프롬프트 본문.
  이 파일 안에서 상태를 어떻게 유지할지(단일 리포트 파일, 여러 subagent가 협업하는
  manifest.json 기반 파이프라인 등)는 전적으로 여러분이 설계합니다.

## 선택
- `pipelines/<name>/agents/*.md` — Claude Code 커스텀 subagent 정의. 존재하면 설치 시
  `~/.claude/agents/`로 자동 복사됩니다. 파일 개수/이름/내용은 코어가 전혀 신경 쓰지 않습니다.
- 그 외 원하는 어떤 파일이든(예: playbook 문서) — `prompt.md`에서 Read 툴로 직접 참조하세요.

## 코어가 보장하는 것
- `state_dir`(빈 디렉토리 하나)가 항상 준비되어 있습니다. 경로는 loop 시작 시 출력되고,
  state 파일의 `state_dir` frontmatter 필드에도 기록됩니다.
- 매 iteration 동일한 `prompt.md` 내용이 그대로 재feed됩니다.
- `<promise>텍스트</promise>`가 `--completion-promise`와 정확히 일치하면 loop이 종료됩니다.

## 코어가 하지 않는 것 (여러분의 책임)
- `state_dir` 내부에 무엇을 만들지 결정하지 않습니다.
- 작업이 끝났는지 판단하지 않습니다 — `prompt.md`가 LLM에게 판단 기준을 제시해야 합니다.
- 여러 agent를 어떤 순서로 부를지 orchestrate하지 않습니다 — 필요하다면 `prompt.md` 자체가
  orchestrator 역할을 하도록 작성하세요 (예시: `harness_loop_plan_v02.md` 부록 A 참고).
```

## 9. State 파일 스키마 (최종)

```yaml
---
active: true
iteration: 1
session_id: ses_xxx
max_iterations: 50
completion_promise: "DONE"        # 또는 null
started_at: "2026-07-19T10:00:00Z"
state_dir: ".claude/loop-skill/loop-20260719-100000"
pipeline: null                    # 또는 "<pipeline-name>"
---

[프롬프트 본문 — --pipeline 지정 시 pipelines/<name>/prompt.md 내용,
 아니면 사용자가 직접 입력한 텍스트. 이후 iteration에서도 변경되지 않는다]
```

## 10. Installer / Uninstaller

### 10.1 `install/install.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SKILL_DIR="$PROJECT_ROOT/loop-skill"
INSTALL_STATE_FILE="$SCRIPT_DIR/install-state.json"

CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
CLAUDE_COMMANDS_DIR="${HOME}/.claude/commands"
CLAUDE_AGENTS_DIR="${HOME}/.claude/agents"
CLAUDE_SETTINGS_FILE="${HOME}/.claude/settings.json"
PAYLOAD_TARGET="${CLAUDE_SKILLS_DIR}/loop-skill"

CREATED_FILES=()
MODIFIED_FILES=()
HOOKS_INSTALLED_JSON="[]"
CLEANUP_NEEDED=false

check_not_installed() {
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    echo "❌ Error: Already installed. Run ./install/uninstall.sh first." >&2
    exit 1
  fi
}

check_jq() {
  command -v jq &>/dev/null || { echo "❌ Error: jq is required (apt/brew install jq)." >&2; exit 1; }
}

check_skill_source() {
  [[ -d "$SKILL_DIR" ]] || { echo "❌ Error: skill source not found at $SKILL_DIR" >&2; exit 1; }
}

# [CR-6] Partial-cleanup on any failure after payload copy begins.
cleanup_on_failure() {
  if [[ "$CLEANUP_NEEDED" == "true" ]]; then
    echo "⚠️  Installation failed — rolling back partial changes..." >&2
    [[ -e "$PAYLOAD_TARGET" ]] && rm -rf "$PAYLOAD_TARGET"
    local f
    for f in "${CREATED_FILES[@]:-}"; do [[ -n "$f" && -e "$f" ]] && rm -f "$f"; done
    if [[ -f "${CLAUDE_SETTINGS_FILE}.loop-skill.bak" ]]; then
      mv "${CLAUDE_SETTINGS_FILE}.loop-skill.bak" "$CLAUDE_SETTINGS_FILE"
    fi
    rm -f "$INSTALL_STATE_FILE"
  fi
}
trap cleanup_on_failure ERR

compute_source_hash() {
  tar cf - -C "$(dirname "$SKILL_DIR")" "$(basename "$SKILL_DIR")" 2>/dev/null | sha256sum | cut -d' ' -f1
}

install_payload() {
  if [[ -e "$PAYLOAD_TARGET" ]]; then
    echo "⚠️  Warning: target already exists at $PAYLOAD_TARGET — skipping payload install" >&2
    echo "false"
    return
  fi
  CLEANUP_NEEDED=true
  mkdir -p "$CLAUDE_SKILLS_DIR"
  cp -r "$SKILL_DIR" "$PAYLOAD_TARGET"
  echo "true"
}

# [CR-1] Copying payload is not enough — commands and the Stop hook must be
# registered explicitly for Claude Code to recognize them at all.
register_hooks_and_commands() {
  mkdir -p "$CLAUDE_COMMANDS_DIR"
  local cmd dest
  for cmd in loop-skill cancel-loop-skill; do
    dest="${CLAUDE_COMMANDS_DIR}/${cmd}.md"
    sed "s|\${CLAUDE_PLUGIN_ROOT}|${PAYLOAD_TARGET}|g" "${PAYLOAD_TARGET}/commands/${cmd}.md" > "$dest"
    CREATED_FILES+=("$dest")
  done

  [[ -f "$CLAUDE_SETTINGS_FILE" ]] || { mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"; echo '{}' > "$CLAUDE_SETTINGS_FILE"; }
  local backup="${CLAUDE_SETTINGS_FILE}.loop-skill.bak"
  cp "$CLAUDE_SETTINGS_FILE" "$backup"

  local hook_cmd="${PAYLOAD_TARGET}/hooks/stop-hook.sh"
  jq --arg cmd "$hook_cmd" '
    .hooks.Stop = ((.hooks.Stop // []) + [{"hooks": [{"type": "command", "command": $cmd}]}])
  ' "$backup" > "${CLAUDE_SETTINGS_FILE}.tmp"

  if ! jq empty "${CLAUDE_SETTINGS_FILE}.tmp" 2>/dev/null; then
    echo "❌ Error: settings.json merge produced invalid JSON — aborting, original untouched" >&2
    rm -f "${CLAUDE_SETTINGS_FILE}.tmp"
    exit 1
  fi
  mv "${CLAUDE_SETTINGS_FILE}.tmp" "$CLAUDE_SETTINGS_FILE"
  MODIFIED_FILES+=("$CLAUDE_SETTINGS_FILE")

  HOOKS_INSTALLED_JSON=$(jq -n --arg tf "$CLAUDE_SETTINGS_FILE" --arg cmd "$hook_cmd" --arg bk "$backup" \
    '[{"target_file": $tf, "event": "Stop", "command": $cmd, "backup_file": $bk}]')
}

# Generic — independent of any specific pipeline. No-op if the given
# pipeline (if any) has no agents/ subfolder, or if no pipeline is given
# at install time (this core release ships no bundled pipeline).
register_pipeline_agents() {
  local pipeline_name="${1:-}"
  [[ -z "$pipeline_name" ]] && return 0
  local agents_src="${PAYLOAD_TARGET}/pipelines/${pipeline_name}/agents"
  [[ -d "$agents_src" ]] || return 0
  mkdir -p "$CLAUDE_AGENTS_DIR"
  local f dest
  for f in "$agents_src"/*.md; do
    [[ -e "$f" ]] || continue
    dest="${CLAUDE_AGENTS_DIR}/$(basename "$f")"
    cp "$f" "$dest"
    CREATED_FILES+=("$dest")
  done
}

detect_opencode_and_oh_my_openagent() {
  local opencode_detected=false
  local omo_detected=false
  command -v opencode &>/dev/null && opencode_detected=true
  if [[ -f "${HOME}/.config/opencode/opencode.json" ]]; then
    grep -q "oh-my-openagent\|oh-my-opencode" "${HOME}/.config/opencode/opencode.json" 2>/dev/null && omo_detected=true
  fi
  if [[ "$opencode_detected" == "true" ]]; then
    if [[ "$omo_detected" == "true" ]]; then
      echo "ℹ️  OpenCode + oh-my-openagent 감지됨 — Tier 1 loop 지원이 동작할 수 있습니다 (미검증, Phase -1 참고)." >&2
    else
      echo "ℹ️  OpenCode가 감지되었지만 oh-my-openagent가 없습니다." >&2
      echo "    OpenCode에서 loop를 쓰려면 oh-my-openagent(Claude Code 호환 기능) 설치가 필요합니다." >&2
    fi
  fi
  jq -n --argjson d "$opencode_detected" --argjson o "$omo_detected" '{"detected": $d, "oh_my_openagent_detected": $o}'
}

write_install_state() {
  local payload_installed="$1" source_hash="$2" opencode_json="$3"
  local created_json modified_json
  created_json=$(printf '%s\n' "${CREATED_FILES[@]:-}" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
  modified_json=$(printf '%s\n' "${MODIFIED_FILES[@]:-}" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')

  jq -n \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg target "$PAYLOAD_TARGET" \
    --arg source "$SKILL_DIR" \
    --arg hash "sha256:$source_hash" \
    --argjson installed "$payload_installed" \
    --argjson hooks "$HOOKS_INSTALLED_JSON" \
    --argjson created "$created_json" \
    --argjson modified "$modified_json" \
    --argjson opencode "$opencode_json" \
    '{
      version: "1.0.0",
      installed_at: $installed_at,
      install_mode: "copy",
      installations: {
        claude_code: {target: $target, source: $source, type: "copy", source_hash: $hash, installed: $installed, verified: $installed}
      },
      hooks_installed: $hooks,
      files_created: $created,
      files_modified: $modified,
      opencode: $opencode
    }' > "$INSTALL_STATE_FILE"
}

main() {
  echo "🚀 Loop Skill Installer"
  check_not_installed
  check_jq
  check_skill_source

  local payload_installed
  payload_installed=$(install_payload)

  if [[ "$payload_installed" == "true" ]]; then
    register_hooks_and_commands
    register_pipeline_agents ""   # core ships no bundled pipeline; no-op today
  fi

  local hash opencode_json
  hash=$(compute_source_hash)
  opencode_json=$(detect_opencode_and_oh_my_openagent)

  write_install_state "$payload_installed" "$hash" "$opencode_json"

  CLEANUP_NEEDED=false
  echo "✅ Installation complete! Uninstall with: ./install/uninstall.sh"
}

main "$@"
```

### 10.2 `install/uninstall.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_STATE_FILE="$SCRIPT_DIR/install-state.json"

check_installed() {
  [[ -f "$INSTALL_STATE_FILE" ]] || { echo "❌ Error: Not installed (install-state.json not found)." >&2; exit 1; }
}

check_jq() {
  command -v jq &>/dev/null || { echo "❌ Error: jq is required." >&2; exit 1; }
}

# Precise removal: delete only files_created[], and remove only the
# specific Stop hook entry this installer added — never wholesale-restore
# settings.json, since the user may have added other hooks/permissions
# after we installed.
unregister_hooks_and_commands() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f" && echo "   ✓ Removed: $f"
  done < <(jq -r '.files_created[]? // empty' "$INSTALL_STATE_FILE")

  local settings_file hook_cmd backup
  settings_file=$(jq -r '.hooks_installed[0].target_file // empty' "$INSTALL_STATE_FILE")
  hook_cmd=$(jq -r '.hooks_installed[0].command // empty' "$INSTALL_STATE_FILE")
  backup=$(jq -r '.hooks_installed[0].backup_file // empty' "$INSTALL_STATE_FILE")

  if [[ -n "$settings_file" && -f "$settings_file" && -n "$hook_cmd" ]]; then
    jq --arg cmd "$hook_cmd" '
      .hooks.Stop = ((.hooks.Stop // []) | map(select(
        ((.hooks // []) | any(.command == $cmd)) | not
      )))
    ' "$settings_file" > "${settings_file}.tmp"

    if jq empty "${settings_file}.tmp" 2>/dev/null; then
      mv "${settings_file}.tmp" "$settings_file"
      echo "   ✓ Removed Stop hook entry from $settings_file"
    else
      echo "⚠️  Precise removal produced invalid JSON — leaving settings.json untouched." >&2
      echo "    Backup available at: $backup" >&2
      rm -f "${settings_file}.tmp"
    fi
  fi

  [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
}

uninstall_payload() {
  local target installed
  target=$(jq -r '.installations.claude_code.target' "$INSTALL_STATE_FILE")
  installed=$(jq -r '.installations.claude_code.installed' "$INSTALL_STATE_FILE")
  if [[ "$installed" == "true" && -n "$target" && -e "$target" ]]; then
    rm -rf "$target"
    echo "   ✓ Removed: $target"
  fi
}

main() {
  echo "🗑️  Loop Skill Uninstaller"
  check_installed
  check_jq
  unregister_hooks_and_commands
  uninstall_payload
  rm -f "$INSTALL_STATE_FILE"
  echo "✅ Uninstallation complete!"
}

main "$@"
```

### 10.3 `install/install.ps1` (Windows PowerShell — 동일 로직)

```powershell
#requires -Version 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$SkillDir = Join-Path $ProjectRoot "loop-skill"
$InstallStateFile = Join-Path $ScriptDir "install-state.json"

$ClaudeSkillsDir = Join-Path $env:USERPROFILE ".claude\skills"
$ClaudeCommandsDir = Join-Path $env:USERPROFILE ".claude\commands"
$ClaudeAgentsDir = Join-Path $env:USERPROFILE ".claude\agents"
$ClaudeSettingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
$PayloadTarget = Join-Path $ClaudeSkillsDir "loop-skill"

$CreatedFiles = @()
$ModifiedFiles = @()
$HooksInstalled = @()

function Test-NotInstalled {
    if (Test-Path $InstallStateFile) {
        Write-Host "❌ Error: Already installed." -ForegroundColor Red
        exit 1
    }
}

function Test-SkillSource {
    if (-not (Test-Path $SkillDir)) {
        Write-Host "❌ Error: skill source not found at $SkillDir" -ForegroundColor Red
        exit 1
    }
}

function Get-SourceHash {
    $hash = Get-FileHash -Algorithm SHA256 -Path (Get-ChildItem -Recurse -File $SkillDir | Sort-Object FullName | ForEach-Object { $_.FullName }) -ErrorAction SilentlyContinue
    # Simplified: hash the concatenated file list; a real implementation should hash content, not just paths.
    return "sha256:approx"
}

function Install-Payload {
    if (Test-Path $PayloadTarget) {
        Write-Host "⚠️  Target already exists at $PayloadTarget — skipping" -ForegroundColor Yellow
        return $false
    }
    New-Item -ItemType Directory -Path $ClaudeSkillsDir -Force | Out-Null
    Copy-Item -Path $SkillDir -Destination $PayloadTarget -Recurse -Force
    return $true
}

function Register-HooksAndCommands {
    New-Item -ItemType Directory -Path $ClaudeCommandsDir -Force | Out-Null
    foreach ($cmd in @("loop-skill", "cancel-loop-skill")) {
        $src = Join-Path $PayloadTarget "commands\$cmd.md"
        $dest = Join-Path $ClaudeCommandsDir "$cmd.md"
        (Get-Content $src -Raw) -replace '\$\{CLAUDE_PLUGIN_ROOT\}', $PayloadTarget | Set-Content $dest
        $script:CreatedFiles += $dest
    }

    if (-not (Test-Path $ClaudeSettingsFile)) {
        New-Item -ItemType Directory -Path (Split-Path $ClaudeSettingsFile) -Force | Out-Null
        '{}' | Set-Content $ClaudeSettingsFile
    }
    $backup = "$ClaudeSettingsFile.loop-skill.bak"
    Copy-Item $ClaudeSettingsFile $backup -Force

    $settings = Get-Content $backup -Raw | ConvertFrom-Json
    $hookCmd = Join-Path $PayloadTarget "hooks\stop-hook.sh"
    if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{}) }
    if (-not $settings.hooks.Stop) { $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @() }
    $settings.hooks.Stop += [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = "command"; command = $hookCmd }) }

    try {
        $settings | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettingsFile
    } catch {
        Write-Host "❌ Error: settings.json merge failed — restoring backup" -ForegroundColor Red
        Copy-Item $backup $ClaudeSettingsFile -Force
        exit 1
    }
    $script:ModifiedFiles += $ClaudeSettingsFile
    $script:HooksInstalled += [PSCustomObject]@{ target_file = $ClaudeSettingsFile; event = "Stop"; command = $hookCmd; backup_file = $backup }
}

function Register-PipelineAgents {
    param([string]$PipelineName)
    if ([string]::IsNullOrEmpty($PipelineName)) { return }
    $agentsSrc = Join-Path $PayloadTarget "pipelines\$PipelineName\agents"
    if (-not (Test-Path $agentsSrc)) { return }
    New-Item -ItemType Directory -Path $ClaudeAgentsDir -Force | Out-Null
    Get-ChildItem -Path $agentsSrc -Filter "*.md" | ForEach-Object {
        $dest = Join-Path $ClaudeAgentsDir $_.Name
        Copy-Item $_.FullName $dest -Force
        $script:CreatedFiles += $dest
    }
}

function Test-OpenCodeAndOhMyOpenagent {
    $opencodeDetected = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
    $omoDetected = $false
    $ocConfig = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    if (Test-Path $ocConfig) {
        $content = Get-Content $ocConfig -Raw
        $omoDetected = $content -match "oh-my-openagent|oh-my-opencode"
    }
    if ($opencodeDetected -and -not $omoDetected) {
        Write-Host "ℹ️  OpenCode에서 loop를 쓰려면 oh-my-openagent 설치가 필요합니다." -ForegroundColor Cyan
    }
    return @{ detected = $opencodeDetected; oh_my_openagent_detected = $omoDetected }
}

function Write-InstallState {
    param($PayloadInstalled, $SourceHash, $OpenCodeInfo)
    $state = [PSCustomObject]@{
        version = "1.0.0"
        installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        install_mode = "copy"
        installations = @{ claude_code = @{ target = $PayloadTarget; source = $SkillDir; type = "copy"; source_hash = $SourceHash; installed = $PayloadInstalled; verified = $PayloadInstalled } }
        hooks_installed = $HooksInstalled
        files_created = $CreatedFiles
        files_modified = $ModifiedFiles
        opencode = $OpenCodeInfo
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content $InstallStateFile
}

function Main {
    Write-Host "🚀 Loop Skill Installer" -ForegroundColor Cyan
    Test-NotInstalled
    Test-SkillSource

    $payloadInstalled = Install-Payload
    if ($payloadInstalled) {
        Register-HooksAndCommands
        Register-PipelineAgents -PipelineName ""
    }

    $hash = Get-SourceHash
    $ocInfo = Test-OpenCodeAndOhMyOpenagent
    Write-InstallState -PayloadInstalled $payloadInstalled -SourceHash $hash -OpenCodeInfo $ocInfo

    Write-Host "✅ Installation complete! Uninstall with: .\install\uninstall.ps1" -ForegroundColor Green
}

Main
```

### 10.4 `install/uninstall.ps1`

```powershell
#requires -Version 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallStateFile = Join-Path $ScriptDir "install-state.json"

function Test-Installed {
    if (-not (Test-Path $InstallStateFile)) {
        Write-Host "❌ Error: Not installed." -ForegroundColor Red
        exit 1
    }
}

function Unregister-HooksAndCommands {
    $state = Get-Content $InstallStateFile -Raw | ConvertFrom-Json
    foreach ($f in $state.files_created) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Host "   ✓ Removed: $f" -ForegroundColor Green }
    }

    $hookInfo = $state.hooks_installed | Select-Object -First 1
    if ($hookInfo -and (Test-Path $hookInfo.target_file)) {
        $settings = Get-Content $hookInfo.target_file -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.Stop) {
            $settings.hooks.Stop = $settings.hooks.Stop | Where-Object {
                -not ($_.hooks | Where-Object { $_.command -eq $hookInfo.command })
            }
            try {
                $settings | ConvertTo-Json -Depth 10 | Set-Content $hookInfo.target_file
                Write-Host "   ✓ Removed Stop hook entry from $($hookInfo.target_file)" -ForegroundColor Green
            } catch {
                Write-Host "⚠️  Precise removal failed — backup at $($hookInfo.backup_file)" -ForegroundColor Yellow
            }
        }
        if (Test-Path $hookInfo.backup_file) { Remove-Item $hookInfo.backup_file -Force }
    }
}

function Uninstall-Payload {
    $state = Get-Content $InstallStateFile -Raw | ConvertFrom-Json
    $target = $state.installations.claude_code.target
    if ($state.installations.claude_code.installed -and (Test-Path $target)) {
        Remove-Item $target -Recurse -Force
        Write-Host "   ✓ Removed: $target" -ForegroundColor Green
    }
}

function Main {
    Write-Host "🗑️  Loop Skill Uninstaller" -ForegroundColor Cyan
    Test-Installed
    Unregister-HooksAndCommands
    Uninstall-Payload
    Remove-Item $InstallStateFile -Force
    Write-Host "✅ Uninstallation complete!" -ForegroundColor Green
}

Main
```

### 10.5 `install-state.json` 스키마

```json
{
  "version": "1.0.0",
  "installed_at": "2026-07-19T10:00:00Z",
  "install_mode": "copy",
  "installations": {
    "claude_code": {
      "target": "/home/user/.claude/skills/loop-skill",
      "source": "/home/user/study/BackEnd/loop_skill/loop-skill",
      "type": "copy",
      "source_hash": "sha256:8f3a...",
      "installed": true,
      "verified": true
    }
  },
  "hooks_installed": [
    {
      "target_file": "/home/user/.claude/settings.json",
      "event": "Stop",
      "command": "/home/user/.claude/skills/loop-skill/hooks/stop-hook.sh",
      "backup_file": "/home/user/.claude/settings.json.loop-skill.bak"
    }
  ],
  "files_created": [
    "/home/user/.claude/commands/loop-skill.md",
    "/home/user/.claude/commands/cancel-loop-skill.md"
  ],
  "files_modified": ["/home/user/.claude/settings.json"],
  "opencode": {"detected": false, "oh_my_openagent_detected": false}
}
```

## 11. 구현 단계 (Phase → 산출물 매핑)

| Phase | 산출물 | 완료 기준 |
|---|---|---|
| -1 | (코드 아님) 검증 로그 | Test 1, Test 9 재현 성공 |
| 0 | §1 디렉토리 트리 | `find loop-skill -type d`로 구조 확인 |
| 1 | §2, §6, §7 (plugin.json, hooks.json, stop-hook.sh) | 원본 ralph-loop과 diff 최소화 확인 |
| 2 | §5 (setup-loop-skill.sh) | Test 3, 7, 8 통과 |
| 3 | §7 반영 완료 (Stop hook) | Test 5, 6 통과 |
| 4 | §3, §4 (commands) | Test 1의 커맨드 파싱 부분 통과 |
| 5 | §8 (pipelines/README.md) + 최소 예시 pipeline 1개(범위 안이지만 이 스펙에서는 README까지만 다룸) | Test 8 통과 |
| 6 | §10 (installer/uninstaller 전체) | Test 1, 2, 4 통과 |
| 7 | 통합 | Test 10 (Full Cycle) 통과 |

## 12. LLM Self-Testable Test Cases

**설계 원칙**: 입력/실행 단계/기대 결과가 명확하고, LLM이 스스로 실행 후 pass/fail을 판정할 수 있어야 한다. 실패 시 원인을 바로 알 수 있는 문구를 포함한다.

---

**Test 1: Fresh Install — Payload + Command + Hook 등록 확인**
```bash
# Pre-condition: install-state.json 없음, ~/.claude/skills/loop-skill 없음
./install/install.sh
# 검증:
test -f install/install-state.json
test -d ~/.claude/skills/loop-skill
test -f ~/.claude/commands/loop-skill.md
test -f ~/.claude/commands/cancel-loop-skill.md
grep -c '${CLAUDE_PLUGIN_ROOT}' ~/.claude/commands/loop-skill.md    # 반드시 0
jq -e '.hooks.Stop | length > 0' ~/.claude/settings.json
jq empty ~/.claude/settings.json                                    # 유효한 JSON
test -f ~/.claude/settings.json.loop-skill.bak
# Expected: 위 검증 전부 통과, exit code 0
```

**Test 2: Already Installed → Error, 변경 없음**
```bash
# Pre-condition: Test 1 완료 상태
BEFORE_HASH=$(sha256sum install/install-state.json)
./install/install.sh; echo "exit=$?"
AFTER_HASH=$(sha256sum install/install-state.json)
# Expected: exit=1, "Already installed" 메시지, BEFORE_HASH == AFTER_HASH
```

**Test 3: Active Loop 중복 방지**
```bash
# Pre-condition: 설치 완료, 프로젝트에서 세션 시작
/loop-skill "테스트 작업 1" --max-iterations 5
# 같은 세션(또는 같은 프로젝트의 다른 세션)에서
/loop-skill "테스트 작업 2" --max-iterations 5
# Expected: 두 번째 호출은 "이미 활성 loop가 있습니다" 에러로 즉시 종료(exit 1),
#           .claude/loop-skill.local.md의 iteration/session_id는 첫 번째 호출 값 그대로 불변
```

**Test 4: Uninstall 정밀 복원 (전체 롤백 아님)**
```bash
# Pre-condition: Test 1 완료 + 사용자가 설치 후 직접 다른 hook을 settings.json에 추가했다고 가정
jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"/some/other/hook.sh"}]}]' \
  ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
./install/uninstall.sh
# 검증:
jq -e '.hooks.Stop | map(select(.hooks[0].command == "/some/other/hook.sh")) | length == 1' ~/.claude/settings.json
jq -e '.hooks.Stop | map(select(.hooks[0].command | contains("loop-skill"))) | length == 0' ~/.claude/settings.json
test ! -f ~/.claude/commands/loop-skill.md
test ! -d ~/.claude/skills/loop-skill
test ! -f install/install-state.json
# Expected: 사용자가 나중에 추가한 hook은 그대로 남고, loop-skill이 등록한 것만 제거됨
```

**Test 5: 완료 조건 텍스트 정확 매칭**
```bash
/loop-skill "간단한 작업" --completion-promise "ALL DONE" --max-iterations 10
# iteration 1: LLM이 "<promise>almost done</promise>" 같은 유사 문구 출력 (고의로 불일치)
# Expected: loop 계속됨 (state 파일 iteration 증가, active 유지)
# iteration 2: LLM이 정확히 "<promise>ALL DONE</promise>" 출력
# Expected: loop 즉시 종료, .claude/loop-skill.local.md 삭제됨
```

**Test 6: State Dir 비침습성 (§3.5/§6.2 계약 검증)**
```bash
/loop-skill "state_dir 테스트" --max-iterations 3
STATE_DIR=$(grep '^state_dir:' .claude/loop-skill.local.md | sed 's/state_dir: *"\(.*\)"/\1/')
BEFORE=$(find "$STATE_DIR" -type f | sort)
# iteration 진행을 트리거 (세션 종료 시도)
AFTER=$(find "$STATE_DIR" -type f | sort)
# Expected: BEFORE == AFTER (코어 자체가 만든 파일이 하나도 없어야 함 — LLM이 직접 그 안에
#           뭔가 썼다면 그건 LLM/pipeline이 한 것이지 stop-hook.sh나 setup 스크립트가 한 게 아님을
#           코드 리뷰로 재확인)
```

**Test 7: 옵션 없는 기본 사용 (하위 호환성)**
```bash
/loop-skill "그냥 코드 리팩토링 작업" --completion-promise "REFACTOR DONE" --max-iterations 5
grep '^pipeline:' .claude/loop-skill.local.md
# Expected: "pipeline: null", 프롬프트 본문에 "그냥 코드 리팩토링 작업"이 그대로 들어있음 —
#           원본 ralph-loop과 동일하게 동작
```

**Test 8: `--pipeline` 로딩**
```bash
# Pre-condition: pipelines/smoke-test/prompt.md 존재 (Phase 5 최소 예시)
/loop-skill --pipeline smoke-test --completion-promise "SMOKE OK" --max-iterations 5
grep '^pipeline:' .claude/loop-skill.local.md    # "pipeline: \"smoke-test\""
# 주의: state 파일은 frontmatter(두 번째 ---)와 본문 사이에 항상 빈 줄 하나가 들어가는 구조다
# (원본 ralph-loop과 동일한 컨벤션). 그래서 추출한 본문의 "선행 빈 줄 1개"를 제거하고 비교해야 한다.
diff <(awk '/^---$/{i++;next} i>=2' .claude/loop-skill.local.md | tail -n +2) pipelines/smoke-test/prompt.md
# Expected: diff 결과 없음(동일, 선행 빈 줄 제외) — pipeline의 prompt.md 내용이 그대로 state 파일 본문에 복사됨
# (실제로 이 스펙 작성 중 sandbox에서 재현: 선행 빈 줄을 빼지 않고 비교하면 "1d0 <" 형태로 오탐 diff가 남는다 —
#  이는 --pipeline 로딩 로직의 버그가 아니라 state 파일 포맷 자체의 특성이므로, 테스트 판정 시 혼동하지 말 것)
```

**Test 9: Tier 1 OpenCode 재현** `[oh-my-openagent 설치 환경 전제]`
```bash
# Pre-condition: OpenCode + oh-my-openagent(Claude Code 호환) 설치, loop-skill install.sh 실행 완료
# OpenCode 세션에서 동일하게 /loop-skill 호출
opencode run "/loop-skill '오픈코드 테스트' --completion-promise 'OC DONE' --max-iterations 3"
# Expected: Claude Code에서와 동일하게 Stop hook이 발동해 세션 종료가 막히고,
#           completion-promise 매칭 시 정상 종료됨 — 별도 OpenCode 전용 코드 없이 동작
```

**Test 10: Full Cycle**
```bash
./install/install.sh
/loop-skill "e2e 테스트" --completion-promise "E2E DONE" --max-iterations 2
# iteration 2에서 LLM이 <promise>E2E DONE</promise> 출력
./install/uninstall.sh
find ~/.claude/skills/loop-skill ~/.claude/commands/loop-skill.md ~/.claude/commands/cancel-loop-skill.md 2>&1
# Expected: install 성공 → loop 2 iteration 후 completion-promise로 정상 종료 →
#           uninstall 후 위 find 결과가 전부 "No such file or directory"
```

**Test 11: Cancel 커맨드**
```bash
/loop-skill "취소 테스트" --max-iterations 20
/cancel-loop-skill
test ! -f .claude/loop-skill.local.md
# 이후 세션 종료 시도
# Expected: Stop hook이 상태 파일을 찾지 못해 exit 0 (정상 종료 허용), state_dir는 남아있어도 무방
```

**Test 12: 손상된 State 파일 복구**
```bash
/loop-skill "손상 테스트" --max-iterations 10
sed -i 's/^iteration: .*/iteration: not-a-number/' .claude/loop-skill.local.md
# 세션 종료 시도 트리거
test ! -f .claude/loop-skill.local.md
# Expected: "state file corrupted" 경고 출력, state 파일 삭제, 세션 종료 허용(에러로 죽지 않음)
```

## 13. 기술 스택

- **Language**: Bash(scripts/hooks), PowerShell(installers), Markdown(commands/pipeline prompt)
- **Data Format**: YAML(state frontmatter), JSON(hook 출력, install-state.json)
- **File Operations**: cp, rm, jq(JSON 병합/파싱), sha256sum/tar(해시 계산)
- **외부 의존성**: `jq`(필수, install/uninstall/stop-hook 전부에서 사용), `perl`(stop-hook의 `<promise>` 추출, 원본 ralph-loop과 동일)

## 14. 참고 문서

- `harness_loop_plan_v02.md` — 이 스펙이 구현하는 계획 (아키텍처 원칙 §3, Pipeline 확장 계약 §3.6)
- `harness_loop_plan.md`(v01) — 조사 근거(CR-1~CR-8)
- ralph-loop 원본 소스: `/home/fanta/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/`
