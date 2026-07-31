import Foundation
import os.log

// MARK: - Event Webhook Models

struct EventWebhook: Identifiable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var events: [String]
    var targets: [EventWebhookTarget]?

    var isAllEvents: Bool { events.contains("*") }

    var eventSummary: String {
        if isAllEvents { return "All events" }
        if events.count <= 2 { return events.joined(separator: " + ") }
        return "\(events.count) filters"
    }

    var urlHost: String {
        URL(string: url)?.host ?? url
    }

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        name = json["name"] as? String ?? ""
        url = json["url"] as? String ?? ""
        enabled = json["enabled"] as? Bool ?? true
        events = json["events"] as? [String] ?? ["*"]
        if let targetsArr = json["targets"] as? [[String: Any]] {
            targets = targetsArr.map { EventWebhookTarget(from: $0) }
        } else if let _ = json["targets"] {
            targets = []  // null → system only
        } else {
            targets = nil  // absent → all
        }
    }

    func toPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "name": name,
            "url": url,
            "enabled": enabled,
            "events": events.isEmpty ? ["*"] : events
        ]
        if let targets {
            payload["targets"] = targets.map { ["type": $0.type, "id": $0.id] }
        } else {
            payload["targets"] = NSNull()
        }
        return payload
    }
}

struct EventWebhookTarget: Identifiable {
    var id: String
    var type: String  // "user" or "group"

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? ""
        type = json["type"] as? String ?? "user"
    }
}

struct EventCatalogItem: Identifiable {
    var id: String { event }
    var event: String
    var message: String

    init(from json: [String: Any]) {
        event = json["event"] as? String ?? ""
        message = json["message"] as? String ?? ""
    }
}

// MARK: - AdminEventsViewModel

@Observable
final class AdminEventsViewModel {

    // MARK: - State

    var isLoading = false
    var error: String?

    var webhooks: [EventWebhook] = []
    var eventCatalog: [EventCatalogItem] = []

    // Editor
    var showEditor = false
    var editingWebhookId: String? = nil
    var editorName = ""
    var editorURL = ""
    var editorEnabled = true
    var editorEvents: [String] = ["*"]
    var editorTargetMode: TargetMode = .all
    var editorTargetUserIds: [String] = []
    var editorTargetGroupIds: [String] = []
    var editorEventSearchText = ""

    var isSaving = false
    var showDeleteConfirm = false

    enum TargetMode: String, CaseIterable {
        case all = "All users and system events"
        case system = "System events only"
        case selected = "Specific users or groups"
    }

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminEvents")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        error = nil
        do {
            async let catalogTask = api.getEventCatalog()
            async let webhooksTask = api.getEventWebhooks()
            let (catalogRaw, webhooksRaw) = try await (catalogTask, webhooksTask)
            eventCatalog = catalogRaw.map { EventCatalogItem(from: $0) }.sorted { $0.event < $1.event }
            webhooks = webhooksRaw.map { EventWebhook(from: $0) }.sorted { a, b in
                if a.id == "default" { return true }
                if b.id == "default" { return false }
                return a.name < b.name
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Editor

    func openCreate() {
        editingWebhookId = nil
        editorName = ""
        editorURL = ""
        editorEnabled = true
        editorEvents = ["*"]
        editorTargetMode = .all
        editorTargetUserIds = []
        editorTargetGroupIds = []
        editorEventSearchText = ""
        showEditor = true
    }

    func openEdit(_ webhook: EventWebhook) {
        editingWebhookId = webhook.id
        editorName = webhook.name
        editorURL = webhook.url
        editorEnabled = webhook.enabled
        editorEvents = webhook.events.isEmpty ? ["*"] : webhook.events
        if let targets = webhook.targets {
            if targets.isEmpty {
                editorTargetMode = .system
            } else {
                editorTargetMode = .selected
                editorTargetUserIds = targets.filter { $0.type == "user" }.map { $0.id }
                editorTargetGroupIds = targets.filter { $0.type == "group" }.map { $0.id }
            }
        } else {
            editorTargetMode = .all
        }
        editorEventSearchText = ""
        showEditor = true
    }

    func saveWebhook() async {
        guard let api = apiClient else { return }
        isSaving = true
        error = nil

        var targets: [EventWebhookTarget]?
        switch editorTargetMode {
        case .all:    targets = nil
        case .system: targets = []
        case .selected:
            targets = editorTargetUserIds.map { EventWebhookTarget(from: ["type": "user", "id": $0]) }
                    + editorTargetGroupIds.map { EventWebhookTarget(from: ["type": "group", "id": $0]) }
        }

        var webhook = EventWebhook(from: [:])
        webhook.id = editingWebhookId ?? ""
        webhook.name = editorName.isEmpty ? (editingWebhookId == "default" ? "Default webhook" : "Webhook") : editorName
        webhook.url = editorURL
        webhook.enabled = editorEnabled
        webhook.events = editorEvents.isEmpty ? ["*"] : editorEvents
        webhook.targets = targets

        do {
            if let id = editingWebhookId {
                _ = try await api.updateEventWebhook(id: id, webhook.toPayload())
            } else {
                _ = try await api.createEventWebhook(webhook.toPayload())
            }
            showEditor = false
            await load()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    func deleteWebhook(id: String) async {
        guard let api = apiClient else { return }
        do {
            try await api.deleteEventWebhook(id: id)
            showEditor = false
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleWebhook(_ webhook: EventWebhook) async {
        guard let api = apiClient else { return }
        var updated = webhook
        updated.enabled = !webhook.enabled
        do {
            _ = try await api.updateEventWebhook(id: webhook.id, ["enabled": updated.enabled])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Events Editor Helpers

    var isAllEvents: Bool {
        get { editorEvents.contains("*") }
        set {
            if newValue { editorEvents = ["*"] } else { editorEvents = [] }
        }
    }

    var filteredCatalog: [EventCatalogItem] {
        let q = editorEventSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return eventCatalog }
        return eventCatalog.filter { $0.event.lowercased().contains(q) }
    }

    func toggleEvent(_ event: String) {
        var set = Set(editorEvents.filter { $0 != "*" })
        if set.contains(event) {
            set.remove(event)
        } else {
            set.insert(event)
        }
        editorEvents = set.sorted()
    }

    func removeEventFilter(_ event: String) {
        editorEvents.removeAll { $0 == event }
        if editorEvents.isEmpty { editorEvents = ["*"] }
    }
}
