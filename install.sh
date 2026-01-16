#!/bin/bash
set -e

# Vault Daemon Installer
# Single command to install everything: daemon, dependencies, and menubar app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
APP_NAME="Vault Daemon"
APP_DEST="/Applications/$APP_NAME.app"

echo ""
echo "📦 Vault Daemon Installer"
echo "========================="
echo ""

# Step 1: Check for Bun
echo "🔍 Checking prerequisites..."

BUN_PATH=$(which bun 2>/dev/null || echo "$HOME/.bun/bin/bun")
if [ ! -f "$BUN_PATH" ]; then
    echo ""
    echo "❌ Bun not found."
    echo ""
    read -p "Install Bun now? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo "📥 Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        BUN_PATH="$HOME/.bun/bin/bun"
    else
        echo "Please install Bun manually: curl -fsSL https://bun.sh/install | bash"
        exit 1
    fi
fi

echo "  ✓ Bun: $BUN_PATH"

# Check for Claude CLI
CLAUDE_PATH=$(which claude 2>/dev/null || echo "$HOME/.local/bin/claude")
if [ -f "$CLAUDE_PATH" ]; then
    echo "  ✓ Claude CLI: $CLAUDE_PATH"
else
    echo "  ⚠ Claude CLI not found (install with: npm install -g @anthropic-ai/claude-code)"
fi

# Step 2: Install Node dependencies
echo ""
echo "📥 Installing dependencies..."
cd "$SCRIPT_DIR"
"$BUN_PATH" install --silent

echo "  ✓ Dependencies installed"

# Step 3: Build menubar app
echo ""
echo "🔨 Building menubar app..."

cd "$SCRIPT_DIR/menubar-app"

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "  ⚠ Swift not found. Skipping menubar app build."
    echo "    Install Xcode Command Line Tools: xcode-select --install"
else
    swift build -c release --quiet 2>/dev/null || swift build -c release

    # Create app bundle
    rm -rf "VaultDaemon.app" 2>/dev/null || true
    mkdir -p "VaultDaemon.app/Contents/MacOS"
    mkdir -p "VaultDaemon.app/Contents/Resources"

    cp .build/release/VaultDaemon "VaultDaemon.app/Contents/MacOS/"

    cat > "VaultDaemon.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VaultDaemon</string>
    <key>CFBundleIdentifier</key>
    <string>com.korhonen.vault-daemon-menubar</string>
    <key>CFBundleName</key>
    <string>Vault Daemon</string>
    <key>CFBundleVersion</key>
    <string>1.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

    # Install to /Applications
    echo "  ✓ Menubar app built"

    # Kill existing app if running
    pkill -f "VaultDaemon" 2>/dev/null || true
    sleep 1

    # Copy to Applications
    rm -rf "$APP_DEST" 2>/dev/null || true
    cp -R "VaultDaemon.app" "$APP_DEST"
    echo "  ✓ Installed to $APP_DEST"
fi

cd "$SCRIPT_DIR"

# Step 4: Launch menubar app (it handles vault selection and daemon setup)
echo ""
echo "🚀 Launching Vault Daemon..."
echo ""

if [ -d "$APP_DEST" ]; then
    open "$APP_DEST"

    echo "✅ Installation complete!"
    echo ""
    echo "The menubar app will guide you through selecting your Obsidian vault."
    echo "Look for the ◎ icon in your menubar."
    echo ""
    echo "After setup, the daemon will automatically:"
    echo "  • Watch Tasks/Inbox/ for new task files"
    echo "  • Scan for @agent commands in your vault"
    echo "  • Start on login"
    echo ""
else
    # Fallback: manual setup without menubar app
    echo "⚠ Menubar app not available. Running manual setup..."
    echo ""

    # Prompt for vault path
    read -p "Enter path to your Obsidian vault: " VAULT_PATH
    VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

    if [ ! -d "$VAULT_PATH" ]; then
        echo "❌ Directory not found: $VAULT_PATH"
        exit 1
    fi

    # Create config
    cat > "$SCRIPT_DIR/config.json" << EOF
{
  "vault_path": "$VAULT_PATH",
  "log_path": "auto",
  "log_max_size_mb": 1,
  "state_path": "auto",
  "tasks": {
    "enabled": true,
    "debounce_ms": 5000,
    "max_concurrent": 2
  },
  "agent_tags": {
    "enabled": true,
    "scan_interval_ms": 180000,
    "debounce_ms": 30000,
    "ignore_patterns": ["Tasks/**", ".obsidian/**", "**/node_modules/**", "**/.git/**"]
  },
  "claude": {
    "command": "auto",
    "args": ["--dangerously-skip-permissions"],
    "timeout_ms": 300000
  }
}
EOF

    echo "  ✓ Config created"

    # Create Tasks folders
    mkdir -p "$VAULT_PATH/Tasks/Inbox"
    mkdir -p "$VAULT_PATH/Tasks/In Progress"
    mkdir -p "$VAULT_PATH/Tasks/Blocked"
    mkdir -p "$VAULT_PATH/Tasks/Completed"
    echo "  ✓ Tasks folders created"

    # Install LaunchAgent
    LABEL="com.vault-daemon"
    PLIST_PATH="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
    LOG_PATH="$HOME_DIR/Library/Logs/vault-daemon.log"

    mkdir -p "$HOME_DIR/Library/LaunchAgents"

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BUN_PATH</string>
        <string>run</string>
        <string>$SCRIPT_DIR/daemon.ts</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$VAULT_PATH</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:$HOME_DIR/.bun/bin:/opt/homebrew/bin:$HOME_DIR/.local/bin</string>
        <key>HOME</key>
        <string>$HOME_DIR</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    echo "  ✓ Daemon started"
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "Commands:"
    echo "  View logs:    tail -f $LOG_PATH"
    echo "  Stop daemon:  launchctl unload $PLIST_PATH"
    echo "  Start daemon: launchctl load $PLIST_PATH"
    echo ""
    echo "Test it:"
    echo "  echo 'List the files in my vault' > '$VAULT_PATH/Tasks/Inbox/test.md'"
fi
