#!/usr/bin/env bun

import { watch } from "chokidar";
import { spawn, type Subprocess, which } from "bun";
import { readdir, readFile, writeFile, rename, stat, appendFile, truncate } from "fs/promises";
import { join, relative, basename, dirname } from "path";
import { existsSync } from "fs";
import { homedir } from "os";

// =============================================================================
// Types
// =============================================================================

interface Config {
  vault_path: string | "auto";
  log_path: string | "auto";
  log_max_size_mb: number;
  state_path: string | "auto";
  tasks: {
    enabled: boolean;
    debounce_ms: number;
    max_concurrent: number;
  };
  agent_tags: {
    enabled: boolean;
    scan_interval_ms: number;
    debounce_ms: number;
    ignore_patterns: string[];
  };
  claude: {
    command: string | "auto";
    args: string[];
    timeout_ms: number;
  };
}

interface ResolvedConfig extends Omit<Config, "vault_path" | "log_path" | "state_path" | "claude"> {
  vault_path: string;
  log_path: string;
  state_path: string;
  claude: {
    command: string;
    args: string[];
    timeout_ms: number;
  };
}

interface DaemonState {
  status: "idle" | "working" | "blocked" | "paused" | "error";
  active_tasks: number;
  last_scan: string | null;
  last_error: string | null;
  tasks_completed_today: number;
  agent_commands_today: number;
}

interface TaskInfo {
  path: string;
  name: string;
  content: string;
}

type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR";

// =============================================================================
// Globals
// =============================================================================

const CONFIG_PATH = join(import.meta.dir, "config.json");
let config: ResolvedConfig;
let state: DaemonState = {
  status: "idle",
  active_tasks: 0,
  last_scan: null,
  last_error: null,
  tasks_completed_today: 0,
  agent_commands_today: 0,
};

const taskQueue: TaskInfo[] = [];
const activeProcesses: Map<string, Subprocess> = new Map();
const pendingDebounces: Map<string, Timer> = new Map();

// =============================================================================
// Logging
// =============================================================================

async function log(level: LogLevel, message: string): Promise<void> {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] [${level}] ${message}\n`;

  // Console output
  const prefix = { DEBUG: "🔍", INFO: "ℹ️ ", WARN: "⚠️ ", ERROR: "❌" }[level];
  console.log(`${prefix} ${message}`);

  // File output with rotation
  try {
    const stats = existsSync(config.log_path) ? await stat(config.log_path) : null;
    const maxBytes = config.log_max_size_mb * 1024 * 1024;

    if (stats && stats.size > maxBytes) {
      // Read file, keep last 80%
      const content = await readFile(config.log_path, "utf-8");
      const lines = content.split("\n");
      const keepLines = Math.floor(lines.length * 0.8);
      await writeFile(config.log_path, lines.slice(-keepLines).join("\n"));
    }

    await appendFile(config.log_path, line);
  } catch (err) {
    console.error("Failed to write log:", err);
  }
}

// =============================================================================
// State Management
// =============================================================================

async function saveState(): Promise<void> {
  try {
    await writeFile(config.state_path, JSON.stringify(state, null, 2));
  } catch (err) {
    console.error("Failed to save state:", err);
  }
}

function updateState(updates: Partial<DaemonState>): void {
  state = { ...state, ...updates };
  saveState();
}

// =============================================================================
// Task Execution
// =============================================================================

async function moveTask(taskPath: string, toFolder: string): Promise<string> {
  const fileName = basename(taskPath);
  const newPath = join(config.vault_path, "Tasks", toFolder, fileName);
  await rename(taskPath, newPath);
  await log("INFO", `Moved task to ${toFolder}: ${fileName}`);
  return newPath;
}

async function executeTask(task: TaskInfo): Promise<void> {
  const taskName = basename(task.path);
  await log("INFO", `Starting task: ${taskName}`);

  // Move to In Progress
  const inProgressPath = await moveTask(task.path, "In Progress");

  updateState({
    status: "working",
    active_tasks: state.active_tasks + 1,
  });

  try {
    // Build prompt for Claude
    const prompt = `You are executing a task from the user's Obsidian vault task queue.

TASK FILE: ${taskName}
TASK CONTENT:
${task.content}

INSTRUCTIONS:
1. Read the task carefully and execute what is requested
2. Work within the Obsidian vault at: ${config.vault_path}
3. If you need clarification, respond with questions in a specific format (see below)
4. When complete, summarize what you did

If you have questions that BLOCK your progress, output them in this exact format:
---
## Questions from Claude
1. [Your question]
2. [Another question if needed]
<!-- Answer below or edit the task description above, then save -->

