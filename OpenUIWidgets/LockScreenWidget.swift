//
//  LockScreenWidget.swift
//  OpenUIWidgets
//
//  Lock Screen accessories for Open Relay, styled after Apple's own
//  Lock Screen widgets (system text styles, `AccessoryWidgetBackground`,
//  single-tint SF Symbols that follow the user's Lock Screen colour).
//
//  • LockScreenWidget  — "New Chat" (circular / rectangular / inline)
//  • VoiceLockScreenWidget  — "Voice" (circular)
//  • CameraLockScreenWidget — "Camera" (circular)
//
//  Taps are handled with `.widgetURL(_:)` — the only reliable way to open the
//  app from a Lock Screen accessory. (Interactive `Button(intent:)` with an
//  extension-only `OpenURLIntent` silently did nothing on tap.) The URLs are
//  routed by `handleDeepLink` in `Open_UIApp.swift`.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

/// Static provider — lock-screen accessories have no time-varying content.
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (LockScreenEntry) -> Void
    ) {
        completion(LockScreenEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<LockScreenEntry>) -> Void
    ) {
        let entry = LockScreenEntry(date: Date())
        let nextUpdate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Timeline Entry

struct LockScreenEntry: TimelineEntry {
    let date: Date
}

// MARK: - Widget Configurations

/// "New Chat" — the primary Lock Screen widget. Keeps the original `kind`
/// so widgets users have already placed keep working after updating.
struct LockScreenWidget: Widget {
    static let kind: String = "com.openui.openui.LockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenProvider()) { _ in
            NewChatAccessoryView()
        }
        .configurationDisplayName("New Chat")
        .description("Start a new chat with Open Relay.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

/// "Voice" — one tap into a voice call.
struct VoiceLockScreenWidget: Widget {
    static let kind: String = "com.openui.openui.VoiceLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenProvider()) { _ in
            CircularActionView(symbol: "waveform", accessibilityText: "Start Voice Call")
                .widgetURL(OpenUIURL.voiceCall)
        }
        .configurationDisplayName("Voice")
        .description("Start a voice call with Open Relay.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// "Camera" — new chat with the camera already open.
struct CameraLockScreenWidget: Widget {
    static let kind: String = "com.openui.openui.CameraLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenProvider()) { _ in
            CircularActionView(symbol: "camera.fill", accessibilityText: "Camera Chat")
                .widgetURL(OpenUIURL.cameraChat)
        }
        .configurationDisplayName("Camera")
        .description("Snap a photo and ask Open Relay about it.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - New Chat Views

/// Picks the right layout for each accessory family. The whole widget is a
/// single tap target that opens `openui://new-chat`.
private struct NewChatAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                NewChatRectangularView()
            case .accessoryInline:
                NewChatInlineView()
            default:
                CircularActionView(symbol: "plus.bubble.fill", accessibilityText: "New Chat")
            }
        }
        .widgetURL(OpenUIURL.newChat)
    }
}

// MARK: - Shared Circular Accessory

/// Circular accessory in the system style: the adaptive Lock Screen backdrop
/// with a single centred SF Symbol that picks up the user's Lock Screen tint.
private struct CircularActionView: View {
    let symbol: String
    let accessibilityText: String

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .widgetAccentable()
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - accessoryRectangular

/// Laid out like Apple's Calendar / Reminders accessories: a small tinted
/// app caption on top, a headline, then a secondary line.
private struct NewChatRectangularView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text("Open Relay")
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
            }
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .widgetAccentable()

            Text("New Chat")
                .font(.headline)

            Text("Ask anything…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Relay, New Chat")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - accessoryInline

/// Single line above the clock. Falls back to a shorter label when space is tight.
private struct NewChatInlineView: View {
    var body: some View {
        ViewThatFits {
            Label("Ask Open Relay", systemImage: "plus.bubble.fill")
            Label("New Chat", systemImage: "plus.bubble.fill")
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Previews

#Preview("New Chat · Circular", as: .accessoryCircular) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("New Chat · Rectangular", as: .accessoryRectangular) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("New Chat · Inline", as: .accessoryInline) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("Voice", as: .accessoryCircular) {
    VoiceLockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("Camera", as: .accessoryCircular) {
    CameraLockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}
