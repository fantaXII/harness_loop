# 역방향 Loop 적용 구현 스펙 (v03)

## 문서 버전

- v03.0 (최초) — `harness_loop_plan_v03.md` 확정 설계를 구현 가능한 파일 단위 스펙으로 전개.
- 이 스펙에 포함된 스크립트 로직(frontmatter 분리 awk, 완료계약 감지 정규식, meta 생성 jq)은
  작성 중 sandbox에서 실제로 실행해 동작을 확인했다(§0 하단 참고).

## 0. 이 스펙의 범위

- **구현 대상:** `harness_loop_plan_v03.md`가 확정한 설계 — 기존 skill을 `<name>-loop`로 rename +
  wrap하고, start쪽 엔진(`setup-loop-skill.sh`/`.ps1`)을 각 skill에 번들 복사, Stop 훅은 중앙 1개
  유지. `apply-skill.sh`/`.ps1`(적용), `unapply-skill.sh`/`.ps1`(원복)을 `loop-skill` 플러그인
  페이로드에 신규 스크립트로 추가한다.
- **코어(v02) 변경은 단 하나:** `scripts/setup-loop-skill.sh`에 `--prompt-file` 모드 추가(§2).
  `hooks/stop-hook.sh`, state 파일 스키마, `status.json` 완료 신호는 **무수정**.
- **범위 밖(§0 of plan v03 그대로 승계):** 동시성 락, 디스크/권한/인코딩 방어, UX 장식(진행바·색상),
  버전 계약 강제/마이그레이션, 문서 세트, 성능 최적화, 외부 통합. 이번 스펙도 이 경계를 유지한다.
- **알려진 미해결 risk (plan v03 §13.1 승계, 이 스펙에서도 해결하지 않음):** R1(Stop 훅 멱등 등록의
  다중 settings 레이어 dedup), R2(세션 중 훅 등록 즉시 발화 여부 — Phase 0 실측 대상), R3(죽은 loop의
  state 지뢰). 이 스펙은 R1을 "loop-skill install.sh가 이미 등록한 훅이 있는지 존재 확인" 수준까지만
  다루고(§4.1의 사전조건 체크), R1의 완전한 다층 dedup·R3의 liveness 판정은 구현하지 않는다 —
  구현 시 별도 결정 필요(plan §13.1 그대로 인용).
- **검증 방법론:** 이 스펙의 핵심 텍스트 처리 로직(frontmatter 첫 두 `---` 제거, 완료계약 중복감지
  정규식, `.loop-meta.json` jq 생성)은 작성 중 bash sandbox에서 직접 실행해 확인했다. 특히
  frontmatter 추출 awk는 **본문에 `---`가 있는 케이스**(plan §13 위험 항목)로 실측했다 — 최초 시도한
  두 규칙짜리 awk(`/^---$/ && n<2 {next} {print}`)는 print 규칙에 조건이 없어 frontmatter 본문까지
  통과시키는 버그가 있었고, `n>=2` 조건을 추가해 수정 후 재검증했다. §3.1의 스크립트는 수정된
  버전이다.

---

## 1. 디렉토리 구조 (구현 대상)

기존 `loop-skill/` 페이로드(v02, 이미 구현됨)에 아래를 추가한다. 기존 파일 중 수정되는 것은
`scripts/setup-loop-skill.sh` 하나뿐(§2).

```
loop-skill/
  .claude-plugin/
    plugin.json                    # (기존, 무수정) — engine_version 출처로 읽힘
  commands/
    loop-skill.md                  # (기존, 무수정)
    cancel-loop-skill.md           # (기존, 무수정)
  hooks/
    hooks.json                     # (기존, 무수정)
    stop-hook.sh                   # (기존, 무수정)
  scripts/
    setup-loop-skill.sh            # (수정 — §2: --prompt-file 추가)
    setup-loop-skill.ps1           # (신규 — §3: bash 엔진의 PowerShell 대응, 동일 계약)
    apply-skill.sh                 # (신규 — §4)
    unapply-skill.sh               # (신규 — §5)
    apply-skill.ps1                # (신규 — §6)
    unapply-skill.ps1              # (신규 — §6)
  pipelines/                       # (기존, 무수정 — v03과 무관)
  install/                         # (기존, 무수정 — loop-skill 자체 설치는 v02 그대로)
```

**설치 후 대상 머신 레이아웃** (apply 실행 후, plan §6.2와 동일):

```
~/.claude/skills/
  loop-skill/                      # v02 코어 (Stop 훅 런타임 + apply/unapply 스크립트 소재지)
  <name>-loop/                     # apply 결과물 — §7 launcher + 번들 엔진 + pipeline.md + meta
~/.claude/loop-applied/
  backups/<name>/                  # pristine 원본 (비활성)
  apply-state.json                 # 적용 이력
```

`apply-skill.sh`/`unapply-skill.sh`는 `loop-skill` 플러그인 설치 시 v02 install.sh가 다른
스크립트들처럼 실행 권한을 부여해 배치한다(이 스펙에서는 install.sh 자체는 수정하지 않고, 새 파일이
`scripts/`에 있으면 기존 `cp -r "$SKILL_DIR" "$PAYLOAD_TARGET"` 전체 복사 로직이 자동으로 포함한다 —
install.sh 코드 변경 불필요).

---

## 2. 코어 변경 — `scripts/setup-loop-skill.sh`에 `--prompt-file` 추가

plan v03 §10의 유일한 코어 변경. 기존 `--pipeline`/인라인 PROMPT 분기 옆에 새 분기를 추가한다.
아래는 기존 스크립트(§103-122 라인 부근, "Resolve the prompt body" 섹션)에 대한 **diff**다.

```diff
--- a/loop-skill/scripts/setup-loop-skill.sh
+++ b/loop-skill/scripts/setup-loop-skill.sh
@@ -13,10 +13,12 @@
 PROMPT_PARTS=()
 MAX_ITERATIONS=""
 PIPELINE_NAME=""
+PROMPT_FILE=""
 STATE_DIR_OVERRIDE=""
 CLI_MAX_ITERATIONS_SET=false
 CLI_PIPELINE_SET=false
@@ -30,6 +32,7 @@ USAGE:
 OPTIONS:
   --max-iterations <n>   Maximum iterations before auto-stop (default: 50, 0 = unlimited)
   --pipeline <name>       Load pipelines/<name>/prompt.md as the loop body
                           (value = folder name under pipelines/, e.g. "l1-log-analysis")
+  --prompt-file <path>     Load an arbitrary absolute-path file as the loop body
+                          (used by apply-skill.sh launchers; see harness_loop_plan_v03.md §10)
   --state-dir <path>       Override the default state_dir location
   -h, --help              Show this help message
@@ -60,6 +63,12 @@
       fi
       PIPELINE_NAME="$2"; CLI_PIPELINE_SET=true; shift 2 ;;
+    --prompt-file)
+      if [[ -z "${2:-}" ]] || [[ ! -f "$2" ]]; then
+        echo "❌ Error: --prompt-file requires an existing file path, got: ${2:-<missing>}" >&2
+        exit 1
+      fi
+      PROMPT_FILE="$2"; shift 2 ;;
     --state-dir)
       if [[ -z "${2:-}" ]]; then
@@ -103,7 +112,10 @@
 # Resolve the prompt body: --pipeline takes precedence over inline PROMPT.
 # The core does NOT interpret pipeline prompt.md content — it is read and
 # copied verbatim. PIPELINE_NAME must match a folder name under pipelines/.
-if [[ -n "$PIPELINE_NAME" ]]; then
+# §10 (v03): --prompt-file sits between --pipeline and inline PROMPT in
+# precedence. Unlike --pipeline, it takes an absolute path and never touches
+# ${CLAUDE_PLUGIN_ROOT} — this is what makes bundled per-skill engines
+# relocatable (harness_loop_plan_v03.md §7.2).
+if [[ -n "$PIPELINE_NAME" ]]; then
   PIPELINE_PROMPT_FILE="${CLAUDE_PLUGIN_ROOT:-.}/pipelines/${PIPELINE_NAME}/prompt.md"
   if [[ ! -f "$PIPELINE_PROMPT_FILE" ]]; then
     echo "❌ Error: pipeline '$PIPELINE_NAME' not found (expected $PIPELINE_PROMPT_FILE)" >&2
     exit 1
   fi
   PROMPT=$(cat "$PIPELINE_PROMPT_FILE")
+elif [[ -n "$PROMPT_FILE" ]]; then
+  PROMPT=$(cat "$PROMPT_FILE")
 else
   PROMPT="${PROMPT_PARTS[*]:-}"
   if [[ -z "$PROMPT" ]]; then
     echo "❌ Error: No prompt provided and no --pipeline given" >&2
     echo "   Examples:" >&2
     echo "     /loop-skill Build a REST API for todos" >&2
     echo "     /loop-skill --pipeline l1-log-analysis" >&2
+    echo "     /loop-skill --prompt-file /abs/path/pipeline.md" >&2
     exit 1
   fi
 fi
@@ -134,6 +150,8 @@
 if [[ -n "$PIPELINE_NAME" ]]; then
   PIPELINE_YAML="\"$PIPELINE_NAME\""
+elif [[ -n "$PROMPT_FILE" ]]; then
+  PIPELINE_YAML="\"prompt-file:$(basename "$(dirname "$PROMPT_FILE")")\""
 else
   PIPELINE_YAML="null"
 fi
```

