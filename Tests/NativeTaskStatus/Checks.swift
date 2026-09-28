import Foundation

@main struct Checks {
    @MainActor static func main() async {
        let h = Harness()
        #if BASELINE
        h.updateTaskStatus(taskId: "paper", newStatus: "completed")
        await Task.yield()
        precondition(h.tasks[0].status == "pending", "A failed unsupported update must not be shown as saved progress")
        #else
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        h.applyTaskUpdate(["tasks": [["id": "paper", "content": "Fold paper", "status": "completed"]]])
        check(h.tasks[0].isCompleted, "Live server snapshot updates visible status")
        check(h.conversation?.tasks == h.tasks, "Chat state and panel stay consistent")
        let completed = h.tasks
        for malformed: [String: Any]? in [nil, [:], ["tasks": "invalid"], ["tasks": [["id": "paper", "status": "pending"]]]] {
            h.applyTaskUpdate(malformed)
            check(h.tasks == completed, "Malformed event preserves last authoritative snapshot")
        }
        h.applyTaskUpdate(["tasks": [["id": "same", "content": "A", "status": "pending"], ["id": "same", "content": "B", "status": "pending"]]])
        check(h.tasks == completed, "Duplicate IDs cannot corrupt list identity")
        h.applyTaskUpdate(["tasks": []])
        check(h.tasks.isEmpty && h.conversation?.tasks.isEmpty == true, "Explicit empty snapshot clears tasks")
        let statuses = ["pending", "in_progress", "completed", "cancelled"]
        h.applyTaskUpdate(["tasks": statuses.map { ["id": $0, "content": "Paper \($0)", "status": $0] }])
        check(h.tasks.map(\.status) == statuses, "All native states and order preserved")
        h.applyTaskUpdate(["tasks": statuses.map { ["id": $0, "content": "Paper \($0)", "status": $0] }])
        check(h.tasks.count == 4, "Duplicate snapshot is idempotent")
        h.conversation = nil
        h.applyTaskUpdate(["tasks": []])
        check(h.tasks.isEmpty, "No conversation required to clear visible tasks")
        print("\(checks) task snapshot checks passed; active/passive routing and read-only source checks passed")
        #endif
    }
}
