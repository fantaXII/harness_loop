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
