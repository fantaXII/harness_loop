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
