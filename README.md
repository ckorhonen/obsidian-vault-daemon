# Obsidian Vault Daemon

A background daemon that monitors your Obsidian vault and executes Claude Code tasks automatically.

## Features

| Feature | Description |
|---------|-------------|
| **Task Queue** | Drop markdown files in `Tasks/Inbox/` for autonomous execution |
| **@agent Commands** | Write `@agent <instruction>` anywhere in vault for inline AI assistance |
| **Scheduled Tasks** | Cron-based scheduling with SwiftUI editor for recurring automation |
| **Menubar App** | Native macOS menubar app for status, pause/resume, and manual triggers |
| **Sync-Safe** | Debounced file watching to avoid conflicts with Obsidian sync |

## Requirements

- **macOS 12+** (Linux support planned)
- **Claude CLI** (`npm install -g @anthropic-ai/claude-code`)
- An Obsidian vault

## Quick Start

```bash
git clone https://github.com/ckorhonen/obsidian-vault-daemon.git
cd obsidian-vault-daemon
./install.sh
```

That's it! The installer will:
1. Install Bun (if needed)
2. Install dependencies
3. Build the menubar app
4. Launch the setup wizard to select your vault

Look for the **◎** icon in your menubar to complete setup.

---

## What the Installer Does

```
./install.sh
    │
    ├── Check/install Bun runtime
    ├── Install Node dependencies (bun install)
    ├── Build menubar app (Swift)
    ├── Install to /Applications/
    └── Launch menubar app
            │
            └── First-run setup wizard
                    ├── Auto-detect Obsidian vaults
                    ├── Create Tasks folders
                    ├── Install LaunchAgent
                    └── Start daemon
```

After setup, the daemon runs automatically on login.

---

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

## Menubar App

### Status Icons

| Icon | State |
|------|-------|
| `◎` | Setup required - first run |
| `◉` | Idle - daemon running, no active tasks |
| `◐` | Working - processing task(s) |
| `◍` | Blocked - task waiting for input |
| `◯` | Paused - daemon stopped |
| `◉!` | Error - check logs |

### Menu Options

| Option | Description |
|--------|-------------|
| **Status** | Current state + active task count |
| **Vault** | Currently configured vault |
| **View Logs** | Opens log file in Console.app |
| **View Tasks** | Opens Tasks folder in Finder |
| **Open Vault** | Opens vault folder in Finder |
| **Force Scan** | Immediate @agent scan |
| **Schedules** | Create, edit, enable/disable scheduled tasks |
| **Pause/Resume** | Toggle daemon |
| **Change Vault** | Reconfigure vault location |
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

## Scheduled Tasks

Run Claude prompts automatically on a schedule. Create recurring automations like daily email sync, weekly vault organization, or monthly reports.

### Creating a Schedule

1. Click the menubar icon (◉)
2. Go to **Schedules → New Schedule...**
3. Enter a name and Claude prompt
4. Select frequency (Hourly / Daily / Weekly / Monthly / Custom)
5. Click **Create**

### Schedule Options

| Preset | Description | Example Cron |
|--------|-------------|--------------|
| **Hourly** | Run at a specific minute each hour | `30 * * * *` (at :30) |
| **Daily** | Run at a specific time each day | `0 9 * * *` (9:00 AM) |
| **Weekly** | Run on a specific day and time | `0 9 * * 1` (Monday 9 AM) |
| **Monthly** | Run on a specific day of month | `0 9 1 * *` (1st at 9 AM) |
| **Custom** | Full cron expression | `*/15 * * * *` (every 15 min) |

### How It Works

1. Daemon loads schedules from `~/.vault-daemon-schedules.json`
2. At the scheduled time, creates a task file in `Tasks/Inbox/`
3. Task file is named `[scheduled] Schedule Name.md`
4. Normal task processing takes over from there

### Managing Schedules

From the menubar **Schedules** submenu:
- **● Schedule Name** - Enabled schedule (click for submenu)
- **○ Schedule Name** - Disabled schedule
- **Enable/Disable** - Toggle without deleting
- **Edit...** - Modify name, prompt, or timing
- **Delete** - Remove schedule permanently

### Schedule File Format

Schedules are stored in `~/.vault-daemon-schedules.json`:

```json
{
  "schedules": [
    {
      "id": "uuid",
      "name": "Daily Email Sync",
      "prompt": "Check my email and summarize important messages",
      "cron": "0 9 * * *",
      "enabled": true,
      "lastRun": "2026-01-16T09:00:00Z",
      "createdAt": "2026-01-15T10:00:00Z"
    }
  ]
}
```

### Hot Reload

The daemon watches the schedules file for changes. Edit it directly or use the menubar app - changes take effect immediately without restart.

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

## Configuration

Configuration is stored in two places:
- `~/.vault-daemon-config.json` - Used by menubar app
- `config.json` in daemon directory - Used by daemon

The menubar app manages both automatically. For manual configuration:

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

### Configuration Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vault_path` | string | - | Path to Obsidian vault |
| `log_path` | string | `"auto"` | Path to log file |
| `log_max_size_mb` | number | `1` | Max log file size before rotation |
| `state_path` | string | `"auto"` | Path to daemon state file |
| `tasks.enabled` | boolean | `true` | Enable task queue processing |
| `tasks.debounce_ms` | number | `5000` | Debounce for file changes |
| `tasks.max_concurrent` | number | `2` | Max concurrent Claude processes |
| `agent_tags.enabled` | boolean | `true` | Enable @agent tag scanning |
| `agent_tags.scan_interval_ms` | number | `180000` | Periodic scan interval (3 min) |
| `agent_tags.debounce_ms` | number | `30000` | Debounce for file change scans |
| `agent_tags.ignore_patterns` | string[] | See above | Glob patterns to ignore |
| `claude.command` | string | `"auto"` | Claude CLI path or "auto" |
| `claude.args` | string[] | `["--dangerously-skip-permissions"]` | Claude CLI arguments |
| `claude.timeout_ms` | number | `300000` | Task timeout (5 min) |

**Path auto-resolution:**
- `log_path: "auto"` → `~/Library/Logs/vault-daemon.log`
- `state_path: "auto"` → `~/.vault-daemon-state.json`
- `claude.command: "auto"` → Finds Claude CLI automatically

---

## Manual Control

```bash
# Start daemon (foreground, for debugging)
bun run daemon.ts

# Stop daemon
launchctl unload ~/Library/LaunchAgents/com.vault-daemon.plist

# Start daemon
launchctl load ~/Library/LaunchAgents/com.vault-daemon.plist

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
| Setup wizard doesn't appear | Delete `~/.vault-daemon-config.json` and relaunch app |

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
rm -rf "/Applications/Vault Daemon.app"

# Remove state files
rm ~/.vault-daemon-state.json
rm ~/.vault-daemon-config.json
rm ~/.vault-daemon-schedules.json

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
