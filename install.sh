#!/usr/bin/env bash
# Install Drawbridge into a project: ./install.sh [project-dir]
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
DEST=$(cd "${1:-.}" && pwd)

for bin in git jq awk; do command -v "$bin" >/dev/null || { echo "drawbridge: '$bin' is required" >&2; exit 1; }; done
[ "$SRC" = "$DEST" ] && { echo "drawbridge: pass the target project dir, e.g. ./install.sh ~/code/my-app" >&2; exit 1; }

mkdir -p "$DEST/.claude/skills"
rm -rf "$DEST/.claude/skills/drawbridge"
cp -R "$SRC/.claude/skills/drawbridge" "$DEST/.claude/skills/drawbridge"
chmod +x "$DEST/.claude/skills/drawbridge/gate.sh"

# Merge the PreToolUse hook into .claude/settings.json without touching other settings.
SETTINGS="$DEST/.claude/settings.json"
HOOK_CMD='"$CLAUDE_PROJECT_DIR"/.claude/skills/drawbridge/gate.sh'
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if jq -e --arg c "$HOOK_CMD" '[.. | objects | select(.command? == $c)] | length > 0' "$SETTINGS" >/dev/null; then
  echo "hook already present in .claude/settings.json"
else
  tmp=$(mktemp)
  jq --arg c "$HOOK_CMD" '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$c}]}]' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "added PreToolUse hook to .claude/settings.json"
fi

touch "$DEST/.gitignore"
grep -qxF '.drawbridge/' "$DEST/.gitignore" || { echo '.drawbridge/' >> "$DEST/.gitignore"; echo "added .drawbridge/ to .gitignore"; }

echo "Drawbridge installed in $DEST. Restart Claude Code in that project to load the hook."
