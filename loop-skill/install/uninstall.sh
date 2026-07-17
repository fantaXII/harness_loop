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
