# Obsidian Vault Daemon

A background daemon that monitors your Obsidian vault and executes Claude Code tasks automatically.

## Features

| Feature | Description |
|---------|-------------|
| **Task Queue** | Drop markdown files in `Tasks/Inbox/` for autonomous execution |
| **@agent Commands** | Write `@agent <instruction>` anywhere in vault for inline AI assistance |
| **Menubar App** | Native macOS menubar app for status, pause/resume, and manual triggers |
| **Sync-Safe** | Debounced file watching to avoid conflicts with Obsidian sync |

## Requirements

- **macOS** (Linux support planned)
- **Bun** runtime (>= 1.0)
- **Claude CLI** (`@anthropic-ai/claude-code`)
- An Obsidian vault

## Quick Start

```bash
# Clone the repo
git clone https://github.com/ckorhonen/obsidian-vault-daemon.git
cd obsidian-vault-daemon

# Install dependencies
bun install

# Copy and configure
cp config.example.json config.json
# Edit config.json to set your vault_path (or leave as "auto" if installing in vault)

# Test run (foreground)
bun run daemon.ts

# Install as LaunchAgent (auto-start on login)
./install.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    LaunchAgent (auto-start)                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     vault-daemon (Bun)                           │
│                                                                  │
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │  Task Watcher   │    │  @agent Scanner │                     │
│  │  (chokidar)     │    │  (poll/watch)   │                     │
│  └────────┬────────┘    └────────┬────────┘                     │
│           │                      │                               │
│           └──────────┬───────────┘                               │
│                      ▼                                           │
│           ┌─────────────────────┐                               │
│           │   Execution Queue   │                               │
│           │   (max 2 concurrent)│                               │
│           └──────────┬──────────┘                               │
│                      ▼                                           │
│           ┌─────────────────────┐                               │
│           │   Claude CLI        │                               │
│           │   (subprocess)      │                               │
│           └─────────────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Menubar App (Swift)                           │
│  - Status indicator (idle/working/blocked/paused)               │
│  - View logs, pause/resume, force scan                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Installation

### Prerequisites

```bash
# Install Bun
curl -fsSL https://bun.sh/install | bash

# Install Claude CLI
npm install -g @anthropic-ai/claude-code

# Verify
bun --version
claude --version
```

### Clone & Setup

```bash
git clone https://github.com/ckorhonen/obsidian-vault-daemon.git
cd obsidian-vault-daemon

# Install Node dependencies
bun install

# Create config from example
cp config.example.json config.json
```

### Configure

Edit `config.json`:

```json
{
  "vault_path": "/path/to/your/obsidian/vault",
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
    "ignore_patterns": [
      "Tasks/**",
      ".obsidian/**",
      "**/node_modules/**"
    ]
  },

  "claude": {
    "command": "auto",
    "args": ["--dangerously-skip-permissions"],
    "timeout_ms": 300000
  }
}
```

**Path auto-resolution:**
- `vault_path: "auto"` - Uses parent of daemon directory (for in-vault installation)
- `log_path: "auto"` - Uses `~/Library/Logs/vault-daemon.log` on macOS
- `state_path: "auto"` - Uses `~/.vault-daemon-state.json`
- `claude.command: "auto"` - Finds Claude CLI automatically

### Create Vault Folders

```bash
# In your Obsidian vault, create the task folders:
mkdir -p "Tasks/Inbox" "Tasks/In Progress" "Tasks/Blocked" "Tasks/Completed"
```

### Install LaunchAgent (Auto-Start)

```bash
./install.sh
```

This will:
1. Generate a LaunchAgent plist for your user
2. Install it to `~/Library/LaunchAgents/`
3. Load the daemon

### Verify Installation

```bash
# Check daemon is running
launchctl list | grep vault-daemon

# Check logs
tail -f ~/Library/Logs/vault-daemon.log

# Test task execution
echo "List the files in the Research folder" > "/path/to/vault/Tasks/Inbox/test-task.md"
```

---

## Menubar App (Optional)

A native macOS menubar app for controlling the daemon.

### Build

```bash
cd menubar-app
./build.sh
```

### Install

1. Move `VaultDaemon.app` to `/Applications/`
2. Add to Login Items: System Settings → General → Login Items → Add "VaultDaemon"

### Status Icons

| Icon | State |
|------|-------|
| `◉` | Idle - daemon running, no active tasks |
| `◐` | Working - processing task(s) |
| `◍` | Blocked - task waiting for input |
| `◯` | Paused - daemon stopped |
| `◉!` | Error - check logs |

### Menu Options

| Option | Description |
|--------|-------------|
| **Status** | Current state + active task count |
| **View Logs** | Opens log file in Console.app |
| **View Tasks** | Opens Tasks folder in Finder |
| **Force Scan** | Immediate @agent scan |
| **Pause/Resume** | Toggle LaunchAgent |
| **Quit** | Stop menubar app (daemon continues) |

---

## Task System

### Folder Structure

```
Tasks/
├── Inbox/          # Drop new tasks here
├── In Progress/    # Currently being worked on
├── Blocked/        # Waiting for user input
└── Completed/      # Finished tasks with output
```

### Task Lifecycle

```
  ┌─────────┐
  │  Inbox  │ ◄── User creates task file
  └────┬────┘
       │ daemon detects (5s debounce)
       ▼
┌─────────────┐
│ In Progress │ ◄── Claude working
└──────┬──────┘
       │
   ┌───┴───┐
   │       │
   ▼       ▼
