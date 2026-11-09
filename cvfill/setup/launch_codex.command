#!/bin/bash
# Auto-Apply — opens your assistant (a Codex session) primed on your tool.
# Double-clicked via the Auto-Apply app, or run directly. First run = guided setup;
# after that it resumes where you left off.
set -u

# This file lives in <project>/cvfill/setup/ ; project root is two levels up.
SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SETUP/../.." && pwd)"
MARKER="$HOME/.cvfill/.onboarded"

cd "$PROJECT" || { echo "Can't find the tool folder."; read -r; exit 1; }

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex isn't installed yet. Please run the installer (install.command) first."
  echo "Press Return to close."; read -r; exit 1
fi

clear
echo "======================================================="
echo "  Auto-Apply — your job-application assistant"
echo "  Just type what you want. Examples:"
echo "    • find me software internships at NVIDIA"
echo "    • add my LinkedIn and phone number"
echo "    • fill this application: <paste a job link>"
echo "    • also search Microsoft"
echo "  (Type /quit to leave. You can always reopen this.)"
echo "======================================================="
echo

if [ ! -f "$MARKER" ]; then
  mkdir -p "$(dirname "$MARKER")"
  codex "$(cat "$SETUP/onboarding_prompt.md")"
  date > "$MARKER"
else
  codex resume --last || codex "$(cat "$SETUP/welcome_back_prompt.md")"
fi
