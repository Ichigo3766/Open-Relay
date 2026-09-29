"""Compile production calendar models/methods against synthetic transport only."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
here = Path(__file__).resolve().parent
models = (root / "Open UI/Core/Models/CalendarModels.swift").read_text()
if "--baseline" in sys.argv:
    models = subprocess.check_output(["git", "show", "4151a735:Open UI/Core/Models/CalendarModels.swift"], cwd=root, text=True)
source = models.replace("import SwiftUI", "")
source += "\nstruct Color { static let blue = Color(); init() {}; init?(hex: String) {} }\n"

def method(text, signature):
    start = text.index(signature)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

test = "Reproduction.swift"
if "--actions" in sys.argv:
    api = (root / "Open UI/Core/Networking/APIClient.swift").read_text()
    vm = (root / "Open UI/Features/Calendar/ViewModels/CalendarViewModel.swift").read_text()
    source += (here / "Stubs.swift").read_text()
    source += "\n@MainActor final class APIClient { let network = Network()\n"
    source += method(api, "    func respondToCalendarEvent(") + "\n}\n"
    source += "@MainActor final class ActionProbe { let apiClient: APIClient; private let rsvpScope: String?; var respondingEventIds: Set<String> = []; var events: [CalendarEvent] = []; var selectedEvent: CalendarEvent?\n"
    source += method(vm, "    init(apiClient:") + "\n"
    source += method(vm, "    func respondToEvent(") + "\n}\n"
    test = "Checks.swift"

with tempfile.TemporaryDirectory(prefix="calendar-rsvp-") as directory:
    work = Path(directory)
    (work / "Source.swift").write_text(source)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Source.swift"), str(here / test), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
