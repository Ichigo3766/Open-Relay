import SwiftUI

// MARK: - Context Menu Actions

/// A context menu builder that provides themed, consistent menu items
/// for common actions throughout the app.
///
/// Usage:
/// ```swift
/// Text("Hello")
///     .contextMenu {
///         ConversationContextMenu(
///             onRename: { },
///             onPin: { },
///             onShare: { },
///             onDelete: { }
///         )
///     }
/// ```
struct ConversationContextMenu: View {
    var onRename: (() -> Void)?
    var onPin: (() -> Void)?
    var isPinned: Bool = false
    var onArchive: (() -> Void)?
    var onShare: (() -> Void)?
    var onUnshare: (() -> Void)?
    var isShared: Bool = false
    var onDelete: (() -> Void)?

    // Folder support
    /// Available folders to move the conversation into.
    var folders: [ChatFolder] = []
    /// The folder the conversation currently belongs to (nil = no folder).
    var currentFolderId: String?
    /// Called with the target folder ID (nil = remove from folder).
    var onMoveToFolder: ((String?) -> Void)?

    var body: some View {
        Group {
            if let onRename {
                Button {
                    Haptics.play(.light)
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            if let onPin {
                Button {
                    Haptics.play(.light)
                    onPin()
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
            }

            if let onArchive {
                Button {
                    Haptics.play(.light)
                    onArchive()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }

            // Move to Folder submenu — only shown when folders exist
            if let onMoveToFolder, !folders.isEmpty {
                Menu {
                    // Option to remove from current folder
                    if currentFolderId != nil {
                        Button {
                            Haptics.play(.light)
                            onMoveToFolder(nil)
                        } label: {
                            Label(
                                String(localized: "Remove from Folder"),
                                systemImage: "folder.badge.minus"
                            )
                        }
                        Divider()
                    }

                    // Each available folder
                    ForEach(folders) { folder in
                        Button {
                            Haptics.play(.light)
                            onMoveToFolder(folder.id)
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                if folder.id == currentFolderId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(folder.id == currentFolderId)
                    }
                } label: {
                    Label(
                        String(localized: "Move to Folder"),
                        systemImage: "folder.badge.plus"
                    )
                }
            }

            if isShared, let onUnshare {
                Button {
                    Haptics.play(.light)
                    onUnshare()
                } label: {
                    Label("Unshare", systemImage: "link.badge.plus")
                }
            }

            if let onShare {
                Button {
                    Haptics.play(.light)
                    onShare()
                } label: {
                    Label(isShared ? "Copy Share Link" : "Share", systemImage: "square.and.arrow.up")
                }
            }

            if let onDelete {
                Divider()
                Button(role: .destructive) {
                    Haptics.notify(.warning)
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Message Context Menu

/// Context menu for individual chat messages.
struct MessageContextMenu: View {
    var onCopy: (() -> Void)?
    var onReply: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onShare: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        Group {
            if let onCopy {
                Button {
                    Haptics.notify(.success)
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if let onReply {
                Button {
                    Haptics.play(.light)
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }

            if let onEdit {
                Button {
                    Haptics.play(.light)
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            if let onRegenerate {
                Button {
                    Haptics.play(.medium)
                    onRegenerate()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
            }

            if let onShare {
                Button {
                    Haptics.play(.light)
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if let onDelete {
                Divider()
                Button(role: .destructive) {
                    Haptics.notify(.warning)
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Model Selector Menu

/// A menu for selecting an AI model.
struct ModelSelectorMenu<Label: View>: View {
    let models: [ModelMenuItem]
    let selectedModelId: String?
    let onSelect: (String) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(models) { model in
                Button {
                    onSelect(model.id)
                } label: {
                    HStack {
                        Text(model.name)
                        if model.id == selectedModelId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            label()
        }
    }
}

/// A model item for use in the model selector menu.
struct ModelMenuItem: Identifiable {
    let id: String
    let name: String
    var description: String? = nil
}

// MARK: - Confirmation Dialog Helper

/// A view modifier that presents a themed destructive confirmation dialog.
struct DestructiveConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let destructiveTitle: String
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
                Button(destructiveTitle, role: .destructive, action: onConfirm)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(message))
            }
    }
}

extension View {
    /// Presents a destructive confirmation dialog.
    func destructiveConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        destructiveTitle: String = "Delete",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DestructiveConfirmation(
            isPresented: isPresented,
            title: title,
            message: message,
            destructiveTitle: destructiveTitle,
            onConfirm: onConfirm
        ))
    }
}

// MARK: - Preview

#Preview("Context Menus") {
    List {
        ForEach(1...5, id: \.self) { i in
            Text("Conversation \(i)")
                .contextMenu {
                    ConversationContextMenu(
                        onRename: {},
                        onPin: {},
                        isPinned: i == 1,
                        onShare: {},
                        onDelete: {}
                    )
                }
        }
    }
    .themed()
}
