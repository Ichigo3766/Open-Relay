"""Compile actual calendar wire and management methods with synthetic transport."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
def method(text, signature):
    start = text.index(signature)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

api = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
vm = (root / "Open UI/Features/Calendar/ViewModels/CalendarViewModel.swift").read_text()
models = (root / "Open UI/Core/Models/CalendarModels.swift").read_text().replace("import SwiftUI", "")
wire = models + "\nstruct Color { static let blue = Color(); init() {}; init?(hex: String) {} }\n"
wire += (root / "Tests/CalendarManagement/Stubs.swift").read_text()
wire += "final class APIClient { let network = Network()\n"
for name in ["saveCalendar", "setDefaultCalendar", "deleteCalendar"]:
    wire += method(api, "    func " + name + "(") + "\n"
wire += "}\n@MainActor final class ActionProbe {\nlet apiClient: APIClient; private let calendarScope: String?; private let calendarUserId: String?\n"
wire += "var isManagingCalendars = false; var calendars: [OWCalendar] = []; var events: [CalendarEvent] = []\n"
wire += "var selectedEvent: CalendarEvent?; var visibleCalendarIds: Set<String> = []\n"
wire += method(vm, "    init(apiClient:") + "\n"
for signature in ["    private func manageCalendar<", "    func saveCalendar(", "    func makeDefaultCalendar(", "    func removeCalendar("]:
    wire += method(vm, signature) + "\n"
selector = vm
if "--baseline-default" in sys.argv:
    selector = subprocess.check_output(["git", "show", "4151a735:Open UI/Features/Calendar/ViewModels/CalendarViewModel.swift"], cwd=root, text=True)
wire += method(selector, "    var defaultCalendarId:") + "\n"
wire += "}\n"
with tempfile.TemporaryDirectory(prefix="relay-calendar-management-") as directory:
    work = Path(directory)
    (work / "Wire.swift").write_text(wire)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Wire.swift"),
        str(root / "Tests/CalendarManagement/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
