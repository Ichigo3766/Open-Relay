import Foundation

// MARK: - Terminal Server

/// Represents a terminal server available to the user.
///
/// Open Terminal is a separate service (typically a Docker container) that
/// provides shell access, file management, and command execution to AI models.
/// When connected to Open WebUI, the model can run commands, manage files,
/// and interact with a real operating system environment.
struct TerminalServer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    /// Display name — falls back to ID if name is empty.
    var displayName: String {
        name.isEmpty ? id : name
    }
}

// MARK: - Terminal Config

/// Response from `GET /api/v1/terminals/{server_id}/api/config`.
/// Indicates which features the terminal server supports.
struct TerminalConfig: Sendable {
    let terminal: Bool
    let notebooks: Bool

    init(from json: [String: Any]) {
        let features = json["features"] as? [String: Any] ?? [:]
        terminal = features["terminal"] as? Bool ?? false
        notebooks = features["notebooks"] as? Bool ?? false
    }
}

// MARK: - Terminal File Item

/// Represents a file or directory in the terminal's filesystem.
struct TerminalFileItem: Identifiable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let permissions: String?

    var id: String { path }

    /// File extension (lowercased) for icon resolution.
    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Human-readable file size.
    var formattedSize: String? {
        guard let size, !isDirectory else { return nil }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        if size < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(size) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(size) / (1024 * 1024 * 1024))
    }

    /// SF Symbol name for this file type.
    var iconName: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension {
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "HTML", "css", "scss": return "globe"
        case "json", "yaml", "yml", "xml", "toml": return "curlybraces"
        case "md", "txt", "rtf", "log": return "doc.plaintext"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return "photo"
        case "mp3", "wav", "m4a", "flac", "ogg": return "waveform"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "zip", "tar", "gz", "rar", "7z", "bz2", "xz": return "archivebox"
        case "sh", "bash", "zsh": return "terminal"
        case "dockerfile": return "shippingbox"
        case "gitignore", "env": return "gearshape"
        default: return "doc"
        }
    }

    /// Parses a file item from the terminal server's JSON response.
    init(from json: [String: Any], basePath: String) {
        let rawName = json["name"] as? String ?? ""
        name = rawName
        let typeStr = json["type"] as? String
        isDirectory = json["is_dir"] as? Bool ?? json["isDir"] as? Bool ?? (typeStr == "directory")
        size = json["size"] as? Int64 ?? (json["size"] as? Int).map { Int64($0) }
        permissions = json["permissions"] as? String

        // Build full path
        let base = basePath.hasSuffix("/") ? basePath : basePath + "/"
        path = base + rawName

        // Parse modified date
        if let ts = json["modified"] as? Double {
            modified = Date(timeIntervalSince1970: ts)
        } else if let ts = json["modified"] as? Int {
            modified = Date(timeIntervalSince1970: Double(ts))
        } else if let dateStr = json["modified"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            modified = formatter.date(from: dateStr)
        } else {
            modified = nil
        }
    }

    /// Manual initializer for previews/testing.
    init(name: String, path: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil, permissions: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

// MARK: - Terminal Command Result

/// Result of executing a command on the terminal server.
struct TerminalCommandResult: Sendable {
    let id: String
    let command: String
    let output: String
    let exitCode: Int?
    let isRunning: Bool
    /// The next offset to pass for incremental output polling.
    let nextOffset: Int

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        command = json["command"] as? String ?? ""
        exitCode = json["exit_code"] as? Int ?? json["exitCode"] as? Int
        isRunning = json["status"] as? String == "running"
            || json["is_running"] as? Bool == true
        nextOffset = json["next_offset"] as? Int ?? 0

        // The Open Terminal API returns `output` as an array of
        // {type: "stdout"|"stderr"|"output", data: "..."} objects.
        // Join all `data` fields into a single string for display.
        if let outputArray = json["output"] as? [[String: Any]] {
            output = outputArray.compactMap { $0["data"] as? String }.joined()
        } else if let outputStr = json["output"] as? String {
            // Fallback for any server that returns a plain string
            output = outputStr
        } else {
            output = ""
        }
    }
}
