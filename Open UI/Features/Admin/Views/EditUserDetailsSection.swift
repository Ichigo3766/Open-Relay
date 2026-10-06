import SwiftUI

extension APIClient {
    /// GET /users/{id}/groups (admin) → group names.
    func getUserGroupNames(userId: String) async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/users/\(userId)/groups")
        let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return arr.compactMap { $0["name"] as? String }
    }

    /// GET /users/{id}/active → online now?
    func isUserActive(userId: String) async throws -> Bool {
        let json = try await network.requestJSON(path: "/api/v1/users/\(userId)/active")
        return json["active"] as? Bool ?? false
    }

    /// GET /users/{id}/oauth/sessions (admin). The server answers 400 when there are none.
    func getUserOAuthSessions(userId: String) async -> [(provider: String, expiresAt: Int)] {
        guard let (data, _) = try? await network.requestRaw(path: "/api/v1/users/\(userId)/oauth/sessions"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.map { ($0["provider"] as? String ?? "?", $0["expires_at"] as? Int ?? 0) }
    }
}

/// Edit User → groups, online status, connected OAuth sessions (read-only).
struct EditUserDetailsSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    let userId: String

    @State private var groups: [String]?
    @State private var active: Bool?
    @State private var sessions: [(provider: String, expiresAt: Int)] = []

    var body: some View {
        SettingsSection(header: "Details") {
            VStack(alignment: .leading, spacing: 0) {
                row("Status") {
                    if let active {
                        HStack(spacing: 6) {
                            Circle().fill(active ? Color.green : Color.gray).frame(width: 8, height: 8)
                            Text(active ? "Online" : "Offline")
                        }
                    } else { ProgressView().controlSize(.small) }
                }
                Divider().padding(.leading, Spacing.md)
                row("Groups") {
                    if let groups {
                        Text(groups.isEmpty ? "None" : groups.joined(separator: ", ")).multilineTextAlignment(.trailing)
                    } else { ProgressView().controlSize(.small) }
                }
                if !sessions.isEmpty {
                    Divider().padding(.leading, Spacing.md)
                    row("OAuth Sessions") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                                Text("\(s.provider) · expires \(Date(timeIntervalSince1970: TimeInterval(s.expiresAt)).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .task(id: userId) {
            guard let api = dependencies.apiClient else { return }
            async let g = try? api.getUserGroupNames(userId: userId)
            async let a = try? api.isUserActive(userId: userId)
            async let s = api.getUserOAuthSessions(userId: userId)
            groups = await g ?? []
            active = await a ?? false
            sessions = await s
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .top) {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textSecondary)
            Spacer()
            value().scaledFont(size: 14).foregroundStyle(theme.textPrimary)
        }
        .padding(Spacing.md)
    }
}
