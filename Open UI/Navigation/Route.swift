import Foundation

/// Defines all navigable routes in the app.
enum Route: Hashable {
    case chatList
    case chatDetail(conversationId: String)
    case newChat
    case voiceCall(startNewConversation: Bool = false)
    case notesList
    case noteEditor(noteId: String)
    case settings
    case serverConnection
    case profile
    case appearance
    case serverManagement
    case privacySecurity
    case about
    case login
    case ldapLogin
    case ssoAuth
    case onboarding
}

extension Route: Identifiable {
    var id: Self { self }
}
