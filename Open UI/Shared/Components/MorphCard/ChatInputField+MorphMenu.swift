import SwiftUI

// MARK: - Composer Morph Card (menu wiring)

extension ChatInputField {
    func toolsMenu(revealed: Bool) -> some View {
        ToolsMenuSheet(
            webSearchEnabled: $webSearchEnabled,
            imageGenerationEnabled: $imageGenerationEnabled,
            codeInterpreterEnabled: $codeInterpreterEnabled,
            isWebSearchAvailable: isWebSearchAvailable,
            isImageGenerationAvailable: isImageGenerationAvailable,
            isCodeInterpreterAvailable: isCodeInterpreterAvailable,
            tools: tools,
            selectedToolIds: $selectedToolIds,
            isLoadingTools: isLoadingTools,
            onRefreshTools: onRefreshTools,
            onFileAttachment: onFileAttachment,
            onPhotoAttachment: onPhotoAttachment,
            onCameraCapture: onCameraCapture,
            onWebAttachment: onWebAttachment,
            onFilesAttachment: onFilesAttachment,
            onNotesAttachment: onNotesAttachment,
            onKnowledgeAttachment: onKnowledgeAttachment,
            onReferenceChatAttachment: onReferenceChatAttachment,
            apiClient: apiClient,
            notesManager: notesManager,
            conversationManager: conversationManager,
            selectedNotes: $selectedNotes,
            selectedKnowledgeItems: $selectedKnowledgeItems,
            selectedReferenceChats: $selectedReferenceChats,
            onFilesSelected: onFilesSelected,
            photoPicker: photoPicker,
            onOpenToolUserValves: onOpenToolUserValves,
            isNotesEnabled: true,
            skills: skills,
            selectedSkillIds: $selectedSkillIds,
            isLoadingSkills: isLoadingSkills,
            isToolPermissionsEnabled: isToolPermissionsEnabled,
            toolApprovalMode: toolApprovalMode,
            onToolApprovalModeChange: onToolApprovalModeChange,
            onCloseCard: { action in closeMorph(then: action) },
            onOpenCamera: onCameraCaptured != nil ? { showCameraFromMenu() } : nil,
            onExpandedChange: { expanded in
                withAnimation(MorphCardMetrics.spring) { morphMenuExpanded = expanded }
            },
            contentRevealed: revealed
        )
    }
}
