import SwiftUI

// MARK: - Tool Approval Banner
//
// Shown above the chat input when a tool call is waiting for user approval.
// Mirrors the web client's approve/deny buttons on a pending tool_call output item.
//
// Layout:
//   ┌──────────────────────────────────────────────────────────┐
//   │  🔧 search_web   { "query": "Swift concurrency..." }     │
//   │       [Deny]                               [Allow] ↩    │
//   └──────────────────────────────────────────────────────────┘

struct ToolApprovalBanner: View {
    // MARK: - Inputs

    /// The function name being called, e.g. `"search_web"`.
    let toolName: String
    /// Raw JSON arguments string.
    let arguments: String

    /// Whether a resolve call is in-flight (shows spinner, disables buttons).
    var isResolving: Bool = false

    var onApprove: () -> Void
    var onDeny: () -> Void

    // MARK: - Environment

    @Environment(\.theme) private var theme

    // MARK: - Argument preview

    private var argumentPreview: String {
        let cleaned = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !obj.isEmpty {
            let pairs = obj
                .sorted(by: { $0.key < $1.key })
                .prefix(3)
                .map { k, v -> String in
                    let vStr: String
                    if let s = v as? String { vStr = s }
                    else if let n = v as? NSNumber { vStr = n.stringValue }
                    else { vStr = String(describing: v) }
                    let t = vStr.count > 50 ? String(vStr.prefix(50)) + "…" : vStr
                    return "\(k): \(t)"
                }
                .joined(separator: "  ·  ")
            return pairs
        }
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top separator
            Rectangle()
                .fill(theme.inputBorder)
                .frame(height: 0.5)

            HStack(alignment: .center, spacing: 10) {
                // Tool icon + name + arguments
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.accentColor)

                        Text(toolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                    }

                    if !argumentPreview.isEmpty {
                        Text(argumentPreview)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Action buttons
                if isResolving {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(theme.accentColor)
                } else {
                    HStack(spacing: 8) {
                        // Deny button
                        Button(action: onDeny) {
                            Text("Deny")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(theme.inputBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .accessibilityLabel("Deny tool call")

                        // Allow button
                        Button(action: onApprove) {
                            HStack(spacing: 4) {
                                Text("Allow")
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "return")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(theme.buttonPrimaryText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.buttonPrimary)
                            )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("Allow tool call")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.inputBackground)
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isResolving)
    }
}
