import SwiftUI
import MarkdownView

// MARK: - Channel Markdown View

/// Renders channel message content with mention highlighting and full markdown.
/// All messages go through MarkdownView — simple, consistent, no branching.
///
/// Mention formats from the server:
/// - `<@U:userId|DisplayName>` → Bold @DisplayName
/// - `<@M:modelId|ModelName>` → Bold ⚡ @ModelName
struct ChannelMarkdownView: View {
    let content: String
    let currentUserId: String?
    let isCurrentUser: Bool
    /// Set of channel IDs the current user has access to.
    /// Used to render inaccessible channels as #Unknown.
    let accessibleChannelIds: Set<String>
    
    @Environment(\.theme) private var theme
    
    init(content: String, currentUserId: String? = nil, isCurrentUser: Bool = false, accessibleChannelIds: Set<String> = []) {
        self.content = content
        self.currentUserId = currentUserId
        self.isCurrentUser = isCurrentUser
        self.accessibleChannelIds = accessibleChannelIds
    }
    
    /// Quick check: does this content need markdown rendering?
    /// Only matches actual markdown syntax, not emoji variation selectors (which contain * in surrogate pairs).
    private var needsMarkdown: Bool {
        let clean = ChannelMessage.parseMentions(in: content)
        // Check for multi-char patterns first (more specific)
        let blockPatterns = ["```", "**", "__", "~~", "- ", "1. ", "> ", "# ", "## ", "### ", "---", "***", "| "]
        for p in blockPatterns {
            if clean.contains(p) { return true }
        }
        // Single backtick (inline code) — but not emoji variation selectors
        if clean.contains("`") { return true }
        // Single [ for links
        if clean.contains("[") && clean.contains("](") { return true }
        return false
    }
    
    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if needsMarkdown || content.contains("<@") || content.contains("<#") {
            // Rich content or mentions → full markdown rendering
            StreamingMarkdownView(
                content: preprocessMentions(content),
                isStreaming: false,
                textColor: isCurrentUser ? theme.brandOnPrimary : nil
            )
        } else {
            // Plain text → native Text view (self-sizes to content width)
            Text(content)
                .scaledFont(size: 15)
                .foregroundStyle(isCurrentUser ? theme.brandOnPrimary : theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    /// Converts mention tags and channel link tags to markdown text.
    /// `<@U:id|name>` → `**@name**`
    /// `<@M:id|name>` → `**⚡ @name**`
    /// `<#C:channelId|channelName>` → tappable `[**#channelName**](openui-channel://channelId)`
    private func preprocessMentions(_ text: String) -> String {
        var result = text
        
        // Process @mentions: <@U:id|name> and <@M:id|name>
        if result.contains("<@") {
            let mentionPattern = #"<@([UM]):([^|>]+)\|([^>]+)>"#
            if let regex = try? NSRegularExpression(pattern: mentionPattern) {
                let nsText = result as NSString
                for match in regex.matches(in: result, range: NSRange(location: 0, length: nsText.length)).reversed() {
                    let type = nsText.substring(with: match.range(at: 1))
                    let name = nsText.substring(with: match.range(at: 3))
                    let replacement = type == "M" ? "**⚡ @\(name)**" : "**@\(name)**"
                    if let matchRange = Range(match.range, in: result) {
                        result.replaceSubrange(matchRange, with: replacement)
                    }
                }
            }
        }
        
        // Process #channel links: <#C:channelId|channelName> (with optional C: for legacy compat)
        // Accessible channels → tappable markdown link: [**#name**](openui-channel://id)
        // Inaccessible channels → non-tappable: **#Unknown**
        if result.contains("<#") {
            let channelPattern = #"<#(?:C:)?([^|>]+)\|([^>]+)>"#
            if let regex = try? NSRegularExpression(pattern: channelPattern) {
                let nsText = result as NSString
                for match in regex.matches(in: result, range: NSRange(location: 0, length: nsText.length)).reversed() {
                    let channelId = nsText.substring(with: match.range(at: 1))
                    let channelName = nsText.substring(with: match.range(at: 2))
                    let replacement: String
                    if accessibleChannelIds.isEmpty || accessibleChannelIds.contains(channelId) {
                        // Tappable link — MarkdownView renders [text](url) as a link
                        replacement = "[**#\(channelName)**](openui-channel://\(channelId))"
                    } else {
                        // No access — show #Unknown (non-tappable)
                        replacement = "**#Unknown**"
                    }
                    if let matchRange = Range(match.range, in: result) {
                        result.replaceSubrange(matchRange, with: replacement)
                    }
                }
            }
        }
        
        return result
    }
}

// MARK: - Channel Reply Preview

struct ChannelReplyPreview: View {
    let senderName: String
    let content: String
    let isModel: Bool
    
    @Environment(\.theme) private var theme
    
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isModel ? theme.mentionModelText : theme.replyBorder)
                .frame(width: 3)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    if isModel {
                        Image(systemName: "cpu")
                            .scaledFont(size: 9)
                            .foregroundStyle(theme.mentionModelText)
                    }
                    Text(senderName)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(isModel ? theme.mentionModelText : theme.replyBorder)
                }
                
