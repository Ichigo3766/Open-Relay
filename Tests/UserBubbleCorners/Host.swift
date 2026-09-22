import SwiftUI

// The component needs only the role, not the app's networking or chat storage.
enum MessageRole { case user, assistant, system }

@main struct BubbleTestHost: App {
    var body: some Scene {
        WindowGroup { BubbleExamples().themed() }
    }
}

struct BubbleExamples: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Message bubbles")
                .font(.title2.bold())
                .padding(.horizontal, Spacing.screenPadding)
            ChatMessageBubble(role: .assistant) {
                Text("Let's plan a small craft project.")
            }
            ChatMessageBubble(role: .user) {
                Text("A paper lantern.")
            }
            ChatMessageBubble(role: .assistant) {
                Text("Choose the materials and colors.")
            }
            ChatMessageBubble(role: .user) {
                Text("Use blue paper, yellow stars, and a small handle.")
            }
            ChatMessageBubble(role: .assistant) {
                Text("Add any final details.")
            }
            ChatMessageBubble(role: .user) {
                Text("Cut the paper.\nFold the corners.\nAdd yellow stars.\nAttach a blue handle.")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.textPrimary)
        .padding(.vertical, 24)
        .background(theme.background)
    }
}
