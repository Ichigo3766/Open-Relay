//
//  OpenUIWidgetsBundle.swift
//  OpenUIWidgets
//

import WidgetKit
import SwiftUI

@main
struct OpenUIWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // Home screen widget — single resizable widget (drag to switch small ↔ medium)
        QuickActionsWidget()

        // Lock screen accessories
        LockScreenWidget()          // New Chat — accessoryCircular / accessoryRectangular / accessoryInline
        VoiceLockScreenWidget()     // Voice call — accessoryCircular
        CameraLockScreenWidget()    // Camera chat — accessoryCircular

        // Control Center (iOS 18+)
        OpenUIWidgetsControl()

        // Voice call — Dynamic Island + Lock Screen Live Activity
        VoiceCallLiveActivity()

        // Dictation — Dynamic Island + Lock Screen recording indicator
        DictationLiveActivity()
    }
}
