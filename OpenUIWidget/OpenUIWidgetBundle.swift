import WidgetKit
import SwiftUI

/// Entry point for the Open UI widget extension bundle.
@main
struct OpenUIWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentChatsWidget()
        QuickActionsWidget()
    }
}