                Text(ChannelMessage.parseMentions(in: content).prefix(80))
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.replyText)
                    .lineLimit(2)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.replyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Channel File Card

struct ChannelFileCard: View {
    let name: String
    let contentType: String?
    let onTap: (() -> Void)?
    
    @Environment(\.theme) private var theme
    
    private var fileIcon: String {
        guard let ct = contentType?.lowercased() else { return "doc" }
        if ct.contains("pdf") { return "doc.text" }
        if ct.contains("spreadsheet") || ct.contains("csv") || ct.contains("excel") { return "tablecells" }
        if ct.contains("presentation") || ct.contains("powerpoint") { return "rectangle.stack" }
        if ct.contains("text") || ct.contains("plain") { return "doc.plaintext" }
        if ct.contains("zip") || ct.contains("archive") { return "doc.zipper" }
        if ct.contains("video") { return "film" }
        if ct.contains("audio") { return "waveform" }
        return "doc"
    }
    
    private var fileExtension: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
    
    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: fileIcon)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.fileCardText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileExtension)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                
                Spacer(minLength: 0)
                
                Image(systemName: "arrow.down.circle")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.fileCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.fileCardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Channel Image Grid

struct ChannelImageGrid: View {
    let imageFiles: [ChatMessageFile]
    let apiClient: APIClient?
    
    var body: some View {
        let count = min(imageFiles.count, 4)
        
        switch count {
        case 1:
            if let fileId = imageFiles[0].url, !fileId.isEmpty {
                AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case 2:
            HStack(spacing: 3) {
                ForEach(Array(imageFiles.prefix(2).enumerated()), id: \.offset) { _, file in
                    if let fileId = file.url, !fileId.isEmpty {
                        AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                            .frame(maxWidth: 140, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        default:
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 3),
                GridItem(.flexible(), spacing: 3)
            ], spacing: 3) {
                ForEach(Array(imageFiles.prefix(4).enumerated()), id: \.offset) { index, file in
                    if let fileId = file.url, !fileId.isEmpty {
                        AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                            .frame(maxHeight: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if index == 3 && imageFiles.count > 4 {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.black.opacity(0.5))
                                    Text("+\(imageFiles.count - 4)")
                                        .scaledFont(size: 18, weight: .bold)
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: 280)
        }
    }
}

// MARK: - Thread Reply Count Badge

struct ThreadReplyBadge: View {
    let replyCount: Int
    let latestReplyAt: Date?
    let onTap: () -> Void
    
    @Environment(\.theme) private var theme
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .scaledFont(size: 11, weight: .medium)
                Text("\(replyCount) Repl\(replyCount == 1 ? "y" : "ies")")
                    .scaledFont(size: 12, weight: .semibold)
                if let date = latestReplyAt {
                    Text("·")
                        .scaledFont(size: 10)
                        .foregroundStyle(theme.textTertiary)
                    Text("Last reply \(date.chatTimestamp)")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .foregroundStyle(theme.brandPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.brandPrimary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
