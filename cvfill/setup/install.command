#!/bin/bash
# =====================================================================
#  Auto-Apply — one-click installer (double-click this file)
#  For a non-technical owner: installs the Codex assistant, builds the
#  tool, sets up the vault, and makes a clickable "Auto-Apply" app.
#  Shows native windows for each step; details scroll in this window.
# =====================================================================
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SETUP/../.." && pwd)"
APP_DIR="$HOME/Applications/Auto-Apply.app"
TITLE="Auto-Apply Setup"

# ---- native window helpers (osascript) ----
info()    { osascript -e "display dialog \"$1\" with title \"$TITLE\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1; }
confirm() { osascript -e "display dialog \"$1\" with title \"$TITLE\" buttons {\"Not now\",\"Yes\"} default button \"Yes\"" >/dev/null 2>&1; }
fail()    { osascript -e "display dialog \"$1\" with title \"$TITLE\" buttons {\"OK\"} default button \"OK\" with icon stop" >/dev/null 2>&1; }
step()    { echo; echo ">>> $1"; }

clear
echo "==============================================="
echo "  Auto-Apply installer"
echo "  (you can watch progress here; windows will"
echo "   pop up when we need you)"
echo "==============================================="

info "Welcome! This sets up your personal job-application assistant.\n\nIt will:\n  • install the Codex assistant\n  • sign you in\n  • build the tool and create an \"Auto-Apply\" app you can click\n\nTakes a few minutes. Click OK to begin."

# ---- 1. Xcode Command Line Tools (needed to build the tool) ----
step "Checking developer tools..."
if ! xcode-select -p >/dev/null 2>&1; then
  info "macOS needs to install a small developer package first.\n\nClick OK, then click \"Install\" in Apple's window and wait for it to finish. When it's done, come back and click OK on the next window."
  xcode-select --install >/dev/null 2>&1
  info "Click OK here ONCE Apple's \"Command Line Tools\" install has finished."
fi
xcode-select -p >/dev/null 2>&1 || { fail "Developer tools still missing. Please run this installer again after they finish installing."; exit 1; }

# ---- 2. Homebrew (used to install Codex + the PDF reader) ----
step "Checking Homebrew (software installer)..."
if ! command -v brew >/dev/null 2>&1; then
  if confirm "We'd like to install Homebrew, Apple's common software installer. It's safe and widely used.\n\nYou may be asked for your Mac password in this window. Install it?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
fi

# ---- 3. Codex CLI (the assistant) ----
step "Installing the Codex assistant..."
if ! command -v codex >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install codex || brew install --cask codex
  elif command -v npm >/dev/null 2>&1; then
    npm install -g @openai/codex
  fi
fi
if ! command -v codex >/dev/null 2>&1; then
  fail "Couldn't install Codex automatically. Please install Node or Homebrew, then run this installer again."
  exit 1
fi
echo "Codex: $(codex --version 2>/dev/null)"

# ---- 4. Sign in to Codex (uses your Codex / ChatGPT subscription) ----
step "Signing you in to Codex..."
if ! codex login status >/dev/null 2>&1; then
  info "Next, a browser window will open to sign in to your Codex (ChatGPT) account.\n\nSign in, then come back here."
  codex login || true
fi
codex login status >/dev/null 2>&1 && echo "Signed in to Codex." || echo "Not signed in yet — you can finish this later from the app."

# ---- 5. Build the tool ----
step "Building the tool..."
if ! ( cd "$PROJECT" && make >/dev/null 2>build/_install_build.log ); then
  fail "The build hit a problem. Details are in build/_install_build.log inside the tool folder."
  exit 1
fi
echo "Built."

# ---- 6. PDF reader (to read your resume) ----
step "Checking the resume reader..."
if ! command -v pdftotext >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  brew install poppler || true
fi

# ---- 7. Create the vault (where your info is stored) ----
step "Preparing your info vault..."
python3 "$PROJECT/cvfill/vault.py" init || true

# ---- 8. Make the clickable Auto-Apply app ----
step "Creating your Auto-Apply app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Auto-Apply</string>
  <key>CFBundleDisplayName</key><string>Auto-Apply</string>
  <key>CFBundleIdentifier</key><string>com.autoapply.assistant</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>autoapply</string>
</dict></plist>
PLIST
cat > "$APP_DIR/Contents/MacOS/autoapply" <<LAUNCH
#!/bin/bash
open -a Terminal "$PROJECT/cvfill/setup/launch_codex.command"
LAUNCH
chmod +x "$APP_DIR/Contents/MacOS/autoapply"
chmod +x "$PROJECT/cvfill/setup/launch_codex.command"
# Also drop a copy on the Desktop for easy finding.
ln -sf "$APP_DIR" "$HOME/Desktop/Auto-Apply.app" 2>/dev/null || true

echo "App created at $APP_DIR"

# ---- 9. Done ----
if confirm "All set! 🎉\n\nYour \"Auto-Apply\" app is in Applications (and on your Desktop).\nOpen it anytime to talk to your assistant — just type what you want.\n\nOpen it now to finish setting up your info and find your first jobs?"; then
  open "$APP_DIR"
fi
echo; echo "Done. You can close this window."
