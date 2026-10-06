//
//  OpenUIWidgetsControl.swift
//  OpenUIWidgets
//
//  Control Center widget (iOS 18+) — one-tap "New Chat" button.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - New Chat Control Button

struct OpenUIWidgetsControl: ControlWidget {
    static let kind: String = "com.openui.openui.OpenUINewChatControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNewChatControlIntent()) {
                Label("New Chat", systemImage: "bubble.left.and.text.bubble.right.fill")
            }
        }
        .displayName("New Chat")
        .description("Start a new AI chat instantly from Control Center.")
    }
}

// `OpenNewChatControlIntent` lives in `Open UI/Shared/Widgets/ControlCenterIntents.swift`
// and is compiled into both the app and this extension. That's required for an
// `openAppWhenRun` control intent to actually run in the app when tapped.
