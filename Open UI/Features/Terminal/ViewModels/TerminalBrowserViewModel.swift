import Foundation
import os.log

/// Manages the state for the terminal file browser panel.
///
/// Handles directory navigation, file operations (create, delete, upload, download),
/// and command execution on the terminal server. All operations are proxied through
/// the Open WebUI backend.
@MainActor @Observable
final class TerminalBrowserViewModel {
    // MARK: - State

    /// Current directory path being viewed.
    var currentPath: String = "/home/user"
    /// Files and folders in the current directory.
    var items: [TerminalFileItem] = []
    /// Whether we're loading directory contents.
    var isLoading: Bool = false
    /// Error message to display.
    var errorMessage: String?
    /// Navigation history for back navigation.
    var pathHistory: [String] = []

    // MARK: - Command Runner State

    /// Current command input text.
    var commandInput: String = ""
    /// Command output history (prompt + output pairs).
    var commandHistory: [CommandEntry] = []
    /// Whether a command is currently executing.
    var isExecutingCommand: Bool = false
    /// Whether the terminal section is expanded.
    var isTerminalExpanded: Bool = false

    // MARK: - Action State

    /// Whether the new folder alert is showing.
    var showNewFolderAlert: Bool = false
    /// New folder name input.
    var newFolderName: String = ""
    /// File being renamed (nil = not renaming).
    var renamingFile: TerminalFileItem?
    /// New name for the file being renamed.
    var renameText: String = ""

    // MARK: - Private

    private var apiClient: APIClient?
    private var serverId: String = ""
    private let logger = Logger(subsystem: "com.openui", category: "TerminalBrowser")

    /// Path segments for breadcrumb navigation.
    var pathSegments: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var segments: [(name: String, path: String)] = [("/", "/")]
        var accumulated = ""
        for component in components {
            accumulated += "/\(component)"
            segments.append((component, accumulated))
        }
        return segments
    }

    /// Sorted items: directories first, then files, both alphabetically.
    var sortedItems: [TerminalFileItem] {
        let dirs = items.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs + files
    }

    // MARK: - Setup

    func configure(apiClient: APIClient, serverId: String) {
        self.apiClient = apiClient
        self.serverId = serverId
    }

    /// Resets all state to defaults. Called when switching to a new chat
    /// so the file browser starts fresh.
    func reset() {
        currentPath = "/home/user"
        items = []
        isLoading = false
        errorMessage = nil
        pathHistory = []
        commandInput = ""
        commandHistory = []
        isExecutingCommand = false
        isTerminalExpanded = false
        showNewFolderAlert = false
        newFolderName = ""
        renamingFile = nil
        renameText = ""
    }

    // MARK: - Navigation

    /// Loads the contents of the current directory.
    func loadDirectory() async {
        guard let apiClient, !serverId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await apiClient.terminalListFiles(serverId: serverId, path: currentPath)
        } catch {
            logger.error("Failed to list files at \(self.currentPath): \(error.localizedDescription)")
            errorMessage = "Failed to load directory: \(error.localizedDescription)"
            items = []
        }
        isLoading = false
    }

    /// Navigates into a directory.
    func navigateToDirectory(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    /// Navigates to a specific path segment (breadcrumb tap).
    func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    /// Navigates back to the previous directory.
    func navigateBack() {
        guard let previous = pathHistory.popLast() else { return }
        currentPath = previous
        Task { await loadDirectory() }
    }

    /// Refreshes the current directory.
    func refresh() {
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    /// Creates a new folder in the current directory.
    func createFolder(name: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let folderPath = currentPath.hasSuffix("/")
            ? "\(currentPath)\(name)"
            : "\(currentPath)/\(name)"
        do {
            try await apiClient.terminalMkdir(serverId: serverId, path: folderPath)
            await loadDirectory()
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }

    /// Deletes a file or directory.
    func deleteItem(_ item: TerminalFileItem) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalDeleteFile(serverId: serverId, path: item.path)
            // Remove from local list immediately for snappy feel
            items.removeAll { $0.path == item.path }
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
            await loadDirectory() // Refresh to get accurate state
        }
    }

    /// Downloads a file and returns the local URL for sharing/preview.
    func downloadFile(_ item: TerminalFileItem) async -> URL? {
        guard let apiClient, !serverId.isEmpty else { return nil }
        do {
            let (data, _) = try await apiClient.terminalDownloadFile(serverId: serverId, path: item.path)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("terminal_downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent(item.name)
            try data.write(to: fileURL)
            return fileURL
        } catch {
            errorMessage = "Failed to download: \(error.localizedDescription)"
            return nil
        }
    }

    /// Uploads a file to the current directory.
    func uploadFile(data: Data, fileName: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalUploadFile(
                serverId: serverId,
                fileData: data,
                fileName: fileName,
                destinationPath: currentPath
            )
            await loadDirectory()
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Command Execution

    /// Executes a command on the terminal server.
    ///
    /// Uses the Open Terminal API's `wait` parameter for synchronous execution
    /// of short commands, and offset-based polling for long-running commands.
    func executeCommand(_ command: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        commandInput = ""
        isExecutingCommand = true

        let entry = CommandEntry(command: trimmed, output: "", isRunning: true)
        commandHistory.append(entry)
        let entryIndex = commandHistory.count - 1

        do {
            // Execute with wait=10 — short commands will complete inline
            let result = try await apiClient.terminalExecute(
                serverId: serverId, command: trimmed, cwd: currentPath
            )

            // Update output from the initial response
            commandHistory[entryIndex].output = result.output

            if result.isRunning {
                // Long-running command — poll with offset-based incremental reads
                var currentOffset = result.nextOffset
                var attempts = 0
                while attempts < 30 { // Max ~150 seconds (30 × 5s wait)
                    let status = try await apiClient.terminalGetCommandStatus(
                        serverId: serverId,
                        processId: result.id,
                        offset: currentOffset
                    )
                    // Append only new output (offset-based, no duplication)
                    if !status.output.isEmpty {
                        commandHistory[entryIndex].output += status.output
                    }
                    currentOffset = status.nextOffset

                    if !status.isRunning {
                        commandHistory[entryIndex].isRunning = false
                        commandHistory[entryIndex].exitCode = status.exitCode
                        break
                    }
                    attempts += 1
                }
                if attempts >= 30 {
                    commandHistory[entryIndex].output += "\n[Timed out after ~150s]"
                    commandHistory[entryIndex].isRunning = false
                }
            } else {
                // Command already finished — update final state
                commandHistory[entryIndex].isRunning = false
                commandHistory[entryIndex].exitCode = result.exitCode
            }

            // If the command was a cd, update the current path
            if trimmed.hasPrefix("cd ") {
                let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !target.isEmpty {
                    // Re-fetch current directory to pick up the changed path
                    await loadDirectory()
                }
            }
        } catch {
            commandHistory[entryIndex].output = "Error: \(error.localizedDescription)"
            commandHistory[entryIndex].isRunning = false
        }

        isExecutingCommand = false
    }
}

// MARK: - Command Entry

/// A single command + output pair in the terminal history.
struct CommandEntry: Identifiable {
    let id = UUID()
    let command: String
    var output: String
    var isRunning: Bool
    var exitCode: Int?
}