`pipeline:` frontmatter 필드는 `--prompt-file` 사용 시 `"prompt-file:<부모디렉토리명>"` 형태로
기록된다(예: `-loop` skill 안에서 실행되면 `"prompt-file:l1-log-analysis-loop"`). 이는 진단용
문자열일 뿐, 코어가 파싱하지 않는다(v02 §3.6 원칙 유지).

**변경되지 않는 것(명시적으로 강조):** `[CR-4]` 활성 loop 가드, state 파일 frontmatter 스키마,
`.claude/loop-skill.config` 처리, `--max-iterations` 로직은 diff에 없다 — 그대로다.

---

## 3. `scripts/setup-loop-skill.ps1` (신규 — Windows 엔진)

`setup-loop-skill.sh`와 **동일 계약**(같은 state 파일 스키마, 같은 CLI 옵션, 같은 `[CR-4]` 가드,
`--prompt-file` 포함)을 구현하는 PowerShell 버전. `-loop` skill이 Windows에서 `apply_skill.ps1`로
wrap됐을 때 launcher가 이 스크립트를 호출한다(plan §7.1.2).

```powershell
# setup-loop-skill.ps1 — Loop Skill Setup Script (PowerShell)
# 계약은 setup-loop-skill.sh와 동일. state 파일 포맷(YAML frontmatter + 본문)도 동일하게 생성한다.
# 상세 주석은 bash 버전(§2, 원본 setup-loop-skill.sh) 참고 — 여기서는 문법 차이만 표기.

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$ErrorActionPreference = "Stop"

$StateFile = ".claude\loop-skill.local.md"
$ConfigFile = ".claude\loop-skill.config"
$DefaultMaxIterations = 50

$PromptParts = @()
$MaxIterations = $null
$PipelineName = ""
$PromptFile = ""
$StateDirOverride = ""
$CliMaxIterationsSet = $false
$CliPipelineSet = $false

$i = 0
while ($i -lt $Args.Count) {
  switch ($Args[$i]) {
    { $_ -in "-h", "--help" } {
      Write-Host "Loop Skill - Generic self-referential development loop (PowerShell)"
      Write-Host "See setup-loop-skill.sh --help for full option reference (identical options)."
      exit 0
    }
    "--max-iterations" {
      $val = $Args[$i + 1]
      if (-not ($val -match '^\d+$')) {
        Write-Error "❌ Error: --max-iterations must be a non-negative integer, got: $val"
        exit 1
      }
      $MaxIterations = $val; $CliMaxIterationsSet = $true; $i += 2; continue
    }
    "--pipeline" {
      $PipelineName = $Args[$i + 1]; $CliPipelineSet = $true; $i += 2; continue
    }
    "--prompt-file" {
      $val = $Args[$i + 1]
      if (-not (Test-Path -Path $val -PathType Leaf)) {
        Write-Error "❌ Error: --prompt-file requires an existing file path, got: $val"
        exit 1
      }
      $PromptFile = $val; $i += 2; continue
    }
    "--state-dir" {
      $StateDirOverride = $Args[$i + 1]; $i += 2; continue
    }
    default {
      $PromptParts += $Args[$i]; $i += 1; continue
    }
  }
}

# §3.7 config defaults (동일 우선순위: CLI > config 파일 > 내장 기본값)
if (Test-Path $ConfigFile) {
  $configContent = Get-Content $ConfigFile
  $configPipeline = ($configContent | Select-String '^LOOP_SKILL_PIPELINE=' | Select-Object -Last 1)
  $configMaxIter  = ($configContent | Select-String '^LOOP_SKILL_MAX_ITERATIONS=' | Select-Object -Last 1)
  if (-not $CliPipelineSet -and $configPipeline) {
    $PipelineName = ($configPipeline -split '=', 2)[1]
  }
  if (-not $CliMaxIterationsSet -and $configMaxIter) {
    $val = ($configMaxIter -split '=', 2)[1]
    if ($val -match '^\d+$') { $MaxIterations = $val }
    else { Write-Warning "⚠️  ignoring invalid LOOP_SKILL_MAX_ITERATIONS: $val" }
  }
}
if (-not $MaxIterations) { $MaxIterations = $DefaultMaxIterations }

# [CR-4] Active loop guard
if (Test-Path $StateFile) {
  $frontmatter = (Get-Content $StateFile) -join "`n"
  if ($frontmatter -match 'iteration:\s*(\d+)') { $currentIter = $Matches[1] } else { $currentIter = "?" }
  Write-Error "❌ Error: 이미 활성 loop가 있습니다 (iteration $currentIter)"
  Write-Error "   중지하려면 /cancel-loop-skill을 실행하거나 status.json 완료 신호/max-iterations 도달을 기다리세요."
  exit 1
}

# Resolve prompt body: --pipeline > --prompt-file > inline PROMPT (§10, 동일 우선순위)
if ($PipelineName) {
  $pluginRoot = if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { "." }
  $pipelinePromptFile = Join-Path $pluginRoot "pipelines\$PipelineName\prompt.md"
  if (-not (Test-Path $pipelinePromptFile)) {
    Write-Error "❌ Error: pipeline '$PipelineName' not found (expected $pipelinePromptFile)"
    exit 1
  }
  $Prompt = Get-Content $pipelinePromptFile -Raw
} elseif ($PromptFile) {
  $Prompt = Get-Content $PromptFile -Raw
} else {
  $Prompt = $PromptParts -join " "
  if (-not $Prompt) {
    Write-Error "❌ Error: No prompt provided and no --pipeline/--prompt-file given"
    exit 1
  }
}

# state_dir 준비
$RunId = "loop-" + (Get-Date -AsUTC -Format "yyyyMMdd-HHmmss")
$StateDir = if ($StateDirOverride) { $StateDirOverride } else { ".claude\loop-skill\$RunId" }
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path ".claude" | Out-Null

