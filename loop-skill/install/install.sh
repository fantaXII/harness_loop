#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# install/ lives inside loop-skill/ (see spec §1), so the skill payload root
# IS the parent of install/ — not a "loop-skill" subdirectory beneath it.
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
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