┌─────┐  ┌─────────┐
│Done │  │ Blocked │ ◄── Claude has questions
└──┬──┘  └────┬────┘
   │          │ user updates file
   │          ▼
   │    ┌─────────────┐
   │    │ In Progress │ (retry)
   │    └──────┬──────┘
   │           │
   ▼           ▼
┌───────────────────┐
│    Completed      │ ◄── Summary appended
└───────────────────┘
```

### Task File Format

**Minimal** (just instructions):
```markdown
Research the latest developments in MCP servers and create a summary.
```

**With frontmatter** (optional):
```markdown
---
priority: high
tags: [research, ai]
---

Research the latest developments in MCP servers and create a summary.
```

### Blocked State

When Claude needs clarification, the task is moved to `Blocked/` with questions:

```markdown
---
status: blocked
blocked_at: 2026-01-15T21:30:00Z
---

Research the latest developments in MCP servers...

---

## Questions from Claude

1. Should I focus on official Anthropic MCP servers or community implementations?
2. What time range - last week, month, or all-time?
3. Should the output be a single note or multiple notes by topic?

<!-- Answer below or edit the task description above, then save -->
```

Answer the questions and save - daemon will retry automatically.

---

## @agent Commands

### Syntax

Write anywhere in a markdown file:

```markdown
@agent <instruction>
```

### Examples

```markdown
# My Research Note

This is some content about quantum computing.

@agent expand this section with more technical details

More content here...

@agent rewrite the above paragraph to be more concise
```

### Behavior

1. Daemon scans vault files (configurable interval or on-change)
2. Finds `@agent` patterns (ignores code blocks, tables, documentation)
3. Sends file + instruction to Claude
4. Claude edits file in-place, removing the `@agent` line
5. Result appears where the command was

### Ignored Patterns

The scanner automatically ignores:
- Content inside code blocks (fenced and indented)
- Inline code containing `@agent`
- Table rows
- Blockquotes
- Headers mentioning @agent (documentation)

---

## Configuration Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vault_path` | string | `"auto"` | Path to Obsidian vault |
| `log_path` | string | `"auto"` | Path to log file |
| `log_max_size_mb` | number | `1` | Max log file size before rotation |
| `state_path` | string | `"auto"` | Path to daemon state file |
| `tasks.enabled` | boolean | `true` | Enable task queue processing |
| `tasks.debounce_ms` | number | `5000` | Debounce for file changes |
| `tasks.max_concurrent` | number | `2` | Max concurrent Claude processes |
| `agent_tags.enabled` | boolean | `true` | Enable @agent tag scanning |
| `agent_tags.scan_interval_ms` | number | `180000` | Periodic scan interval (3 min) |
| `agent_tags.debounce_ms` | number | `30000` | Debounce for file change scans |
| `agent_tags.ignore_patterns` | string[] | See example | Glob patterns to ignore |
| `claude.command` | string | `"auto"` | Claude CLI path or "auto" |
| `claude.args` | string[] | `["--dangerously-skip-permissions"]` | Claude CLI arguments |
| `claude.timeout_ms` | number | `300000` | Task timeout (5 min) |

---

## Manual Control

```bash
# Start daemon (foreground)
bun run daemon.ts

# Stop daemon (if using LaunchAgent)
launchctl unload ~/Library/LaunchAgents/com.vault-daemon.plist

# Restart daemon
launchctl unload ~/Library/LaunchAgents/com.vault-daemon.plist
launchctl load ~/Library/LaunchAgents/com.vault-daemon.plist

# View status
launchctl list | grep vault-daemon
```

---

## Logs

- **Location**: `~/Library/Logs/vault-daemon.log`
- **Max size**: 1 MB (oldest entries evicted automatically)
- **Format**: `[ISO8601] [LEVEL] message`

| Level | Description |
|-------|-------------|
| `INFO` | Normal operations |
| `WARN` | Non-fatal issues |
| `ERROR` | Failures requiring attention |
| `DEBUG` | Verbose (for troubleshooting) |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tasks not processing | Check logs, verify daemon is running |
| @agent not working | Check ignore patterns, verify scan interval |
| Claude errors | Check Claude CLI auth, run `claude` manually |
| Sync conflicts | Increase debounce times in config |
| High CPU | Reduce scan frequency, add ignore patterns |
| Menubar app shows "Stopped" | Run `launchctl load ~/Library/LaunchAgents/com.vault-daemon.plist` |

---

## Security Notes

- Daemon runs Claude with `--dangerously-skip-permissions` for autonomous operation
- Only processes files within the configured vault
- Task outputs stay within vault (no external writes by default)
- Review completed tasks regularly

---

## Uninstall

```bash
# Stop and remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.vault-daemon.plist
rm ~/Library/LaunchAgents/com.vault-daemon.plist

# Remove menubar app
rm -rf /Applications/VaultDaemon.app

# Remove state files
rm ~/.vault-daemon-state.json
rm ~/.vault-daemon-config.json

# Delete the repo
rm -rf /path/to/obsidian-vault-daemon
```

---

## Contributing

Pull requests welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a PR with clear description

---

## License

MIT License - see [LICENSE](LICENSE)

---

## Related Projects

- [Claude Code](https://github.com/anthropics/claude-code) - Claude CLI
- [Obsidian](https://obsidian.md) - Knowledge base app