$PipelineYaml = if ($PipelineName) { "`"$PipelineName`"" }
  elseif ($PromptFile) { "`"prompt-file:$(Split-Path (Split-Path $PromptFile -Parent) -Leaf)`"" }
  else { "null" }

$StartedAt = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
$SessionId = $env:CLAUDE_CODE_SESSION_ID

@"
---
active: true
iteration: 1
session_id: $SessionId
max_iterations: $MaxIterations
started_at: "$StartedAt"
state_dir: "$StateDir"
pipeline: $PipelineYaml
---

$Prompt
"@ | Set-Content -Path $StateFile -Encoding utf8NoBOM

Write-Host "🔄 Loop skill activated in this session!"
Write-Host ""
Write-Host "Iteration: 1"
Write-Host "Max iterations: $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'unlimited' })"
Write-Host "State dir: $StateDir"
Write-Host ""
Write-Host "To end this loop, write EXACTLY this JSON to $StateDir\status.json using the Write tool:"
Write-Host '  {"status": "complete"}'
```

**동일 계약 검증 포인트(구현 시 필수, plan §14 Phase 6):** bash 버전과 PowerShell 버전이 만드는
`loop-skill.local.md`의 frontmatter 필드명·순서·YAML 형식이 동일해야 `stop-hook.sh`(bash로 고정,
훅은 항상 하나)가 어느 엔진이 만든 state 파일이든 동일하게 파싱한다. 이 스펙의 두 스크립트는 필드
순서를 의도적으로 맞췄다.

---

## 4. `scripts/apply-skill.sh` (신규)

plan v03 §7.3의 적용 절차를 구현한다. 로직은 이 스펙 작성 중 핵심 부분(frontmatter 분리, 완료계약
감지, meta 생성)을 sandbox에서 검증했다(§0).

```bash
#!/bin/bash
# apply-skill.sh — 기존 skill을 <name>-loop로 rename+wrap한다 (harness_loop_plan_v03.md §7.3).
# 이 스크립트 자신은 loop-skill 플러그인의 scripts/ 안에 살며, 자기 옆의 setup-loop-skill.sh(.ps1)를
# "번들할 엔진 소스"로 삼는다 — 그래서 이동해도(CLAUDE_PLUGIN_ROOT 불의존) 항상 자기 옆을 본다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_SH="${SCRIPT_DIR}/setup-loop-skill.sh"
ENGINE_PS1="${SCRIPT_DIR}/setup-loop-skill.ps1"
PLUGIN_JSON="${SCRIPT_DIR}/../.claude-plugin/plugin.json"

SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
LOOP_APPLIED_DIR="${HOME}/.claude/loop-applied"
BACKUPS_DIR="${LOOP_APPLIED_DIR}/backups"
APPLY_STATE_FILE="${LOOP_APPLIED_DIR}/apply-state.json"

TEMPLATE_VERSION="1"

# --- 인자 파싱 ---------------------------------------------------------
ORIGIN=""
KEEP_MODEL_INVOCATION=false
FORCE=false
DRY_RUN=false
MODE="apply"   # apply | upgrade | upgrade-all | status | list

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat << 'HELP_EOF'
apply-skill.sh - 기존 skill을 <name>-loop로 wrap한다

USAGE:
  apply-skill.sh <origin-name-or-path> [옵션]
  apply-skill.sh --upgrade <name>
  apply-skill.sh --upgrade-all
  apply-skill.sh --status [<name>]
  apply-skill.sh --list

OPTIONS:
  --keep-model-invocation   원본의 disable-model-invocation 값을 그대로 유지
                            (기본은 loop 안전을 위해 true로 강제)
  --force                   drift 경고(origin_checksum 불일치)를 무시하고 진행
  --dry-run                 실제 변경 없이 계획만 출력
HELP_EOF
      exit 0 ;;
    --keep-model-invocation) KEEP_MODEL_INVOCATION=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --upgrade)
      MODE="upgrade"
      if [[ -z "${2:-}" ]]; then echo "❌ --upgrade requires a name" >&2; exit 1; fi
      ORIGIN="$2"; shift 2 ;;
    --upgrade-all) MODE="upgrade-all"; shift ;;
    --status) MODE="status"; ORIGIN="${2:-}"; [[ -n "${2:-}" ]] && shift; shift ;;
    --list) MODE="status"; shift ;;
    *)
      if [[ -n "$ORIGIN" ]]; then echo "❌ 인자가 여러 개입니다: $ORIGIN, $1" >&2; exit 1; fi
      ORIGIN="$1"; shift ;;
  esac
done

command -v jq &>/dev/null || { echo "❌ Error: jq가 필요합니다." >&2; exit 1; }
[[ -f "$ENGINE_SH" && -f "$ENGINE_PS1" ]] || {
  echo "❌ Error: loop-skill 코어가 불완전합니다 (setup-loop-skill.sh/.ps1 필요)." >&2; exit 1; }

ENGINE_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
mkdir -p "$SKILLS_DIR" "$BACKUPS_DIR"
[[ -f "$APPLY_STATE_FILE" ]] || echo '{}' > "$APPLY_STATE_FILE"

# --- 공용 함수 -----------------------------------------------------------

# frontmatter의 첫 두 `---` 구분자만 제거하고 본문(뒤쪽 `---` 포함)은 그대로 보존한다.
# (이 awk는 sandbox에서 "본문에 ---가 있는 skill"로 실측 검증됨 — §0)
extract_pipeline_body() {
  local skill_md="$1"
  awk '
    /^---$/ && n<2 { n++; next }
    n>=2 { print }
  ' "$skill_md"
}

# 완료계약이 이미 있는지 대소문자 무시로 감지 (plan §8)
has_completion_contract() {
  grep -qiE '(status\.json|완료.*신호|completion.*signal)' "$1"
}

completion_contract_footer() {
  cat << 'FOOTER_EOF'

---
## Loop 완료 신호 (loop 코어가 자동 주입)
작업이 진짜로 완전히 끝났다면, Write 툴로 `<state_dir>/status.json`에 정확히 다음을 기록해
loop을 종료하세요:
    {"status": "complete"}
escape 용도로 앞당겨 쓰지 마세요. 진짜 불가능하면 대신:
    {"status": "failed", "reason": "<짧고 정직한 사유>"}
FOOTER_EOF
}

# frontmatter 필드 하나를 단순 grep으로 추출 (robust YAML 파서 아님 — §0 경계로 수용)
frontmatter_field() {
  local skill_md="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -m1 "^${key}:" "$skill_md" | sed -E "s/^${key}:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\1/")
  echo "${val:-$default}"
}

