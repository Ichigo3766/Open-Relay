import SwiftUI

/// The toolbar and sidebar share the existing monitor; displaying status never starts a check.
struct ConnectionStatusButton: View {
    var isSidebar = false
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var showServerSwitcher = false

    private var monitor: ServerConnectionMonitor { dependencies.connectionMonitor }
    private var tint: Color { monitor.connectionState == .connected ? theme.success : theme.warning }

    var body: some View {
        Group {
            if isSidebar || monitor.connectionState != .connected {
                Menu {
                    Text(monitor.disconnectTitle)
                    if monitor.connectionState != .connected {
                        Text("You can keep reading saved chats and editing your draft.")
                        Button("Retry Connection", systemImage: "arrow.clockwise") {
                            monitor.triggerImmediateCheck()
                        }
                    }
                    if monitor.canSwitchServer {
                        Button("Switch Server", systemImage: "arrow.left.arrow.right") {
                            showServerSwitcher = true
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if monitor.connectionState == .checking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: monitor.disconnectIcon)
                                .font(.system(size: isSidebar ? 9 : 12, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                        Text(isSidebar ? "Open Relay" : monitor.disconnectTitle)
                            .scaledFont(size: isSidebar ? 13 : 11, weight: .medium)
                            .foregroundStyle(isSidebar ? theme.textPrimary : tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, isSidebar ? 0 : 8)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Connection: " + monitor.disconnectTitle)
                .accessibilityIdentifier(isSidebar ? "sidebar-connection-status" : "connection-status")
            }
        }
        .sheet(isPresented: $showServerSwitcher) {
            NavigationStack {
                ScrollView {
                    SavedServersView(viewModel: dependencies.authViewModel,
                                     showAddServerButton: true,
                                     onDismiss: { showServerSwitcher = false })
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Switch Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { showServerSwitcher = false }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .onChange(of: dependencies.authViewModel.phase) { _, phase in
            if phase == .authenticated || phase == .authMethodSelection { showServerSwitcher = false }
        }
    }
}
