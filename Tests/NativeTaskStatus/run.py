"""Focused checks compile the actual task decoder/update method, with a stub chat."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    if baseline:
        return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True)
    return (root / path).read_text()

vm = source("Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
model = source("Open UI/Core/Models/Conversation.swift").split("// MARK: - Conversation")[0]
if baseline:
    method = vm[vm.index("    func updateTaskStatus("):vm.index("    private func cleanupStreaming()")]
else:
    method = vm[vm.index("    private func applyTaskUpdate("):vm.index("    private func cleanupStreaming()")].replace("private func", "func")
    assert vm.count('case "chat:message:tasks":') == 2, "Active and passive listeners must both handle native tasks"
    for obsolete in ["updateTaskStatus", "extractAndApplyTasksFromContent", "parseTaskJSON", "lastTaskExtractionLength"]:
        assert obsolete not in vm
    assert "updateChatTask" not in source("Open UI/Core/Networking/APIClient.swift")
    row = source("Open UI/Shared/Components/TaskListView.swift").split("private struct TaskRowView:")[1]
    assert "Button(" not in row and "onToggle" not in row
    assert ".accessibilityValue(task.status" in row

stub = '''
struct Chat { var id = "demo"; var tasks: [ChatTask] }
struct API { func updateChatTask(chatId: String, taskId: String, status: String) async throws { throw NSError(domain: "Synthetic404", code: 404) } }
struct Manager { let apiClient = API() }
@MainActor final class Harness {
    var tasks = [ChatTask(id: "paper", content: "Fold paper", status: "pending")]
    var conversation: Chat? = Chat(tasks: [ChatTask(id: "paper", content: "Fold paper", status: "pending")])
    var conversationId: String? = "demo"
    var manager: Manager? = Manager()
'''
with tempfile.TemporaryDirectory(prefix="relay-task-status-") as directory:
    directory = pathlib.Path(directory)
    production = directory / "Production.swift"
    production.write_text(model + stub + method + "\n}\n")
    binary = directory / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(production), str(root / "Tests/NativeTaskStatus/Checks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