# <name>-loop 디렉토리에 launcher SKILL.md를 생성한다 (plan §7.1)
generate_launcher() {
  local target_dir="$1" loop_name="$2" description="$3" mi_value="$4" shell_kind="$5"
  local shell_line=""
  [[ "$shell_kind" == "powershell" ]] && shell_line=$'\nshell: powershell'
  local engine_file="setup-loop-skill.sh"
  [[ "$shell_kind" == "powershell" ]] && engine_file="setup-loop-skill.ps1"

  cat > "${target_dir}/SKILL.md" << EOF
---
name: ${loop_name}
description: "${description} (ralph-loop 모드: 완료까지 self-referential 반복)"
disable-model-invocation: ${mi_value}
allowed-tools: ["Bash(\${CLAUDE_SKILL_DIR}/${engine_file}:*)"]${shell_line}
---

# ${loop_name} (loop-wrapped)

\`\`\`!
"\${CLAUDE_SKILL_DIR}/${engine_file}" --prompt-file "\${CLAUDE_SKILL_DIR}/pipeline.md" \$ARGUMENTS
\`\`\`

이 skill은 위 pipeline을 self-referential loop으로 실행합니다. 매 iteration에서 같은
\`pipeline.md\`가 재feed되며, 직전 결과물은 파일(및 보고된 \`state_dir\`)과 git 히스토리로 이어집니다.

CRITICAL: loop은 pipeline이 \`<state_dir>/status.json\`에 \`{"status":"complete"}\`를 Write 툴로
기록하거나 \`--max-iterations\`에 도달할 때만 멈춥니다. 완전히 끝났을 때만 complete를 쓰세요.
진짜 불가능하면 \`{"status":"failed","reason":"<사유>"}\`를 쓰세요.
EOF
}

# --- apply/upgrade 본체 ---------------------------------------------------
# BACKUP_DIR(pristine)에서 TARGET_DIR(<name>-loop)를 (재)생성한다.
# apply 최초 실행과 --upgrade 양쪽에서 공유 — pipeline 본문은 항상 여기서 pristine으로부터
# 재생성되므로 완료계약 footer가 중첩되지 않는다 (plan §5.2).
build_loop_skill() {
  local name="$1" backup_dir="$2" target_dir="$3" mi_policy="$4"

  local origin_skill_md="${backup_dir}/SKILL.md"
  local body
  body=$(extract_pipeline_body "$origin_skill_md")
  if [[ -z "$(echo "$body" | tr -d '[:space:]')" ]]; then
    echo "❌ Error: '${name}'의 SKILL.md 본문이 비어 있습니다 (frontmatter-only skill은 wrap할 수 없습니다)." >&2
    return 1
  fi
  echo "$body" > "${target_dir}/pipeline.md"

  local injected=false
  if ! has_completion_contract "${target_dir}/pipeline.md"; then
    completion_contract_footer >> "${target_dir}/pipeline.md"
    injected=true
  else
    echo "ℹ️  완료계약 지시가 이미 있어 footer를 주입하지 않았습니다."
  fi

  cp "$ENGINE_SH" "${target_dir}/setup-loop-skill.sh"; chmod +x "${target_dir}/setup-loop-skill.sh"
  cp "$ENGINE_PS1" "${target_dir}/setup-loop-skill.ps1"

  local description mi_value shell_kind
  description=$(frontmatter_field "$origin_skill_md" "description" "$name")
  if [[ "$mi_policy" == "preserved" ]]; then
    mi_value=$(frontmatter_field "$origin_skill_md" "disable-model-invocation" "false")
  else
    mi_value="true"
  fi
  # apply-skill.sh(bash)로 실행 중이므로 bash launcher를 생성한다.
  # (apply-skill.ps1로 실행되면 §6에서 동일 함수의 PowerShell 버전이 shell_kind=powershell로 부른다)
  shell_kind="bash"
  generate_launcher "$target_dir" "${name}-loop" "$description" "$mi_value" "$shell_kind"

  # 부가 파일 복사 (SKILL.md는 이미 pipeline.md로 소비했으므로 제외)
  local f b
  for f in "${backup_dir}"/*; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f")"
    [[ "$b" == "SKILL.md" ]] && continue
    if [[ "$b" == "agents" && -d "$f" ]]; then
      cp -r "$f" "${target_dir}/agents"
      mkdir -p "$AGENTS_DIR"
      local agent_file
      for agent_file in "$f"/*.md; do
        [[ -e "$agent_file" ]] || continue
        cp "$agent_file" "${AGENTS_DIR}/$(basename "$agent_file")"
      done
      continue
    fi
    cp -r "$f" "${target_dir}/${b}"
  done

  local checksum
  checksum="sha256:$(sha256sum "$origin_skill_md" | cut -d' ' -f1)"

  jq -n \
    --arg origin_name "$name" \
    --arg origin "wrapped" \
    --arg origin_path "${SKILLS_DIR}/${name}" \
    --arg backup_path "$backup_dir" \
    --arg origin_checksum "$checksum" \
    --arg engine_version "$ENGINE_VERSION" \
    --arg template_version "$TEMPLATE_VERSION" \
    --arg original_mi "$(frontmatter_field "$origin_skill_md" "disable-model-invocation" "false")" \
    --arg mi_policy "$mi_policy" \
    --argjson contract_injected "$injected" \
    --arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      origin_name: $origin_name,
      origin: $origin,
      origin_path: $origin_path,
      backup_path: $backup_path,
      origin_checksum: $origin_checksum,
      engine_version: $engine_version,
      template_version: $template_version,
      original_model_invocation: $original_mi,
      model_invocation_policy: $mi_policy,
      contract_injected: $contract_injected,
      applied_at: $applied_at
    }' > "${target_dir}/.loop-meta.json"
}

record_apply_state() {
  local name="$1" backup_dir="$2" target_dir="$3"
  local tmp; tmp="${APPLY_STATE_FILE}.tmp.$$"
  jq --arg name "$name" --arg backup "$backup_dir" --arg target "$target_dir" \
    '.[$name] = {backup_path: $backup, target_path: $target}' \
    "$APPLY_STATE_FILE" > "$tmp" && mv "$tmp" "$APPLY_STATE_FILE"
}

# --- do_apply (최초 wrap) -------------------------------------------------
do_apply() {
  local origin="$1"
  local origin_dir name
  if [[ "$origin" == */* ]]; then origin_dir="$origin"; else origin_dir="${SKILLS_DIR}/${origin}"; fi
  name="$(basename "$origin_dir")"

  if [[ "$name" == *-loop ]]; then
    echo "❌ Error: 이미 loop skill입니다: $name" >&2
    exit 1
  fi

  local loop_name="${name}-loop"
  local target_dir="${SKILLS_DIR}/${loop_name}"

  # 이미 wrap된 skill에 대한 재실행(재적용/업그레이드)인지 먼저 판별한다. wrap 후에는
  # origin_dir가 backup으로 이동해 사라지는 것이 정상이므로, 이 분기는 반드시 아래의
  # "origin_dir가 유효한 skill이어야 한다" 검증보다 먼저 와야 한다 — 순서를 바꾸면
  # "apply-skill.sh <name>을 두 번째 실행"(plan §7.4가 약속하는 재적용 경로)이 origin_dir
  # 부재로 즉시 에러 처리되어 버린다(이 스펙 작성 중 sandbox 실행으로 실제로 재현된 버그).
  if [[ -d "$target_dir" ]]; then
    if [[ -f "${target_dir}/.loop-meta.json" ]]; then
      echo "ℹ️  이미 wrap되어 있습니다. --upgrade로 진행합니다: $name"
      do_upgrade "$name"
      return $?
    else
      echo "❌ Error: 동일 skill 존재: ${loop_name} (loop wrap이 아님 — 이름 변경 또는 제거 후 재시도)" >&2
      exit 1
    fi
  fi

  # 여기 도달했다면 최초 wrap이므로 origin_dir가 실제 유효한 skill이어야 한다.
  [[ -d "$origin_dir" && -f "${origin_dir}/SKILL.md" ]] || {
    echo "❌ Error: '${origin}'은(는) 유효한 skill 디렉토리가 아닙니다 (SKILL.md 없음): $origin_dir" >&2
    exit 1
  }

  local backup_dir="${BACKUPS_DIR}/${name}"
  if [[ -e "$backup_dir" ]]; then
    echo "❌ Error: 이전 apply의 백업이 이미 존재합니다: $backup_dir (수동 확인 필요, 자동 덮어쓰기 안 함)" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    cat << EOF
[dry-run] 다음이 수행됩니다:
  이동: $origin_dir -> $backup_dir
  생성: $target_dir/ (SKILL.md, setup-loop-skill.sh, .ps1, pipeline.md, .loop-meta.json)
  결과: /$name 사라짐, /$loop_name 등장
EOF
    return 0
  fi

  local mi_policy="forced-disabled"
  [[ "$KEEP_MODEL_INVOCATION" == "true" ]] && mi_policy="preserved"

  # --- 트랜잭션: 실패 시 원본 복원 (v02 install.sh cleanup_on_failure 패턴) ---
  local cleanup_needed=false
  cleanup_on_failure() {
    if [[ "$cleanup_needed" == "true" ]]; then
      echo "⚠️  apply 실패 — 롤백 중..." >&2
      [[ -e "$target_dir" ]] && rm -rf "$target_dir"
      [[ -d "$backup_dir" && ! -d "$origin_dir" ]] && mv "$backup_dir" "$origin_dir"
    fi
  }
  trap cleanup_on_failure ERR

  mv "$origin_dir" "$backup_dir"
  cleanup_needed=true
  mkdir -p "$target_dir"

  build_loop_skill "$name" "$backup_dir" "$target_dir" "$mi_policy"
  record_apply_state "$name" "$backup_dir" "$target_dir"

  cleanup_needed=false
  trap - ERR

  echo "✅ 적용됨: /${loop_name} (engine v${ENGINE_VERSION}, 원본은 ${backup_dir}에 보관)"
}

# --- do_upgrade (재적용) --------------------------------------------------
do_upgrade() {
  local name_or_loop="$1"
  local name="$name_or_loop" loop_name
  [[ "$name_or_loop" == *-loop ]] && name="${name_or_loop%-loop}"
  loop_name="${name}-loop"
  local target_dir="${SKILLS_DIR}/${loop_name}"

  [[ -f "${target_dir}/.loop-meta.json" ]] || {
    echo "❌ Error: '${loop_name}'은(는) loop wrap이 아닙니다 (.loop-meta.json 없음)." >&2
    exit 1
  }

  local backup_dir
  backup_dir=$(jq -r '.backup_path' "${target_dir}/.loop-meta.json")
  [[ -d "$backup_dir" ]] || {
    echo "❌ Error: pristine 백업을 찾을 수 없습니다: $backup_dir" >&2
    exit 1
  }

  # drift 감지 (plan §9)
  local stored_checksum current_checksum
  stored_checksum=$(jq -r '.origin_checksum' "${target_dir}/.loop-meta.json")
  current_checksum="sha256:$(sha256sum "${backup_dir}/SKILL.md" | cut -d' ' -f1)"
  if [[ "$stored_checksum" != "$current_checksum" && "$FORCE" != "true" ]]; then
    echo "⚠️  drift 감지: 백업의 SKILL.md가 최초 apply 이후 변경된 것으로 보입니다." >&2
    echo "   stored=$stored_checksum current=$current_checksum" >&2
    echo "   계속하려면 --force를 붙이세요." >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $loop_name: 번들 엔진 재복사 + launcher/pipeline.md 재생성 (engine -> v${ENGINE_VERSION})"
    return 0
  fi

  local mi_policy
  mi_policy=$(jq -r '.model_invocation_policy' "${target_dir}/.loop-meta.json")
  [[ "$KEEP_MODEL_INVOCATION" == "true" ]] && mi_policy="preserved"

  # pipeline.md/SKILL.md/엔진을 통째로 재생성 (pristine에서, 절대 기존 pipeline.md에서 재추출 안 함)
  rm -f "${target_dir}/pipeline.md" "${target_dir}/SKILL.md" \
        "${target_dir}/setup-loop-skill.sh" "${target_dir}/setup-loop-skill.ps1"
  build_loop_skill "$name" "$backup_dir" "$target_dir" "$mi_policy"

  echo "✅ 업그레이드됨: /${loop_name} (engine v${ENGINE_VERSION})"
}

do_upgrade_all() {
  local d name any=false
  for d in "${SKILLS_DIR}"/*-loop; do
    [[ -f "${d}/.loop-meta.json" ]] || continue
    any=true
    name=$(basename "$d"); name="${name%-loop}"
    echo "--- ${name} ---"
    do_upgrade "$name" || echo "⚠️  ${name} 업그레이드 실패, 계속 진행" >&2
  done
  [[ "$any" == "true" ]] || echo "wrap된 skill이 없습니다."
}

do_status() {
  local d name origin engine applied_at
  printf "%-28s %-9s %-9s %-12s %s\n" "NAME" "ORIGIN" "ENGINE" "APPLIED_AT" ""
  for d in "${SKILLS_DIR}"/*-loop; do
    [[ -f "${d}/.loop-meta.json" ]] || continue
    name=$(basename "$d")
    origin=$(jq -r '.origin' "${d}/.loop-meta.json")
    engine=$(jq -r '.engine_version' "${d}/.loop-meta.json")
    applied_at=$(jq -r '.applied_at' "${d}/.loop-meta.json")
    local mark=""
    [[ "$engine" != "$ENGINE_VERSION" ]] && mark=" (뒤처짐, 최신 v${ENGINE_VERSION})"
    printf "%-28s %-9s %-9s %-12s%s\n" "$name" "$origin" "$engine" "$applied_at" "$mark"
  done
}

# --- 디스패치 --------------------------------------------------------------
case "$MODE" in
  apply)
    [[ -n "$ORIGIN" ]] || { echo "❌ Error: origin skill 이름 또는 경로가 필요합니다." >&2; exit 1; }
    do_apply "$ORIGIN" ;;
  upgrade) do_upgrade "$ORIGIN" ;;
  upgrade-all) do_upgrade_all ;;
  status) do_status ;;
esac
```

---

## 5. `scripts/unapply-skill.sh` (신규)

plan v03 §7.6의 원복 절차. `<name>` 또는 `<name>-loop` 둘 다 받아준다.

```bash
#!/bin/bash
# unapply-skill.sh — <name>-loop를 삭제하고 pristine 원본을 <name>으로 복원한다 (plan §7.6).
set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
LOOP_APPLIED_DIR="${HOME}/.claude/loop-applied"
APPLY_STATE_FILE="${LOOP_APPLIED_DIR}/apply-state.json"

DRY_RUN=false
NAME_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) echo "USAGE: unapply-skill.sh <name-or-name-loop> [--dry-run]"; exit 0 ;;
    *) NAME_ARG="$1"; shift ;;
  esac
done

[[ -n "$NAME_ARG" ]] || { echo "❌ Error: 이름이 필요합니다." >&2; exit 1; }
command -v jq &>/dev/null || { echo "❌ Error: jq가 필요합니다." >&2; exit 1; }

NAME="$NAME_ARG"
[[ "$NAME_ARG" == *-loop ]] && NAME="${NAME_ARG%-loop}"
LOOP_NAME="${NAME}-loop"
TARGET_DIR="${SKILLS_DIR}/${LOOP_NAME}"
ORIGIN_TARGET="${SKILLS_DIR}/${NAME}"

[[ -f "${TARGET_DIR}/.loop-meta.json" ]] || {
  echo "❌ Error: '${LOOP_NAME}'은(는) loop wrap이 아니거나 존재하지 않습니다." >&2
  exit 1
}

BACKUP_DIR=$(jq -r '.backup_path' "${TARGET_DIR}/.loop-meta.json")
[[ -d "$BACKUP_DIR" ]] || {
  echo "❌ Error: pristine 백업을 찾을 수 없습니다: $BACKUP_DIR (수동 복구 필요)" >&2
  exit 1
}

if [[ -e "$ORIGIN_TARGET" ]]; then
  echo "❌ Error: 복원 대상이 이미 존재합니다: $ORIGIN_TARGET — 수동 확인 필요, 자동 덮어쓰기 안 함." >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  cat << EOF
[dry-run] 다음이 수행됩니다:
  삭제: $TARGET_DIR
  복원: $BACKUP_DIR -> $ORIGIN_TARGET
  결과: /$LOOP_NAME 사라지고 /$NAME 복귀
EOF
  exit 0
fi

# agents/ 정리: 이 apply가 등록한 것만 (원본 agents/ 안 파일명 기준)
if [[ -d "${BACKUP_DIR}/agents" ]]; then
  for f in "${BACKUP_DIR}/agents"/*.md; do
    [[ -e "$f" ]] || continue
    rm -f "${AGENTS_DIR}/$(basename "$f")"
  done
fi

rm -rf "$TARGET_DIR"
mv "$BACKUP_DIR" "$ORIGIN_TARGET"

if [[ -f "$APPLY_STATE_FILE" ]]; then
  tmp="${APPLY_STATE_FILE}.tmp.$$"
  jq --arg name "$NAME" 'del(.[$name])' "$APPLY_STATE_FILE" > "$tmp" && mv "$tmp" "$APPLY_STATE_FILE"
fi

echo "✅ 원복됨: /${NAME} (${LOOP_NAME} 및 백업 제거)"
```

---

## 6. `scripts/apply-skill.ps1` / `scripts/unapply-skill.ps1` (Windows)

bash 버전과 동일 로직의 PowerShell 번역. `generate_launcher`에 해당하는 부분만 `shell: powershell`
frontmatter와 `.ps1` 엔진 파일명을 쓰도록 분기하는 점이 유일한 실질적 차이다(plan §7.1.2 표).

```powershell
# apply-skill.ps1 — apply-skill.sh와 동일 로직 (PowerShell). 함수 단위 대응:
#   extract_pipeline_body -> Get-PipelineBody
#   has_completion_contract -> Test-CompletionContract
#   generate_launcher -> New-Launcher (shell: powershell 고정, .ps1 엔진 참조)
#   build_loop_skill / do_apply / do_upgrade / do_upgrade_all / do_status -> 동일 이름 함수로 대응
# 세부 문법(jq -> ConvertTo-Json/ConvertFrom-Json, sha256sum -> Get-FileHash 등)만 변환.

param(
  [string]$Origin,
  [switch]$KeepModelInvocation,
  [switch]$Force,
  [switch]$DryRun,
  [string]$Upgrade,
  [switch]$UpgradeAll,
  [string]$Status
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EngineSh  = Join-Path $ScriptDir "setup-loop-skill.sh"
$EnginePs1 = Join-Path $ScriptDir "setup-loop-skill.ps1"
$PluginJson = Join-Path $ScriptDir "..\.claude-plugin\plugin.json"

$SkillsDir = Join-Path $HOME ".claude\skills"
$AgentsDir = Join-Path $HOME ".claude\agents"
$LoopAppliedDir = Join-Path $HOME ".claude\loop-applied"
$BackupsDir = Join-Path $LoopAppliedDir "backups"
$ApplyStateFile = Join-Path $LoopAppliedDir "apply-state.json"
$TemplateVersion = "1"

New-Item -ItemType Directory -Force -Path $SkillsDir, $BackupsDir | Out-Null
if (-not (Test-Path $ApplyStateFile)) { "{}" | Set-Content $ApplyStateFile }

$EngineVersion = (Get-Content $PluginJson | ConvertFrom-Json).version

function Get-PipelineBody {
  param([string]$SkillMd)
  $lines = Get-Content $SkillMd
  $n = 0
  $out = @()
  foreach ($line in $lines) {
    if ($line -eq "---" -and $n -lt 2) { $n++; continue }
    if ($n -ge 2) { $out += $line }
  }
  return ($out -join "`n")
}

