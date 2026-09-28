"""Compile the native event draft against synthetic event inputs only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
models = (root / "Open UI/Core/Models/CalendarModels.swift").read_text().replace("import SwiftUI", "")
color = "struct Color { static let blue = Color(); init() {}; init?(hex: String) {} }\n"
def method(text, signature):
    start = text.index(signature)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

api = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
wire = (root / "Tests/CalendarEditing/Stubs.swift").read_text()
wire += "\nfinal class WireClient { let network = Network()\n"
wire += method(api, "    func getCalendarEvent(") + "\n" + method(api, "    func saveCalendarEvent(") + "\n}\n"
detail = (root / "Open UI/Features/Calendar/Views/CalendarEventDetailView.swift").read_text()
wire += "struct DetailProbe { var event: CalendarEvent\n" + method(detail, "    private var reminderLabel:").replace("private var", "var") + "\n}\n"
vm = (root / "Open UI/Features/Calendar/ViewModels/CalendarViewModel.swift").read_text()
wire += "final class ActionProbe { let apiClient = EventAPI(); var selectedEvent: CalendarEvent?; var events: [CalendarEvent] = []; var errorMessage: String?\n"
wire += "func loadEventsForDisplayedMonth() async { do { events = try apiClient.refresh() } catch { errorMessage = error.localizedDescription } }\n"
wire += method(vm, "    func saveEvent(") + "\n}\n"
with tempfile.TemporaryDirectory(prefix="relay-calendar-editing-") as directory:
    work = Path(directory)
    (work / "Models.swift").write_text(models + color + wire)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Models.swift"),
        str(root / "Open UI/Core/Models/CalendarEventDraft.swift"),
        str(root / "Tests/CalendarEditing/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
