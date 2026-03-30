import SwiftUI

/// Centralized navigation state manager using NavigationStack paths.
@Observable
final class AppRouter {
    var path = NavigationPath()
    var channelPath = NavigationPath()
    var presentedSheet: Route?

    /// Whether the voice call full-screen cover is presented.
    var isVoiceCallPresented: Bool = false

    /// Whether the voice call has been minimized (sheet dismissed, but call still active).
    var isVoiceCallMinimized: Bool = false

    /// The voice call view model for the currently presented voice call.
    var voiceCallViewModel: VoiceCallViewModel?

    /// Navigates to a route by pushing onto the stack.
    func navigate(to route: Route) {
        path.append(route)
    }

    /// Pops back one level in the navigation stack.
    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Pops to the root of the navigation stack.
    func popToRoot() {
        path = NavigationPath()
    }

    /// Presents a route as a sheet.
    func presentSheet(_ route: Route) {
        presentedSheet = route
    }

    /// Dismisses the current sheet.
    func dismissSheet() {
        presentedSheet = nil
    }

    /// Presents the voice call as a full-screen cover with a pre-configured view model.
    func presentVoiceCall(viewModel: VoiceCallViewModel) {
        self.voiceCallViewModel = viewModel
        self.isVoiceCallMinimized = false
        self.isVoiceCallPresented = true
    }

    /// Minimizes the voice call — dismisses the sheet but keeps the call running.
    /// A floating pill overlay appears so the user can restore or end the call.
    func minimizeVoiceCall() {
        isVoiceCallPresented = false
        isVoiceCallMinimized = true
    }

    /// Restores the minimized voice call by re-presenting the full sheet.
    func expandVoiceCall() {
        isVoiceCallMinimized = false
        isVoiceCallPresented = true
    }

    /// Dismisses the voice call entirely (call ended).
    func dismissVoiceCall() {
        isVoiceCallPresented = false
        isVoiceCallMinimized = false
        voiceCallViewModel = nil
    }

    /// Resets all navigation state to root — called on server switch so stale
    /// screens (chat detail, settings, etc.) from the previous server don't persist.
    func resetAll() {
        path = NavigationPath()
        channelPath = NavigationPath()
        presentedSheet = nil
        if isVoiceCallPresented || isVoiceCallMinimized {
            isVoiceCallPresented = false
            isVoiceCallMinimized = false
            voiceCallViewModel = nil
        }
    }
}
