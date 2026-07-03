#!/usr/bin/env bash
# Installs the statusline script into ~/.claude and wires it up in
# ~/.claude/settings.json without touching any other settings you have there.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed. Install it first:" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Debian/Ubuntu: sudo apt-get install jq" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/statusline-command.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_DIR/statusline-command.sh" "$DEST"
chmod +x "$DEST"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

tmp=$(mktemp)
jq --arg cmd 'bash "$HOME/.claude/statusline-command.sh"' \
  '.statusLine = {type: "command", command: $cmd}' \
  "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "Installed $DEST"
echo "Updated statusLine in $SETTINGS"
echo "Restart Claude Code (or start a new session) to see it."
