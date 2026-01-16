import SwiftUI
import AppKit

@main
struct VaultDaemonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?

    // State
    private var daemonState: DaemonState?
    private var isDaemonRunning = false

    // Paths - resolved dynamically from state file or defaults
    private let statePath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".vault-daemon-state.json")
    private let logPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/vault-daemon.log")
    private let launchAgentLabel = "com.vault-daemon"

    // Tasks path discovered from state or fallback
    private var tasksPath: URL {
        // Try to read vault path from a companion config file
        let configPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vault-daemon-config.json")
        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(SimpleConfig.self, from: data) {
            return URL(fileURLWithPath: config.vault_path).appendingPathComponent("Tasks")
        }
        // Fallback: try common locations
        let possiblePaths = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Vault/Vault/Tasks"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Vault/Tasks"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Obsidian/Tasks"),
        ]
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return possiblePaths[0]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set initial icon
        updateIcon(state: .idle)

        // Build menu
        setupMenu()

        // Load initial state
        loadState()

        // Check if daemon is running
        checkDaemonStatus()

        // Start refresh timer (check state every 5 seconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.loadState()
            self?.checkDaemonStatus()
        }
    }

    private func updateIcon(state: IconState) {
        if let button = statusItem.button {
            let icon: String
            switch state {
            case .idle:
                icon = "◉"
            case .working:
                icon = "◐"
            case .blocked:
                icon = "◍"
            case .paused:
                icon = "◯"
            case .error:
                icon = "◉!"
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem(title: "Vault Daemon", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Status line
        let statusItem = NSMenuItem(title: "Status: checking...", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 100
        menu.addItem(statusItem)

        // Active tasks
        let tasksItem = NSMenuItem(title: "Active: 0", action: nil, keyEquivalent: "")
        tasksItem.isEnabled = false
        tasksItem.tag = 101
        menu.addItem(tasksItem)

        // Today stats
        let statsItem = NSMenuItem(title: "Today: 0 tasks, 0 @agent", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        statsItem.tag = 102
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        // View Logs
        let viewLogsItem = NSMenuItem(title: "View Logs...", action: #selector(viewLogs), keyEquivalent: "l")
        viewLogsItem.target = self
        menu.addItem(viewLogsItem)

        // View Tasks Folder
        let viewTasksItem = NSMenuItem(title: "View Tasks Folder...", action: #selector(viewTasks), keyEquivalent: "t")
        viewTasksItem.target = self
        menu.addItem(viewTasksItem)

        menu.addItem(NSMenuItem.separator())

        // Force Scan
        let scanItem = NSMenuItem(title: "Force @agent Scan", action: #selector(forceScan), keyEquivalent: "s")
        scanItem.target = self
        scanItem.tag = 103
        menu.addItem(scanItem)

        menu.addItem(NSMenuItem.separator())

        // Pause/Resume
        let pauseItem = NSMenuItem(title: "Pause Daemon", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.tag = 104
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Menubar App", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: statePath),
              let state = try? JSONDecoder().decode(DaemonState.self, from: data) else {
            return
        }

        daemonState = state
        updateMenu()

        // Update icon based on state
        if !isDaemonRunning {
            updateIcon(state: .paused)
        } else {
            switch state.status {
            case "idle":
                updateIcon(state: .idle)
            case "working":
                updateIcon(state: .working)
            case "blocked":
                updateIcon(state: .blocked)
            case "error":
                updateIcon(state: .error)
            case "paused":
                updateIcon(state: .paused)
            default:
                updateIcon(state: .idle)
            }
        }
    }

    private func updateMenu() {
        guard let menu = statusItem.menu, let state = daemonState else { return }

        // Update status
        if let item = menu.item(withTag: 100) {
            let statusText = isDaemonRunning ? state.status.capitalized : "Stopped"
            item.title = "Status: \(statusText)"
        }

        // Update active tasks
        if let item = menu.item(withTag: 101) {
            item.title = "Active: \(state.active_tasks)"
        }

        // Update today stats
        if let item = menu.item(withTag: 102) {
            item.title = "Today: \(state.tasks_completed_today) tasks, \(state.agent_commands_today) @agent"
        }

        // Update pause item
        if let item = menu.item(withTag: 104) {
            item.title = isDaemonRunning ? "Pause Daemon" : "Resume Daemon"
        }
    }

    private func checkDaemonStatus() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", launchAgentLabel]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            isDaemonRunning = task.terminationStatus == 0
            updateMenu()
        } catch {
            isDaemonRunning = false
        }
    }

    @objc private func viewLogs() {
        NSWorkspace.shared.open(logPath)
    }

    @objc private func viewTasks() {
        NSWorkspace.shared.open(tasksPath)
    }

    @objc private func forceScan() {
        // Write a trigger file that the daemon can watch for
        // For now, just show a notification that manual triggering requires daemon restart
        let alert = NSAlert()
        alert.messageText = "Force Scan"
        alert.informativeText = "The daemon will scan for @agent tags on its next interval. To force immediate scan, restart the daemon."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func togglePause() {
        let task = Process()
        task.launchPath = "/bin/launchctl"

        let plistPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")

        if isDaemonRunning {
            task.arguments = ["unload", plistPath.path]
        } else {
            task.arguments = ["load", plistPath.path]
        }

        do {
            try task.run()
            task.waitUntilExit()

            isDaemonRunning = !isDaemonRunning
            updateIcon(state: isDaemonRunning ? .idle : .paused)
            updateMenu()
        } catch {
            NSLog("Vault Daemon: Failed to \(isDaemonRunning ? "pause" : "resume") daemon")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

enum IconState {
    case idle
    case working
    case blocked
    case paused
    case error
}

struct DaemonState: Codable {
    let status: String
    let active_tasks: Int
    let last_scan: String?
    let last_error: String?
    let tasks_completed_today: Int
    let agent_commands_today: Int
}

struct SimpleConfig: Codable {
    let vault_path: String
}