function Test-CompletionContract {
  param([string]$PipelineMd)
  $content = Get-Content $PipelineMd -Raw
  return ($content -match '(?i)(status\.json|완료.*신호|completion.*signal)')
}

function Get-CompletionContractFooter {
  return @"

---
## Loop 완료 신호 (loop 코어가 자동 주입)
작업이 진짜로 완전히 끝났다면, Write 툴로 ``<state_dir>/status.json``에 정확히 다음을 기록해
loop을 종료하세요:
    {"status": "complete"}
escape 용도로 앞당겨 쓰지 마세요. 진짜 불가능하면 대신:
    {"status": "failed", "reason": "<짧고 정직한 사유>"}
"@
}

function Get-FrontmatterField {
  param([string]$SkillMd, [string]$Key, [string]$DefaultVal = "")
  $line = Get-Content $SkillMd | Where-Object { $_ -match "^${Key}:" } | Select-Object -First 1
  if (-not $line) { return $DefaultVal }
  $val = ($line -replace "^${Key}:\s*", "") -replace '^"(.*)"$', '$1'
  if ([string]::IsNullOrWhiteSpace($val)) { return $DefaultVal }
  return $val
}

function New-Launcher {
  param([string]$TargetDir, [string]$LoopName, [string]$Description, [string]$MiValue)
  @"
---
name: $LoopName
description: "$Description (ralph-loop 모드: 완료까지 self-referential 반복)"
disable-model-invocation: $MiValue
allowed-tools: ["Bash(`${CLAUDE_SKILL_DIR}/setup-loop-skill.ps1:*)"]
shell: powershell
---

# $LoopName (loop-wrapped)

``````!
"`${CLAUDE_SKILL_DIR}/setup-loop-skill.ps1" --prompt-file "`${CLAUDE_SKILL_DIR}/pipeline.md" `$ARGUMENTS
``````

이 skill은 위 pipeline을 self-referential loop으로 실행합니다. 매 iteration에서 같은
``pipeline.md``가 재feed되며, 직전 결과물은 파일(및 보고된 ``state_dir``)과 git 히스토리로 이어집니다.

CRITICAL: loop은 pipeline이 ``<state_dir>/status.json``에 ``{"status":"complete"}``를 Write 툴로
기록하거나 ``--max-iterations``에 도달할 때만 멈춥니다. 완전히 끝났을 때만 complete를 쓰세요.
진짜 불가능하면 ``{"status":"failed","reason":"<사유>"}``를 쓰세요.
"@ | Set-Content -Path (Join-Path $TargetDir "SKILL.md") -Encoding utf8NoBOM
}

function Build-LoopSkill {
  param([string]$Name, [string]$BackupDir, [string]$TargetDir, [string]$MiPolicy)

  $originSkillMd = Join-Path $BackupDir "SKILL.md"
  $body = Get-PipelineBody -SkillMd $originSkillMd
  if ([string]::IsNullOrWhiteSpace($body)) {
    Write-Error "❌ '$Name'의 SKILL.md 본문이 비어 있습니다 (frontmatter-only skill은 wrap할 수 없습니다)."
  }
  $pipelinePath = Join-Path $TargetDir "pipeline.md"
  $body | Set-Content -Path $pipelinePath -Encoding utf8NoBOM

  $injected = $false
  if (-not (Test-CompletionContract -PipelineMd $pipelinePath)) {
    Add-Content -Path $pipelinePath -Value (Get-CompletionContractFooter)
    $injected = $true
  }

  Copy-Item $EngineSh (Join-Path $TargetDir "setup-loop-skill.sh")
  Copy-Item $EnginePs1 (Join-Path $TargetDir "setup-loop-skill.ps1")

  $description = Get-FrontmatterField -SkillMd $originSkillMd -Key "description" -DefaultVal $Name
  if ($MiPolicy -eq "preserved") {
    $miValue = Get-FrontmatterField -SkillMd $originSkillMd -Key "disable-model-invocation" -DefaultVal "false"
  } else {
    $miValue = "true"
  }
  New-Launcher -TargetDir $TargetDir -LoopName "$Name-loop" -Description $description -MiValue $miValue

  Get-ChildItem $BackupDir | Where-Object { $_.Name -ne "SKILL.md" } | ForEach-Object {
    if ($_.Name -eq "agents" -and $_.PSIsContainer) {
      Copy-Item $_.FullName (Join-Path $TargetDir "agents") -Recurse
      New-Item -ItemType Directory -Force -Path $AgentsDir | Out-Null
      Get-ChildItem $_.FullName -Filter "*.md" | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $AgentsDir $_.Name)
      }
    } else {
      Copy-Item $_.FullName (Join-Path $TargetDir $_.Name) -Recurse
    }
  }

  $checksum = "sha256:" + (Get-FileHash $originSkillMd -Algorithm SHA256).Hash.ToLower()
  $originalMi = Get-FrontmatterField -SkillMd $originSkillMd -Key "disable-model-invocation" -DefaultVal "false"

  [ordered]@{
    origin_name = $Name
    origin = "wrapped"
    origin_path = (Join-Path $SkillsDir $Name)
    backup_path = $BackupDir
    origin_checksum = $checksum
    engine_version = $EngineVersion
    template_version = $TemplateVersion
    original_model_invocation = $originalMi
    model_invocation_policy = $MiPolicy
    contract_injected = $injected
    applied_at = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
  } | ConvertTo-Json | Set-Content (Join-Path $TargetDir ".loop-meta.json")
}

# do_apply / do_upgrade / do_upgrade_all / do_status는 apply-skill.sh와 동일한 제어 흐름을
# PowerShell 관용구(Test-Path, Move-Item, Remove-Item, ConvertFrom-Json)로 옮긴 것 — 지면상
# 본문은 §4의 do_apply/do_upgrade와 1:1 대응이므로 반복하지 않는다. 구현 시 §4를 그대로 이식.
```

```powershell
# unapply-skill.ps1 — unapply-skill.sh와 동일 로직 (PowerShell)
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$SkillsDir = Join-Path $HOME ".claude\skills"
$AgentsDir = Join-Path $HOME ".claude\agents"
$ApplyStateFile = Join-Path $HOME ".claude\loop-applied\apply-state.json"

$BaseName = $Name -replace '-loop$', ''
$LoopName = "$BaseName-loop"
$TargetDir = Join-Path $SkillsDir $LoopName
$OriginTarget = Join-Path $SkillsDir $BaseName
$MetaFile = Join-Path $TargetDir ".loop-meta.json"

if (-not (Test-Path $MetaFile)) {
  Write-Error "❌ '$LoopName'은(는) loop wrap이 아니거나 존재하지 않습니다."
}
$Meta = Get-Content $MetaFile | ConvertFrom-Json
$BackupDir = $Meta.backup_path
if (-not (Test-Path $BackupDir)) {
  Write-Error "❌ pristine 백업을 찾을 수 없습니다: $BackupDir"
}
if (Test-Path $OriginTarget) {
  Write-Error "❌ 복원 대상이 이미 존재합니다: $OriginTarget — 수동 확인 필요."
}

if ($DryRun) {
  Write-Host "[dry-run] 삭제: $TargetDir / 복원: $BackupDir -> $OriginTarget"
  exit 0
}

$AgentsSrc = Join-Path $BackupDir "agents"
if (Test-Path $AgentsSrc) {
  Get-ChildItem $AgentsSrc -Filter "*.md" | ForEach-Object {
    Remove-Item (Join-Path $AgentsDir $_.Name) -ErrorAction SilentlyContinue
  }
}

Remove-Item $TargetDir -Recurse -Force
Move-Item $BackupDir $OriginTarget

if (Test-Path $ApplyStateFile) {
  $state = Get-Content $ApplyStateFile | ConvertFrom-Json -AsHashtable
  $state.Remove($BaseName)
  $state | ConvertTo-Json | Set-Content $ApplyStateFile
}

Write-Host "✅ 원복됨: /$BaseName ($LoopName 및 백업 제거)"
```

---

## 7. launcher `SKILL.md` 산출물 (참고 정리)

`apply-skill.sh`/`.ps1`의 `generate_launcher`/`New-Launcher`가 실제로 만들어내는 파일은 plan v03
§7.1과 동일하며, §4/§6의 heredoc이 **유일한 정의**다(별도 템플릿 파일을 두지 않음 — 기존 코드베이스
컨벤션대로 생성 스크립트 내부 heredoc으로 관리, `setup-loop-skill.sh`가 state 파일을 heredoc으로
쓰는 것과 동일한 패턴).

---

## 8. `.loop-meta.json` 스키마 (최종)

plan v03 §9과 동일. `apply-skill.sh`의 `build_loop_skill`이 생성하는 정확한 필드:

```json
{
  "origin_name": "l1-log-analysis",
  "origin": "wrapped",
  "origin_path": "/home/user/.claude/skills/l1-log-analysis",
  "backup_path": "/home/user/.claude/loop-applied/backups/l1-log-analysis",
  "origin_checksum": "sha256:...",
  "engine_version": "0.1.0",
  "template_version": "1",
  "original_model_invocation": "false",
  "model_invocation_policy": "forced-disabled",
  "contract_injected": true,
  "applied_at": "2026-07-19T00:00:00Z"
}
```

필드 타입 주의: `original_model_invocation`/`model_invocation_policy`는 문자열("true"/"false",
"forced-disabled"/"preserved")로 저장한다 — `disable-model-invocation` frontmatter 값 자체가
문자열 grep으로 추출되므로 일관성을 위해 문자열로 유지(불리언 캐스팅은 하지 않음, §0 단순성 원칙).

---

## 9. `~/.claude/loop-applied/apply-state.json` 스키마

전역 적용 이력. `origin_name`을 키로 하는 단순 맵(v02 `install-state.json`과 달리 배열이 아니라
맵인 이유: `apply-skill.sh`가 이름으로 O(1) 조회/삭제해야 하므로).

```json
{
  "l1-log-analysis": {
    "backup_path": "/home/user/.claude/loop-applied/backups/l1-log-analysis",
    "target_path": "/home/user/.claude/skills/l1-log-analysis-loop"
  }
}
```

---

## 10. Phase → 산출물 매핑

| Phase | 산출물 | 완료 기준 (plan v03 §14 그대로) |
|---|---|---|
| 0 | (코드 아님) 스파이크 로그 | Test 1, Test 15 재현 성공 + R2(§0) 실측 결과 기록 |
| 1 | §2 diff 반영된 `setup-loop-skill.sh` | 기존 v02 Test 1-12(implementation-spec_v02.md §12) 회귀 없음 + `--prompt-file` 스모크 |
| 2 | §3 `setup-loop-skill.ps1` | bash 버전과 동일 state 파일 산출 확인(§3 "동일 계약 검증") |
| 3 | §4 `apply-skill.sh` | Test 1-8, 11, 12, 14 통과 |
| 4 | §4 `--upgrade`/`--upgrade-all`/`--status` | Test 4, 5, 6 통과 |
| 5 | §5 `unapply-skill.sh` | Test 7 통과 |
| 6 | §6 `apply-skill.ps1`/`unapply-skill.ps1` | Test 15 (Windows 환경) 통과 |
| 7 | 통합 | 전체 테스트 스위트 통과 + README 갱신 |

---

## 11. LLM Self-Testable Test Cases

**설계 원칙**(implementation-spec_v02.md §12과 동일): 입력/실행 단계/기대 결과가 명확하고, LLM이
스스로 실행 후 pass/fail을 판정할 수 있어야 한다. 실패 시 원인을 바로 알 수 있는 문구를 포함한다.

---

**Test 1: 기본 wrap — 파일 구조 확인**
```bash
# Pre-condition: loop-skill 코어 설치됨, ~/.claude/skills/demo/SKILL.md 존재
# (SKILL.md 본문에 완료계약 지시 없음 — 자동주입 검증 겸함)
mkdir -p ~/.claude/skills/demo
cat > ~/.claude/skills/demo/SKILL.md << 'EOF'
---
name: demo
description: "demo skill"
---

이것은 데모 작업입니다. 파일을 하나 만드세요.
EOF

~/.claude/skills/loop-skill/scripts/apply-skill.sh demo

test ! -d ~/.claude/skills/demo
test -d ~/.claude/skills/demo-loop
test -f ~/.claude/skills/demo-loop/SKILL.md
test -x ~/.claude/skills/demo-loop/setup-loop-skill.sh
test -f ~/.claude/skills/demo-loop/setup-loop-skill.ps1
test -f ~/.claude/skills/demo-loop/pipeline.md
test -f ~/.claude/skills/demo-loop/.loop-meta.json
test -d ~/.claude/loop-applied/backups/demo
test -f ~/.claude/loop-applied/backups/demo/SKILL.md
jq -e '.engine_version and .origin == "wrapped"' ~/.claude/skills/demo-loop/.loop-meta.json
# Expected: 위 검증 전부 통과, exit code 0
```

**Test 2: loop 동작 (end-to-end)**
```bash
# Pre-condition: Test 1 완료
cd /tmp/some-project   # 임의 프로젝트 디렉토리
/demo-loop --max-iterations 10
STATE_DIR=$(grep '^state_dir:' .claude/loop-skill.local.md | sed 's/state_dir: *"\(.*\)"/\1/')
test -n "$STATE_DIR"
echo '{"status": "complete"}' > "$STATE_DIR/status.json"
# 세션 종료 시도 트리거
test ! -f .claude/loop-skill.local.md
# Expected: /demo-loop가 setup-loop-skill.sh(번들본)를 기동, 중앙 Stop 훅이 iteration을 진행,
#           status.json complete 작성 후 loop 종료 및 state 파일 삭제
```

**Test 3: 완료계약 자동 주입 vs 중복 방지**
```bash
# 3a: 완료 지시 없는 skill (Test 1의 demo) → footer 주입 확인
grep -c 'Loop 완료 신호' ~/.claude/skills/demo-loop/pipeline.md   # 1

# 3b: 완료 지시가 이미 있는 skill
mkdir -p ~/.claude/skills/demo2
cat > ~/.claude/skills/demo2/SKILL.md << 'EOF'
---
name: demo2
---

작업을 하고, 완료되면 status.json에 완료 신호를 쓰세요.
EOF
~/.claude/skills/loop-skill/scripts/apply-skill.sh demo2
grep -c 'Loop 완료 신호' ~/.claude/skills/demo2-loop/pipeline.md   # 0 (이미 감지했으므로 주입 안 함)
# Expected: 3a는 footer 정확히 1회, 3b는 0회(중복 주입 안 함)
```

**Test 4: idempotent 재적용 (footer 중첩 방지)**
```bash
# Pre-condition: Test 1 완료
~/.claude/skills/loop-skill/scripts/apply-skill.sh demo   # 재실행 -> 자동으로 upgrade 경로
grep -c 'Loop 완료 신호' ~/.claude/skills/demo-loop/pipeline.md   # 여전히 1 (2가 아님)
test -d ~/.claude/skills/demo-loop
test ! -d ~/.claude/skills/demo   # 원본은 여전히 없음(중복 wrap 아님)
# Expected: footer가 두 번째 apply에도 정확히 1개만 존재 — pristine 백업에서 재추출했다는 증거
```

**Test 5: 버전 가시성 (`--status`)**
```bash
# Pre-condition: Test 1 완료
~/.claude/skills/loop-skill/scripts/apply-skill.sh --status | grep 'demo-loop'
# Expected: "demo-loop ... wrapped ... <engine_version> ... <applied_at>" 형식 한 줄 출력

# plugin.json version을 인위로 올려서 재검증
jq '.version = "0.2.0"' ~/.claude/skills/loop-skill/.claude-plugin/plugin.json > /tmp/p.json
mv /tmp/p.json ~/.claude/skills/loop-skill/.claude-plugin/plugin.json
~/.claude/skills/loop-skill/scripts/apply-skill.sh --status | grep 'demo-loop'
# Expected: "뒤처짐, 최신 v0.2.0" 표시가 demo-loop 줄에 붙어 나옴
```

**Test 6: `--upgrade-all`**
```bash
# Pre-condition: Test 5로 plugin.json version이 0.2.0으로 올라간 상태
OLD_ENGINE_HASH=$(sha256sum ~/.claude/skills/demo-loop/setup-loop-skill.sh | cut -d' ' -f1)
~/.claude/skills/loop-skill/scripts/apply-skill.sh --upgrade-all
NEW_ENGINE_HASH=$(sha256sum ~/.claude/skills/demo-loop/setup-loop-skill.sh | cut -d' ' -f1)
jq -r '.engine_version' ~/.claude/skills/demo-loop/.loop-meta.json   # "0.2.0"
# pipeline 본문(작업 지시)은 보존되어야 함
grep -q '데모 작업' ~/.claude/skills/demo-loop/pipeline.md
# Expected: engine_version이 갱신됨, 번들 엔진 파일 자체가 최신 소스와 동일 해시로 교체됨,
#           pipeline.md의 원본 작업 지시 내용은 그대로 유지
```

**Test 7: 원복 (unapply)**
```bash
# Pre-condition: Test 1 완료
ORIGIN_CHECKSUM_BEFORE=$(sha256sum ~/.claude/loop-applied/backups/demo/SKILL.md | cut -d' ' -f1)
~/.claude/skills/loop-skill/scripts/unapply-skill.sh demo
test -d ~/.claude/skills/demo
test ! -d ~/.claude/skills/demo-loop
test ! -d ~/.claude/loop-applied/backups/demo
ORIGIN_CHECKSUM_AFTER=$(sha256sum ~/.claude/skills/demo/SKILL.md | cut -d' ' -f1)
[[ "$ORIGIN_CHECKSUM_BEFORE" == "$ORIGIN_CHECKSUM_AFTER" ]]
jq -e '.demo == null' ~/.claude/loop-applied/apply-state.json
# Expected: /demo 복귀, /demo-loop 및 backup 소멸, 체크섬 완전 일치(원본 무손상), apply-state에서 제거됨
```

**Test 8: 중복 방지 (동시 존재 안 함)**
```bash
# Pre-condition: Test 1 완료 (demo-loop 활성 상태)
ls ~/.claude/skills/ | grep -c '^demo$'        # 0
ls ~/.claude/skills/ | grep -c '^demo-loop$'   # 1
# Expected: 원본 이름과 -loop 이름이 동시에 존재하지 않음
```

**Test 9: 동시성 가드 (`[CR-4]` 재사용)**
```bash
# Pre-condition: Test 1 완료, 같은 프로젝트에서
/demo-loop --max-iterations 20
/loop-skill "다른 작업" --max-iterations 5
# Expected: 두 번째 호출은 "이미 활성 loop가 있습니다" 에러(exit 1) —
#           -loop skill이 시작한 loop과 /loop-skill이 같은 [CR-4] 가드를 공유함을 증명
```

**Test 10: cancel 재사용**
```bash
# Pre-condition: /demo-loop 활성 중 (Test 9 상황)
/cancel-loop-skill
test ! -f .claude/loop-skill.local.md
# Expected: -loop skill이 시작한 loop도 기존 /cancel-loop-skill로 즉시 중단됨 (skill별 cancel 불필요)
```

**Test 11: 본문 `---` 보존 (frontmatter 파싱 정확성)**
```bash
mkdir -p ~/.claude/skills/demo3
# 본문에 완료계약 지시(§8)를 포함시켜 자동 footer 주입을 피한다 — footer 자체도 `---` 구분선을
# 포함하므로, 주입되면 본문 --- 개수 assertion이 "frontmatter 파싱"과 "footer 주입" 두 가지를
# 뒤섞게 된다. 이 테스트는 순수하게 frontmatter 분리 로직만 검증한다(footer 주입은 Test 3).
cat > ~/.claude/skills/demo3/SKILL.md << 'EOF'
---
name: demo3
---

1단계 작업 설명.

---

2단계 작업 설명 (위 구분선은 본문 내용이며 보존되어야 함).
완료되면 status.json에 완료 신호를 쓰세요.
EOF
~/.claude/skills/loop-skill/scripts/apply-skill.sh demo3
grep -c '^name: demo3$' ~/.claude/skills/demo3-loop/pipeline.md   # 0 (frontmatter 키는 제거됨)
grep -c '^---$' ~/.claude/skills/demo3-loop/pipeline.md            # 1 (본문 구분선만 남음, footer 미주입)
grep -q '2단계 작업 설명' ~/.claude/skills/demo3-loop/pipeline.md
# Expected: frontmatter 키(name:)는 사라지고, 본문 안의 --- 및 그 뒤 내용은 온전히 보존됨.
# (본문에 완료계약 문구가 없는 케이스의 footer 주입 시 --- 개수는 Test 3에서 별도 검증)
```

**Test 12: 빈 본문 에러**
```bash
mkdir -p ~/.claude/skills/demo4
cat > ~/.claude/skills/demo4/SKILL.md << 'EOF'
---
name: demo4
description: "frontmatter만 있고 본문 없음"
---
EOF
~/.claude/skills/loop-skill/scripts/apply-skill.sh demo4; echo "exit=$?"
test ! -d ~/.claude/skills/demo4-loop
test -d ~/.claude/skills/demo4    # 롤백되어 원본이 그대로 남아있어야 함
# Expected: exit != 0, "frontmatter-only skill은 wrap할 수 없습니다" 에러 메시지, 원본 무손상(롤백 확인)
```

**Test 13: 번들 relocatable (§2 relocatable 근거 실측)**
```bash
# Pre-condition: Test 1 완료
cp ~/.claude/skills/demo-loop/setup-loop-skill.sh /tmp/relocated-setup.sh
cd /tmp/another-project
bash /tmp/relocated-setup.sh --prompt-file ~/.claude/skills/demo-loop/pipeline.md --max-iterations 3
test -f .claude/loop-skill.local.md
grep -q 'pipeline: "prompt-file:demo-loop"' .claude/loop-skill.local.md
# Expected: 번들 엔진을 원래 위치가 아닌 임의 경로에 복사해 실행해도 정상 동작
#           (CLAUDE_PLUGIN_ROOT 등 위치 의존성이 없다는 증거)
```

**Test 14: 동명 skill 충돌 (install 실패)**
```bash
# Pre-condition: meta 없는 무관한 demo5-loop가 이미 존재
mkdir -p ~/.claude/skills/demo5-loop
echo "무관한 기존 skill" > ~/.claude/skills/demo5-loop/SKILL.md
mkdir -p ~/.claude/skills/demo5
cat > ~/.claude/skills/demo5/SKILL.md << 'EOF'
---
name: demo5
---
작업
EOF
~/.claude/skills/loop-skill/scripts/apply-skill.sh demo5; echo "exit=$?"
# Expected: exit != 0, "동일 skill 존재: demo5-loop (loop wrap이 아님 ...)" 메시지,
#           기존 demo5-loop/SKILL.md 내용 무손상(덮어쓰기 안 됨), demo5는 원래 위치에 그대로
grep -q '무관한 기존 skill' ~/.claude/skills/demo5-loop/SKILL.md
test -d ~/.claude/skills/demo5
```

**Test 15: 크로스-OS 번들 (Windows 환경 필요)** `[Windows/PowerShell 전제]`
```powershell
# Pre-condition: Windows 머신에 loop-skill 코어 설치됨, ~/.claude/skills/demo6 존재(SKILL.md만)
& "$HOME\.claude\skills\loop-skill\scripts\apply-skill.ps1" -Origin demo6

Test-Path "$HOME\.claude\skills\demo6-loop\setup-loop-skill.sh"    # $true (bash 엔진도 번들됨)
Test-Path "$HOME\.claude\skills\demo6-loop\setup-loop-skill.ps1"   # $true
Select-String -Path "$HOME\.claude\skills\demo6-loop\SKILL.md" -Pattern "shell: powershell"
Select-String -Path "$HOME\.claude\skills\demo6-loop\SKILL.md" -Pattern "setup-loop-skill\.ps1"
# Expected: 폴더에 .sh + .ps1 엔진이 둘 다 존재(OS 중립 폴더), 활성 launcher는
#           shell: powershell로 .ps1 엔진을 가리킴(§7.1.2)
```

---

## 12. 기술 스택

- **Language**: Bash(엔진/apply/unapply), PowerShell(크로스-OS 대응 엔진/apply/unapply),
  Markdown(launcher `SKILL.md`/pipeline 본문)
- **Data Format**: YAML(state frontmatter, launcher frontmatter), JSON(`.loop-meta.json`,
  `apply-state.json`, hook 출력)
- **File Operations**: `mv`/`cp -r`/`rm -rf`, `jq`(JSON 생성·병합·파싱), `sha256sum`(drift 체크섬),
  `awk`(frontmatter 첫 두 `---` 분리 — §0에서 검증된 로직)
- **외부 의존성**: `jq`(필수, v02와 동일). `--prompt-file` 자체는 신규 의존성 없음.

---

## 13. 참고 문서

- `harness_loop_plan_v03.md` — 이 스펙이 구현하는 설계(§0 비목표, §5-9 wrap 메커니즘, §11 동시성,
  §13 위험/risk point, §14 Phase).
- `implementation-spec_v02.md` — loop 엔진 코어(§5 setup-loop-skill.sh, §7 stop-hook.sh)의 원본,
  이 스펙의 §2 diff가 대상으로 하는 파일.
- `harness_loop_plan_v02.md` — v02 아키텍처 원칙(§3.6 확장 계약 등), 이 스펙이 그대로 승계.
