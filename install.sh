#!/bin/bash
set -e

# Vault Daemon Installer
# Generates LaunchAgent plist with correct paths for current machine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
LABEL="com.vault-daemon"

# Find bun
BUN_PATH=$(which bun 2>/dev/null || echo "$HOME/.bun/bin/bun")
if [ ! -f "$BUN_PATH" ]; then
    echo "❌ Bun not found. Install with: curl -fsSL https://bun.sh/install | bash"
    exit 1
fi

echo "📦 Vault Daemon Installer"
echo "========================="
echo "Vault:  $VAULT_DIR"
echo "Daemon: $SCRIPT_DIR"
echo "Bun:    $BUN_PATH"
echo ""

# Install dependencies
echo "📥 Installing dependencies..."
cd "$SCRIPT_DIR"
"$BUN_PATH" install

# Generate plist
PLIST_PATH="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME_DIR/Library/Logs/vault-daemon.log"

echo "📝 Generating LaunchAgent plist..."
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
    <string>$VAULT_DIR</string>

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

echo "✅ Plist created: $PLIST_PATH"

# Unload if already loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# Load the agent
echo "🚀 Loading LaunchAgent..."
launchctl load "$PLIST_PATH"

echo ""
echo "✅ Vault Daemon installed and running!"
echo ""
echo "Commands:"
echo "  View logs:    tail -f $LOG_PATH"
echo "  Stop daemon:  launchctl unload $PLIST_PATH"
echo "  Start daemon: launchctl load $PLIST_PATH"
echo ""
echo "Test it by creating a task:"
echo "  echo 'List files in Research/' > '$VAULT_DIR/Tasks/Inbox/test-task.md'"
