#!/bin/bash
# =====================================================================
#  Auto-Apply — DMG launcher (the "Install Auto-Apply" icon)
#  A mounted DMG is read-only, and the tool needs a writable home and
#  locally-built binaries (that's what keeps macOS from blocking them).
#  So this copies the tool into your Applications folder, clears the
#  "downloaded from the internet" quarantine, and starts the real setup.
# =====================================================================
set -u
TITLE="Auto-Apply"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Auto-Apply"                       # the tool folder that ships beside this file
DEST="$HOME/Applications/Auto-Apply"

osascript -e "display dialog \"Welcome! This will copy Auto-Apply into your Applications folder and start setup.\n\nClick OK to continue.\" with title \"$TITLE\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1

if [ ! -d "$SRC" ]; then
  osascript -e "display dialog \"Couldn't find the Auto-Apply files next to this installer. Please re-download the .dmg.\" with title \"$TITLE\" buttons {\"OK\"} with icon stop" >/dev/null 2>&1
  exit 1
fi

echo "Copying Auto-Apply to $DEST ..."
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST" || { echo "Copy failed."; read -r; exit 1; }

# Clear quarantine on the copied tree so its scripts run without per-file warnings.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
chmod +x "$DEST/cvfill/setup/"*.command 2>/dev/null || true

echo "Starting setup..."
exec "$DEST/cvfill/setup/install.command"