Otherwise, complete the task and provide a summary of what was accomplished.`;

    // Spawn Claude
    const proc = spawn({
      cmd: [config.claude.command, ...config.claude.args, "-p", prompt],
      cwd: config.vault_path,
      stdout: "pipe",
      stderr: "pipe",
    });

    activeProcesses.set(taskName, proc);

    // Set timeout
    const timeout = setTimeout(() => {
      proc.kill();
      log("WARN", `Task timed out: ${taskName}`);
    }, config.claude.timeout_ms);

    // Wait for completion
    const exitCode = await proc.exited;
    clearTimeout(timeout);
    activeProcesses.delete(taskName);

    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();

    if (exitCode !== 0) {
      throw new Error(`Claude exited with code ${exitCode}: ${stderr}`);
    }

    // Check if Claude is blocked (has questions)
    if (stdout.includes("## Questions from Claude")) {
      // Append questions to task file and move to Blocked
      const blockedContent = `${task.content}

---
status: blocked
blocked_at: ${new Date().toISOString()}
---

${stdout}`;

      await writeFile(inProgressPath, blockedContent);
      await moveTask(inProgressPath, "Blocked");
      await log("INFO", `Task blocked with questions: ${taskName}`);

      updateState({
        status: state.active_tasks > 1 ? "working" : "blocked",
        active_tasks: state.active_tasks - 1,
      });
    } else {
      // Task completed - append summary and move to Completed
      const completedContent = `${task.content}

---
completed_at: ${new Date().toISOString()}
---

## Completion Summary

${stdout}`;

      await writeFile(inProgressPath, completedContent);
      await moveTask(inProgressPath, "Completed");
      await log("INFO", `Task completed: ${taskName}`);

      updateState({
        status: state.active_tasks > 1 ? "working" : "idle",
        active_tasks: state.active_tasks - 1,
        tasks_completed_today: state.tasks_completed_today + 1,
      });
    }
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    await log("ERROR", `Task failed: ${taskName} - ${errorMsg}`);

    // Append error and move to Blocked
    const errorContent = `${task.content}

---
status: error
error_at: ${new Date().toISOString()}
---

## Error

\`\`\`
${errorMsg}
\`\`\`

<!-- Fix the issue and move back to Inbox to retry -->`;

    try {
      await writeFile(inProgressPath, errorContent);
      await moveTask(inProgressPath, "Blocked");
    } catch {
      // File might have been moved already
    }

    updateState({
      status: state.active_tasks > 1 ? "working" : "error",
      active_tasks: Math.max(0, state.active_tasks - 1),
      last_error: errorMsg,
    });
  }
}

async function processTaskQueue(): Promise<void> {
  while (taskQueue.length > 0 && state.active_tasks < config.tasks.max_concurrent) {
    const task = taskQueue.shift();
    if (task) {
      executeTask(task); // Don't await - run concurrently
    }
  }
}

// =============================================================================
// @agent Tag Processing
// =============================================================================

/**
 * Extract real @agent commands from markdown content.
 * Filters out:
 * - Content inside fenced code blocks (```)
 * - Content inside inline code (`...`)
 * - Lines that look like documentation (tables, ASCII art, quotes)
 * - @agent not at the start of a line
 */
function extractAgentCommands(content: string): Array<{ fullMatch: string; instruction: string; lineNumber: number }> {
  const results: Array<{ fullMatch: string; instruction: string; lineNumber: number }> = [];

  // Remove fenced code blocks first
  const withoutCodeBlocks = content.replace(/```[\s\S]*?```/g, (match) => {
    // Replace with same number of newlines to preserve line numbers
    return match.split("\n").map(() => "").join("\n");
  });

  // Process line by line
  const lines = withoutCodeBlocks.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Skip lines that look like documentation/code
    if (
      line.includes("|") || // Table rows
      line.includes("→") || // ASCII arrows (often in diagrams)
      line.includes("```") || // Leftover code fence markers
      line.trim().startsWith(">") || // Blockquotes
      line.trim().startsWith("#") && line.includes("@agent") || // Headers mentioning @agent
      /^\s{4,}/.test(line) || // Indented code blocks (4+ spaces)
      line.includes("`@agent") || // Inline code containing @agent
      line.includes("@agent`") // Inline code containing @agent
    ) {
      continue;
    }

    // Match @agent at start of line (with optional whitespace)
    const match = line.match(/^\s*@agent\s+(.+)$/);
    if (match) {
      results.push({
        fullMatch: line,
        instruction: match[1].trim(),
        lineNumber: i + 1,
      });
    }
  }

  return results;
}

