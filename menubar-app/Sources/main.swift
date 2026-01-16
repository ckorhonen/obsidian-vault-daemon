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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var setupWindowController: NSWindowController?

    // State
    private var daemonState: DaemonState?
    private var isDaemonRunning = false
    private var isConfigured = false

    // Paths
    private let configPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".vault-daemon-config.json")
    private let statePath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".vault-daemon-state.json")
    private let logPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/vault-daemon.log")
    private let launchAgentLabel = "com.vault-daemon"
    private let launchAgentPath: URL

    private var config: DaemonConfig?

    override init() {
        launchAgentPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Check if configured
        loadConfig()

        if !isConfigured {
            // Show setup on first run
            updateIcon(state: .setup)
            setupMenu()
            showSetupWindow()
        } else {
            // Normal operation
            updateIcon(state: .idle)
            setupMenu()
            loadState()
            checkDaemonStatus()

            // Start refresh timer
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.loadState()
                self?.checkDaemonStatus()
            }
        }
    }

    // MARK: - Configuration

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configPath),
              let loadedConfig = try? JSONDecoder().decode(DaemonConfig.self, from: data) else {
            isConfigured = false
            return
        }

        config = loadedConfig
        isConfigured = true
    }

    private func saveConfig(_ newConfig: DaemonConfig) {
        config = newConfig
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(newConfig) else { return }
        try? data.write(to: configPath)
        isConfigured = true
    }

    // MARK: - Setup Window

    private func showSetupWindow() {
        let setupView = SetupView(
            detectedVaults: detectVaults(),
            onComplete: { [weak self] vaultPath in
                self?.completeSetup(vaultPath: vaultPath)
            }
        )

        let hostingController = NSHostingController(rootView: setupView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Vault Daemon Setup"
        window.setContentSize(NSSize(width: 500, height: 400))
        window.styleMask = [.titled, .closable]
        window.center()

        setupWindowController = NSWindowController(window: window)
        setupWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func detectVaults() -> [DetectedVault] {
        var vaults: [DetectedVault] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Common vault locations
        let searchPaths = [
            "\(home)/Documents",
            "\(home)/Vault",
            "\(home)/Obsidian",
            "\(home)/Library/Mobile Documents/iCloud~md~obsidian/Documents",
            "\(home)/Desktop",
        ]

        for searchPath in searchPaths {
            guard let contents = try? fm.contentsOfDirectory(atPath: searchPath) else { continue }

            for item in contents {
                let itemPath = "\(searchPath)/\(item)"
                let obsidianPath = "\(itemPath)/.obsidian"

                // Check if this is a vault (has .obsidian folder)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: obsidianPath, isDirectory: &isDir), isDir.boolValue {
                    vaults.append(DetectedVault(
                        name: item,
                        path: itemPath
                    ))
                }
            }
        }

        // Also check if the search paths themselves are vaults
        for searchPath in searchPaths {
            let obsidianPath = "\(searchPath)/.obsidian"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: obsidianPath, isDirectory: &isDir), isDir.boolValue {
                let name = (searchPath as NSString).lastPathComponent
                if !vaults.contains(where: { $0.path == searchPath }) {
                    vaults.append(DetectedVault(name: name, path: searchPath))
                }
            }
        }

        return vaults
    }

    private func completeSetup(vaultPath: String) {
        setupWindowController?.close()
        setupWindowController = nil

        // Save config
        let newConfig = DaemonConfig(
            vault_path: vaultPath,
            log_path: logPath.path,
            log_max_size_mb: 1,
            state_path: statePath.path,
            tasks: TasksConfig(enabled: true, debounce_ms: 5000, max_concurrent: 2),
            agent_tags: AgentTagsConfig(
                enabled: true,
                scan_interval_ms: 180000,
                debounce_ms: 30000,
                ignore_patterns: ["Tasks/**", ".obsidian/**", "**/node_modules/**", "**/.git/**"]
            ),
            claude: ClaudeConfig(command: "auto", args: ["--dangerously-skip-permissions"], timeout_ms: 300000)
        )
        saveConfig(newConfig)

        // Create Tasks folders if they don't exist
        createTaskFolders(vaultPath: vaultPath)

        // Check for Bun and daemon
        if !checkPrerequisites() {
            showPrerequisitesAlert()
            return
        }

        // Install LaunchAgent
        installLaunchAgent(vaultPath: vaultPath)

        // Switch to normal operation
        isConfigured = true
        setupMenu()
        updateIcon(state: .idle)
        loadState()
        checkDaemonStatus()

        // Start refresh timer
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.loadState()
            self?.checkDaemonStatus()
        }
    }

    private func createTaskFolders(vaultPath: String) {
        let fm = FileManager.default
        let folders = ["Tasks/Inbox", "Tasks/In Progress", "Tasks/Blocked", "Tasks/Completed"]

        for folder in folders {
            let folderPath = "\(vaultPath)/\(folder)"
            try? fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }
    }

    private func checkPrerequisites() -> Bool {
        // Check for Bun
        let bunPaths = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "\(NSHomeDirectory())/.bun/bin/bun"
        ]

        for path in bunPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    private func showPrerequisitesAlert() {
        let alert = NSAlert()
        alert.messageText = "Prerequisites Missing"
        alert.informativeText = """
        Vault Daemon requires:

        1. Bun runtime - Install with:
           curl -fsSL https://bun.sh/install | bash

        2. Claude CLI - Install with:
           npm install -g @anthropic-ai/claude-code

        3. Clone the daemon repo:
           git clone https://github.com/ckorhonen/obsidian-vault-daemon.git
           cd obsidian-vault-daemon && bun install

        After installing, restart this app.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Installation Guide")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/ckorhonen/obsidian-vault-daemon#installation")!)
        }
        NSApplication.shared.terminate(nil)
    }

    private func findBunPath() -> String {
        let bunPaths = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "\(NSHomeDirectory())/.bun/bin/bun"
        ]

        for path in bunPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return "/opt/homebrew/bin/bun"
    }

    private func findDaemonPath() -> String? {
        // Check common locations for the daemon
        let possiblePaths = [
            "\(NSHomeDirectory())/Repos/obsidian-vault-daemon/daemon.ts",
            "\(NSHomeDirectory())/Developer/obsidian-vault-daemon/daemon.ts",
            "\(NSHomeDirectory())/Projects/obsidian-vault-daemon/daemon.ts",
            "/usr/local/share/obsidian-vault-daemon/daemon.ts",
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func installLaunchAgent(vaultPath: String) {
        guard let daemonPath = findDaemonPath() else {
            showDaemonNotFoundAlert()
            return
        }

        let daemonDir = (daemonPath as NSString).deletingLastPathComponent
        let bunPath = findBunPath()
        let home = NSHomeDirectory()

        // Also write config.json to daemon directory
        let daemonConfigPath = "\(daemonDir)/config.json"
        if let configData = try? JSONEncoder().encode(config) {
            try? configData.write(to: URL(fileURLWithPath: daemonConfigPath))
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(bunPath)</string>
                <string>run</string>
                <string>\(daemonPath)</string>
            </array>

            <key>WorkingDirectory</key>
            <string>\(vaultPath)</string>

            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/usr/local/bin:/usr/bin:/bin:\(home)/.bun/bin:/opt/homebrew/bin:\(home)/.local/bin</string>
                <key>HOME</key>
                <string>\(home)</string>
            </dict>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <true/>

            <key>StandardOutPath</key>
            <string>\(logPath.path)</string>

            <key>StandardErrorPath</key>
            <string>\(logPath.path)</string>

            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """

        // Ensure LaunchAgents directory exists
        let launchAgentsDir = (launchAgentPath.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Write plist
        try? plistContent.write(to: launchAgentPath, atomically: true, encoding: .utf8)

        // Unload if exists, then load
        let unloadTask = Process()
        unloadTask.launchPath = "/bin/launchctl"
        unloadTask.arguments = ["unload", launchAgentPath.path]
        try? unloadTask.run()
        unloadTask.waitUntilExit()

        let loadTask = Process()
        loadTask.launchPath = "/bin/launchctl"
        loadTask.arguments = ["load", launchAgentPath.path]
        try? loadTask.run()
        loadTask.waitUntilExit()
    }

    private func showDaemonNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "Daemon Not Found"
        alert.informativeText = """
        Could not find the vault daemon. Please clone it:

        git clone https://github.com/ckorhonen/obsidian-vault-daemon.git ~/Repos/obsidian-vault-daemon
        cd ~/Repos/obsidian-vault-daemon && bun install

        Then restart this app.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Icon States

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
            case .setup:
                icon = "◎"
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem(title: "Vault Daemon", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        if !isConfigured {
            // Setup mode menu
            let setupItem = NSMenuItem(title: "Setup Required...", action: #selector(openSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        } else {
            // Normal menu
            // Status line
            let statusMenuItem = NSMenuItem(title: "Status: checking...", action: nil, keyEquivalent: "")
            statusMenuItem.isEnabled = false
            statusMenuItem.tag = 100
            menu.addItem(statusMenuItem)

            // Vault path
            if let vaultPath = config?.vault_path {
                let vaultItem = NSMenuItem(title: "Vault: \((vaultPath as NSString).lastPathComponent)", action: nil, keyEquivalent: "")
                vaultItem.isEnabled = false
                menu.addItem(vaultItem)
            }

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

            // Open Vault
            let openVaultItem = NSMenuItem(title: "Open Vault...", action: #selector(openVault), keyEquivalent: "o")
            openVaultItem.target = self
            menu.addItem(openVaultItem)

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

            // Change Vault
            let changeVaultItem = NSMenuItem(title: "Change Vault...", action: #selector(changeVault), keyEquivalent: "")
            changeVaultItem.target = self
            menu.addItem(changeVaultItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - State Management

    private func loadState() {
        guard let data = try? Data(contentsOf: statePath),
              let state = try? JSONDecoder().decode(DaemonState.self, from: data) else {
            return
        }

        daemonState = state
        updateMenuState()

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

    private func updateMenuState() {
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
            updateMenuState()
        } catch {
            isDaemonRunning = false
        }
    }

    // MARK: - Actions

    @objc private func openSetup() {
        showSetupWindow()
    }

    @objc private func viewLogs() {
        NSWorkspace.shared.open(logPath)
    }

    @objc private func viewTasks() {
        guard let vaultPath = config?.vault_path else { return }
        let tasksPath = URL(fileURLWithPath: vaultPath).appendingPathComponent("Tasks")
        NSWorkspace.shared.open(tasksPath)
    }

    @objc private func openVault() {
        guard let vaultPath = config?.vault_path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: vaultPath))
    }

    @objc private func forceScan() {
        // Write a trigger file that the daemon watches
        let triggerPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vault-daemon-trigger")
        try? "scan".write(to: triggerPath, atomically: true, encoding: .utf8)

        // Show confirmation
        let alert = NSAlert()
        alert.messageText = "Scan Triggered"
        alert.informativeText = "The daemon will scan for @agent tags momentarily."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func togglePause() {
        let task = Process()
        task.launchPath = "/bin/launchctl"

        if isDaemonRunning {
            task.arguments = ["unload", launchAgentPath.path]
        } else {
            task.arguments = ["load", launchAgentPath.path]
        }

        do {
            try task.run()
            task.waitUntilExit()

            isDaemonRunning = !isDaemonRunning
            updateIcon(state: isDaemonRunning ? .idle : .paused)
            updateMenuState()
        } catch {
            NSLog("Vault Daemon: Failed to \(isDaemonRunning ? "pause" : "resume") daemon")
        }
    }

    @objc private func changeVault() {
        isConfigured = false
        showSetupWindow()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Setup View

struct SetupView: View {
    let detectedVaults: [DetectedVault]
    let onComplete: (String) -> Void

    @State private var selectedVault: DetectedVault?
    @State private var customPath: String = ""
    @State private var useCustomPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Vault Daemon")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Select your Obsidian vault to enable AI-powered task automation.")
                    .foregroundColor(.secondary)
            }

            Divider()

            // Detected vaults
            if !detectedVaults.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Detected Vaults")
                        .font(.headline)

                    ForEach(detectedVaults, id: \.path) { vault in
                        HStack {
                            Image(systemName: selectedVault?.path == vault.path && !useCustomPath ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedVault?.path == vault.path && !useCustomPath ? .accentColor : .secondary)

                            VStack(alignment: .leading) {
                                Text(vault.name)
                                    .fontWeight(.medium)
                                Text(vault.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(8)
                        .background(selectedVault?.path == vault.path && !useCustomPath ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedVault = vault
                            useCustomPath = false
                        }
                    }
                }
            }

            // Custom path option
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: useCustomPath ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(useCustomPath ? .accentColor : .secondary)

                    Text("Choose a different folder...")
                        .fontWeight(.medium)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    useCustomPath = true
                    selectCustomFolder()
                }

                if useCustomPath && !customPath.isEmpty {
                    Text(customPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)
                }
            }

            Spacer()

            // Action buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    let path = useCustomPath ? customPath : (selectedVault?.path ?? "")
                    if !path.isEmpty {
                        onComplete(path)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(useCustomPath ? customPath.isEmpty : selectedVault == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // Auto-select first vault
            if let first = detectedVaults.first {
                selectedVault = first
            }
        }
    }

    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select Vault"

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }
}

// MARK: - Models

enum IconState {
    case idle
    case working
    case blocked
    case paused
    case error
    case setup
}

struct DetectedVault: Identifiable {
    let id = UUID()
    let name: String
    let path: String
}

struct DaemonState: Codable {
    let status: String
    let active_tasks: Int
    let last_scan: String?
    let last_error: String?
    let tasks_completed_today: Int
    let agent_commands_today: Int
}

struct DaemonConfig: Codable {
    let vault_path: String
    let log_path: String
    let log_max_size_mb: Int
    let state_path: String
    let tasks: TasksConfig
    let agent_tags: AgentTagsConfig
    let claude: ClaudeConfig
}

struct TasksConfig: Codable {
    let enabled: Bool
    let debounce_ms: Int
    let max_concurrent: Int
}

struct AgentTagsConfig: Codable {
    let enabled: Bool
    let scan_interval_ms: Int
    let debounce_ms: Int
    let ignore_patterns: [String]
}

struct ClaudeConfig: Codable {
    let command: String
    let args: [String]
    let timeout_ms: Int
}