async function processAgentTag(filePath: string, instruction: string, fullMatch: string, lineNumber: number): Promise<void> {
  const fileName = basename(filePath);
  await log("INFO", `Processing @agent in ${fileName}:${lineNumber}: "${instruction.slice(0, 50)}..."`);

  try {
    const content = await readFile(filePath, "utf-8");

    const prompt = `You are processing an inline @agent command in an Obsidian note.

FILE: ${filePath}
LINE: ${lineNumber}
INSTRUCTION: ${instruction}

CURRENT FILE CONTENT:
${content}

INSTRUCTIONS:
1. Execute the instruction in the context of this file
2. Edit the file to fulfill the request
3. REMOVE the @agent line after completing the task
4. Keep your changes focused and minimal
5. Preserve the rest of the file structure

Use the Edit tool to modify the file. The @agent line to remove is: "${fullMatch.trim()}"`;

    const proc = spawn({
      cmd: [config.claude.command, ...config.claude.args, "-p", prompt],
      cwd: config.vault_path,
      stdout: "pipe",
      stderr: "pipe",
    });

    const exitCode = await proc.exited;

    if (exitCode !== 0) {
      const stderr = await new Response(proc.stderr).text();
      throw new Error(`Claude exited with code ${exitCode}: ${stderr}`);
    }

    await log("INFO", `Completed @agent in ${fileName}`);
    updateState({
      agent_commands_today: state.agent_commands_today + 1,
    });
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    await log("ERROR", `@agent failed in ${fileName}: ${errorMsg}`);
  }
}

async function scanForAgentTags(): Promise<void> {
  await log("DEBUG", "Scanning vault for @agent tags...");
  updateState({ last_scan: new Date().toISOString() });

  const ignorePatterns = config.agent_tags.ignore_patterns;

  async function scanDirectory(dir: string): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      const relativePath = relative(config.vault_path, fullPath);

      // Check ignore patterns
      const shouldIgnore = ignorePatterns.some((pattern) => {
        const regex = new RegExp(
          "^" + pattern.replace(/\*\*/g, ".*").replace(/\*/g, "[^/]*") + "$"
        );
        return regex.test(relativePath);
      });

      if (shouldIgnore) continue;

      if (entry.isDirectory()) {
        await scanDirectory(fullPath);
      } else if (entry.name.endsWith(".md")) {
        try {
          const content = await readFile(fullPath, "utf-8");
          const commands = extractAgentCommands(content);

          for (const cmd of commands) {
            await processAgentTag(fullPath, cmd.instruction, cmd.fullMatch, cmd.lineNumber);
          }
        } catch (err) {
          // File might have been deleted/moved
        }
      }
    }
  }

  try {
    await scanDirectory(config.vault_path);
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    await log("ERROR", `Scan failed: ${errorMsg}`);
  }
}

// =============================================================================
// File Watchers
// =============================================================================

function setupTaskWatcher(): void {
  const inboxPath = join(config.vault_path, "Tasks", "Inbox");
  const blockedPath = join(config.vault_path, "Tasks", "Blocked");

  // Watch Inbox for new tasks
  const inboxWatcher = watch(inboxPath, {
    ignoreInitial: false,
    awaitWriteFinish: {
      stabilityThreshold: config.tasks.debounce_ms,
      pollInterval: 100,
    },
  });

  inboxWatcher.on("add", async (filePath) => {
    if (!filePath.endsWith(".md")) return;

    await log("INFO", `New task detected: ${basename(filePath)}`);

    try {
      const content = await readFile(filePath, "utf-8");
      taskQueue.push({ path: filePath, name: basename(filePath), content });
      processTaskQueue();
    } catch (err) {
      await log("ERROR", `Failed to read task: ${basename(filePath)}`);
    }
  });

  // Watch Blocked for user updates (to retry)
  const blockedWatcher = watch(blockedPath, {
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: config.tasks.debounce_ms,
      pollInterval: 100,
    },
  });

  blockedWatcher.on("change", async (filePath) => {
    if (!filePath.endsWith(".md")) return;

    await log("INFO", `Blocked task updated: ${basename(filePath)}`);

    // Clear any pending debounce
    const existing = pendingDebounces.get(filePath);
    if (existing) clearTimeout(existing);

    // Debounce before processing
    pendingDebounces.set(
      filePath,
      setTimeout(async () => {
        pendingDebounces.delete(filePath);

        try {
          const content = await readFile(filePath, "utf-8");

          // Move back to Inbox for reprocessing
          const inboxPath = await moveTask(filePath, "Inbox");
          await log("INFO", `Re-queued blocked task: ${basename(filePath)}`);
        } catch (err) {
          await log("ERROR", `Failed to re-queue task: ${basename(filePath)}`);
        }
      }, config.tasks.debounce_ms)
    );
  });

  log("INFO", "Task watcher started");
}

function setupAgentTagWatcher(): void {
  // Initial scan
  scanForAgentTags();

  // Periodic scan
  setInterval(() => {
    scanForAgentTags();
  }, config.agent_tags.scan_interval_ms);

  // Also watch for file changes with debounce
  const watcher = watch(config.vault_path, {
    ignored: [
      /node_modules/,
      /\.git/,
      /\.obsidian/,
      /Tasks\//,
      /_agent\/daemon/,
    ],
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: config.agent_tags.debounce_ms,
      pollInterval: 1000,
    },
  });

  watcher.on("change", async (filePath) => {
    if (!filePath.endsWith(".md")) return;

    try {
      const content = await readFile(filePath, "utf-8");
      const commands = extractAgentCommands(content);

      for (const cmd of commands) {
        await processAgentTag(filePath, cmd.instruction, cmd.fullMatch, cmd.lineNumber);
      }
    } catch {
      // File might have been deleted
    }
  });

  log("INFO", "@agent tag watcher started");
}

// =============================================================================
// Path Resolution & Auto-Discovery
// =============================================================================

/**
 * Find Claude CLI executable. Tries multiple locations.
 */
async function findClaude(): Promise<string> {
  // Try direct `claude` command first
  const claudePath = which("claude");
  if (claudePath) return claudePath;

  // Common installation paths
  const possiblePaths = [
    join(homedir(), ".local", "bin", "claude"),
    join(homedir(), ".npm-global", "bin", "claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
  ];

  for (const p of possiblePaths) {
    if (existsSync(p)) return p;
  }

  // Fall back to npx
  const npxPath = which("npx");
  if (npxPath) return "npx";

  throw new Error("Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code");
}

/**
 * Resolve config with auto-discovery for paths marked as "auto"
 */
async function resolveConfig(rawConfig: Config): Promise<ResolvedConfig> {
  // Vault path: use daemon's parent directory (assumes daemon is in _agent/daemon/)
  const vaultPath = rawConfig.vault_path === "auto"
    ? dirname(dirname(import.meta.dir))
    : rawConfig.vault_path;

  // Log path: ~/Library/Logs on macOS, ~/.local/share elsewhere
  const logPath = rawConfig.log_path === "auto"
    ? process.platform === "darwin"
      ? join(homedir(), "Library", "Logs", "vault-daemon.log")
      : join(homedir(), ".local", "share", "vault-daemon.log")
    : rawConfig.log_path;

  // State path: home directory
  const statePath = rawConfig.state_path === "auto"
    ? join(homedir(), ".vault-daemon-state.json")
    : rawConfig.state_path;

  // Claude command
  let claudeCommand = rawConfig.claude.command;
  let claudeArgs = [...rawConfig.claude.args];

  if (claudeCommand === "auto") {
    claudeCommand = await findClaude();
    // If using npx, prepend the package name
    if (claudeCommand === "npx") {
      claudeArgs = ["--yes", "@anthropic-ai/claude-code", ...claudeArgs];
    }
  }

  return {
    ...rawConfig,
    vault_path: vaultPath,
    log_path: logPath,
    state_path: statePath,
    claude: {
      command: claudeCommand,
      args: claudeArgs,
      timeout_ms: rawConfig.claude.timeout_ms,
    },
  };
}

// =============================================================================
// Main
// =============================================================================

async function main(): Promise<void> {
  // Load and resolve config
  try {
    const configContent = await readFile(CONFIG_PATH, "utf-8");
    const rawConfig: Config = JSON.parse(configContent);
    config = await resolveConfig(rawConfig);
  } catch (err) {
    console.error("Failed to load config:", err);
    process.exit(1);
  }

  await log("INFO", "=".repeat(50));
  await log("INFO", "Vault Daemon starting...");
  await log("INFO", `Vault: ${config.vault_path}`);
  await log("INFO", `Claude: ${config.claude.command} ${config.claude.args.slice(0, 2).join(" ")}...`);
  await log("INFO", `Tasks enabled: ${config.tasks.enabled}`);
  await log("INFO", `@agent tags enabled: ${config.agent_tags.enabled}`);

  // Initialize state
  updateState({ status: "idle" });

  // Setup watchers
  if (config.tasks.enabled) {
    setupTaskWatcher();
  }

  if (config.agent_tags.enabled) {
    setupAgentTagWatcher();
  }

  await log("INFO", "Vault Daemon ready");

  // Keep process alive
  process.on("SIGINT", async () => {
    await log("INFO", "Shutting down...");
    updateState({ status: "paused" });

    // Kill any active processes
    for (const [name, proc] of activeProcesses) {
      await log("INFO", `Killing task: ${name}`);
      proc.kill();
    }

    process.exit(0);
  });

  process.on("SIGTERM", async () => {
    await log("INFO", "Received SIGTERM, shutting down...");
    updateState({ status: "paused" });
    process.exit(0);
  });
}

main();
